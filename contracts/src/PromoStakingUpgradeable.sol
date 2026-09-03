// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

/// @title PromoStakingUpgradeable
/// @notice Upgradeable RAMM promoter staking gate contract behind UUPS proxy.
contract PromoStakingUpgradeable is Ownable, ReentrancyGuard, Initializable, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    IERC20 public rammToken;
    uint256 public minStake;
    uint256 public lockPeriod;

    struct StakeInfo {
        uint256 amount;
        uint256 stakedAt;
    }

    mapping(address => StakeInfo) public stakes;

    /// @notice Reserved storage gap for layout safety
    uint256[50] private __gap;

    event Staked(address indexed promoter, uint256 amount, uint256 stakedAt);
    event Unstaked(address indexed promoter, uint256 amount);
    event MinStakeUpdated(uint256 oldMin, uint256 newMin);
    event LockPeriodUpdated(uint256 oldPeriod, uint256 newPeriod);

    error BelowMinStake(uint256 provided, uint256 required);
    error NothingStaked();
    error StillLocked(uint256 unlocksAt, uint256 currentTime);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() Ownable(msg.sender) {
        _disableInitializers();
    }

    function initialize(address _rammToken, address _initialOwner) external initializer {
        _transferOwnership(_initialOwner);
        rammToken = IERC20(_rammToken);
        minStake = 1_000 * 1e18;
        lockPeriod = 7 days;
    }

    function stake(uint256 amount) external nonReentrant {
        StakeInfo storage s = stakes[msg.sender];
        uint256 newTotal = s.amount + amount;
        if (newTotal < minStake) revert BelowMinStake(newTotal, minStake);

        rammToken.safeTransferFrom(msg.sender, address(this), amount);
        s.amount = newTotal;
        s.stakedAt = block.timestamp;

        emit Staked(msg.sender, newTotal, block.timestamp);
    }

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

    function isPromoter(address addr) external view returns (bool) {
        return stakes[addr].amount >= minStake;
    }

    function stakeInfo(address addr) external view returns (uint256 amount, uint256 unlocksAt) {
        StakeInfo storage s = stakes[addr];
        amount = s.amount;
        unlocksAt = s.stakedAt > 0 ? s.stakedAt + lockPeriod : 0;
    }

    function setMinStake(uint256 newMin) external onlyOwner {
        emit MinStakeUpdated(minStake, newMin);
        minStake = newMin;
    }

    function setLockPeriod(uint256 newPeriod) external onlyOwner {
        emit LockPeriodUpdated(lockPeriod, newPeriod);
        lockPeriod = newPeriod;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
