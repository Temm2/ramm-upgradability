// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title CampaignValet
/// @notice Per-campaign smart wallet. Receives the brand's 93% revenue share on
///         every PVT purchase. Designed for thousands of instances (one per campaign).
///
/// Revenue split on each buy (set by IMPXMarket):
///   93% → brand (this contract)
///    6% → promoter pool (tracked off-chain via PROMO agent, paid in $RAMM — MVP2+)
///    1% → RAMM platform wallet
///
/// The brand (owner) can withdraw accumulated USDC at any time.
/// Future: escrow, scheduled payouts, multi-sig brand wallets.
contract CampaignValet is Ownable {
    using SafeERC20 for IERC20;

    IERC20 public immutable usdc;

    /// @notice Total USDC received by this valet across all purchases
    uint256 public totalReceived;

    /// @notice Total USDC withdrawn by the brand
    uint256 public totalWithdrawn;

    event RevenueReceived(uint256 amount, uint256 totalReceived, uint256 timestamp);
    event RevenueWithdrawn(address indexed to, uint256 amount, uint256 timestamp);

    error ZeroBalance();

    constructor(address _usdc, address _brandOwner) Ownable(_brandOwner) {
        usdc = IERC20(_usdc);
    }

    /// @notice Called by IMPXMarket on each purchase to deposit brand share.
    ///         Anyone can call (market pushes funds here — no auth needed since
    ///         the USDC transfer itself is the proof of legitimacy).
    function receiveRevenue(uint256 amount) external {
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        totalReceived += amount;
        emit RevenueReceived(amount, totalReceived, block.timestamp);
    }

    /// @notice Brand withdraws all accumulated USDC.
    function withdraw(address to) external onlyOwner {
        uint256 balance = usdc.balanceOf(address(this));
        if (balance == 0) revert ZeroBalance();
        totalWithdrawn += balance;
        usdc.safeTransfer(to, balance);
        emit RevenueWithdrawn(to, balance, block.timestamp);
    }

    /// @notice Withdraw a specific amount (partial withdrawal).
    function withdrawAmount(address to, uint256 amount) external onlyOwner {
        if (amount == 0 || usdc.balanceOf(address(this)) < amount) revert ZeroBalance();
        totalWithdrawn += amount;
        usdc.safeTransfer(to, amount);
        emit RevenueWithdrawn(to, amount, block.timestamp);
    }

    function balance() external view returns (uint256) {
        return usdc.balanceOf(address(this));
    }
}
