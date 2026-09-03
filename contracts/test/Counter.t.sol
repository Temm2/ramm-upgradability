// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Test, console} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {CounterV1} from "../src/CounterV1.sol";
import {CounterV2} from "../src/CounterV2.sol";

contract CounterTest is Test {
    CounterV1 public implV1;
    CounterV2 public implV2;
    ERC1967Proxy public proxy;

    CounterV1 public proxyAsV1;
    CounterV2 public proxyAsV2;

    address public owner = address(0x1111);
    address public alice = address(0x2222);

    function setUp() public {
        vm.startPrank(owner);

        // 1. Deploy Implementation V1
        implV1 = new CounterV1();

        // 2. Prepare initialize data (count = 10)
        bytes memory initData = abi.encodeWithSelector(CounterV1.initialize.selector, owner, 10);

        // 3. Deploy ERC1967Proxy pointing to implV1
        proxy = new ERC1967Proxy(address(implV1), initData);
        proxyAsV1 = CounterV1(address(proxy));

        vm.stopPrank();
    }

    function test_InitialStateAndIncrement() public view {
        assertEq(proxyAsV1.owner(), owner);
        assertEq(proxyAsV1.count(), 10);
    }

    function test_IncrementOnV1() public {
        vm.prank(owner);
        proxyAsV1.increment();
        assertEq(proxyAsV1.count(), 11);
    }

    function test_UpgradeToV2AndPreserveState() public {
        console.log("--------------------------------------------------");
        console.log("[STEP 1] Initializing CounterV1 behind ERC1967Proxy");
        console.log("Proxy Address        :", address(proxy));
        console.log("Implementation V1    :", address(implV1));
        
        // Step A: Increment on V1
        vm.prank(owner);
        proxyAsV1.increment(); // count becomes 11
        console.log("[STEP 2] Count incremented on V1 -> Current Count:", proxyAsV1.count());
        assertEq(proxyAsV1.count(), 11);

        // Step B: Deploy Implementation V2
        vm.startPrank(owner);
        implV2 = new CounterV2();
        console.log("--------------------------------------------------");
        console.log("[STEP 3] Deploying Implementation V2 at:", address(implV2));

        // Step C: Upgrade Proxy to V2 using UUPS upgradeToAndCall
        proxyAsV1.upgradeToAndCall(address(implV2), "");
        proxyAsV2 = CounterV2(address(proxy));
        vm.stopPrank();

        console.log("[STEP 4] Proxy upgraded to V2!");
        console.log("Proxy Address (Same!):", address(proxy));
        console.log("Count after upgrade  :", proxyAsV2.count(), "(PRESERVED!)");
        
        // Step D: Verify STATE PRESERVATION (count is STILL 11!)
        assertEq(proxyAsV2.count(), 11);
        assertEq(proxyAsV2.owner(), owner);

        // Step E: Verify NEW V2 Functions work!
        vm.startPrank(owner);
        proxyAsV2.setMultiplier(2);
        proxyAsV2.incrementBy(5); // 11 + (5 * 2) = 21
        console.log("[STEP 5] V2 incrementBy(5) with multiplier=2 -> New Count:", proxyAsV2.count());
        assertEq(proxyAsV2.count(), 21);

        proxyAsV2.decrement(); // 21 - 1 = 20
        console.log("[STEP 6] V2 decrement() -> Final Count:", proxyAsV2.count());
        assertEq(proxyAsV2.count(), 20);
        console.log("--------------------------------------------------");
        vm.stopPrank();
    }

    function test_RevertNonOwnerUpgrade() public {
        vm.prank(owner);
        implV2 = new CounterV2();

        // Non-owner (Alice) tries to upgrade proxy -> should revert!
        vm.prank(alice);
        vm.expectRevert();
        proxyAsV1.upgradeToAndCall(address(implV2), "");
    }
}
