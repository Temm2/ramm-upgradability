/**
 * Redeploys PVTToken + IMPXMarket for every existing VALET brand campaign
 * against the new multi-market RedemptionNFT/RAMMToken, authorizes each new
 * market, seeds sell-back liquidity, and updates campaigns.json in place.
 *
 * Why: the old RedemptionNFT/RAMMToken only ever authorized the first market
 * ever deployed (Agatha's demo product) — every VALET-created campaign's
 * redemption call reverted with OnlyMarket(). Since IMPXMarket's reference to
 * RedemptionNFT is immutable, existing markets can't be repointed at the new
 * contract — they must be redeployed. This is a one-time migration; going
 * forward, VALET's createCampaign() auto-authorizes new markets itself.
 *
 * This is an accepted reset for demo/testnet data: existing PVT holdings
 * against the OLD per-campaign contracts become orphaned (unredeemable) —
 * codes, campaign metadata, and campaignId are all preserved.
 *
 * Usage: cd agents && npx tsx src/scripts/migrateCampaignContracts.ts
 */
import "dotenv/config"
import { createPublicClient, createWalletClient, http, parseUnits } from "viem"
import type { Address, Hex } from "viem"
import { privateKeyToAccount, generatePrivateKey } from "viem/accounts"
import { baseSepolia } from "viem/chains"
import { readFileSync, writeFileSync } from "fs"
import { fileURLToPath } from "url"
import path from "path"
import { deriveCurveParams } from "../valet/curve.js"

const __dir = path.dirname(fileURLToPath(import.meta.url))
const CAMPAIGNS_PATH = path.resolve(__dir, "../../data/campaigns.json")

const RPC_URL = process.env.BASE_SEPOLIA_RPC_URL!
const DEPLOYER_KEY = process.env.DEPLOYER_PRIVATE_KEY as Hex
const USDC_ADDRESS = process.env.USDC_ADDRESS as Address
const RAMM_ADDRESS = (process.env.RAMM_TOKEN_ADDRESS ?? "0x0000000000000000000000000000000000000000") as Address
const NFT_ADDRESS = (process.env.REDEMPTION_NFT_ADDRESS ?? "0x0000000000000000000000000000000000000000") as Address
const VAULT_ADDRESS = (process.env.VESTING_VAULT_ADDRESS ?? "0x0000000000000000000000000000000000000000") as Address
const STAKING_ADDRESS = (process.env.PROMO_STAKING_ADDRESS ?? "0x0000000000000000000000000000000000000000") as Address
const REGISTRY_ADDRESS = process.env.REGISTRY_ADDRESS as Address
const SEED_USDC = parseUnits("5000", 6)

function loadBytecode(name: string): Hex {
  const p = path.resolve(__dir, `../../../contracts/out/${name}.sol/${name}.json`)
  return JSON.parse(readFileSync(p, "utf8")).bytecode.object as Hex
}

const PVT_DEPLOY_ABI = [{
  type: "constructor",
  inputs: [
    { name: "_productName", type: "string" },
    { name: "_symbol", type: "string" },
    { name: "_supplyCap", type: "uint256" },
    { name: "_initialOwner", type: "address" },
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
    { name: "_usdc", type: "address" },
    { name: "_pvt", type: "address" },
    { name: "_registry", type: "address" },
    { name: "_brandWallet", type: "address" },
    { name: "_campaignWallet", type: "address" },
    { name: "_initialOwner", type: "address" },
    { name: "_buyBrandBps", type: "uint16" },
    { name: "_buyCampaignBps", type: "uint16" },
    { name: "_sellBrandBps", type: "uint16" },
    { name: "_sellCampaignBps", type: "uint16" },
    { name: "_promoterBps", type: "uint16" },
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

const TRANSFER_OWNERSHIP_ABI = [{
  name: "transferOwnership", type: "function", stateMutability: "nonpayable",
  inputs: [{ name: "newOwner", type: "address" }], outputs: [],
}] as const

const SET_MARKET_AUTHORIZED_ABI = [{
  name: "setMarketAuthorized", type: "function", stateMutability: "nonpayable",
  inputs: [{ name: "_market", type: "address" }, { name: "_authorized", type: "bool" }], outputs: [],
}] as const

const SET_MINTER_AUTHORIZED_ABI = [{
  name: "setMinterAuthorized", type: "function", stateMutability: "nonpayable",
  inputs: [{ name: "_minter", type: "address" }, { name: "_authorized", type: "bool" }], outputs: [],
}] as const

const ERC20_ABI = [
  {
    name: "approve", type: "function", stateMutability: "nonpayable",
    inputs: [{ name: "spender", type: "address" }, { name: "amount", type: "uint256" }],
    outputs: [{ name: "", type: "bool" }],
  },
] as const

const DEPOSIT_LIQUIDITY_ABI = [{
  name: "depositLiquidity", type: "function", stateMutability: "nonpayable",
  inputs: [{ name: "amount", type: "uint256" }], outputs: [],
}] as const

interface CampaignRecord {
  campaignId: string
  brandWallet: Address
  campaignWallet?: Address
  campaignPrivateKey?: string
  productName: string
  symbol: string
  totalSupply: number
  pvtAddress: Address
  marketAddress: Address
  deployTxHash: string
  status: string
  redeemedCount: number
  buyPromoterRateBps?: number
  buyPlatformRateBps?: number
  sellPromoterRateBps?: number
  sellPlatformRateBps?: number
  basePriceUsdc?: number
  maxPriceUsdc?: number
  curveShape?: "fast" | "medium" | "slow"
  [key: string]: unknown
}

async function main() {
  // retryCount/retryDelay ride out transient "over rate limit" errors from
  // shared/free RPC endpoints (see the same fix in deployDemoProducts.ts —
  // that script's first run crashed mid-migration on exactly this).
  const transport = http(RPC_URL, { retryCount: 10, retryDelay: 3000 })
  const deployer = privateKeyToAccount(DEPLOYER_KEY)
  const buyer = privateKeyToAccount(process.env.BUYER_PRIVATE_KEY as Hex)
  const deployerWallet = createWalletClient({ account: deployer, chain: baseSepolia, transport })
  const buyerWallet = createWalletClient({ account: buyer, chain: baseSepolia, transport })
  const publicClient = createPublicClient({ chain: baseSepolia, transport })

  const pvtBytecode = loadBytecode("PVTToken")
  const marketBytecode = loadBytecode("IMPXMarket")

  const campaigns: CampaignRecord[] = JSON.parse(readFileSync(CAMPAIGNS_PATH, "utf8"))
  console.log(`Migrating ${campaigns.length} campaigns...\n`)

  let nonce = await publicClient.getTransactionCount({ address: deployer.address, blockTag: "pending" })
  let buyerNonce = await publicClient.getTransactionCount({ address: buyer.address, blockTag: "pending" })

  for (const c of campaigns) {
    console.log(`[${c.productName}] (${c.campaignId.slice(0, 8)})`)

    let campaignWallet = c.campaignWallet
    let campaignPrivateKey = c.campaignPrivateKey
    if (!campaignWallet) {
      campaignPrivateKey = generatePrivateKey()
      campaignWallet = privateKeyToAccount(campaignPrivateKey as Hex).address
      console.log(`  Generated new campaign wallet: ${campaignWallet}`)
    }

    // 1 — PVTToken
    const pvtHash = await deployerWallet.deployContract({
      abi: PVT_DEPLOY_ABI, bytecode: pvtBytecode, nonce: nonce++,
      args: [c.productName, c.symbol, BigInt(c.totalSupply), deployer.address],
    })
    const pvtReceipt = await publicClient.waitForTransactionReceipt({ hash: pvtHash })
    const pvtAddress = pvtReceipt.contractAddress!
    console.log(`  PVT:    ${pvtAddress}`)

    // 2 — IMPXMarket (same bps formula as VALET's createCampaign)
    const buyPromoterRateBps = c.buyPromoterRateBps ?? 600
    const buyPlatformRateBps = c.buyPlatformRateBps ?? 100
    const sellPromoterRateBps = c.sellPromoterRateBps ?? 300
    const sellPlatformRateBps = c.sellPlatformRateBps ?? 50
    const buyBrandBps = 10_000 - buyPromoterRateBps - buyPlatformRateBps
    const buyCampaignBps = buyPromoterRateBps + buyPlatformRateBps
    const sellBrandBps = sellPromoterRateBps + sellPlatformRateBps
    const sellCampaignBps = 0

    // Real brand-configured price range + curve shape, same derivation the
    // live createCampaign() path uses now — falls back to the reference
    // medium/$850-$1200 range if an older campaign record predates these
    // fields (basePriceUsdc has been on CampaignRecord since before this
    // migration; the fallback only matters for genuinely ancient records).
    const curve = deriveCurveParams(
      c.basePriceUsdc ?? 850_000_000,
      c.maxPriceUsdc ?? c.basePriceUsdc ?? 1_200_000_000,
      c.totalSupply,
      c.curveShape ?? "medium"
    )

    const marketHash = await deployerWallet.deployContract({
      abi: MARKET_DEPLOY_ABI, bytecode: marketBytecode, nonce: nonce++,
      args: [
        USDC_ADDRESS, pvtAddress, REGISTRY_ADDRESS,
        c.brandWallet, campaignWallet, deployer.address,
        buyBrandBps, buyCampaignBps, sellBrandBps, sellCampaignBps, buyPromoterRateBps,
        curve,
      ],
    })
    const marketReceipt = await publicClient.waitForTransactionReceipt({ hash: marketHash })
    const marketAddress = marketReceipt.contractAddress!
    console.log(`  Market: ${marketAddress}`)

    // 3 — Transfer PVT ownership
    // Explicit gas limit — auto-estimation via eth_estimateGas came in short
    // once already this session (OutOfGas on a plain transferOwnership call),
    // don't rely on it for a value this cheap and predictable to bound.
    const transferHash = await deployerWallet.writeContract({
      address: pvtAddress, abi: TRANSFER_OWNERSHIP_ABI,
      functionName: "transferOwnership", gas: 100_000n, nonce: nonce++, args: [marketAddress],
    })
    const transferReceipt = await publicClient.waitForTransactionReceipt({ hash: transferHash })
    if (transferReceipt.status !== "success") {
      throw new Error(`transferOwnership reverted on-chain for ${c.productName} (tx: ${transferHash})`)
    }

    // 4 — Authorize on RedemptionNFT + RAMMToken
    const authNftHash = await deployerWallet.writeContract({
      address: NFT_ADDRESS, abi: SET_MARKET_AUTHORIZED_ABI,
      functionName: "setMarketAuthorized", nonce: nonce++, args: [marketAddress, true],
    })
    const authNftReceipt = await publicClient.waitForTransactionReceipt({ hash: authNftHash })
    if (authNftReceipt.status !== "success") throw new Error(`RedemptionNFT authorization reverted for ${c.productName}`)

    const authRammHash = await deployerWallet.writeContract({
      address: RAMM_ADDRESS, abi: SET_MINTER_AUTHORIZED_ABI,
      functionName: "setMinterAuthorized", nonce: nonce++, args: [marketAddress, true],
    })
    const authRammReceipt = await publicClient.waitForTransactionReceipt({ hash: authRammHash })
    if (authRammReceipt.status !== "success") throw new Error(`RAMMToken authorization reverted for ${c.productName}`)

    const authVaultHash = await deployerWallet.writeContract({
      address: VAULT_ADDRESS, abi: SET_MARKET_AUTHORIZED_ABI,
      functionName: "setMarketAuthorized", nonce: nonce++, args: [marketAddress, true],
    })
    const authVaultReceipt = await publicClient.waitForTransactionReceipt({ hash: authVaultHash })
    if (authVaultReceipt.status !== "success") throw new Error(`VestingVault authorization reverted for ${c.productName}`)
    console.log(`  Authorized on RedemptionNFT + RAMMToken + VestingVault`)

    // 5 — Seed sell-back liquidity from the buyer's existing USDC balance
    try {
      const approveHash = await buyerWallet.writeContract({
        address: USDC_ADDRESS, abi: ERC20_ABI,
        functionName: "approve", nonce: buyerNonce++, args: [marketAddress, SEED_USDC],
      })
      await publicClient.waitForTransactionReceipt({ hash: approveHash })

      const depositHash = await buyerWallet.writeContract({
        address: marketAddress, abi: DEPOSIT_LIQUIDITY_ABI,
        functionName: "depositLiquidity", nonce: buyerNonce++, args: [SEED_USDC],
      })
      await publicClient.waitForTransactionReceipt({ hash: depositHash })
      console.log(`  Seeded 5,000 USDC liquidity`)
    } catch (e) {
      console.warn(`  Liquidity seed failed (non-fatal, retry with seedMarketLiquidity.ts later): ${e}`)
      buyerNonce = await publicClient.getTransactionCount({ address: buyer.address, blockTag: "pending" })
    }

    // 6 — Update the record in place
    c.pvtAddress = pvtAddress
    c.marketAddress = marketAddress
    c.deployTxHash = marketHash
    c.campaignWallet = campaignWallet
    if (campaignPrivateKey) c.campaignPrivateKey = campaignPrivateKey
    c.redeemedCount = 0 // accurate: the fresh contract genuinely has 0 on-chain redemptions
    // NOTE: do NOT touch c.status here. Last migration blindly flipped every
    // sold_out -> active on the assumption it was always a stale artifact of
    // the old broken redemption counter — for Sneakers Air it was a deliberate
    // brand-set demo state, and got silently undone. Status is independent of
    // the redemption counter; leave it exactly as the brand set it.

    // Checkpoint after every campaign, not just once at the end — a crash
    // partway through a bulk run (rate limit, RPC blip) shouldn't lose every
    // already-migrated campaign's new addresses. Exactly what happened to
    // deployDemoProducts.ts's first run before this same fix landed there.
    writeFileSync(CAMPAIGNS_PATH, JSON.stringify(campaigns, null, 2))
    console.log()
  }

  console.log(`Wrote ${CAMPAIGNS_PATH}`)
  console.log("\nDone.")
}

main().catch((err) => { console.error(err); process.exit(1) })
