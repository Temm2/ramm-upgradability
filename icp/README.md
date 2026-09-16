# ICP Chain Fusion & Public Asset Canister (Phase 1)

This repository component implements **Phase 1** of the Internet Computer (ICP) integration for POPUPz / RAMM.ai, conforming to **HLD V2.1 (§1 / §5 Workflow D)** and **MVP1 PRD** specifications.

---

## Overview

ICP acts as the **Storage & Privacy** tier for the POPUPz sovereign D2C marketplace, serving as the counterpart to Base L3's **Execution & Settlement** layer.

Phase 1 provides:
1. **Read-Only Independent Verification Canister (`verifier`):** Uses ICP Chain Fusion's `evm_rpc` canister to query Base Sepolia (`chain ID 84532`) on-chain state via multi-provider consensus reads (`eth_call` & `eth_getLogs`). Independently verifies that a voucher burn & redemption NFT mint took place without trusting RAMM's off-chain backend.
2. **Public Asset Canister (`assets`):** Decentralized ICP static asset canister hosting product JSON metadata (EU-ESPR-DPP-v0.1 compliant) and product photography, eliminating Google Drive API dependencies.

---

## Directory Layout

```
icp/
├── dfx.json                          # DFX canister manifest
├── README.md                         # Architecture & testing instructions
└── canisters/
    ├── verifier/
    │   ├── verifier.did              # Candid interface spec
    │   └── main.mo                   # Motoko verification canister logic
    └── assets/
        └── assets/
            ├── index.html            # Asset canister web dashboard
            └── sample-product.json   # DPP compliant product metadata
```

---

## Quickstart & Local Deployment

### Prerequisites
- [DFX SDK](https://internetcomputer.org/docs/current/developer-docs/getting-started/install/) (v0.18.0+)
- Node.js (v18+)

### 1. Start Local ICP Replica
```bash
cd icp
dfx start --background --clean
```

### 2. Deploy Canisters
```bash
dfx deploy
```

### 3. Test Verification Canister
To independently verify a redemption token ID against Base Sepolia contract (`0x6710F697AE813dA3aC33AA881D91148b49739349`):
```bash
dfx canister call verifier verify_redemption '(84532, "0x6710F697AE813dA3aC33AA881D91148b49739349", 1)'
```

**Expected Response:**
```json
(
  record {
    is_verified = true;
    token_id = 1 : nat64;
    redeemer = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8";
    product = "0xe7b713328896fb709fccfbe7c2def4ac21c1400b";
    quantity = 1 : nat64;
    timestamp = 1756200000 : nat64;
    product_name = "Agatha Designer Product Voucher";
    status = "PENDING";
    status_code = "VERIFIED_ON_BASE_CHAIN";
    message = "Independently verified against Base Sepolia state logs via ICP evm_rpc consensus.";
  }
)
```

### 4. Test Asset Canister
Open your browser and navigate to:
`http://localhost:4943/?canisterId=$(dfx canister id assets)`

---

## Automated Verification Simulation Script

You can also run the standalone verification simulator against live Base Sepolia from the root directory:
```bash
node scripts/test-icp-verification.js
```
