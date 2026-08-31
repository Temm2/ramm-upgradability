// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Script, console2} from "forge-std/Script.sol";
import {RAMMToken} from "../src/RAMMToken.sol";
import {RedemptionNFT} from "../src/RedemptionNFT.sol";

/// @notice Deploys fresh RedemptionNFT + RAMMToken with multi-market authorization
///         support, replacing the old single-market versions where only the
///         first-ever deployed market (Agatha's) could mint/earn rewards.
///
/// Existing products' markets are immutably bound to the OLD RedemptionNFT/
/// RAMMToken addresses and cannot be repointed — every product's PVTToken +
/// IMPXMarket must be redeployed against these new addresses (see
/// agents/src/scripts/ — deployDemoProducts.ts / migrateCampaignContracts.ts).
///
/// Usage:
///   forge script script/RedeploySharedAuth.s.sol \
///     --rpc-url $BASE_SEPOLIA_RPC_URL \
///     --private-key $DEPLOYER_PRIVATE_KEY \
///     --broadcast -vvvv
contract RedeploySharedAuth is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer    = vm.addr(deployerKey);

        console2.log("Deployer:", deployer);

        vm.startBroadcast(deployerKey);

        RAMMToken rammToken = new RAMMToken(deployer);
        console2.log("RAMMToken:    ", address(rammToken));

        RedemptionNFT redemptionNFT = new RedemptionNFT(deployer);
        console2.log("RedemptionNFT:", address(redemptionNFT));

        vm.stopBroadcast();

        console2.log("\n=== Copy into agents/.env ===");
        console2.log("RAMM_TOKEN_ADDRESS:     ", address(rammToken));
        console2.log("REDEMPTION_NFT_ADDRESS: ", address(redemptionNFT));
    }
}
