// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {RAMMTokenUpgradeable} from "../src/RAMMTokenUpgradeable.sol";
import {PVTTokenUpgradeable} from "../src/PVTTokenUpgradeable.sol";

/// @notice Regression test for a real bug found in review: the original
/// RAMMTokenUpgradeable/PVTTokenUpgradeable set their ERC20 name/symbol only
/// in the constructor (regular ERC20), which never reaches a proxy's actual
/// storage — every deployed proxy's name()/symbol() would have returned "".
/// Confirmed empty before the __ERC20_init() fix; asserted correct here so
/// it can never silently regress.
contract NameCheckTest is Test {
    function test_RAMMTokenProxyHasRealNameAndSymbol() public {
        RAMMTokenUpgradeable impl = new RAMMTokenUpgradeable();
        bytes memory initData = abi.encodeCall(RAMMTokenUpgradeable.initialize, (address(0xBEEF)));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        RAMMTokenUpgradeable token = RAMMTokenUpgradeable(address(proxy));

        assertEq(token.name(), "RAMM");
        assertEq(token.symbol(), "RAMM");
    }

    function test_PVTTokenProxyUsesRealProductNameAndSymbol() public {
        PVTTokenUpgradeable impl = new PVTTokenUpgradeable();
        bytes memory initData = abi.encodeCall(
            PVTTokenUpgradeable.initialize,
            ("Agatha by Elmira Medins", "EM-AGT", 30, address(0xBEEF))
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        PVTTokenUpgradeable token = PVTTokenUpgradeable(address(proxy));

        // Not just non-empty — must match the actual product, not a
        // hardcoded generic literal (the second bug found alongside the first).
        assertEq(token.name(), "Agatha by Elmira Medins");
        assertEq(token.symbol(), "EM-AGT");
    }
}
