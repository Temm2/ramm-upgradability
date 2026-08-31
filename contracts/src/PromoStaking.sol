// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PromoStaking — PRD Workflow E: Gate promoter access via RAMM token stake
///
/// Promoters stake RAMM to unlock the PROMO agent and earn referral rewards.
/// Anti-spam: minimum stake prevents wash-trading via throwaway wallets.
///
/// Flow:
///   1. User holds RAMM tokens (earned by buying PVTs)
///   2. User calls stake(amount ≥ MIN_STAKE) → becomes a verified promoter
///   3. IMPXMarket checks isPromoter(addr) before crediting referral rewards
///   4. User can unstake after LOCK_PERIOD (prevents stake→spam→unstake)
contract PromoStaking is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─── Config ──────────────────────────────────────────────────────────────

    IERC20 public immutable rammToken;

    /// @notice Minimum RAMM stake required to become a promoter (1,000 RAMM)
    uint256 public minStake = 1_000 * 1e18;

    /// @notice Lock period before unstaking is allowed (7 days anti-spam)
    uint256 public lockPeriod = 7 days;

    // ─── State ───────────────────────────────────────────────────────────────

    struct StakeInfo {
        uint256 amount;
        uint256 stakedAt;
    }

    mapping(address => StakeInfo) public stakes;

    // ─── Events ──────────────────────────────────────────────────────────────

    event Staked(address indexed promoter, uint256 amount, uint256 stakedAt);
    event Unstaked(address indexed promoter, uint256 amount);
    event MinStakeUpdated(uint256 oldMin, uint256 newMin);
    event LockPeriodUpdated(uint256 oldPeriod, uint256 newPeriod);

    // ─── Errors ──────────────────────────────────────────────────────────────

    error BelowMinStake(uint256 provided, uint256 required);
    error NothingStaked();
    error StillLocked(uint256 unlocksAt, uint256 currentTime);

    // ─────────────────────────────────────────────────────────────────────────

    constructor(address _rammToken, address _initialOwner) Ownable(_initialOwner) {
        rammToken = IERC20(_rammToken);
    }

    // ─── Stake ───────────────────────────────────────────────────────────────

    /// @notice Stake RAMM tokens to become a verified promoter.
    ///         Adding to an existing stake resets the lock period.
    function stake(uint256 amount) external nonReentrant {
        StakeInfo storage s = stakes[msg.sender];
        uint256 newTotal = s.amount + amount;
        if (newTotal < minStake) revert BelowMinStake(newTotal, minStake);

        rammToken.safeTransferFrom(msg.sender, address(this), amount);
        s.amount = newTotal;
        s.stakedAt = block.timestamp;

        emit Staked(msg.sender, newTotal, block.timestamp);
    }

    // ─── Unstake ─────────────────────────────────────────────────────────────

    /// @notice Withdraw staked RAMM after lock period has elapsed.
    function unstake() external nonReentrant {
        StakeInfo storage s = stakes[msg.sender];
        if (s.amount == 0) revert NothingStaked();

        uint256 unlocksAt = s.stakedAt + lockPeriod;
        if (block.timestamp < unlocksAt) revert StillLocked(unlocksAt, block.timestamp);

        uint256 amount = s.amount;
        s.amount = 0;
        s.stakedAt = 0;

        rammToken.safeTransfer(msg.sender, amount);
        emit Unstaked(msg.sender, amount);
    }

    // ─── View ────────────────────────────────────────────────────────────────

    /// @notice Returns true if addr has staked at least minStake RAMM.
    function isPromoter(address addr) external view returns (bool) {
        return stakes[addr].amount >= minStake;
    }

    /// @notice Returns staked amount and unlock timestamp for addr.
    function stakeInfo(address addr) external view returns (uint256 amount, uint256 unlocksAt) {
        StakeInfo storage s = stakes[addr];
        amount = s.amount;
        unlocksAt = s.stakedAt > 0 ? s.stakedAt + lockPeriod : 0;
    }

    // ─── Admin ───────────────────────────────────────────────────────────────

    function setMinStake(uint256 newMin) external onlyOwner {
        emit MinStakeUpdated(minStake, newMin);
        minStake = newMin;
    }

    function setLockPeriod(uint256 newPeriod) external onlyOwner {
        emit LockPeriodUpdated(lockPeriod, newPeriod);
        lockPeriod = newPeriod;
    }
}
