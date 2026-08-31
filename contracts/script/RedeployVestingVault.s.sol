// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Script, console2} from "forge-std/Script.sol";
import {VestingVault} from "../src/VestingVault.sol";

/// @notice Deploys a fresh VestingVault with multi-market authorization support,
///         replacing the old single-market version where only one IMPXMarket
///         could ever be authorized to credit a promoter's escrow tranche.
///
/// Existing products' markets are immutably bound to the OLD VestingVault
/// address and cannot be repointed — every product's PVTToken + IMPXMarket
/// must be redeployed against this new address (see
/// agents/src/scripts/deployDemoProducts.ts / migrateCampaignContracts.ts).
///
/// RedemptionNFT, RAMMToken, PromoStaking, and MockUSDC are unaffected and
/// reused as-is — only VestingVault's authorization model changed.
///
/// Usage:
///   forge script script/RedeployVestingVault.s.sol \
///     --rpc-url $BASE_SEPOLIA_RPC_URL \
///     --private-key $DEPLOYER_PRIVATE_KEY \
///     --broadcast -vvvv
contract RedeployVestingVault is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer    = vm.addr(deployerKey);
        address usdc        = vm.envAddress("USDC_ADDRESS");

        console2.log("Deployer:", deployer);
        console2.log("USDC:    ", usdc);

        vm.startBroadcast(deployerKey);

        VestingVault vestingVault = new VestingVault(usdc, deployer);
        console2.log("VestingVault:", address(vestingVault));

        vm.stopBroadcast();

        console2.log("\n=== Copy into agents/.env and app/constants/env.ts ===");
        console2.log("VESTING_VAULT_ADDRESS:", address(vestingVault));
    }
}
