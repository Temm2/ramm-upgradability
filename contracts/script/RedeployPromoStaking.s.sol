// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Script, console2} from "forge-std/Script.sol";
import {PromoStaking} from "../src/PromoStaking.sol";

/// @notice Deploys a fresh PromoStaking pointing at the CURRENT RAMMToken.
///
/// PromoStaking's `rammToken` is immutable, set at deploy time. The existing
/// deployment was made before this session's RAMMToken redeploy (fixing the
/// single-minter authorization bug) and was never updated — it still points
/// at the old, now-abandoned RAMMToken. No one can stake real RAMM against it
/// since IMPXMarket only ever mints the new RAMMToken. PromoStaking itself
/// needed no authorization-pattern fix (unlike RedemptionNFT/RAMMToken/
/// VestingVault), which is why it was missed in the earlier migration passes
/// — but its stale immutable reference still requires a fresh deployment.
///
/// Usage:
///   forge script script/RedeployPromoStaking.s.sol \
///     --rpc-url $BASE_SEPOLIA_RPC_URL \
///     --private-key $DEPLOYER_PRIVATE_KEY \
///     --broadcast -vvvv
contract RedeployPromoStaking is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer    = vm.addr(deployerKey);
        address rammToken   = vm.envAddress("RAMM_TOKEN_ADDRESS");

        console2.log("Deployer: ", deployer);
        console2.log("RAMMToken:", rammToken);

        vm.startBroadcast(deployerKey);

        PromoStaking promoStaking = new PromoStaking(rammToken, deployer);
        console2.log("PromoStaking:", address(promoStaking));

        vm.stopBroadcast();

        console2.log("\n=== Copy into agents/.env and app/constants/env.ts ===");
        console2.log("PROMO_STAKING_ADDRESS:", address(promoStaking));
    }
}
