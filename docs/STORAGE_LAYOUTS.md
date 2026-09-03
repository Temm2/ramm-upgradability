# Storage Layout Artifact: The Four Platform Singletons

This document serves as the **authoritative storage layout reference** for the four shared platform singleton contracts (`RAMMToken`, `RedemptionNFT`, `VestingVault`, and `PromoStaking`). 

It directly fulfills **Task 2 of the client's upgradability pipeline** and acts as the mandatory prerequisite artifact for **Task 4 (Storage Gap Discipline)** to guarantee zero storage collisions or variable reordering during UUPS upgradeable proxy migration.

---

## 1. Overview & Storage Rules for UUPS Upgradeability

When converting standard contracts into `@openzeppelin/contracts-upgradeable` UUPS proxies, the following EVM storage rules MUST be enforced:

1. **Storage Slot Preservation**: Existing state variable slots MUST NOT be reordered, deleted, or repurposed.
2. **Inheritance Order Parity**: The layout of inherited base contracts (`ERC20Upgradeable`, `ERC1155Upgradeable`, `OwnableUpgradeable`, `ReentrancyGuardUpgradeable`) must align strictly with storage slot declarations.
3. **Immutable to Storage Migration**: Variables declared as `immutable` in non-upgradeable contracts (e.g., `usdc` in `VestingVault`, `rammToken` in `PromoStaking`) do not occupy storage slots today. Converting them to state variables in upgradeable implementations requires appending them at the end of the contract storage layout or after standard gaps.
4. **Storage Gap Reserve**: Every upgradeable contract must declare `uint256[50] private __gap;` at the end of its storage definitions to allow future state expansion without shifting downstream storage slots.

---

## 2. Singleton Storage Layout Maps

### 2.1 `RAMMToken.sol`
- **Contract Name**: `RAMMToken`
- **Compiler Version**: `0.8.23`
- **Inheritance Hierarchy**: `RAMMToken` → `ERC20` → `Ownable`

| Slot | Offset | Bytes | Variable Name | Type | Source Contract | Description / Upgrade Notes |
| :---: | :---: | :---: | :--- | :--- | :--- | :--- |
| **0** | 0 | 32 | `_balances` | `mapping(address => uint256)` | `ERC20` | Token balances mapping |
| **1** | 0 | 32 | `_allowances` | `mapping(address => mapping(address => uint256))` | `ERC20` | Spender approvals mapping |
| **2** | 0 | 32 | `_totalSupply` | `uint256` | `ERC20` | Total minted supply |
| **3** | 0 | 32 | `_name` | `string` | `ERC20` | Token name ("RAMM") |
| **4** | 0 | 32 | `_symbol` | `string` | `ERC20` | Token symbol ("RAMM") |
| **5** | 0 | 20 | `_owner` | `address` | `Ownable` | Contract admin / deployer |
| **6** | 0 | 32 | `totalMinted` | `uint256` | `RAMMToken` | Total cumulative minted RAMM |
| **7** | 0 | 32 | `authorizedMinters` | `mapping(address => bool)` | `RAMMToken` | Authorized market minters |

---

### 2.2 `RedemptionNFT.sol`
- **Contract Name**: `RedemptionNFT`
- **Compiler Version**: `0.8.23`
- **Inheritance Hierarchy**: `RedemptionNFT` → `ERC1155` → `Ownable`

| Slot | Offset | Bytes | Variable Name | Type | Source Contract | Description / Upgrade Notes |
| :---: | :---: | :---: | :--- | :--- | :--- | :--- |
| **0** | 0 | 32 | `_balances` | `mapping(uint256 => mapping(address => uint256))` | `ERC1155` | Token ID balance mapping |
| **1** | 0 | 32 | `_operatorApprovals` | `mapping(address => mapping(address => bool))` | `ERC1155` | Operator approval mapping |
| **2** | 0 | 32 | `_uri` | `string` | `ERC1155` | Base URI string |
| **3** | 0 | 20 | `_owner` | `address` | `Ownable` | Contract admin / deployer |
| **4** | 0 | 32 | `_nextTokenId` | `uint256` | `RedemptionNFT` | Auto-incrementing serial counter |
| **5** | 0 | 32 | `authorizedMarkets` | `mapping(address => bool)` | `RedemptionNFT` | Authorized market minters |
| **6** | 0 | 32 | `redemptions` | `mapping(uint256 => struct RedemptionData)` | `RedemptionNFT` | DPP metadata struct mapping |

#### `RedemptionData` Struct Layout (Packed in Mapping `redemptions`):
- `address product` (20 bytes)
- `address redeemer` (20 bytes)
- `uint256 quantity` (32 bytes)
- `uint256 timestamp` (32 bytes)
- `string productName` (32 bytes)
- `string status` (32 bytes)
- `string code` (32 bytes)
- `string checkoutUrl` (32 bytes)
- `string dppUri` (32 bytes)

---

### 2.3 `VestingVault.sol`
- **Contract Name**: `VestingVault`
- **Compiler Version**: `0.8.23`
- **Inheritance Hierarchy**: `VestingVault` → `Ownable` → `ReentrancyGuard`

| Slot | Offset | Bytes | Variable Name | Type | Source Contract | Description / Upgrade Notes |
| :---: | :---: | :---: | :--- | :--- | :--- | :--- |
| **-** | - | - | `usdc` | `IERC20` | `VestingVault` | Currently `immutable` (Bytecode). Will move to storage slot in UUPS conversion. |
| **0** | 0 | 20 | `_owner` | `address` | `Ownable` | Contract admin / deployer |
| **1** | 0 | 32 | `vestingPeriod` | `uint256` | `VestingVault` | Time-lock duration (7 days default) |
| **2** | 0 | 32 | `authorizedMarkets` | `mapping(address => bool)` | `VestingVault` | Authorized markets crediting rewards |
| **3** | 0 | 32 | `tranches` | `mapping(address => struct Tranche[])` | `VestingVault` | Promoter referral tranches |
| **4** | 0 | 32 | `pendingBalance` | `mapping(address => uint256)` | `VestingVault` | Total locked/unclaimed balance |

---

### 2.4 `PromoStaking.sol`
- **Contract Name**: `PromoStaking`
- **Compiler Version**: `0.8.23`
- **Inheritance Hierarchy**: `PromoStaking` → `Ownable` → `ReentrancyGuard`

| Slot | Offset | Bytes | Variable Name | Type | Source Contract | Description / Upgrade Notes |
| :---: | :---: | :---: | :--- | :--- | :--- | :--- |
| **-** | - | - | `rammToken` | `IERC20` | `PromoStaking` | Currently `immutable` (Bytecode). Will move to storage slot in UUPS conversion. |
| **0** | 0 | 20 | `_owner` | `address` | `Ownable` | Contract admin / deployer |
| **1** | 0 | 32 | `minStake` | `uint256` | `PromoStaking` | Minimum RAMM required (1,000 RAMM) |
| **2** | 0 | 32 | `lockPeriod` | `uint256` | `PromoStaking` | Unstake lock duration (7 days default) |
| **3** | 0 | 32 | `stakes` | `mapping(address => struct StakeInfo)` | `PromoStaking` | Staker records mapping |

---

## 3. Verification & Compliance Matrix

The storage layouts above were extracted and verified directly using `solc 0.8.23` via Foundry:
```bash
forge inspect RAMMToken storageLayout
forge inspect RedemptionNFT storageLayout
forge inspect VestingVault storageLayout
forge inspect PromoStaking storageLayout
```

All 4 singleton layouts are strictly locked. Any future PR or code modification adding state variables MUST append new slots at the end of the contract definition after storage gap reservations.
