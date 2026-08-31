// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title RAMMToken
/// @notice Platform reward token. Earned by buying PVTs and promoting drops.
///
/// Distribution (IMPXMarket handles automatic minting on buy):
///   - 100 RAMM per PVT purchased (buyer reward)
///   - Batch airdrop by owner for promoter rewards (off-chain tracking)
///
/// Hard cap: 1,000,000,000 RAMM (1B tokens, 18 decimals).
contract RAMMToken is ERC20, Ownable {
    uint256 public constant MAX_SUPPLY = 1_000_000_000 * 1e18;
    uint256 public totalMinted;

    /// @notice Markets allowed to mint. One RAMMToken contract is shared across
    ///         every product's IMPXMarket, so this must support many authorized
    ///         minters, not just one — each new campaign's market gets
    ///         authorized here automatically at deploy time (see VALET).
    mapping(address => bool) public authorizedMinters;

    event MinterAuthorized(address indexed minter, bool authorized);

    error MaxSupplyExceeded();
    error OnlyMinterOrOwner();

    modifier onlyMinterOrOwner() {
        if (!authorizedMinters[msg.sender] && msg.sender != owner()) revert OnlyMinterOrOwner();
        _;
    }

    constructor(address initialOwner) ERC20("RAMM", "RAMM") Ownable(initialOwner) {}

    function setMinterAuthorized(address _minter, bool _authorized) external onlyOwner {
        authorizedMinters[_minter] = _authorized;
        emit MinterAuthorized(_minter, _authorized);
    }

    /// @notice Mint RAMM to a single address (called by market on each buy).
    function mint(address to, uint256 amount) external onlyMinterOrOwner {
        if (totalMinted + amount > MAX_SUPPLY) revert MaxSupplyExceeded();
        totalMinted += amount;
        _mint(to, amount);
    }

    /// @notice Batch airdrop for promoter payouts (owner only).
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
}
