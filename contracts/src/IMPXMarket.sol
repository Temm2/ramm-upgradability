// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {PVTToken} from "./PVTToken.sol";
import {SigmoidMath} from "./SigmoidMath.sol";
import {RAMMToken} from "./RAMMToken.sol";
import {RedemptionNFT} from "./RedemptionNFT.sol";
import {VestingVault} from "./VestingVault.sol";
import {PromoStaking} from "./PromoStaking.sol";
import {RammRegistry} from "./RammRegistry.sol";

/// @title IMPXMarket — per-campaign wallet revenue split
/// @notice Sigmoidal bonding curve AMM for RAMM drops.
///
/// Revenue split on each buy:
///   93% → brandWallet  (brand's custodial wallet, controlled by VALET)
///    7% → campaignWallet (per-campaign treasury, controlled by VALET)
///
/// Revenue split on each sell (buyback):
///   93% → seller
///    5% → brandWallet  (brand recoups partial liquidity)
///    2% → campaignWallet (promoter distribution)
///
/// NOTE: Buy proceeds are routed immediately to brandWallet/campaignWallet.
///       For sell to work the contract needs USDC liquidity — call
///       depositLiquidity() to fund the buyback pool before allowing sells.
///
/// Buy flow:
///   1. USDC.approve(market, maxCost)
///   2. swapUSDCForPVT(productId, qty, maxCost, referralCode)
///
/// Sell flow:
///   1. market.sellPVT(productId, qty, minReturn)
contract IMPXMarket is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SigmoidMath for uint256;

    // ─────────────────────────────────────────────────────────────────────────
    // State
    // ─────────────────────────────────────────────────────────────────────────

    IERC20 public immutable usdc;
    PVTToken public immutable pvt;

    /// @notice Where rammToken/redemptionNFT/vestingVault/promoStaking actually
    ///         live — looked up dynamically on every call instead of cached as
    ///         immutables, so a fix to any of those four never requires
    ///         redeploying this market. See RammRegistry.sol for why.
    RammRegistry public immutable registry;

    /// @notice Bps of actualCost routed to a staked promoter's VestingVault
    ///         tranche on a referred buy, carved OUT of CAMPAIGN_BPS (not on
    ///         top of it — the campaign share already notionally covers both
    ///         promoter + platform cuts, matching the existing off-chain
    ///         buyCampaignBps = buyPromoterRateBps + buyPlatformRateBps formula
    ///         VALET uses today). Unreferred / non-staked buys are unaffected.
    uint256 public immutable PROMOTER_BPS;

    uint256 public currentSupply;
    bool public isSecondaryMarket;

    // ── Bonding curve shape (per-market, set at deploy time) ─────────────────
    // Was five hardcoded constants shared by every market (SigmoidMath.sol),
    // regardless of the market's actual supply cap or the brand's chosen
    // fast/medium/slow curve — captured in the campaign wizard but never
    // reaching the contract. See SigmoidMath.sol's CurveParams doc and
    // agents/src/valet/curve.ts (deriveCurveParams) for how these five values
    // get derived from what a brand actually configures.
    uint256 public immutable CURVE_B;          // inflection supply — also the
                                                // isSecondaryMarket threshold below
    uint256 public immutable CURVE_C;          // steepness
    uint256 public immutable CURVE_P;          // base price at inflection, USDC 6dp
    uint256 public immutable CURVE_A_PRIMARY;  // amplitude below the inflection
    uint256 public immutable CURVE_A_SECONDARY; // amplitude at/above the inflection

    /// @notice GMV tracking — total USDC received across all buys
    uint256 public accruedRevenue;

    /// @notice RAMM tokens awarded to buyer per PVT purchased
    uint256 public constant RAMM_PER_PVT = 100 * 1e18;

    // ── Buy split (per-campaign, set at deploy time) ─────────────────────────
    /// @notice Basis points routed to brandWallet on each buy (e.g. 9300 = 93%)
    uint256 public immutable BRAND_BPS;
    /// @notice Basis points routed to campaignWallet on each buy (e.g. 700 = 7%)
    uint256 public immutable CAMPAIGN_BPS;

    // ── Sell split (applied to gross proceeds) ────────────────────────────────
    /// @notice Total bps deducted from seller gross proceeds
    uint256 public immutable SELL_SPREAD_BPS;
    /// @notice Bps of gross proceeds routed to brandWallet on sell (e.g. 500 = 5%)
    uint256 public immutable SELL_BRAND_BPS;
    /// @notice Bps of gross proceeds routed to campaignWallet on sell (e.g. 200 = 2%)
    uint256 public immutable SELL_CAMPAIGN_BPS;

    /// @notice Brand's custodial wallet — receives BRAND_BPS on buy + SELL_BRAND_BPS on sell
    address public immutable brandWallet;

    /// @notice VALET-controlled per-campaign wallet — receives CAMPAIGN_BPS on buy + SELL_CAMPAIGN_BPS on sell
    address public immutable campaignWallet;

    // ─────────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────────

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

    // ─────────────────────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────────────────────

    error SlippageExceeded(uint256 actualCost, uint256 maxCost);
    error InsufficientUSDCAllowance(uint256 required, uint256 allowed);
    error InsufficientUSDCBalance(uint256 required, uint256 available);
    error InsufficientContractUSDC(uint256 required, uint256 available);
    error InsufficientPVTHolding(uint256 required, uint256 available);
    error CannotSellMoreThanSupply(uint256 quantity, uint256 supply);
    error SoldOut(uint256 requested, uint256 remaining);
    error ZeroQuantity();
    error NoRevenue();

    // ─────────────────────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────────────────────

    /// @param _usdc              MockUSDC / Circle USDC
    /// @param _pvt               PVTToken (transfer ownership to this contract after)
    /// @param _registry          RammRegistry — resolves rammToken/redemptionNFT/vestingVault/promoStaking
    /// @param _brandWallet       Brand's custodial wallet
    /// @param _campaignWallet    VALET-controlled campaign treasury wallet
    /// @param _initialOwner      Deployer address
    /// @param _buyBrandBps       Buy split for brand (e.g. 9300). buyBrandBps + buyCampaignBps must equal 10000.
    /// @param _buyCampaignBps    Buy split for campaign treasury (e.g. 700)
    /// @param _sellBrandBps      Sell deduction routed to brandWallet (e.g. 500)
    /// @param _sellCampaignBps   Sell deduction routed to campaignWallet (e.g. 200)
    /// @param _promoterBps       Bps of actualCost credited to a staked promoter on a referred
    ///                           buy, carved out of buyCampaignBps (e.g. 600)
    /// @param _curve             Bonding curve shape — see SigmoidMath.CurveParams and
    ///                           deriveCurveParams() in agents/src/valet/curve.ts for how
    ///                           a brand's (minPrice, maxPrice, totalSupply, curveShape)
    ///                           inputs turn into this struct's five raw values.
    constructor(
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
    ) Ownable(_initialOwner) {
        require(_buyBrandBps + _buyCampaignBps == 10_000, "buy BPS must sum to 10000");
        require(_sellBrandBps + _sellCampaignBps <= 10_000, "sell BPS must not exceed 10000");
        require(_promoterBps <= _buyCampaignBps, "promoter BPS must not exceed campaign BPS");
        require(_curve.b > 0 && _curve.c > 0 && _curve.p > 0, "curve params must be non-zero");
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

    /// @notice Reassembles the struct SigmoidMath's functions take, from the
    ///         five immutables above (structs can't be immutable directly).
    function _curveParams() internal view returns (SigmoidMath.CurveParams memory) {
        return SigmoidMath.CurveParams({
            b: CURVE_B, c: CURVE_C, p: CURVE_P,
            aPrimary: CURVE_A_PRIMARY, aSecondary: CURVE_A_SECONDARY
        });
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Registry lookups — resolved fresh on every call, never cached
    // ─────────────────────────────────────────────────────────────────────────

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

    /// @notice Decodes a referral code into a promoter address. Matches the
    ///         client's encodeReferralCode() (abi.encode(address)) — anything
    ///         else (empty '0x', malformed input) is treated as "no referrer"
    ///         rather than reverting the whole purchase.
    function _decodeReferrer(bytes calldata referralCode) private pure returns (address) {
        if (referralCode.length != 32) return address(0);
        return abi.decode(referralCode, (address));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Core: Buy
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Buy `quantity` PVT via bonding curve. Rewards buyer with $RAMM.
    /// @param referralCode Reserved for future PROMO referral routing (unused in this version).
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

        // Revenue split: 93% → brandWallet, 7% → campaignWallet (immediate routing).
        // A referred buy from a staked promoter carves PROMOTER_BPS OUT of the
        // campaign share into VestingVault escrow instead — the campaign share
        // already notionally covers both cuts (see PROMOTER_BPS docs above), so
        // the brand's split and the overall 100% total are unaffected either way.
        uint256 brandShare    = (actualCost * BRAND_BPS) / 10_000;
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

        // Mint RAMM reward to buyer — non-blocking (failure doesn't revert purchase)
        uint256 rammReward = quantity * RAMM_PER_PVT;
        try _rammToken().mint(msg.sender, rammReward) {} catch {}

        emit SwapSuccess(msg.sender, quantity, actualCost, currentSupply, rammReward, block.timestamp);
        return true;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Read: Pricing
    // ─────────────────────────────────────────────────────────────────────────

    function getCurrentPrice() external view returns (uint256 price) {
        return SigmoidMath.getPrice(currentSupply, _curveParams());
    }

    function getQuote(uint256 quantity) external view returns (uint256 totalCost) {
        return SigmoidMath.getTotalCost(currentSupply, quantity, _curveParams());
    }

    function getCurveData()
        external
        view
        returns (uint256[] memory supplies, uint256[] memory prices)
    {
        uint256 cap = pvt.supplyCap();
        uint256 points = cap / 10 + 1;
        supplies = new uint256[](points);
        prices = new uint256[](points);
        SigmoidMath.CurveParams memory params = _curveParams();
        for (uint256 i = 0; i < points; i++) {
            supplies[i] = i * 10;
            prices[i] = SigmoidMath.getPrice(i * 10, params);
        }
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

    // ─────────────────────────────────────────────────────────────────────────
    // Core: Sell
    // ─────────────────────────────────────────────────────────────────────────

    function getSellQuote(uint256 quantity)
        external
        view
        returns (uint256 grossProceeds, uint256 netProceeds)
    {
        if (quantity == 0 || quantity > currentSupply) return (0, 0);
        grossProceeds = SigmoidMath.getTotalCost(currentSupply - quantity, quantity, _curveParams());
        // Mirror sellPVT arithmetic exactly to avoid rounding divergence
        uint256 sellBrandFee    = (grossProceeds * SELL_BRAND_BPS)    / 10_000;
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

        uint256 grossProceeds   = SigmoidMath.getTotalCost(currentSupply - quantity, quantity, _curveParams());
        uint256 sellBrandFee    = (grossProceeds * SELL_BRAND_BPS)    / 10_000;
        uint256 sellCampaignFee = (grossProceeds * SELL_CAMPAIGN_BPS) / 10_000;
        uint256 netProceeds     = grossProceeds - sellBrandFee - sellCampaignFee;

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

    // ─────────────────────────────────────────────────────────────────────────
    // Core: Redeem
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Burn `quantity` PVT and receive a RedemptionNFT (order receipt).
    ///         NFT tokenId = serial number. Status starts as PENDING; RAMM fulfills on ship.
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

    // ─────────────────────────────────────────────────────────────────────────
    // Liquidity
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Deposit USDC into the buyback liquidity pool.
    ///         Called by campaignWallet or anyone wishing to fund sellbacks.
    ///         Required because buy proceeds are routed out immediately.
    function depositLiquidity(uint256 amount) external {
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        emit LiquidityDeposited(msg.sender, amount, block.timestamp);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Admin
    // ─────────────────────────────────────────────────────────────────────────

    function withdrawRevenue(address to) external onlyOwner {
        uint256 amount = usdc.balanceOf(address(this));
        if (amount == 0) revert NoRevenue();
        accruedRevenue = 0;
        usdc.safeTransfer(to, amount);
        emit RevenueWithdrawn(to, amount, block.timestamp);
    }
}
