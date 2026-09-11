// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

/// @title PVTTokenUpgradeable
/// @notice Product Voucher Token (0 decimals) compatible with BeaconProxy and UUPS upgradeable proxies.
contract PVTTokenUpgradeable is ERC20Upgradeable, OwnableUpgradeable, UUPSUpgradeable {
    string public productName;
    uint256 public supplyCap;
    uint256 public totalMinted;

    /// @notice Reserved storage gap for layout safety
    uint256[50] private __gap;

    event TokensBurned(address indexed burner, uint256 amount, uint256 timestamp);

    error SupplyCapExceeded(uint256 requested, uint256 remaining);
    error InsufficientBalance(uint256 requested, uint256 available);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        string memory _productName,
        string memory _symbol,
        uint256 _supplyCap,
        address _initialOwner
    ) external initializer {
        // Matches the real PVTToken.sol: ERC20(_productName, _symbol) — the
        // token's ERC20 name IS the product name (e.g. "Agatha by Elmira
        // Medins"), not a generic literal. The original constructor here
        // hardcoded ERC20("PVT", "PVT") — every proxy would have shared that
        // same wrong name/symbol AND, before this fix, an empty one (see
        // below) regardless of what _productName/_symbol were passed.
        __ERC20_init(_productName, _symbol);
        __Ownable_init(_initialOwner);
        productName = _productName;
        supplyCap = _supplyCap;
    }

    function mint(address to, uint256 amount) external onlyOwner {
        uint256 remaining = supplyCap - totalMinted;
        if (amount > remaining) {
            revert SupplyCapExceeded(amount, remaining);
        }
        totalMinted += amount;
        _mint(to, amount * 10 ** decimals());
    }

    function burn(uint256 amount) external {
        if (balanceOf(msg.sender) < amount) {
            revert InsufficientBalance(amount, balanceOf(msg.sender));
        }
        _burn(msg.sender, amount);
        emit TokensBurned(msg.sender, amount, block.timestamp);
    }

    function burnFrom(address from, uint256 amount) external onlyOwner {
        if (balanceOf(from) < amount) {
            revert InsufficientBalance(amount, balanceOf(from));
        }
        _burn(from, amount);
        if (totalMinted >= amount) totalMinted -= amount;
        emit TokensBurned(from, amount, block.timestamp);
    }

    function remainingSupply() external view returns (uint256) {
        return supplyCap - totalMinted;
    }

    function decimals() public pure override returns (uint8) {
        return 0;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
