// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title MockUSDC
/// @notice Testnet-only mintable USDC stand-in. 6 decimals to match mainnet Circle USDC.
/// @dev Deploy this first. Address is passed into IMPXMarket constructor.
contract MockUSDC is ERC20, Ownable {
    uint8 private constant _DECIMALS = 6;

    /// @param initialOwner Deployer EOA — receives initial supply and mint rights
    constructor(address initialOwner)
        ERC20("USD Coin", "USDC")
        Ownable(initialOwner)
    {
        // Mint 10,000,000 USDC to deployer for testnet distribution
        _mint(initialOwner, 10_000_000 * 10 ** _DECIMALS);
    }

    /// @notice Mint USDC to any address (testnet only — remove on mainnet)
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    /// @notice Faucet function — anyone can claim 1,000 USDC for testing
    function faucet() external {
        _mint(msg.sender, 1_000 * 10 ** _DECIMALS);
    }

    function decimals() public pure override returns (uint8) {
        return _DECIMALS;
    }
}
