// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {PVTToken} from "./PVTToken.sol";
import {SigmoidMath} from "./SigmoidMath.sol";
import {RAMMToken} from "./RAMMToken.sol";
import {RedemptionNFT} from "./RedemptionNFT.sol";
import {VestingVault} from "./VestingVault.sol";
import {PromoStaking} from "./PromoStaking.sol";
import {RammRegistry} from "./RammRegistry.sol";

/// @title IMPXMarketUpgradeable — Per-campaign bonding curve market compatible with BeaconProxy and ERC1967Proxy.
/// @dev No UUPSUpgradeable/_authorizeUpgrade here — correct for the Beacon Proxy
///      pattern this is meant to be deployed behind: upgrade authority lives in
///      the shared UpgradeableBeacon, not in each market's own implementation.
///      ReentrancyGuard (not ReentrancyGuardUpgradeable) — see the note in
///      VestingVaultUpgradeable.sol.
contract IMPXMarketUpgradeable is OwnableUpgradeable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SigmoidMath for uint256;

    // Config & State
    IERC20 public usdc;
    PVTToken public pvt;
    RammRegistry public registry;

    uint256 public PROMOTER_BPS;
    uint256 public currentSupply;
    bool public isSecondaryMarket;

    uint256 public CURVE_B;
    uint256 public CURVE_C;
    uint256 public CURVE_P;
    uint256 public CURVE_A_PRIMARY;
    uint256 public CURVE_A_SECONDARY;

    uint256 public accruedRevenue;
    uint256 public constant RAMM_PER_PVT = 100 * 1e18;

    uint256 public BRAND_BPS;
    uint256 public CAMPAIGN_BPS;

    uint256 public SELL_SPREAD_BPS;
    uint256 public SELL_BRAND_BPS;
    uint256 public SELL_CAMPAIGN_BPS;

    address public brandWallet;
    address public campaignWallet;

    /// @notice Storage gap for market state expansion
    uint256[50] private __gap;

    event SwapSuccess(
        address indexed buyer,
        uint256 quantity,
        uint256 totalCostUsdc,
        uint256 newSupply,
        uint256 rammRewarded,
        uint256 timestamp
    );

    event SwapFailed(
        address indexed buyer,
        uint256 quantity,
        uint256 quotedCost,
        uint256 actualCost,
        string reason
    );

    event MarketTransition(uint256 supplyAtTransition, uint256 timestamp);

    event SellSuccess(
        address indexed seller,
        uint256 quantity,
        uint256 grossProceeds,
        uint256 netProceeds,
        uint256 newSupply,
        uint256 timestamp
    );

    event RevenueSplit(uint256 brandShare, uint256 campaignShare, uint256 timestamp);
    event ReferralCredited(address indexed promoter, address indexed buyer, uint256 amount, uint256 timestamp);
    event RevenueWithdrawn(address indexed to, uint256 amount, uint256 timestamp);
    event LiquidityDeposited(address indexed from, uint256 amount, uint256 timestamp);

    event RedeemSuccess(
        address indexed redeemer,
        uint256 quantity,
        uint256 newSupply,
        uint256 nftTokenId,
        uint256 timestamp
    );

    error SlippageExceeded(uint256 actualCost, uint256 maxCost);
    error InsufficientUSDCAllowance(uint256 required, uint256 allowed);
    error InsufficientUSDCBalance(uint256 required, uint256 available);
    error InsufficientContractUSDC(uint256 required, uint256 available);
    error InsufficientPVTHolding(uint256 required, uint256 available);
    error CannotSellMoreThanSupply(uint256 quantity, uint256 supply);
    error SoldOut(uint256 requested, uint256 remaining);
    error ZeroQuantity();
    error NoRevenue();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _usdc,
        address _pvt,
        address _registry,
        address _brandWallet,
        address _campaignWallet,
        address _initialOwner,
        uint16 _buyBrandBps,
        uint16 _buyCampaignBps,
        uint16 _sellBrandBps,
        uint16 _sellCampaignBps,
        uint16 _promoterBps,
        SigmoidMath.CurveParams memory _curve
    ) external initializer {
        require(_buyBrandBps + _buyCampaignBps == 10_000, "buy BPS must sum to 10000");
        require(_sellBrandBps + _sellCampaignBps <= 10_000, "sell BPS must not exceed 10000");
        require(_promoterBps <= _buyCampaignBps, "promoter BPS must not exceed campaign BPS");
        require(_curve.b > 0 && _curve.c > 0 && _curve.p > 0, "curve params must be non-zero");

        __Ownable_init(_initialOwner);
        usdc = IERC20(_usdc);
        pvt = PVTToken(_pvt);
        registry = RammRegistry(_registry);
        brandWallet = _brandWallet;
        campaignWallet = _campaignWallet;
        BRAND_BPS = _buyBrandBps;
        CAMPAIGN_BPS = _buyCampaignBps;
        SELL_BRAND_BPS = _sellBrandBps;
        SELL_CAMPAIGN_BPS = _sellCampaignBps;
        SELL_SPREAD_BPS = _sellBrandBps + _sellCampaignBps;
        PROMOTER_BPS = _promoterBps;
        CURVE_B = _curve.b;
        CURVE_C = _curve.c;
        CURVE_P = _curve.p;
        CURVE_A_PRIMARY = _curve.aPrimary;
        CURVE_A_SECONDARY = _curve.aSecondary;
    }

    function _curveParams() internal view returns (SigmoidMath.CurveParams memory) {
        return SigmoidMath.CurveParams({
            b: CURVE_B, c: CURVE_C, p: CURVE_P,
            aPrimary: CURVE_A_PRIMARY, aSecondary: CURVE_A_SECONDARY
        });
    }

    function _rammToken() internal view returns (RAMMToken) {
        return RAMMToken(registry.rammToken());
    }

    function _redemptionNFT() internal view returns (RedemptionNFT) {
        return RedemptionNFT(registry.redemptionNFT());
    }

    function _vestingVault() internal view returns (VestingVault) {
        return VestingVault(registry.vestingVault());
    }

    function _promoStaking() internal view returns (PromoStaking) {
        return PromoStaking(registry.promoStaking());
    }

    function _decodeReferrer(bytes calldata referralCode) private pure returns (address) {
        if (referralCode.length != 32) return address(0);
        return abi.decode(referralCode, (address));
    }

    function swapUSDCForPVT(
        address productId,
        uint256 quantity,
        uint256 maxUsdcCost,
        bytes calldata referralCode
    )
        external
        nonReentrant
        returns (bool success)
    {
        require(productId == address(pvt), "Wrong productId");
        if (quantity == 0) revert ZeroQuantity();

        uint256 remaining = pvt.remainingSupply();
        if (quantity > remaining) revert SoldOut(quantity, remaining);

        uint256 actualCost = SigmoidMath.getTotalCost(currentSupply, quantity, _curveParams());

        if (actualCost > maxUsdcCost) {
            emit SwapFailed(msg.sender, quantity, maxUsdcCost, actualCost, "SLIPPAGE_EXCEEDED");
            revert SlippageExceeded(actualCost, maxUsdcCost);
        }

        uint256 allowed = usdc.allowance(msg.sender, address(this));
        if (allowed < actualCost) revert InsufficientUSDCAllowance(actualCost, allowed);

        uint256 buyerBalance = usdc.balanceOf(msg.sender);
        if (buyerBalance < actualCost) revert InsufficientUSDCBalance(actualCost, buyerBalance);

        usdc.safeTransferFrom(msg.sender, address(this), actualCost);

        uint256 brandShare = (actualCost * BRAND_BPS) / 10_000;
        uint256 campaignShare = actualCost - brandShare;

        address promoter = _decodeReferrer(referralCode);
        uint256 promoterCut = 0;
        if (promoter != address(0) && promoter != msg.sender && _promoStaking().isPromoter(promoter)) {
            promoterCut = (actualCost * PROMOTER_BPS) / 10_000;
            campaignShare -= promoterCut;
        }

        usdc.safeTransfer(brandWallet, brandShare);
        if (campaignShare > 0) usdc.safeTransfer(campaignWallet, campaignShare);
        if (promoterCut > 0) {
            VestingVault vault = _vestingVault();
            usdc.safeTransfer(address(vault), promoterCut);
            vault.credit(promoter, promoterCut);
            emit ReferralCredited(promoter, msg.sender, promoterCut, block.timestamp);
        }

        accruedRevenue += actualCost;
        emit RevenueSplit(brandShare, campaignShare, block.timestamp);

        currentSupply += quantity;

        if (!isSecondaryMarket && currentSupply >= CURVE_B) {
            isSecondaryMarket = true;
            emit MarketTransition(currentSupply, block.timestamp);
        }

        pvt.mint(msg.sender, quantity);

        uint256 rammReward = quantity * RAMM_PER_PVT;
        try _rammToken().mint(msg.sender, rammReward) {} catch {}

        emit SwapSuccess(msg.sender, quantity, actualCost, currentSupply, rammReward, block.timestamp);
        return true;
    }

    function getCurrentPrice() external view returns (uint256 price) {
        return SigmoidMath.getPrice(currentSupply, _curveParams());
    }

    function getQuote(uint256 quantity) external view returns (uint256 totalCost) {
        return SigmoidMath.getTotalCost(currentSupply, quantity, _curveParams());
    }

    function getMarketState()
        external
        view
        returns (
            uint256 supply,
            uint256 supplyCap,
            uint256 remaining,
            uint256 currentPrice,
            bool secondaryMarket
        )
    {
        supply = currentSupply;
        supplyCap = pvt.supplyCap();
        remaining = pvt.remainingSupply();
        currentPrice = SigmoidMath.getPrice(currentSupply, _curveParams());
        secondaryMarket = isSecondaryMarket;
    }

    function getSellQuote(uint256 quantity)
        external
        view
        returns (uint256 grossProceeds, uint256 netProceeds)
    {
        if (quantity == 0 || quantity > currentSupply) return (0, 0);
        grossProceeds = SigmoidMath.getTotalCost(currentSupply - quantity, quantity, _curveParams());
        uint256 sellBrandFee = (grossProceeds * SELL_BRAND_BPS) / 10_000;
        uint256 sellCampaignFee = (grossProceeds * SELL_CAMPAIGN_BPS) / 10_000;
        netProceeds = grossProceeds - sellBrandFee - sellCampaignFee;
    }

    function sellPVT(address productId, uint256 quantity, uint256 minUsdcReturn)
        external
        nonReentrant
        returns (bool success)
    {
        require(productId == address(pvt), "Wrong productId");
        if (quantity == 0) revert ZeroQuantity();
        if (quantity > currentSupply) revert CannotSellMoreThanSupply(quantity, currentSupply);

        uint256 sellerBalance = pvt.balanceOf(msg.sender);
        if (sellerBalance < quantity) revert InsufficientPVTHolding(quantity, sellerBalance);

        uint256 grossProceeds = SigmoidMath.getTotalCost(currentSupply - quantity, quantity, _curveParams());
        uint256 sellBrandFee = (grossProceeds * SELL_BRAND_BPS) / 10_000;
        uint256 sellCampaignFee = (grossProceeds * SELL_CAMPAIGN_BPS) / 10_000;
        uint256 netProceeds = grossProceeds - sellBrandFee - sellCampaignFee;

        if (netProceeds < minUsdcReturn) revert SlippageExceeded(netProceeds, minUsdcReturn);

        uint256 contractUsdcBal = usdc.balanceOf(address(this));
        if (contractUsdcBal < grossProceeds) revert InsufficientContractUSDC(grossProceeds, contractUsdcBal);

        pvt.burnFrom(msg.sender, quantity);
        currentSupply -= quantity;
        if (accruedRevenue >= grossProceeds) accruedRevenue -= grossProceeds;
        else accruedRevenue = 0;

        usdc.safeTransfer(msg.sender, netProceeds);
        usdc.safeTransfer(brandWallet, sellBrandFee);
        usdc.safeTransfer(campaignWallet, sellCampaignFee);

        emit SellSuccess(msg.sender, quantity, grossProceeds, netProceeds, currentSupply, block.timestamp);
        return true;
    }

    function redeemPVT(address productId, uint256 quantity)
        external
        nonReentrant
        returns (uint256 nftTokenId)
    {
        require(productId == address(pvt), "Wrong productId");
        if (quantity == 0) revert ZeroQuantity();

        uint256 redeemerBalance = pvt.balanceOf(msg.sender);
        if (redeemerBalance < quantity) revert InsufficientPVTHolding(quantity, redeemerBalance);

        pvt.burnFrom(msg.sender, quantity);
        if (currentSupply >= quantity) currentSupply -= quantity;

        nftTokenId = _redemptionNFT().mint(msg.sender, address(pvt), pvt.productName(), quantity);

        emit RedeemSuccess(msg.sender, quantity, currentSupply, nftTokenId, block.timestamp);
    }

    function depositLiquidity(uint256 amount) external {
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        emit LiquidityDeposited(msg.sender, amount, block.timestamp);
    }

    function withdrawRevenue(address to) external onlyOwner {
        uint256 amount = usdc.balanceOf(address(this));
        if (amount == 0) revert NoRevenue();
        accruedRevenue = 0;
        usdc.safeTransfer(to, amount);
        emit RevenueWithdrawn(to, amount, block.timestamp);
    }
}
