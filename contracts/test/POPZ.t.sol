// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Test, console2} from "forge-std/Test.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {PVTToken} from "../src/PVTToken.sol";
import {RAMMToken} from "../src/RAMMToken.sol";
import {RedemptionNFT} from "../src/RedemptionNFT.sol";
import {IMPXMarket} from "../src/IMPXMarket.sol";
import {PromoStaking} from "../src/PromoStaking.sol";
import {VestingVault} from "../src/VestingVault.sol";
import {RammRegistry} from "../src/RammRegistry.sol";
import {SigmoidMath} from "../src/SigmoidMath.sol";

contract POPZTest is Test {
    MockUSDC public usdc;
    PVTToken public pvt;
    RAMMToken public rammToken;
    RedemptionNFT public redemptionNFT;
    IMPXMarket public market;
    PromoStaking public promoStaking;
    VestingVault public vestingVault;
    RammRegistry public registry;

    address public deployer        = makeAddr("deployer");
    address public buyer           = makeAddr("buyer");
    address public buyer2          = makeAddr("buyer2");
    address public brand           = makeAddr("brand");           // brandWallet
    address public campaignWallet  = makeAddr("campaignWallet");  // per-campaign VALET wallet
    address public promoter        = makeAddr("promoter");

    uint256 constant SUPPLY_CAP = 600;
    bytes constant NO_REFERRAL  = bytes("");

    // ─────────────────────────────────────────────────────────────────────────
    // Setup
    // ─────────────────────────────────────────────────────────────────────────

    function setUp() public {
        vm.startPrank(deployer);

        usdc          = new MockUSDC(deployer);
        pvt           = new PVTToken("Neo Air Sneakers", "POPZ-NAS", SUPPLY_CAP, deployer);
        rammToken     = new RAMMToken(deployer);
        redemptionNFT = new RedemptionNFT(deployer);
        promoStaking  = new PromoStaking(address(rammToken), deployer);
        vestingVault  = new VestingVault(address(usdc), deployer);
        registry      = new RammRegistry(
            deployer,
            address(rammToken),
            address(redemptionNFT),
            address(vestingVault),
            address(promoStaking)
        );

        market = new IMPXMarket(
            address(usdc),
            address(pvt),
            address(registry),
            brand,
            campaignWallet,
            deployer,
            9300, // buyBrandBps
            700,  // buyCampaignBps
            500,  // sellBrandBps
            200,  // sellCampaignBps
            600,  // promoterBps
            // Original fixed curve — kept literal so every existing price
            // assertion below stays valid unchanged; parameterization tests
            // live in their own block further down.
            SigmoidMath.CurveParams({b: 500, c: 100_000, p: 1_000, aPrimary: 100, aSecondary: 200})
        );

        // Wire permissions
        pvt.transferOwnership(address(market));
        rammToken.setMinterAuthorized(address(market), true);
        redemptionNFT.setMarketAuthorized(address(market), true);
        vestingVault.setMarketAuthorized(address(market), true);

        // Seed market with sell-back liquidity + fund buyers
        usdc.transfer(address(market), 100_000 * 1e6);
        usdc.transfer(buyer,  2_000 * 1e6);
        usdc.transfer(buyer2, 2_000 * 1e6);

        vm.stopPrank();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MockUSDC
    // ─────────────────────────────────────────────────────────────────────────

    function test_USDC_Decimals() public view {
        assertEq(usdc.decimals(), 6);
    }

    function test_USDC_InitialSupply() public view {
        assertEq(usdc.balanceOf(buyer),  2_000 * 1e6);
        assertEq(usdc.balanceOf(buyer2), 2_000 * 1e6);
    }

    function test_USDC_Faucet() public {
        address anon = makeAddr("anon");
        vm.prank(anon);
        usdc.faucet();
        assertEq(usdc.balanceOf(anon), 1_000 * 1e6);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // SigmoidMath
    // ─────────────────────────────────────────────────────────────────────────

    // The original fixed constants, now just one possible CurveParams value
    // instead of hardcoded inside the library — see the parameterization
    // block further down for tests against other shapes/scales.
    function _originalCurve() private pure returns (SigmoidMath.CurveParams memory) {
        return SigmoidMath.CurveParams({b: 500, c: 100_000, p: 1_000, aPrimary: 100, aSecondary: 200});
    }

    function test_Sigmoid_AtZero() public pure {
        uint256 price = SigmoidMath.getPrice(0, _originalCurve());
        assertApproxEqRel(price, 900 * 1e6, 0.05e18);
    }

    function test_Sigmoid_AtInflection() public pure {
        uint256 price = SigmoidMath.getPrice(500, _originalCurve());
        assertApproxEqRel(price, 1_000 * 1e6, 0.01e18);
    }

    function test_Sigmoid_AtMaxSupply() public pure {
        // Secondary curve (A=200): price at supply=1000 ≈ $1,169
        uint256 price = SigmoidMath.getPrice(1_000, _originalCurve());
        assertApproxEqRel(price, 1_169 * 1e6, 0.01e18);
    }

    function test_Sigmoid_SecondaryZoneHigherThanPrimary() public pure {
        SigmoidMath.CurveParams memory curve = _originalCurve();
        // At inflection both curves give exactly P_RAW = $1000
        assertEq(SigmoidMath.getPrice(500, curve), 1_000 * 1e6);
        // Just above inflection: secondary is steeper than primary would have been
        assertGt(SigmoidMath.getPrice(501, curve), SigmoidMath.getPrice(499, curve));
        // Price at supply=1000 (secondary) > supply=1000 under old primary curve (~$1084)
        assertGt(SigmoidMath.getPrice(1_000, curve), 1_084 * 1e6);
    }

    function test_Sigmoid_IsMonotonicallyIncreasing() public pure {
        SigmoidMath.CurveParams memory curve = _originalCurve();
        uint256 prevPrice = SigmoidMath.getPrice(0, curve);
        for (uint256 s = 10; s <= 600; s += 10) {
            uint256 price = SigmoidMath.getPrice(s, curve);
            assertGe(price, prevPrice);
            prevPrice = price;
        }
    }

    function test_Sigmoid_GetTotalCost_SingleUnit() public pure {
        SigmoidMath.CurveParams memory curve = _originalCurve();
        assertEq(SigmoidMath.getTotalCost(0, 1, curve), SigmoidMath.getPrice(0, curve));
    }

    function test_Sigmoid_GetTotalCost_MultiUnit() public pure {
        SigmoidMath.CurveParams memory curve = _originalCurve();
        uint256 cost = SigmoidMath.getTotalCost(100, 3, curve);
        uint256 expected = SigmoidMath.getPrice(100, curve) + SigmoidMath.getPrice(101, curve) + SigmoidMath.getPrice(102, curve);
        assertEq(cost, expected);
    }

    function test_Sigmoid_Parameterized_DifferentMarketsDifferentCurves() public pure {
        // A demo-scale market (supply cap 50) using the SAME fixed constants
        // as the original design barely moves in price across its whole
        // range — this is the exact bug the parameterization fixes. A curve
        // whose b/c actually scale to the market's own supply cap (as
        // deriveCurveParams() in agents/src/valet/curve.ts computes) spans
        // its configured range properly instead.
        SigmoidMath.CurveParams memory stale = _originalCurve(); // b=500 — irrelevant to a 50-unit market
        SigmoidMath.CurveParams memory scaled = SigmoidMath.CurveParams({
            b: 25, c: 250, p: 967, aPrimary: 138, aSecondary: 276
        }); // deriveCurveParams(850e6, 1200e6, 50, "medium")

        uint256 staleRange = SigmoidMath.getPrice(50, stale) - SigmoidMath.getPrice(0, stale);
        uint256 scaledRange = SigmoidMath.getPrice(50, scaled) - SigmoidMath.getPrice(0, scaled);

        assertLt(staleRange, 10 * 1e6, "stale b=500 curve barely moves across a 50-unit market");
        assertGt(scaledRange, 300 * 1e6, "scaled curve actually spans the configured price range");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // PVTToken
    // ─────────────────────────────────────────────────────────────────────────

    function test_PVT_OwnerIsMarket() public view {
        assertEq(pvt.owner(), address(market));
    }

    function test_PVT_SupplyCap() public view {
        assertEq(pvt.supplyCap(), SUPPLY_CAP);
        assertEq(pvt.remainingSupply(), SUPPLY_CAP);
    }

    function test_PVT_Decimals() public view {
        assertEq(pvt.decimals(), 0);
    }

    function test_PVT_OnlyMarketCanMint() public {
        vm.expectRevert();
        vm.prank(buyer);
        pvt.mint(buyer, 1);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // RAMMToken — MVP2
    // ─────────────────────────────────────────────────────────────────────────

    function test_RAMM_MinterIsMarket() public view {
        assertTrue(rammToken.authorizedMinters(address(market)));
    }

    function test_RAMM_BuyerReceivesRewardOnPurchase() public {
        uint256 qty = 2;
        uint256 quote = market.getQuote(qty);
        vm.startPrank(buyer);
        usdc.approve(address(market), quote);
        market.swapUSDCForPVT(address(pvt), qty, quote, NO_REFERRAL);
        vm.stopPrank();

        uint256 expectedRAMM = qty * market.RAMM_PER_PVT();
        assertEq(rammToken.balanceOf(buyer), expectedRAMM);
        console2.log("RAMM rewarded:", expectedRAMM / 1e18, "RAMM tokens");
    }

    function test_RAMM_MaxSupplyEnforced() public {
        uint256 maxSupply = rammToken.MAX_SUPPLY(); // read before prank so prank isn't consumed
        vm.prank(deployer);
        rammToken.mint(deployer, maxSupply);

        vm.expectRevert(RAMMToken.MaxSupplyExceeded.selector);
        vm.prank(deployer);
        rammToken.mint(deployer, 1);
    }

    function test_RAMM_OnlyMinterOrOwnerCanMint() public {
        vm.expectRevert(RAMMToken.OnlyMinterOrOwner.selector);
        vm.prank(buyer);
        rammToken.mint(buyer, 100 * 1e18);
    }

    function test_RAMM_BatchMint() public {
        address[] memory recipients = new address[](2);
        recipients[0] = buyer;
        recipients[1] = buyer2;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 500 * 1e18;
        amounts[1] = 300 * 1e18;

        vm.prank(deployer);
        rammToken.batchMint(recipients, amounts);

        assertEq(rammToken.balanceOf(buyer),  500 * 1e18);
        assertEq(rammToken.balanceOf(buyer2), 300 * 1e18);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // RedemptionNFT — MVP2
    // ─────────────────────────────────────────────────────────────────────────

    function test_RedemptionNFT_MarketIsSet() public view {
        assertTrue(redemptionNFT.authorizedMarkets(address(market)));
    }

    function test_RedemptionNFT_OnlyMarketCanMint() public {
        vm.expectRevert(RedemptionNFT.OnlyMarket.selector);
        vm.prank(buyer);
        redemptionNFT.mint(buyer, address(pvt), "Test Product", 1);
    }

    function test_Redeem_MintsNFT() public {
        // Buy first
        uint256 quote = market.getQuote(1);
        vm.startPrank(buyer);
        usdc.approve(address(market), quote);
        market.swapUSDCForPVT(address(pvt), 1, quote, NO_REFERRAL);

        // Redeem → NFT minted
        uint256 nftId = market.redeemPVT(address(pvt), 1);
        vm.stopPrank();

        assertEq(nftId, 1, "First redemption serial = 1");
        assertEq(redemptionNFT.balanceOf(buyer, nftId), 1); // ERC-1155: balance = 1 for owned serial
        assertEq(pvt.balanceOf(buyer), 0);

        (
            address product,
            address redeemer,
            uint256 quantity,
            ,
            string memory productName,
            string memory status,
            ,
            ,
        ) = redemptionNFT.redemptions(nftId);

        assertEq(product, address(pvt));
        assertEq(redeemer, buyer);
        assertEq(quantity, 1);
        assertEq(productName, "Neo Air Sneakers");
        assertEq(status, "PENDING");

        console2.log("NFT uri:", redemptionNFT.uri(nftId));
    }

    function test_Redeem_SerialNumberIncrementsPerRedemption() public {
        uint256 quote1 = market.getQuote(1);
        vm.startPrank(buyer);
        usdc.approve(address(market), quote1);
        market.swapUSDCForPVT(address(pvt), 1, quote1, NO_REFERRAL);
        uint256 id1 = market.redeemPVT(address(pvt), 1);
        vm.stopPrank();

        uint256 quote2 = market.getQuote(1);
        vm.startPrank(buyer2);
        usdc.approve(address(market), quote2);
        market.swapUSDCForPVT(address(pvt), 1, quote2, NO_REFERRAL);
        uint256 id2 = market.redeemPVT(address(pvt), 1);
        vm.stopPrank();

        assertEq(id2, id1 + 1, "Serial numbers increment");
    }

    function test_Redeem_Fulfill() public {
        uint256 quote = market.getQuote(1);
        vm.startPrank(buyer);
        usdc.approve(address(market), quote);
        market.swapUSDCForPVT(address(pvt), 1, quote, NO_REFERRAL);
        uint256 nftId = market.redeemPVT(address(pvt), 1);
        vm.stopPrank();

        // RAMM admin fulfills
        string memory encryptedCode = "AES256:abc123xyz";
        vm.prank(deployer);
        redemptionNFT.fulfill(nftId, encryptedCode);

        (,,,, , string memory status, string memory code, , ) = redemptionNFT.redemptions(nftId);
        assertEq(status, "FULFILLED");
        assertEq(code, encryptedCode);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Buy — happy path
    // ─────────────────────────────────────────────────────────────────────────

    function test_Buy_SingleToken() public {
        uint256 quote = market.getQuote(1);
        vm.startPrank(buyer);
        usdc.approve(address(market), quote);
        bool success = market.swapUSDCForPVT(address(pvt), 1, quote, NO_REFERRAL);
        vm.stopPrank();

        assertTrue(success);
        assertEq(pvt.balanceOf(buyer), 1);
        assertEq(market.currentSupply(), 1);
        assertEq(usdc.balanceOf(buyer), 2_000 * 1e6 - quote);
        assertGt(rammToken.balanceOf(buyer), 0);
    }

    function test_Buy_MultipleTokens() public {
        uint256 qty = 2;
        uint256 quote = market.getQuote(qty);
        vm.startPrank(buyer);
        usdc.approve(address(market), quote);
        market.swapUSDCForPVT(address(pvt), qty, quote, NO_REFERRAL);
        vm.stopPrank();

        assertEq(pvt.balanceOf(buyer), qty);
        assertEq(rammToken.balanceOf(buyer), qty * market.RAMM_PER_PVT());
    }

    function test_Buy_TwoBuyers() public {
        uint256 quote1 = market.getQuote(1);
        vm.startPrank(buyer);
        usdc.approve(address(market), quote1);
        market.swapUSDCForPVT(address(pvt), 1, quote1, NO_REFERRAL);
        vm.stopPrank();

        uint256 quote2 = market.getQuote(1);
        assertGe(quote2, quote1);

        vm.startPrank(buyer2);
        usdc.approve(address(market), quote2);
        market.swapUSDCForPVT(address(pvt), 1, quote2, NO_REFERRAL);
        vm.stopPrank();

        assertEq(pvt.balanceOf(buyer),  1);
        assertEq(pvt.balanceOf(buyer2), 1);
        assertEq(market.currentSupply(), 2);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Slippage protection
    // ─────────────────────────────────────────────────────────────────────────

    function test_Buy_RevertOnSlippage() public {
        uint256 quote = market.getQuote(1);
        vm.startPrank(buyer);
        usdc.approve(address(market), quote);
        vm.expectRevert(abi.encodeWithSelector(IMPXMarket.SlippageExceeded.selector, quote, quote - 1));
        market.swapUSDCForPVT(address(pvt), 1, quote - 1, NO_REFERRAL);
        vm.stopPrank();
    }

    function test_Buy_With2PercentSlippage() public {
        uint256 quote = market.getQuote(1);
        uint256 maxCost = quote + (quote * 200) / 10_000;
        vm.startPrank(buyer);
        usdc.approve(address(market), maxCost);
        assertTrue(market.swapUSDCForPVT(address(pvt), 1, maxCost, NO_REFERRAL));
        vm.stopPrank();
    }

    function test_Buy_RevertOnZeroQuantity() public {
        vm.expectRevert(IMPXMarket.ZeroQuantity.selector);
        vm.prank(buyer);
        market.swapUSDCForPVT(address(pvt), 0, 1_000 * 1e6, NO_REFERRAL);
    }

    function test_Buy_RevertOnInsufficientAllowance() public {
        uint256 quote = market.getQuote(1);
        vm.startPrank(buyer);
        usdc.approve(address(market), quote - 1);
        vm.expectRevert(abi.encodeWithSelector(IMPXMarket.InsufficientUSDCAllowance.selector, quote, quote - 1));
        market.swapUSDCForPVT(address(pvt), 1, quote, NO_REFERRAL);
        vm.stopPrank();
    }

    function test_Buy_RevertWhenSoldOut() public {
        vm.prank(deployer);
        usdc.mint(buyer, 1_000_000 * 1e6);

        uint256 cap = pvt.supplyCap();
        uint256 bigQuote = market.getQuote(cap);

        vm.startPrank(buyer);
        usdc.approve(address(market), bigQuote);
        market.swapUSDCForPVT(address(pvt), cap, bigQuote, NO_REFERRAL);
        vm.stopPrank();

        vm.startPrank(buyer2);
        usdc.approve(address(market), 2_000 * 1e6);
        vm.expectRevert(abi.encodeWithSelector(IMPXMarket.SoldOut.selector, 1, 0));
        market.swapUSDCForPVT(address(pvt), 1, 2_000 * 1e6, NO_REFERRAL);
        vm.stopPrank();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Market transition
    // ─────────────────────────────────────────────────────────────────────────

    function test_Market_TransitionAtInflection() public {
        assertFalse(market.isSecondaryMarket());

        vm.prank(deployer);
        usdc.mint(buyer, 1_000_000 * 1e6);

        uint256 quote = market.getQuote(500);
        vm.startPrank(buyer);
        usdc.approve(address(market), quote);

        vm.expectEmit(false, false, false, false);
        emit IMPXMarket.MarketTransition(500, block.timestamp);

        market.swapUSDCForPVT(address(pvt), 500, quote, NO_REFERRAL);
        vm.stopPrank();

        assertTrue(market.isSecondaryMarket());
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Revenue split
    // ─────────────────────────────────────────────────────────────────────────

    function test_Revenue_BrandShareGoesToBrandWallet() public {
        uint256 quote = market.getQuote(1);
        uint256 brandBalBefore    = usdc.balanceOf(brand);
        uint256 campaignBalBefore = usdc.balanceOf(campaignWallet);

        vm.startPrank(buyer);
        usdc.approve(address(market), quote);
        market.swapUSDCForPVT(address(pvt), 1, quote, NO_REFERRAL);
        vm.stopPrank();

        // Mirror contract arithmetic: brandShare rounds down, campaign gets remainder
        uint256 brandShare    = (quote * market.BRAND_BPS()) / 10_000;
        uint256 campaignShare = quote - brandShare;

        assertEq(usdc.balanceOf(brand),          brandBalBefore    + brandShare,    "brand 93%");
        assertEq(usdc.balanceOf(campaignWallet),  campaignBalBefore + campaignShare, "campaign 7%");
    }

    function test_Revenue_SellFeeSplitToBrandAndCampaign() public {
        // Buy first so we have PVT to sell
        uint256 buyQuote = market.getQuote(1);
        vm.startPrank(buyer);
        usdc.approve(address(market), buyQuote);
        market.swapUSDCForPVT(address(pvt), 1, buyQuote, NO_REFERRAL);
        vm.stopPrank();

        uint256 brandBalBefore    = usdc.balanceOf(brand);
        uint256 campaignBalBefore = usdc.balanceOf(campaignWallet);

        (uint256 gross, uint256 net) = market.getSellQuote(1);
        vm.startPrank(buyer);
        market.sellPVT(address(pvt), 1, net);
        vm.stopPrank();

        uint256 sellBrandFee    = (gross * market.SELL_BRAND_BPS())    / 10_000;
        uint256 sellCampaignFee = (gross * market.SELL_CAMPAIGN_BPS()) / 10_000;

        assertEq(usdc.balanceOf(brand),         brandBalBefore    + sellBrandFee,    "brand 5% of sell");
        assertEq(usdc.balanceOf(campaignWallet), campaignBalBefore + sellCampaignFee, "campaign 2% of sell");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Market state reads
    // ─────────────────────────────────────────────────────────────────────────

    function test_GetMarketState() public view {
        (uint256 supply, uint256 supplyCap, uint256 remaining, uint256 currentPrice, bool secondary) =
            market.getMarketState();
        assertEq(supply, 0);
        assertEq(supplyCap, SUPPLY_CAP);
        assertEq(remaining, SUPPLY_CAP);
        assertGt(currentPrice, 0);
        assertFalse(secondary);
    }

    function test_GetCurveData() public view {
        (uint256[] memory supplies, uint256[] memory prices) = market.getCurveData();
        assertEq(supplies.length, prices.length);
        assertGt(supplies.length, 0);
        for (uint256 i = 1; i < prices.length; i++) {
            assertGe(prices[i], prices[i-1]);
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Sell flow
    // ─────────────────────────────────────────────────────────────────────────

    function test_Sell_Basic() public {
        uint256 buyQuote = market.getQuote(1);
        vm.startPrank(buyer);
        usdc.approve(address(market), buyQuote);
        market.swapUSDCForPVT(address(pvt), 1, buyQuote, NO_REFERRAL);
        uint256 usdcAfterBuy = usdc.balanceOf(buyer);

        (uint256 gross, uint256 net) = market.getSellQuote(1);
        assertLt(net, gross);

        assertTrue(market.sellPVT(address(pvt), 1, net - (net / 20)));
        assertEq(pvt.balanceOf(buyer), 0);
        assertEq(usdc.balanceOf(buyer), usdcAfterBuy + net);
        vm.stopPrank();
    }

    function test_Sell_RevertOnZeroQuantity() public {
        vm.expectRevert(IMPXMarket.ZeroQuantity.selector);
        vm.prank(buyer);
        market.sellPVT(address(pvt), 0, 0);
    }

    function test_Sell_RevertOnInsufficientPVT() public {
        uint256 buyQuote = market.getQuote(1);
        vm.startPrank(buyer);
        usdc.approve(address(market), buyQuote);
        market.swapUSDCForPVT(address(pvt), 1, buyQuote, NO_REFERRAL);
        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSelector(IMPXMarket.InsufficientPVTHolding.selector, 1, 0));
        vm.prank(buyer2);
        market.sellPVT(address(pvt), 1, 0);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Fuzz tests
    // ─────────────────────────────────────────────────────────────────────────

    function testFuzz_Sigmoid_NeverReverts(uint256 supply) public pure {
        supply = bound(supply, 0, 10_000);
        SigmoidMath.getPrice(supply, _originalCurve());
    }

    function testFuzz_Buy_SlippageAlwaysProtects(uint256 slippageBps) public {
        slippageBps = bound(slippageBps, 0, 500);
        uint256 quote = market.getQuote(1);
        uint256 maxCost = quote + (quote * slippageBps) / 10_000;
        vm.startPrank(buyer);
        usdc.approve(address(market), maxCost);
        assertTrue(market.swapUSDCForPVT(address(pvt), 1, maxCost, NO_REFERRAL));
        vm.stopPrank();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // PromoStaking
    // ─────────────────────────────────────────────────────────────────────────

    function _earnRAMM(address addr, uint256 amount) internal {
        vm.prank(deployer);
        rammToken.mint(addr, amount);
    }

    function test_PromoStaking_StakeBecomesPromoter() public {
        uint256 stakeAmt = 1_000 * 1e18;
        _earnRAMM(promoter, stakeAmt);

        vm.startPrank(promoter);
        rammToken.approve(address(promoStaking), stakeAmt);
        promoStaking.stake(stakeAmt);
        vm.stopPrank();

        assertTrue(promoStaking.isPromoter(promoter));
        (uint256 amount, uint256 unlocksAt) = promoStaking.stakeInfo(promoter);
        assertEq(amount, stakeAmt);
        assertGt(unlocksAt, block.timestamp);
    }

    function test_PromoStaking_BelowMinStakeReverts() public {
        uint256 belowMin = 999 * 1e18;
        _earnRAMM(promoter, belowMin);

        vm.startPrank(promoter);
        rammToken.approve(address(promoStaking), belowMin);
        vm.expectRevert(abi.encodeWithSelector(PromoStaking.BelowMinStake.selector, belowMin, promoStaking.minStake()));
        promoStaking.stake(belowMin);
        vm.stopPrank();
    }

    function test_PromoStaking_UnstakeAfterLock() public {
        uint256 stakeAmt = 1_000 * 1e18;
        _earnRAMM(promoter, stakeAmt);

        vm.startPrank(promoter);
        rammToken.approve(address(promoStaking), stakeAmt);
        promoStaking.stake(stakeAmt);

        vm.expectRevert(); // StillLocked
        promoStaking.unstake();

        vm.warp(block.timestamp + 7 days + 1);
        promoStaking.unstake();
        vm.stopPrank();

        assertEq(rammToken.balanceOf(promoter), stakeAmt);
        assertFalse(promoStaking.isPromoter(promoter));
    }

    function test_PromoStaking_NonStakerIsNotPromoter() public view {
        assertFalse(promoStaking.isPromoter(promoter));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // VestingVault
    // ─────────────────────────────────────────────────────────────────────────

    function test_VestingVault_CreditAndClaim() public {
        // seed vault with USDC and credit a tranche
        vm.startPrank(deployer);
        usdc.mint(address(vestingVault), 600 * 1e6);
        vm.stopPrank();

        vm.prank(address(market));
        vestingVault.credit(promoter, 600 * 1e6);

        // nothing claimable yet
        (uint256 claimable, uint256 locked) = vestingVault.balanceOf(promoter);
        assertEq(claimable, 0);
        assertEq(locked, 600 * 1e6);

        // warp past vesting period — still locked, brand hasn't confirmed fulfillment
        vm.warp(block.timestamp + 7 days + 1);
        (claimable, locked) = vestingVault.balanceOf(promoter);
        assertEq(claimable, 0);
        assertEq(locked, 600 * 1e6);

        // brand confirms fulfillment — now claimable
        vm.prank(brand);
        vestingVault.markFulfilled(promoter, 0);
        (claimable, locked) = vestingVault.balanceOf(promoter);
        assertEq(claimable, 600 * 1e6);
        assertEq(locked, 0);

        uint256 balBefore = usdc.balanceOf(promoter);
        vm.prank(promoter);
        vestingVault.claim();
        assertEq(usdc.balanceOf(promoter), balBefore + 600 * 1e6);
    }

    function test_VestingVault_OnlyMarketCanCredit() public {
        vm.expectRevert(VestingVault.OnlyMarket.selector);
        vm.prank(buyer);
        vestingVault.credit(promoter, 100 * 1e6);
    }

    function test_VestingVault_NothingToClaimReverts() public {
        vm.expectRevert(VestingVault.NothingToClaim.selector);
        vm.prank(promoter);
        vestingVault.claim();
    }

    function test_VestingVault_ClaimRevertsWithoutFulfillment() public {
        vm.startPrank(deployer);
        usdc.mint(address(vestingVault), 100 * 1e6);
        vm.stopPrank();

        vm.prank(address(market));
        vestingVault.credit(promoter, 100 * 1e6);

        // fully vested by time, but never fulfilled — still not claimable
        vm.warp(block.timestamp + 7 days + 1);
        vm.expectRevert(VestingVault.NothingToClaim.selector);
        vm.prank(promoter);
        vestingVault.claim();
    }

    function test_VestingVault_OnlyBrandCanMarkFulfilled() public {
        vm.prank(address(market));
        vestingVault.credit(promoter, 100 * 1e6);

        vm.expectRevert(VestingVault.OnlyBrand.selector);
        vm.prank(buyer); // not this campaign's brandWallet
        vestingVault.markFulfilled(promoter, 0);
    }

    function test_VestingVault_MarkFulfilledInvalidTrancheReverts() public {
        vm.expectRevert(VestingVault.InvalidTranche.selector);
        vm.prank(brand);
        vestingVault.markFulfilled(promoter, 0); // promoter has zero tranches
    }

    // ─────────────────────────────────────────────────────────────────────────
    // PROMO — referral routing: staked promoters get credited on-chain,
    // non-staked "promoters" and self-referrals don't.
    // ─────────────────────────────────────────────────────────────────────────

    function _stakePromoter() internal {
        uint256 minStake = promoStaking.minStake();
        vm.prank(deployer); // RAMMToken owner can mint directly for test setup
        rammToken.mint(promoter, minStake);
        vm.startPrank(promoter);
        rammToken.approve(address(promoStaking), minStake);
        promoStaking.stake(minStake);
        vm.stopPrank();
    }

    function test_Promo_ReferralFromNonStakedPromoterDoesNotCreditVault() public {
        bytes memory referralCode = abi.encode(promoter);
        uint256 quote = market.getQuote(1);
        uint256 brandBefore    = usdc.balanceOf(brand);
        uint256 campaignBefore = usdc.balanceOf(campaignWallet);

        vm.startPrank(buyer);
        usdc.approve(address(market), quote);
        market.swapUSDCForPVT(address(pvt), 1, quote, referralCode);
        vm.stopPrank();

        // promoter never staked -> isPromoter() is false -> revenue still 93/7, no vault credit
        uint256 brandShare    = (quote * market.BRAND_BPS()) / 10_000;
        uint256 campaignShare = quote - brandShare;
        assertEq(usdc.balanceOf(brand),         brandBefore    + brandShare);
        assertEq(usdc.balanceOf(campaignWallet), campaignBefore + campaignShare);
        (uint256 claimable, uint256 locked) = vestingVault.balanceOf(promoter);
        assertEq(claimable + locked, 0);
    }

    function test_Promo_ReferralFromStakedPromoterCreditsVestingVault() public {
        _stakePromoter();

        bytes memory referralCode = abi.encode(promoter);
        uint256 quote = market.getQuote(1);
        uint256 campaignBefore = usdc.balanceOf(campaignWallet);

        vm.startPrank(buyer);
        usdc.approve(address(market), quote);
        market.swapUSDCForPVT(address(pvt), 1, quote, referralCode);
        vm.stopPrank();

        uint256 expectedPromoterCut = (quote * market.PROMOTER_BPS()) / 10_000;
        uint256 brandShare = (quote * market.BRAND_BPS()) / 10_000;
        uint256 expectedCampaignShare = quote - brandShare - expectedPromoterCut;

        assertEq(usdc.balanceOf(campaignWallet), campaignBefore + expectedCampaignShare);
        (uint256 claimable, uint256 locked) = vestingVault.balanceOf(promoter);
        assertEq(claimable, 0); // still within the 7-day vesting period
        assertEq(locked, expectedPromoterCut);
    }

    function test_Promo_SelfReferralNotCredited() public {
        _stakePromoter();
        // promoter buys through their own referral link
        bytes memory referralCode = abi.encode(promoter);
        uint256 quote = market.getQuote(1);

        vm.startPrank(promoter);
        usdc.approve(address(market), quote);
        // promoter needs USDC to buy — mint some via deployer transfer
        vm.stopPrank();
        vm.prank(deployer);
        usdc.transfer(promoter, quote);
        vm.startPrank(promoter);
        usdc.approve(address(market), quote);
        market.swapUSDCForPVT(address(pvt), 1, quote, referralCode);
        vm.stopPrank();

        (uint256 claimable, uint256 locked) = vestingVault.balanceOf(promoter);
        assertEq(claimable + locked, 0);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Sell fee routing — seller nets 93%; 5% → brand, 2% → campaignWallet
    // ─────────────────────────────────────────────────────────────────────────

    function test_Resale_SellerAlwaysNets93Percent() public {
        uint256 quote = market.getQuote(1);
        vm.startPrank(buyer);
        usdc.approve(address(market), quote);
        market.swapUSDCForPVT(address(pvt), 1, quote, NO_REFERRAL);

        (uint256 gross, uint256 net) = market.getSellQuote(1);
        // Mirror contract arithmetic: two separate fee subtractions (not a single 93% multiply)
        uint256 expectedNet = gross
            - (gross * market.SELL_BRAND_BPS())    / 10_000
            - (gross * market.SELL_CAMPAIGN_BPS()) / 10_000;
        assertEq(net, expectedNet);

        market.sellPVT(address(pvt), 1, net);
        vm.stopPrank();
    }

    function test_Resale_FeeSplitBrandAndCampaign() public {
        uint256 quote = market.getQuote(1);
        vm.startPrank(buyer);
        usdc.approve(address(market), quote);
        market.swapUSDCForPVT(address(pvt), 1, quote, NO_REFERRAL);

        uint256 brandBalBefore    = usdc.balanceOf(brand);
        uint256 campaignBalBefore = usdc.balanceOf(campaignWallet);

        (uint256 gross, uint256 net) = market.getSellQuote(1);
        market.sellPVT(address(pvt), 1, net);
        vm.stopPrank();

        uint256 sellBrandFee    = (gross * market.SELL_BRAND_BPS())    / 10_000;
        uint256 sellCampaignFee = (gross * market.SELL_CAMPAIGN_BPS()) / 10_000;
        assertEq(usdc.balanceOf(brand),         brandBalBefore    + sellBrandFee,    "brand 5%");
        assertEq(usdc.balanceOf(campaignWallet), campaignBalBefore + sellCampaignFee, "campaign 2%");
    }

    function test_Resale_Redeem_NoUsdcMovement() public {
        uint256 quote = market.getQuote(1);
        vm.startPrank(buyer);
        usdc.approve(address(market), quote);
        market.swapUSDCForPVT(address(pvt), 1, quote, NO_REFERRAL);

        uint256 buyerUsdcBeforeRedeem = usdc.balanceOf(buyer);
        market.redeemPVT(address(pvt), 1);
        vm.stopPrank();

        assertEq(usdc.balanceOf(buyer), buyerUsdcBeforeRedeem, "redeem moves no USDC");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // RammRegistry — the whole point: fixing a shared contract is one setX()
    // call, never a market redeploy.
    // ─────────────────────────────────────────────────────────────────────────

    function test_Registry_SwapVestingVault_NoMarketRedeployNeeded() public {
        _stakePromoter();

        // Deploy a *replacement* VestingVault — simulating the fulfillment-
        // gating fix (or any future vault change) shipping — and point the
        // existing, already-deployed `market` at it via the registry. The
        // market contract itself is never touched or redeployed.
        vm.prank(deployer);
        VestingVault newVault = new VestingVault(address(usdc), deployer);
        vm.prank(deployer);
        newVault.setMarketAuthorized(address(market), true);
        vm.prank(deployer);
        registry.setVestingVault(address(newVault));

        assertEq(address(market.registry()), address(registry), "sanity: market still points at the same registry");
        assertEq(registry.vestingVault(), address(newVault), "registry now points at the new vault");

        bytes memory referralCode = abi.encode(promoter);
        uint256 quote = market.getQuote(1);
        vm.startPrank(buyer);
        usdc.approve(address(market), quote);
        market.swapUSDCForPVT(address(pvt), 1, quote, referralCode);
        vm.stopPrank();

        uint256 promoterCut = (quote * market.PROMOTER_BPS()) / 10_000;
        (, uint256 lockedOld) = vestingVault.balanceOf(promoter);
        (, uint256 lockedNew) = newVault.balanceOf(promoter);
        assertEq(lockedOld, 0, "old vault got nothing - market never touches it once registry moves on");
        assertEq(lockedNew, promoterCut, "new vault got the credit, with zero changes to the market contract");
    }

    function test_Registry_OnlyOwnerCanUpdate() public {
        vm.prank(buyer); // not the registry owner
        vm.expectRevert();
        registry.setVestingVault(address(0xBEEF));
    }

    function test_Registry_RejectsZeroAddress() public {
        vm.prank(deployer);
        vm.expectRevert(RammRegistry.ZeroAddress.selector);
        registry.setVestingVault(address(0));
    }

    function test_Registry_ConstructorRejectsZeroAddress() public {
        vm.expectRevert(RammRegistry.ZeroAddress.selector);
        new RammRegistry(deployer, address(0), address(redemptionNFT), address(vestingVault), address(promoStaking));
    }
}
