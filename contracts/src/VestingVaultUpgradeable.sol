// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

interface IBrandWallet {
    function brandWallet() external view returns (address);
}

/// @title VestingVaultUpgradeable
/// @notice Upgradeable time-locked promoter reward escrow vault behind UUPS proxy.
contract VestingVaultUpgradeable is Ownable, ReentrancyGuard, Initializable, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    IERC20 public usdc;
    uint256 public vestingPeriod;

    mapping(address => bool) public authorizedMarkets;

    struct Tranche {
        uint256 amount;
        uint256 unlocksAt;
        bool claimed;
        address market;
        bool fulfilled;
    }

    mapping(address => Tranche[]) public tranches;
    mapping(address => uint256) public pendingBalance;

    /// @notice Storage gap for upgrade safety
    uint256[50] private __gap;

    event Credited(address indexed promoter, uint256 amount, uint256 unlocksAt, uint256 trancheIndex, address indexed market);
    event Claimed(address indexed promoter, uint256 amount, uint256 tranchesClaimed);
    event MarketAuthorized(address indexed market, bool authorized);
    event VestingPeriodUpdated(uint256 oldPeriod, uint256 newPeriod);
    event Fulfilled(address indexed promoter, uint256 indexed trancheIndex, address indexed brandWallet);

    error OnlyMarket();
    error NothingToClaim();
    error OnlyBrand();
    error InvalidTranche();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() Ownable(msg.sender) {
        _disableInitializers();
    }

    function initialize(address _usdc, address _initialOwner) external initializer {
        _transferOwnership(_initialOwner);
        usdc = IERC20(_usdc);
        vestingPeriod = 7 days;
    }

    modifier onlyMarket() {
        if (!authorizedMarkets[msg.sender]) revert OnlyMarket();
        _;
    }

    function credit(address promoter, uint256 amount) external onlyMarket {
        uint256 unlocksAt = block.timestamp + vestingPeriod;
        uint256 idx = tranches[promoter].length;
        tranches[promoter].push(Tranche({
            amount: amount, unlocksAt: unlocksAt, claimed: false, market: msg.sender, fulfilled: false
        }));
        pendingBalance[promoter] += amount;
        emit Credited(promoter, amount, unlocksAt, idx, msg.sender);
    }

    function markFulfilled(address promoter, uint256 trancheIndex) external {
        Tranche[] storage myTranches = tranches[promoter];
        if (trancheIndex >= myTranches.length) revert InvalidTranche();
        Tranche storage t = myTranches[trancheIndex];
        if (IBrandWallet(t.market).brandWallet() != msg.sender) revert OnlyBrand();
        t.fulfilled = true;
        emit Fulfilled(promoter, trancheIndex, msg.sender);
    }

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

    function getTranches(address promoter) external view returns (Tranche[] memory) {
        return tranches[promoter];
    }

    function setMarketAuthorized(address _market, bool _authorized) external onlyOwner {
        authorizedMarkets[_market] = _authorized;
        emit MarketAuthorized(_market, _authorized);
    }

    function setVestingPeriod(uint256 newPeriod) external onlyOwner {
        emit VestingPeriodUpdated(vestingPeriod, newPeriod);
        vestingPeriod = newPeriod;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
