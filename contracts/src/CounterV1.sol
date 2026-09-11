// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

/// @title CounterV1
/// @notice Toy UUPS upgradeable contract to demonstrate storage preservation and upgrade mechanics in isolation.
contract CounterV1 is OwnableUpgradeable, UUPSUpgradeable {
    uint256 public count;

    /// @notice Reserved storage slots for future upgradeable state variables
    uint256[50] private __gap;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializer replacing constructor for proxy deployment
    function initialize(address initialOwner, uint256 _initialCount) external initializer {
        __Ownable_init(initialOwner);
        count = _initialCount;
    }

    function increment() external {
        count += 1;
    }

    /// @notice Authorization check required by UUPSUpgradeable pattern
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
