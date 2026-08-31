// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Minimal interface into IMPXMarket — just enough to look up which
///         brand wallet is allowed to confirm fulfillment for a tranche's
///         campaign, without importing IMPXMarket itself (it already imports
///         VestingVault, so importing it back here would be circular).
interface IBrandWallet {
    function brandWallet() external view returns (address);
}

/// @title VestingVault — PRD Workflow E: Time-locked promoter reward escrow
///
/// Rewards from referral purchases are held here until BOTH conditions are
/// met: the vesting period has elapsed (anti-wash-trade — stake, self-refer,
/// immediately claim, unstake), AND the campaign's brand has confirmed the
/// underlying sale is fulfilled (shipped, no dispute). Time alone is not
/// enough to release funds — a brand withholding fulfillment keeps a tranche
/// locked indefinitely regardless of how long it's been.
///
/// Flow:
///   1. IMPXMarket detects referralCode in tx calldata, verifies promoter stake
///   2. IMPXMarket routes 6% USDC to VestingVault.credit(promoter, amount)
///   3. VestingVault records a Tranche: {amount, unlocksAt = now + VESTING_PERIOD, fulfilled = false}
///   4. The campaign's brand wallet calls markFulfilled() once the order has
///      shipped without dispute
///   5. Once VESTING_PERIOD has elapsed AND the tranche is fulfilled, the
///      promoter calls claim() to withdraw
///
/// Multiple tranches accumulate independently — each purchase creates its own tranche.
contract VestingVault is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─── Config ──────────────────────────────────────────────────────────────

    IERC20 public immutable usdc;

    /// @notice Time before a reward tranche can be claimed (7 days anti-fraud)
    uint256 public vestingPeriod = 7 days;

    /// @notice Markets authorised to credit new tranches. One VestingVault is
    ///         shared across every product's IMPXMarket, so this must support
    ///         many authorized callers, not just one — each new campaign's
    ///         market gets authorized here automatically at deploy time (see
    ///         VALET's createCampaign, mirroring the same pattern already used
    ///         for RedemptionNFT/RAMMToken).
    mapping(address => bool) public authorizedMarkets;

    // ─── State ───────────────────────────────────────────────────────────────

    struct Tranche {
        uint256 amount;
        uint256 unlocksAt;
        bool claimed;
        address market;    // which product's IMPXMarket credited this tranche —
                            // also the campaign whose brandWallet may fulfill it.
        bool fulfilled;     // set by that campaign's brand wallet via
                            // markFulfilled() — release requires this AND the
                            // vesting timer, not time alone.
    }

    /// promoter → list of tranches
    mapping(address => Tranche[]) public tranches;

    /// promoter → total unclaimed USDC (includes locked)
    mapping(address => uint256) public pendingBalance;

    // ─── Events ──────────────────────────────────────────────────────────────

    event Credited(address indexed promoter, uint256 amount, uint256 unlocksAt, uint256 trancheIndex, address indexed market);
    event Claimed(address indexed promoter, uint256 amount, uint256 tranchesClaimed);
    event MarketAuthorized(address indexed market, bool authorized);
    event VestingPeriodUpdated(uint256 oldPeriod, uint256 newPeriod);
    event Fulfilled(address indexed promoter, uint256 indexed trancheIndex, address indexed brandWallet);

    // ─── Errors ──────────────────────────────────────────────────────────────

    error OnlyMarket();
    error NothingToClaim();
    error OnlyBrand();
    error InvalidTranche();

    // ─────────────────────────────────────────────────────────────────────────

    constructor(address _usdc, address _initialOwner) Ownable(_initialOwner) {
        usdc = IERC20(_usdc);
    }

    modifier onlyMarket() {
        if (!authorizedMarkets[msg.sender]) revert OnlyMarket();
        _;
    }

    // ─── Credit (called by IMPXMarket on each referral purchase) ─────────────

    /// @notice Record a new reward tranche for a promoter.
    ///         IMPXMarket must transfer USDC to this contract before calling.
    function credit(address promoter, uint256 amount) external onlyMarket {
        uint256 unlocksAt = block.timestamp + vestingPeriod;
        uint256 idx = tranches[promoter].length;
        tranches[promoter].push(Tranche({
            amount: amount, unlocksAt: unlocksAt, claimed: false, market: msg.sender, fulfilled: false
        }));
        pendingBalance[promoter] += amount;
        emit Credited(promoter, amount, unlocksAt, idx, msg.sender);
    }

    // ─── Fulfillment (called by the campaign's brand wallet) ─────────────────

    /// @notice The brand confirms this specific tranche's underlying sale is
    ///         fulfilled (shipped, no dispute) — one of the two conditions,
    ///         alongside the vesting timer, required before it's claimable.
    ///         Only the brandWallet of the market that credited this tranche
    ///         may call this for it — read live off that market, not cached,
    ///         so it always reflects the campaign's real current brand wallet.
    function markFulfilled(address promoter, uint256 trancheIndex) external {
        Tranche[] storage myTranches = tranches[promoter];
        if (trancheIndex >= myTranches.length) revert InvalidTranche();
        Tranche storage t = myTranches[trancheIndex];
        if (IBrandWallet(t.market).brandWallet() != msg.sender) revert OnlyBrand();
        t.fulfilled = true;
        emit Fulfilled(promoter, trancheIndex, msg.sender);
    }

    // ─── Claim ────────────────────────────────────────────────────────────────

    /// @notice Claim all vested-and-fulfilled tranches in one tx.
    function claim() external nonReentrant {
        Tranche[] storage myTranches = tranches[msg.sender];
        uint256 total = 0;
        uint256 claimed = 0;

        for (uint256 i = 0; i < myTranches.length; i++) {
            Tranche storage t = myTranches[i];
            if (!t.claimed && t.fulfilled && block.timestamp >= t.unlocksAt) {
                total += t.amount;
                t.claimed = true;
                claimed++;
            }
        }

        if (total == 0) revert NothingToClaim();

        pendingBalance[msg.sender] -= total;
        usdc.safeTransfer(msg.sender, total);

        emit Claimed(msg.sender, total, claimed);
    }

    // ─── View ─────────────────────────────────────────────────────────────────

    /// @notice Returns claimable (vested AND fulfilled) and locked (everything
    ///         else still pending — on time, on fulfillment, or both) USDC.
    function balanceOf(address promoter)
        external
        view
        returns (uint256 claimable, uint256 locked)
    {
        Tranche[] storage myTranches = tranches[promoter];
        for (uint256 i = 0; i < myTranches.length; i++) {
            Tranche storage t = myTranches[i];
            if (t.claimed) continue;
            if (t.fulfilled && block.timestamp >= t.unlocksAt) {
                claimable += t.amount;
            } else {
                locked += t.amount;
            }
        }
    }

    /// @notice Returns all tranches for a promoter.
    function getTranches(address promoter) external view returns (Tranche[] memory) {
        return tranches[promoter];
    }

    // ─── Admin ────────────────────────────────────────────────────────────────

    function setMarketAuthorized(address _market, bool _authorized) external onlyOwner {
        authorizedMarkets[_market] = _authorized;
        emit MarketAuthorized(_market, _authorized);
    }

    function setVestingPeriod(uint256 newPeriod) external onlyOwner {
        emit VestingPeriodUpdated(vestingPeriod, newPeriod);
        vestingPeriod = newPeriod;
    }
}
