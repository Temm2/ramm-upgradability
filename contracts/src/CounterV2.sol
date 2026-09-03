// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {CounterV1} from "./CounterV1.sol";

/// @title CounterV2
/// @notice V2 upgrade adding new functionality (incrementBy, decrement, multiplier) while preserving CounterV1 storage layout.
contract CounterV2 is CounterV1 {
    uint256 public multiplier;

    function setMultiplier(uint256 _multiplier) external onlyOwner {
        multiplier = _multiplier;
    }

    function incrementBy(uint256 amount) external {
        count += amount * (multiplier > 0 ? multiplier : 1);
    }

    function decrement() external {
        require(count > 0, "Counter: count cannot be negative");
        count -= 1;
    }
}
