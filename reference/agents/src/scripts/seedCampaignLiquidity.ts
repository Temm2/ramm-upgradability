/**
 * Seeds sell-back liquidity into VALET brand campaigns' markets (as opposed
 * to seedMarketLiquidity.ts, which covers the static demo catalog). Reads
 * marketAddress directly from campaigns.json.
 *
 * Usage: cd agents && npx tsx src/scripts/seedCampaignLiquidity.ts [amountUsdcPerMarket]
 */
import "dotenv/config"
import { createPublicClient, createWalletClient, http, parseUnits, formatUnits } from "viem"
import type { Address, Hex } from "viem"
import { privateKeyToAccount } from "viem/accounts"
import { baseSepolia } from "viem/chains"
import { readFileSync } from "fs"
import { fileURLToPath } from "url"
import path from "path"

const __dir = path.dirname(fileURLToPath(import.meta.url))
const CAMPAIGNS_PATH = path.resolve(__dir, "../../data/campaigns.json")

const RPC_URL = process.env.BASE_SEPOLIA_RPC_URL!
const BUYER_KEY = process.env.BUYER_PRIVATE_KEY as Hex
const USDC_ADDRESS = process.env.USDC_ADDRESS as Address
const MIN_BALANCE_USDC = 1000

const USDC_ABI = [
  { name: "approve", type: "function", stateMutability: "nonpayable",
    inputs: [{ name: "spender", type: "address" }, { name: "amount", type: "uint256" }],
    outputs: [{ name: "", type: "bool" }] },
  { name: "balanceOf", type: "function", stateMutability: "view",
    inputs: [{ name: "account", type: "address" }], outputs: [{ name: "", type: "uint256" }] },
] as const

const MARKET_ABI = [{
  name: "depositLiquidity", type: "function", stateMutability: "nonpayable",
  inputs: [{ name: "amount", type: "uint256" }], outputs: [],
}] as const

async function main() {
  const amountUsdc = parseFloat(process.argv[2] ?? "5000")
  const amount = parseUnits(amountUsdc.toString(), 6)

  // retryCount/retryDelay ride out transient "over rate limit" errors from
  // shared/free RPC endpoints (see the same fix in deployDemoProducts.ts).
  const transport = http(RPC_URL, { retryCount: 10, retryDelay: 3000 })
  const account = privateKeyToAccount(BUYER_KEY)
  const walletClient = createWalletClient({ account, chain: baseSepolia, transport })
  const publicClient = createPublicClient({ chain: baseSepolia, transport })

  const campaigns: { productName: string; marketAddress: Address }[] = JSON.parse(readFileSync(CAMPAIGNS_PATH, "utf8"))
  console.log(`Checking ${campaigns.length} campaign markets, seeding to $${amountUsdc} USDC each if below $${MIN_BALANCE_USDC}...`)

  let nonce = await publicClient.getTransactionCount({ address: account.address, blockTag: "pending" })
  const seeded: string[] = []
  const skipped: string[] = []
  const failed: string[] = []

  for (const c of campaigns) {
    try {
      const balance = await publicClient.readContract({
        address: USDC_ADDRESS, abi: USDC_ABI, functionName: "balanceOf", args: [c.marketAddress],
      }) as bigint

      if (balance >= parseUnits(String(MIN_BALANCE_USDC), 6)) {
        console.log(`  [skip] ${c.productName} — already has $${formatUnits(balance, 6)} USDC`)
        skipped.push(c.productName)
        continue
      }

      const approveHash = await walletClient.writeContract({
        address: USDC_ADDRESS, abi: USDC_ABI, functionName: "approve",
        args: [c.marketAddress, amount], nonce: nonce++,
      })
      await publicClient.waitForTransactionReceipt({ hash: approveHash })

      const depositHash = await walletClient.writeContract({
        address: c.marketAddress, abi: MARKET_ABI, functionName: "depositLiquidity",
        args: [amount], nonce: nonce++,
      })
      await publicClient.waitForTransactionReceipt({ hash: depositHash })
      console.log(`  [seeded] ${c.productName}`)
      seeded.push(c.productName)
    } catch (err) {
      console.error(`  [FAILED] ${c.productName}:`, err instanceof Error ? err.message : String(err))
      failed.push(c.productName)
      nonce = await publicClient.getTransactionCount({ address: account.address, blockTag: "pending" })
    }
  }

  console.log("\n=== Summary ===")
  console.log(`Seeded: ${seeded.length}`, seeded)
  console.log(`Skipped: ${skipped.length}`, skipped)
  console.log(`Failed: ${failed.length}`, failed)
}

main().catch((err) => { console.error(err); process.exit(1) })
