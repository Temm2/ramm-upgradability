// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

/// @title RAMMTokenUpgradeable
/// @notice Upgradeable version of RAMMToken platform reward token behind UUPS proxy.
contract RAMMTokenUpgradeable is ERC20, Ownable, Initializable, UUPSUpgradeable {
    uint256 public constant MAX_SUPPLY = 1_000_000_000 * 1e18;
    uint256 public totalMinted;

    mapping(address => bool) public authorizedMinters;

    /// @notice Reserved storage gap for future layout preservation
    uint256[50] private __gap;

    event MinterAuthorized(address indexed minter, bool authorized);

    error MaxSupplyExceeded();
    error OnlyMinterOrOwner();

    modifier onlyMinterOrOwner() {
        if (!authorizedMinters[msg.sender] && msg.sender != owner()) revert OnlyMinterOrOwner();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() ERC20("RAMM", "RAMM") Ownable(msg.sender) {
        _disableInitializers();
    }

    function initialize(address initialOwner) external initializer {
        _transferOwnership(initialOwner);
    }

    function setMinterAuthorized(address _minter, bool _authorized) external onlyOwner {
        authorizedMinters[_minter] = _authorized;
        emit MinterAuthorized(_minter, _authorized);
    }

    function mint(address to, uint256 amount) external onlyMinterOrOwner {
        if (totalMinted + amount > MAX_SUPPLY) revert MaxSupplyExceeded();
        totalMinted += amount;
        _mint(to, amount);
    }

    function batchMint(address[] calldata recipients, uint256[] calldata amounts) external onlyOwner {
        require(recipients.length == amounts.length, "Length mismatch");
        uint256 total;
        for (uint256 i; i < amounts.length; ++i) total += amounts[i];
        if (totalMinted + total > MAX_SUPPLY) revert MaxSupplyExceeded();
        totalMinted += total;
        for (uint256 i; i < recipients.length; ++i) {
            _mint(recipients[i], amounts[i]);
        }
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
