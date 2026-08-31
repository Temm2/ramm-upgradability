# RAMM — Contract Upgradability Handoff

This is a scoped extract from RAMM's main monorepo — only what's relevant to the
upgradability workstream, not the full codebase (the shopper app, brand dashboard,
and the rest of the agent layer aren't included; none of it is needed for this
work, and it's not this repo's to share).

**Read this first:** [`docs/upgradability-brief.html`](docs/upgradability-brief.html)
(open in a browser) — current state, why it matters now, and the full 7-task plan.
`docs/open-items-overview.html` has the broader project status if useful context.

## Your first two tasks

Everything you need for these is in this repo. Do them in order.

### Task 1 — Map the blast radius (~1 hr)

Run the three audit scripts below against the live 54 markets, then read
`contracts/src/RammRegistry.sol` and both migrations end to end (patches in
`docs/migrations/`). Produces nothing new — the goal is that by the end you can
explain *why the registry solves discovery and not state preservation* without
re-reading anything. This is the prerequisite for every other task.

```
cd reference/agents
npm install
cp .env.example .env       # already filled with real public addresses — nothing to fill in
npx tsx src/scripts/auditRegistry.ts            # expect: 54/54 wired
npx tsx src/scripts/auditOwnership.ts           # expect: 0/54 wrong
npx tsx src/scripts/auditVaultAuthorization.ts  # expect: 0/54 unauthorized
```

Then read, in order:
1. `contracts/src/RammRegistry.sol` — the whole file, it's short.
2. `docs/migrations/01-registry-migration/` — both patches. This is the shared-contract
   indirection layer going in (`1-add-rammregistry.patch`) and all 54 markets moving onto
   it (`2-migrate-54-markets.patch`).
3. `docs/migrations/02-bonding-curve-migration/` — both patches. Same shape of operation,
   for a different reason (the bonding curve's inflection point needed to scale per-market).

### Task 2 — UUPS vs. Transparent Proxy recommendation (~1.5 hrs)

No code. Read OpenZeppelin's docs on both patterns, weigh gas cost per call vs. deploy
simplicity specifically for this project's shape — **many low-value transactions per
market, not few high-value ones** (that framing matters: it's the opposite of what a
lot of proxy-pattern writeups optimize for). Write a half-page recommendation with
reasoning, not just a conclusion. This gets a real decision on record before any
contract in `contracts/src/` actually touches a proxy.

No repo changes needed for this one — a doc, wherever you'd normally put it, is fine.

---

The rest of the 7-task brief (per-market upgrade design, storage-layout discipline,
governance, the final migration, the runbook) comes after these two — don't start
ahead of them.

## What's included

- **`contracts/`** — the complete, self-contained Foundry project (all Solidity
  source, tests, deploy scripts, and the vendored OpenZeppelin dependency). This
  is a real working copy — `forge test` should pass out of the box (63 passing).
  This is where essentially all of the actual upgradability work happens.
- **`reference/agents/`** — a standalone, installable package with the 8
  deploy/audit/seed scripts relevant to Tasks 1 and 6, plus their only real
  dependencies (`curve.ts`, `vault.ts`, `jsonStore.ts`). Verified working from a
  clean `npm install` against real (public) testnet data — not just copied and
  assumed to run.
  - `valet/index.ts.readonly-reference` is the one exception — it's the live
    campaign-creation flow, included unrunnable (it depends on other backend
    modules not in this extract) purely so you can see exactly where/how a new
    `IMPXMarket` gets deployed today.
  - `reference/app/constants/productContracts.ts` and
    `reference/agents/data/campaigns.json` are redacted copies of the real address
    mappings — only `productName`/`pvtAddress`/`marketAddress` kept, nothing else.
- **`docs/migrations/`** — the actual patches for both full-fleet migrations
  referenced in the brief and in Task 1, exported directly from the real commits.

## What's deliberately NOT included, and why

- **No private keys or real `.env` files.** `reference/agents/.env.example` is
  pre-filled with real values, but every one of them is a public contract
  address — there's nothing secret in it. A `DEPLOYER_PRIVATE_KEY` would only be
  needed to actually *deploy* something (not required for Tasks 1-2) — ask for
  that separately over a secure channel if a later task needs it.
- **No `app/` or `app-brand/`** — the shopper app and brand dashboard aren't
  part of this workstream.
- **No git history** — this is a fresh export, not a filtered clone. The two
  migrations you need to read are in `docs/migrations/` as patches instead.

## Getting started

```
cd contracts
forge test    # should show 63 passing
```

Questions about anything trimmed out of this extract — ask, don't guess.
