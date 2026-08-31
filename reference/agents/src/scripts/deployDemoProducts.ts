/**
 * Deploy one PVTToken + IMPXMarket per demo product.
 * Output: app/constants/productContracts.ts
 *
 * Usage:
 *   cd agents && npx tsx src/scripts/deployDemoProducts.ts
 */
import "dotenv/config"
import { createPublicClient, createWalletClient, http } from "viem"
import type { Address, Hex } from "viem"
import { privateKeyToAccount } from "viem/accounts"
import { baseSepolia } from "viem/chains"
import { readFileSync, writeFileSync } from "fs"
import { fileURLToPath } from "url"
import path from "path"
import { deriveCurveParams } from "../valet/curve.js"

const __dir = path.dirname(fileURLToPath(import.meta.url))

// ── Config ────────────────────────────────────────────────────────────────────

const RPC_URL       = process.env.BASE_SEPOLIA_RPC_URL!
const DEPLOYER_KEY  = process.env.DEPLOYER_PRIVATE_KEY as Hex
const USDC_ADDRESS  = process.env.USDC_ADDRESS as Address
const RAMM_ADDRESS  = (process.env.RAMM_TOKEN_ADDRESS ?? "0x0000000000000000000000000000000000000000") as Address
const NFT_ADDRESS   = (process.env.REDEMPTION_NFT_ADDRESS ?? "0x0000000000000000000000000000000000000000") as Address
const VAULT_ADDRESS = (process.env.VESTING_VAULT_ADDRESS ?? "0x0000000000000000000000000000000000000000") as Address
const STAKING_ADDRESS = (process.env.PROMO_STAKING_ADDRESS ?? "0x0000000000000000000000000000000000000000") as Address
const REGISTRY_ADDRESS = process.env.REGISTRY_ADDRESS as Address
const BRAND_WALLET  = process.env.BRAND_ADDRESS as Address   // receives 93% on buy

// ── Products ─────────────────────────────────────────────────────────────────

const PRODUCTS: { id: string; name: string; symbol: string; supplyCap: number }[] = [
  { id: "agatha",              name: "Agatha by Elmira Medins",          symbol: "EM-AGT",  supplyCap: 30 },
  { id: "anaconda",            name: "Anaconda by Elmira Medins",        symbol: "EM-ANA",  supplyCap: 20 },
  { id: "annabelle",           name: "Annabelle by Elmira Medins",       symbol: "EM-ANB",  supplyCap: 25 },
  { id: "arisa",               name: "Arisa by Elmira Medins",           symbol: "EM-ARS",  supplyCap: 35 },
  { id: "astride",             name: "Astride by Elmira Medins",         symbol: "EM-AST",  supplyCap: 40 },
  { id: "aurora",              name: "Aurora by Elmira Medins",          symbol: "EM-AUR",  supplyCap: 30 },
  { id: "autumn",              name: "Autumn by Elmira Medins",          symbol: "EM-AUT",  supplyCap: 25 },
  { id: "bette",               name: "Bette by Elmira Medins",           symbol: "EM-BET",  supplyCap: 25 },
  { id: "bit-of-history",      name: "A Bit of History by Elmira Medins",symbol: "EM-BOH",  supplyCap: 60 },
  { id: "calla",               name: "Calla by Elmira Medins",           symbol: "EM-CAL",  supplyCap: 25 },
  { id: "declaration-of-love", name: "A Declaration of Love by EM",      symbol: "EM-DOL",  supplyCap: 50 },
  { id: "demivika",            name: "Demivika by Elmira Medins",        symbol: "EM-DMV",  supplyCap: 40 },
  { id: "diana",               name: "Diane by Elmira Medins",           symbol: "EM-DIA",  supplyCap: 20 },
  { id: "double-bracelet",     name: "Double Bracelet by Elmira Medins", symbol: "EM-DBR",  supplyCap: 25 },
  { id: "eiffelia",            name: "Eiffelia by Elmira Medins",        symbol: "EM-EIF",  supplyCap: 20 },
  { id: "eivissa",             name: "Eivissa by Elmira Medins",         symbol: "EM-EIV",  supplyCap: 20 },
  { id: "eleonora",            name: "Eleonora by Elmira Medins",        symbol: "EM-ELE",  supplyCap: 30 },
  { id: "eterry-9-black",      name: "Eterry 9 Black by Elmira Medins",  symbol: "EM-E9B",  supplyCap: 20 },
  { id: "eterry-9-red",        name: "Eterry 9 Red by Elmira Medins",    symbol: "EM-E9R",  supplyCap: 20 },
  { id: "eterry-9",            name: "Eterry 9 by Elmira Medins",        symbol: "EM-E9",   supplyCap: 20 },
  { id: "ferraria",            name: "Ferraria by Elmira Medins",        symbol: "EM-FER",  supplyCap: 25 },
  { id: "gemma",               name: "Gemma by Elmira Medins",           symbol: "EM-GEM",  supplyCap: 15 },
  { id: "genesis",             name: "Genesis by Elmira Medins",         symbol: "EM-GEN",  supplyCap: 20 },
  { id: "giada",               name: "Giada by Elmira Medins",           symbol: "EM-GIA",  supplyCap: 20 },
  { id: "isabella",            name: "Isabella by Elmira Medins",        symbol: "EM-ISA",  supplyCap: 15 },
  { id: "jade",                name: "Jade by Elmira Medins",            symbol: "EM-JAD",  supplyCap: 15 },
  { id: "josephine",           name: "Josephine by Elmira Medins",       symbol: "EM-JOS",  supplyCap: 30 },
  { id: "karin",               name: "Karin by Elmira Medins",           symbol: "EM-KAR",  supplyCap: 15 },
  { id: "magic-circles",       name: "Magic Circles (WG) by EM",         symbol: "EM-MGC",  supplyCap: 20 },
  { id: "malina",              name: "Malina by Elmira Medins",          symbol: "EM-MAL",  supplyCap: 35 },
  { id: "moderna",             name: "Moderna by Elmira Medins",         symbol: "EM-MOD",  supplyCap: 30 },
  { id: "nova",                name: "Nova by Elmira Medins",            symbol: "EM-NOV",  supplyCap: 35 },
  { id: "paloma",              name: "Paloma by Elmira Medins",          symbol: "EM-PAL",  supplyCap: 25 },
  { id: "rita",                name: "Rita by Elmira Medins",            symbol: "EM-RIT",  supplyCap: 20 },
  { id: "sensual-skin",        name: "Sensual Skin by Elmira Medins",    symbol: "EM-SSK",  supplyCap: 30 },
  { id: "shania",              name: "Shania by Elmira Medins",          symbol: "EM-SHA",  supplyCap: 30 },
  { id: "skylar",              name: "Skylar by Elmira Medins",          symbol: "EM-SKY",  supplyCap: 20 },
  { id: "symbol-of-love",      name: "Symbol of Love by Elmira Medins",  symbol: "EM-SOL",  supplyCap: 40 },
  { id: "whitney",             name: "Whitney by Elmira Medins",         symbol: "EM-WHI",  supplyCap: 25 },
  { id: "your-name-bracelet",  name: "Your Name Bracelet by EM",         symbol: "EM-YNB",  supplyCap: 30 },
  { id: "zelena",              name: "Zelena by Elmira Medins",          symbol: "EM-ZEL",  supplyCap: 25 },
]

// ── Bytecodes ─────────────────────────────────────────────────────────────────

function loadBytecode(name: string): Hex {
  const p = path.resolve(__dir, `../../../contracts/out/${name}.sol/${name}.json`)
  return JSON.parse(readFileSync(p, "utf8")).bytecode.object as Hex
}

// ── ABIs (deploy-only subset) ─────────────────────────────────────────────────

const PVT_DEPLOY_ABI = [{
  type: "constructor",
  inputs: [
    { name: "_productName", type: "string" },
    { name: "_symbol",      type: "string" },
    { name: "_supplyCap",   type: "uint256" },
    { name: "_initialOwner",type: "address" },
  ],
  stateMutability: "nonpayable",
}] as const

// Constructor shrank from 14 args to 11 when the four shared singleton
// addresses (rammToken/redemptionNFT/vestingVault/promoStaking) moved behind
// a single RammRegistry — see contracts/src/RammRegistry.sol. Grew back to
// 12 with the added _curve tuple — see contracts/src/SigmoidMath.sol.
const MARKET_DEPLOY_ABI = [{
  type: "constructor",
  inputs: [
    { name: "_usdc",             type: "address" },
    { name: "_pvt",              type: "address" },
    { name: "_registry",         type: "address" },
    { name: "_brandWallet",      type: "address" },
    { name: "_campaignWallet",   type: "address" },
    { name: "_initialOwner",     type: "address" },
    { name: "_buyBrandBps",      type: "uint16" },
    { name: "_buyCampaignBps",   type: "uint16" },
    { name: "_sellBrandBps",     type: "uint16" },
    { name: "_sellCampaignBps",  type: "uint16" },
    { name: "_promoterBps",      type: "uint16" },
    {
      name: "_curve", type: "tuple",
      components: [
        { name: "b",          type: "uint256" },
        { name: "c",          type: "uint256" },
        { name: "p",          type: "uint256" },
        { name: "aPrimary",   type: "uint256" },
        { name: "aSecondary", type: "uint256" },
      ],
    },
  ],
  stateMutability: "nonpayable",
}] as const

// Demo catalog has no brand-configured price range (no wizard involved) —
// use the same reference range as the original fixed constants (medium
// shape) so this stays a strict scale-fix, not a pricing change: the actual
// $ range shown is unaffected by the curve, only how much it MOVES across
// each product's own (much smaller) supply cap. See deriveCurveParams() —
// this is exactly the bug it fixes: the old fixed b=500 curve barely moved
// at all across a 20-60 unit demo product's real supply range.
const DEMO_MIN_PRICE_USDC = 850_000_000  // $850
const DEMO_MAX_PRICE_USDC = 1_200_000_000 // $1200

const TRANSFER_OWNERSHIP_ABI = [{
  name: "transferOwnership",
  type: "function",
  stateMutability: "nonpayable",
  inputs: [{ name: "newOwner", type: "address" }],
  outputs: [],
}] as const

const MOCK_USDC_MINT_ABI = [{
  name: "mint",
  type: "function",
  stateMutability: "nonpayable",
  inputs: [{ name: "to", type: "address" }, { name: "amount", type: "uint256" }],
  outputs: [],
}] as const

const ERC20_APPROVE_ABI = [{
  name: "approve",
  type: "function",
  stateMutability: "nonpayable",
  inputs: [{ name: "spender", type: "address" }, { name: "amount", type: "uint256" }],
  outputs: [{ name: "", type: "bool" }],
}] as const

const DEPOSIT_LIQUIDITY_ABI = [{
  name: "depositLiquidity",
  type: "function",
  stateMutability: "nonpayable",
  inputs: [{ name: "amount", type: "uint256" }],
  outputs: [],
}] as const

const SET_MARKET_AUTHORIZED_ABI = [{
  name: "setMarketAuthorized",
  type: "function",
  stateMutability: "nonpayable",
  inputs: [{ name: "_market", type: "address" }, { name: "_authorized", type: "bool" }],
  outputs: [],
}] as const

const SET_MINTER_AUTHORIZED_ABI = [{
  name: "setMinterAuthorized",
  type: "function",
  stateMutability: "nonpayable",
  inputs: [{ name: "_minter", type: "address" }, { name: "_authorized", type: "bool" }],
  outputs: [],
}] as const

// ── Main ──────────────────────────────────────────────────────────────────────

const outPath = path.resolve(__dir, "../../../app/constants/productContracts.ts")

function writeResults(results: Record<string, { pvtAddress: string; marketAddress: string }>) {
  const lines = [
    `// Auto-generated by agents/src/scripts/deployDemoProducts.ts — do not edit by hand`,
    `// Deployed on Base Sepolia ${new Date().toISOString()}`,
    `export const PRODUCT_CONTRACTS: Record<string, { pvtAddress: \`0x\${string}\`; marketAddress: \`0x\${string}\` }> = {`,
    ...Object.entries(results).map(([id, c]) =>
      `  "${id}": { pvtAddress: "${c.pvtAddress}", marketAddress: "${c.marketAddress}" },`
    ),
    `}`,
    ``,
    `export function getProductContracts(productId: string) {`,
    `  return PRODUCT_CONTRACTS[productId]`,
    `}`,
  ]
  writeFileSync(outPath, lines.join("\n"))
}

async function main() {
  const account    = privateKeyToAccount(DEPLOYER_KEY)
  // Bulk 40+-product runs against a shared/rate-limited RPC (e.g. Base's free
  // public endpoint) will hit transient "over rate limit" errors partway
  // through — retryCount/retryDelay here rides those out instead of crashing
  // the whole run. This is exactly what took down the first attempt at this
  // migration: 38/41 products succeeded on-chain but the crash happened
  // before results were ever written to disk (see writeResults below, now
  // called after every product instead of once at the end).
  const transport = http(RPC_URL, { retryCount: 10, retryDelay: 3000 })
  const walletClient = createWalletClient({ account, chain: baseSepolia, transport })
  const publicClient = createPublicClient({ chain: baseSepolia, transport })

  const pvtBytecode    = loadBytecode("PVTToken")
  const marketBytecode = loadBytecode("IMPXMarket")

  const SEED = 10_000n * 1_000_000n  // 10,000 USDC

  // NOTE: deliberately no "skip if already in productContracts.ts" resume
  // logic — that file's existing entries could be from an older deployment
  // generation (e.g. pre-registry-migration markets), not necessarily a
  // crashed run of *this* script. Treating "key present" as "done" would
  // silently skip products that actually still need redeploying. Every run
  // of this script deploys fresh contracts for every product in PRODUCTS;
  // only writeResults()'s incremental checkpointing is meant to survive a
  // crash (so a retry-run can start from a truthful base file), not
  // selective per-product skipping.
  const results: Record<string, { pvtAddress: string; marketAddress: string }> = {}

  let nonce = await publicClient.getTransactionCount({ address: account.address, blockTag: "pending" })
  console.log(`Deployer: ${account.address}  starting nonce: ${nonce}`)
  console.log(`Deploying ${PRODUCTS.length} product(s)...\n`)

  for (const product of PRODUCTS) {
    console.log(`[${product.id}] Deploying PVTToken (${product.symbol}, cap=${product.supplyCap})...`)

    // 1 — PVTToken
    const pvtHash = await walletClient.deployContract({
      abi: PVT_DEPLOY_ABI, bytecode: pvtBytecode, nonce: nonce++,
      args: [product.name, product.symbol, BigInt(product.supplyCap), account.address],
    })
    const pvtReceipt = await publicClient.waitForTransactionReceipt({ hash: pvtHash })
    const pvtAddress = pvtReceipt.contractAddress!
    console.log(`  PVT:    ${pvtAddress}`)

    // 2 — IMPXMarket
    const curve = deriveCurveParams(DEMO_MIN_PRICE_USDC, DEMO_MAX_PRICE_USDC, product.supplyCap, "medium")
    const marketHash = await walletClient.deployContract({
      abi: MARKET_DEPLOY_ABI, bytecode: marketBytecode, nonce: nonce++,
      args: [
        USDC_ADDRESS, pvtAddress, REGISTRY_ADDRESS,
        BRAND_WALLET, account.address, account.address,
        9300, 700, 500, 200, 600, // buyBrandBps, buyCampaignBps, sellBrandBps, sellCampaignBps, promoterBps — matches Deploy.s.sol defaults
        curve,
      ],
    })
    const marketReceipt = await publicClient.waitForTransactionReceipt({ hash: marketHash })
    const marketAddress = marketReceipt.contractAddress!
    console.log(`  Market: ${marketAddress}`)

    // 3 — Transfer PVT ownership to Market
    // Explicit gas limit — auto-estimation via eth_estimateGas came in short
    // once already this session (OutOfGas on a plain transferOwnership call),
    // don't rely on it for a value this cheap and predictable to bound.
    const transferHash = await walletClient.writeContract({
      address: pvtAddress, abi: TRANSFER_OWNERSHIP_ABI,
      functionName: "transferOwnership", gas: 100_000n, nonce: nonce++, args: [marketAddress],
    })
    const transferReceipt = await publicClient.waitForTransactionReceipt({ hash: transferHash })
    if (transferReceipt.status !== "success") {
      throw new Error(`transferOwnership reverted on-chain for ${product.id} (tx: ${transferHash})`)
    }
    console.log(`  Ownership transferred to market`)

    // 3b — Authorize this market on the shared RedemptionNFT + RAMMToken
    if (NFT_ADDRESS !== "0x0000000000000000000000000000000000000000") {
      const authNftHash = await walletClient.writeContract({
        address: NFT_ADDRESS, abi: SET_MARKET_AUTHORIZED_ABI,
        functionName: "setMarketAuthorized", nonce: nonce++, args: [marketAddress, true],
      })
      const authNftReceipt = await publicClient.waitForTransactionReceipt({ hash: authNftHash })
      if (authNftReceipt.status !== "success") throw new Error(`RedemptionNFT authorization reverted for ${product.id}`)
    }
    if (RAMM_ADDRESS !== "0x0000000000000000000000000000000000000000") {
      const authRammHash = await walletClient.writeContract({
        address: RAMM_ADDRESS, abi: SET_MINTER_AUTHORIZED_ABI,
        functionName: "setMinterAuthorized", nonce: nonce++, args: [marketAddress, true],
      })
      const authRammReceipt = await publicClient.waitForTransactionReceipt({ hash: authRammHash })
      if (authRammReceipt.status !== "success") throw new Error(`RAMMToken authorization reverted for ${product.id}`)
    }
    if (VAULT_ADDRESS !== "0x0000000000000000000000000000000000000000") {
      const authVaultHash = await walletClient.writeContract({
        address: VAULT_ADDRESS, abi: SET_MARKET_AUTHORIZED_ABI,
        functionName: "setMarketAuthorized", nonce: nonce++, args: [marketAddress, true],
      })
      const authVaultReceipt = await publicClient.waitForTransactionReceipt({ hash: authVaultHash })
      if (authVaultReceipt.status !== "success") throw new Error(`VestingVault authorization reverted for ${product.id}`)
    }
    console.log(`  Authorized on RedemptionNFT + RAMMToken + VestingVault`)

    // 4 — Seed buyback liquidity (mint → approve → deposit)
    try {
      const mintHash = await walletClient.writeContract({
        address: USDC_ADDRESS, abi: MOCK_USDC_MINT_ABI,
        functionName: "mint", nonce: nonce++, args: [account.address, SEED],
      })
      await publicClient.waitForTransactionReceipt({ hash: mintHash })

      const approveHash = await walletClient.writeContract({
        address: USDC_ADDRESS, abi: ERC20_APPROVE_ABI,
        functionName: "approve", nonce: nonce++, args: [marketAddress, SEED],
      })
      await publicClient.waitForTransactionReceipt({ hash: approveHash })

      const depositHash = await walletClient.writeContract({
        address: marketAddress, abi: DEPOSIT_LIQUIDITY_ABI,
        functionName: "depositLiquidity", nonce: nonce++, args: [SEED],
      })
      await publicClient.waitForTransactionReceipt({ hash: depositHash })
      console.log(`  Seeded 10,000 USDC liquidity`)
    } catch (e) {
      console.warn(`  Liquidity seed failed (non-fatal): ${e}`)
      nonce = await publicClient.getTransactionCount({ address: account.address, blockTag: "pending" })
    }

    results[product.id] = { pvtAddress, marketAddress }
    writeResults(results)  // checkpoint after every product, not just at the end
    console.log()
  }

  console.log(`\nWrote ${outPath}`)

  // Also print env vars for reference
  console.log("\n─── env reference (first product = legacy PVT_ADDRESS) ───")
  const first = results[PRODUCTS[0].id]
  console.log(`PVT_ADDRESS=${first.pvtAddress}`)
  console.log(`MARKET_ADDRESS=${first.marketAddress}`)
  console.log("\nDone.")
}

main().catch((err) => { console.error(err); process.exit(1) })
