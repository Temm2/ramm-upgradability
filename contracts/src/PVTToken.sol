// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title PVTToken
/// @notice Product Voucher Token. Minted by IMPXMarket on successful swap.
///         Each unit represents one redeemable claim on the physical product.
/// @dev Owner is set to IMPXMarket after deployment via transferOwnership().
///      ERC-4337: Smart Account receives minted tokens directly.
contract PVTToken is ERC20, Ownable {
    /// @notice Human-readable product name embedded in token
    string public productName;

    /// @notice Total units available for this drop (hard cap)
    uint256 public immutable supplyCap;

    /// @notice Tracks total minted (burned tokens do not restore supply)
    uint256 public totalMinted;

    event TokensBurned(address indexed burner, uint256 amount, uint256 timestamp);

    error SupplyCapExceeded(uint256 requested, uint256 remaining);
    error InsufficientBalance(uint256 requested, uint256 available);

    /// @param _productName  Human-readable name e.g. "Neo Air Sneakers"
    /// @param _symbol       Token symbol e.g. "POPZ-NAS"
    /// @param _supplyCap    Hard cap on total mintable supply (e.g. 600)
    /// @param _initialOwner Deployer EOA — will transfer ownership to IMPXMarket
    constructor(
        string memory _productName,
        string memory _symbol,
        uint256 _supplyCap,
        address _initialOwner
    ) ERC20(_productName, _symbol) Ownable(_initialOwner) {
        productName = _productName;
        supplyCap = _supplyCap;
    }

    /// @notice Mint PVT to a buyer's Smart Account. Called only by IMPXMarket.
    /// @param to       Recipient Smart Account address
    /// @param amount   Number of tokens to mint (1 token = 1 unit)
    function mint(address to, uint256 amount) external onlyOwner {
        uint256 remaining = supplyCap - totalMinted;
        if (amount > remaining) {
            revert SupplyCapExceeded(amount, remaining);
        }
        totalMinted += amount;
        _mint(to, amount * 10 ** decimals());
    }

    /// @notice Burn PVT for redemption. Called by holder (via Folio agent UserOp).
    /// @param amount Number of tokens to burn (in base units)
    function burn(uint256 amount) external {
        if (balanceOf(msg.sender) < amount) {
            revert InsufficientBalance(amount, balanceOf(msg.sender));
        }
        _burn(msg.sender, amount);
        emit TokensBurned(msg.sender, amount, block.timestamp);
    }

    /// @notice Burn PVT from a seller's account on sell-back. Called only by IMPXMarket.
    ///         Decrements totalMinted so the supply can be re-issued (returns to pool).
    /// @param from   Seller's Smart Account address
    /// @param amount Number of tokens to burn
    function burnFrom(address from, uint256 amount) external onlyOwner {
        if (balanceOf(from) < amount) {
            revert InsufficientBalance(amount, balanceOf(from));
        }
        _burn(from, amount);
        if (totalMinted >= amount) totalMinted -= amount;
        emit TokensBurned(from, amount, block.timestamp);
    }

    /// @notice Remaining mintable supply
    function remainingSupply() external view returns (uint256) {
        return supplyCap - totalMinted;
    }

    /// @notice PVT uses 0 decimals — 1 token = 1 physical unit
    function decimals() public pure override returns (uint8) {
        return 0;
    }
}
