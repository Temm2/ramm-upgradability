# RAMM — Contract Upgradability Handoff

This is a scoped extract from RAMM's main monorepo — only what's relevant to the
upgradability workstream, not the full codebase (the shopper app, brand dashboard,
and the rest of the agent layer aren't included; none of it is needed for this
work, and it's not this repo's to share).

**Start here:** [`docs/upgradability-brief.html`](docs/upgradability-brief.html) —
open it in a browser. It explains the current state, why it matters now, and the
7-task plan this handoff supports. `docs/open-items-overview.html` has the
broader project status if useful context.

## What's included

- **`contracts/`** — the complete, self-contained Foundry project (all Solidity
  source, tests, deploy scripts, and the vendored OpenZeppelin dependency). This
  is a real working copy — `forge test` should pass out of the box. This is
  where essentially all of the actual upgradability work happens.
- **`reference/`** — TypeScript deploy/audit/seed scripts from the backend,
  included as reference for Task 1 and Task 6 in the brief (understanding how a
  market gets deployed and migrated today). These mirror their real relative
  import paths and will run standalone with Node/tsx + a real `.env` (see
  `reference/agents/.env.example`) if you want to actually exercise them against
  a testnet — but reading them is the main point.
  - `valet/index.ts.readonly-reference` is the one exception — it's the live
    campaign-creation flow, included unrunnable (it depends on other backend
    modules not included here) purely so you can see exactly how/where a new
    `IMPXMarket` gets deployed today.
  - `productContracts.ts` is the current public address mapping (product ID →
    contract address) for all 54 live markets — no secrets, just addresses.

## What's deliberately NOT included, and why

- **No private keys, `.env` files, or `agents/data/*.json`.** The real deploy
  scripts need a `DEPLOYER_PRIVATE_KEY` and RPC URL to actually execute against
  testnet — ask for those separately over a secure channel if/when you need to
  run something live, don't expect them here.
- **No `app/` or `app-brand/`** — the shopper app and brand dashboard aren't
  part of this workstream.
- **No git history** — this is a fresh export, not a filtered clone. The
  upgradability brief's §2 already summarizes the relevant history (the two
  full-fleet migrations and what they cost) in prose.

## Getting started

```
cd contracts
forge test    # should show 63 passing
```

Questions about anything trimmed out of this extract — ask, don't guess.
