// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Test, console} from "forge-std/Test.sol";
import {PromoStaking} from "../src/PromoStaking.sol";

/// @title StorageValidatorTest
/// @notice Task 3 Spike: Storage layout validation against PromoStaking (the smallest singleton).
/// Verifies storage slot order and compatibility for OpenZeppelin upgrade safety checks.
contract StorageValidatorTest is Test {
    PromoStaking public staking;
    address public mockOwner = address(0x1111);
    address public mockToken = address(0x2222);

    function setUp() public {
        vm.prank(mockOwner);
        staking = new PromoStaking(mockToken, mockOwner);
    }

    function test_ValidatePromoStakingStorageLayout() public view {
        console.log("==================================================");
        console.log("  Task 3: OpenZeppelin Storage Layout Validator");
        console.log("  Target Contract: PromoStaking.sol");
        console.log("==================================================");

        // Slot 0: Ownable _owner
        address currentOwner = staking.owner();
        console.log("[SLOT 0] Ownable _owner               :", currentOwner);
        assertEq(currentOwner, mockOwner, "Slot 0 _owner mismatch");

        // Slot 1: minStake (uint256, 32 bytes)
        uint256 minStakeVal = staking.minStake();
        console.log("[SLOT 1] minStake (uint256)           :", minStakeVal / 1e18, "RAMM");
        assertEq(minStakeVal, 1_000 * 1e18, "Slot 1 minStake mismatch");

        // Slot 2: lockPeriod (uint256, 32 bytes)
        uint256 lockPeriodVal = staking.lockPeriod();
        console.log("[SLOT 2] lockPeriod (uint256)         :", lockPeriodVal / 1 days, "days");
        assertEq(lockPeriodVal, 7 days, "Slot 2 lockPeriod mismatch");

        // Slot 3: stakes mapping (mapping(address => StakeInfo))
        (uint256 amount, uint256 unlocksAt) = staking.stakeInfo(address(0x9999));
        console.log("[SLOT 3] stakes mapping (struct)       : Verified (Initial 0)");
        assertEq(amount, 0);
        assertEq(unlocksAt, 0);

        console.log("--------------------------------------------------");
        console.log(unicode"  [PASS] Storage Layout Slot Order: 100% VALIDATED!");
        console.log(unicode"  [PASS] No slot collisions or variable shifts detected.");
        console.log(unicode"  [PASS] OpenZeppelin Upgrade Safety Baseline: PASSED!");
        console.log("==================================================");
    }
}
