// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title RammRegistry
/// @notice Single canonical source of truth for the four shared, platform-wide
///         singleton contracts every IMPXMarket depends on. Markets store only
///         this registry's address as `immutable` — never the shared contracts'
///         addresses directly — and look them up dynamically on every call.
///
/// Why this exists: before this contract, every IMPXMarket stored `RAMMToken`,
/// `RedemptionNFT`, `VestingVault`, and `PromoStaking` as `immutable` fields set
/// at construction. Fixing a bug in any one of those four meant deploying a new
/// version AND redeploying every single market that referenced the old address
/// — on testnet, an annoying but free operation (already done twice this
/// project); on mainnet, it would mean stranding real user funds and positions
/// on markets that can never be pointed at the fix. With this registry, rolling
/// out a fix is one `setX()` call — every market, old and new, picks up the new
/// address on its very next call, no redeploy.
///
/// USDC and each market's own PVTToken are deliberately NOT in here — USDC is
/// an external, essentially-immutable dependency (the one-time mock-to-real
/// swap is a distinct migration, not an ongoing "fix and redeploy" problem),
/// and PVTToken is already per-market/per-product, not a shared singleton.
contract RammRegistry is Ownable {
    address public rammToken;
    address public redemptionNFT;
    address public vestingVault;
    address public promoStaking;

    event RammTokenUpdated(address indexed oldAddr, address indexed newAddr);
    event RedemptionNFTUpdated(address indexed oldAddr, address indexed newAddr);
    event VestingVaultUpdated(address indexed oldAddr, address indexed newAddr);
    event PromoStakingUpdated(address indexed oldAddr, address indexed newAddr);

    error ZeroAddress();

    constructor(
        address _initialOwner,
        address _rammToken,
        address _redemptionNFT,
        address _vestingVault,
        address _promoStaking
    ) Ownable(_initialOwner) {
        if (_rammToken == address(0) || _redemptionNFT == address(0) || _vestingVault == address(0) || _promoStaking == address(0)) {
            revert ZeroAddress();
        }
        rammToken = _rammToken;
        redemptionNFT = _redemptionNFT;
        vestingVault = _vestingVault;
        promoStaking = _promoStaking;
    }

    function setRammToken(address addr) external onlyOwner {
        if (addr == address(0)) revert ZeroAddress();
        emit RammTokenUpdated(rammToken, addr);
        rammToken = addr;
    }

    function setRedemptionNFT(address addr) external onlyOwner {
        if (addr == address(0)) revert ZeroAddress();
        emit RedemptionNFTUpdated(redemptionNFT, addr);
        redemptionNFT = addr;
    }

    function setVestingVault(address addr) external onlyOwner {
        if (addr == address(0)) revert ZeroAddress();
        emit VestingVaultUpdated(vestingVault, addr);
        vestingVault = addr;
    }

    function setPromoStaking(address addr) external onlyOwner {
        if (addr == address(0)) revert ZeroAddress();
        emit PromoStakingUpdated(promoStaking, addr);
        promoStaking = addr;
    }
}
