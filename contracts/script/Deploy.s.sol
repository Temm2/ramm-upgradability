// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Script, console2} from "forge-std/Script.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {PVTToken} from "../src/PVTToken.sol";
import {RAMMToken} from "../src/RAMMToken.sol";
import {RedemptionNFT} from "../src/RedemptionNFT.sol";
import {VestingVault} from "../src/VestingVault.sol";
import {PromoStaking} from "../src/PromoStaking.sol";
import {RammRegistry} from "../src/RammRegistry.sol";
import {IMPXMarket} from "../src/IMPXMarket.sol";
import {SigmoidMath} from "../src/SigmoidMath.sol";

/// @notice Deploy RAMM MVP3 contracts to Base Sepolia.
///
/// Usage:
///   forge script script/Deploy.s.sol \
///     --rpc-url $BASE_SEPOLIA_RPC_URL \
///     --private-key $DEPLOYER_PRIVATE_KEY \
///     --broadcast \
///     --verify \
///     -vvvv
///
/// Required env vars:
///   BASE_SEPOLIA_RPC_URL    — Alchemy / public Base Sepolia RPC
///   DEPLOYER_PRIVATE_KEY    — deployer EOA key (needs ETH for gas)
///   BRAND_ADDRESS           — brand custodial wallet (receives 93% on buy)
///   CAMPAIGN_WALLET         — per-campaign VALET wallet (receives 7% on buy)
///
/// After deployment:
///   1. Copy logged addresses into app/constants/env.ts
///   2. Fund the buyer's smart account with USDC (MockUSDC.faucet)
///   3. Fund the buyer's EOA with ETH for gas
///   4. Fund the market with USDC for sell-back liquidity (see step 5 below)
contract Deploy is Script {
    function run() external {
        uint256 deployerKey    = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer       = vm.addr(deployerKey);
        address brand          = vm.envAddress("BRAND_ADDRESS");
        address campaignWallet = vm.envOr("CAMPAIGN_WALLET", deployer);

        console2.log("=== RAMM MVP3 Deployment ===");
        console2.log("Deployer:        ", deployer);
        console2.log("Brand wallet:    ", brand);
        console2.log("Campaign wallet: ", campaignWallet);
        console2.log("Network: Base Sepolia");

        vm.startBroadcast(deployerKey);

        // 1. MockUSDC
        MockUSDC usdc = new MockUSDC(deployer);
        console2.log("MockUSDC:     ", address(usdc));

        // 2. PVTToken — Agatha by Elmira Medins, 30 units
        PVTToken pvt = new PVTToken(
            "Agatha by Elmira Medins",
            "EM-AGT",
            30,
            deployer
        );
        console2.log("PVTToken:     ", address(pvt));

        // 3. RAMMToken — platform reward token (1B cap)
        RAMMToken rammToken = new RAMMToken(deployer);
        console2.log("RAMMToken:    ", address(rammToken));

        // 4. RedemptionNFT — proof-of-redemption NFTs
        RedemptionNFT redemptionNFT = new RedemptionNFT(deployer);
        console2.log("RedemptionNFT:", address(redemptionNFT));

        // 4b. VestingVault — time-locked promoter reward escrow
        VestingVault vestingVault = new VestingVault(address(usdc), deployer);
        console2.log("VestingVault: ", address(vestingVault));

        // 4c. PromoStaking — stake-gated promoter status
        PromoStaking promoStaking = new PromoStaking(address(rammToken), deployer);
        console2.log("PromoStaking: ", address(promoStaking));

        // 4d. RammRegistry — canonical, mutable pointer to the four shared
        // singleton contracts above. Every market stores only this registry's
        // address as immutable; fixing any of the four later is one setX()
        // call here, not a redeploy of every dependent market.
        RammRegistry registry = new RammRegistry(
            deployer,
            address(rammToken),
            address(redemptionNFT),
            address(vestingVault),
            address(promoStaking)
        );
        console2.log("RammRegistry: ", address(registry));

        // 5. IMPXMarket — bonding curve AMM with per-campaign wallet split
        // Default policy: buy 93/7 (6% of which is a staked promoter's
        // referral cut, carved out of the 7% campaign share), sell deductions
        // 5% brand + 2% campaign
        IMPXMarket market = new IMPXMarket(
            address(usdc),
            address(pvt),
            address(registry),
            brand,          // brandWallet
            campaignWallet, // campaignWallet
            deployer,       // initialOwner
            9300,           // buyBrandBps
            700,            // buyCampaignBps
            500,            // sellBrandBps
            200,            // sellCampaignBps
            600,            // promoterBps
            // Original fixed curve, kept literally here — this script is the
            // legacy single-product fallback; real deploys go through
            // agents/src/valet/curve.ts's deriveCurveParams() now (see
            // SigmoidMath.sol / IMPXMarket.sol for why this became per-market).
            SigmoidMath.CurveParams({b: 500, c: 100_000, p: 1_000, aPrimary: 100, aSecondary: 200})
        );
        console2.log("IMPXMarket:   ", address(market));

        // 6. Wire up permissions
        pvt.transferOwnership(address(market));
        console2.log("PVT ownership -> market");

        rammToken.setMinterAuthorized(address(market), true);
        console2.log("RAMMToken minter -> market (authorized)");

        redemptionNFT.setMarketAuthorized(address(market), true);
        console2.log("RedemptionNFT market -> market (authorized)");

        vestingVault.setMarketAuthorized(address(market), true);
        console2.log("VestingVault market -> market (authorized)");

        // 7. Seed market with USDC sell-back liquidity
        //    (buy proceeds are routed out immediately; this pool funds sellbacks)
        usdc.mint(address(market), 50_000 * 1e6);
        console2.log("Seeded market with 50,000 USDC sell-back liquidity");

        vm.stopBroadcast();

        // Summary — copy these into app/constants/env.ts
        console2.log("\n=== Copy to app/constants/env.ts ===");
        console2.log("USDC_ADDRESS:           ", address(usdc));
        console2.log("PVT_ADDRESS:            ", address(pvt));
        console2.log("RAMM_TOKEN_ADDRESS:     ", address(rammToken));
        console2.log("REDEMPTION_NFT_ADDRESS: ", address(redemptionNFT));
        console2.log("VESTING_VAULT_ADDRESS:  ", address(vestingVault));
        console2.log("PROMO_STAKING_ADDRESS:  ", address(promoStaking));
        console2.log("REGISTRY_ADDRESS:       ", address(registry));
        console2.log("MARKET_ADDRESS:         ", address(market));
    }
}
