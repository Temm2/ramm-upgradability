/**
 * Seeds USDC buyback liquidity into every demo product's IMPXMarket contract.
 *
 * Buy proceeds are routed straight out to brand/campaign wallets — a market
 * only has USDC to pay out sells if someone explicitly deposits it via
 * depositLiquidity(). None of the 40 demo product markets (app/constants/
 * productContracts.ts) had this seeded except Agatha (done manually during
 * an earlier debugging session) — every other one reverts on first sell with
 * InsufficientContractUSDC. This seeds all of them from the funded buyer
 * wallet's existing USDC balance (not minting new — same wallet used
 * throughout this project's testing).
 *
 * Usage: cd agents && npx tsx src/scripts/seedMarketLiquidity.ts [amountUsdcPerMarket]
 * Defaults to 5000 USDC per market (matches what Agatha got).
 */
import "dotenv/config"
import { createPublicClient, createWalletClient, http, parseUnits, formatUnits } from "viem"
import type { Address, Hex } from "viem"
import { privateKeyToAccount } from "viem/accounts"
import { baseSepolia } from "viem/chains"
import { readFileSync } from "fs"
import { fileURLToPath } from "url"
import path from "path"

// productContracts.ts lives in the app/ package (a separate project, own
// tsconfig/node_modules) — read as plain text and regex-parsed rather than
// imported as a module, same as deployDemoProducts.ts (which generates this
// file) already does for the reverse direction.
const __dir = path.dirname(fileURLToPath(import.meta.url))
const PRODUCT_CONTRACTS_PATH = path.resolve(__dir, "../../../app/constants/productContracts.ts")

function loadProductContracts(): Record<string, { pvtAddress: Address; marketAddress: Address }> {
  const src = readFileSync(PRODUCT_CONTRACTS_PATH, "utf8")
  const out: Record<string, { pvtAddress: Address; marketAddress: Address }> = {}
  const lineRe = /"([\w-]+)":\s*\{\s*pvtAddress:\s*"(0x[0-9a-fA-F]+)",\s*marketAddress:\s*"(0x[0-9a-fA-F]+)"\s*\}/g
  for (const m of src.matchAll(lineRe)) {
    out[m[1]] = { pvtAddress: m[2] as Address, marketAddress: m[3] as Address }
  }
  return out
}

const RPC_URL = process.env.BASE_SEPOLIA_RPC_URL!
const BUYER_KEY = process.env.BUYER_PRIVATE_KEY as Hex
const USDC_ADDRESS = process.env.USDC_ADDRESS as Address
const MIN_BALANCE_USDC = 1000 // skip markets already funded above this threshold

const USDC_ABI = [
  {
    name: "approve", type: "function", stateMutability: "nonpayable",
    inputs: [{ name: "spender", type: "address" }, { name: "amount", type: "uint256" }],
    outputs: [{ name: "", type: "bool" }],
  },
  {
    name: "balanceOf", type: "function", stateMutability: "view",
    inputs: [{ name: "account", type: "address" }],
    outputs: [{ name: "", type: "uint256" }],
  },
] as const

const MARKET_ABI = [{
  name: "depositLiquidity", type: "function", stateMutability: "nonpayable",
  inputs: [{ name: "amount", type: "uint256" }],
  outputs: [],
}] as const

async function main() {
  const amountArg = process.argv[2]
  const amountUsdc = parseFloat(amountArg ?? "5000")
  const amount = parseUnits(amountUsdc.toString(), 6)

  // retryCount/retryDelay ride out transient "over rate limit" errors from
  // shared/free RPC endpoints across a 40+-market bulk run (see the same fix
  // in deployDemoProducts.ts for why this matters).
  const transport = http(RPC_URL, { retryCount: 10, retryDelay: 3000 })
  const account = privateKeyToAccount(BUYER_KEY)
  const walletClient = createWalletClient({ account, chain: baseSepolia, transport })
  const publicClient = createPublicClient({ chain: baseSepolia, transport })

  const entries = Object.entries(loadProductContracts())
  console.log(`Checking ${entries.length} demo product markets, seeding to $${amountUsdc} USDC each if below $${MIN_BALANCE_USDC}...`)

  let nonce = await publicClient.getTransactionCount({ address: account.address, blockTag: "pending" })

  const skipped: string[] = []
  const seeded: string[] = []
  const failed: { id: string; error: string }[] = []

  for (const [id, contracts] of entries) {
    try {
      const balance = await publicClient.readContract({
        address: USDC_ADDRESS,
        abi: USDC_ABI,
        functionName: "balanceOf",
        args: [contracts.marketAddress],
      }) as bigint

      if (balance >= parseUnits(String(MIN_BALANCE_USDC), 6)) {
        console.log(`  [skip] ${id} — already has $${formatUnits(balance, 6)} USDC`)
        skipped.push(id)
        continue
      }

      const approveHash = await walletClient.writeContract({
        address: USDC_ADDRESS,
        abi: USDC_ABI,
        functionName: "approve",
        args: [contracts.marketAddress, amount],
        nonce: nonce++,
      })
      // Must wait for approve to actually be mined before sending deposit —
      // depositLiquidity's pre-flight simulation reads allowance from latest
      // mined state, which won't reflect an unconfirmed approve yet (this is
      // exactly what caused every market to fail with ERC20InsufficientAllowance
      // on the first unthrottled run).
      await publicClient.waitForTransactionReceipt({ hash: approveHash })

      const depositHash = await walletClient.writeContract({
        address: contracts.marketAddress,
        abi: MARKET_ABI,
        functionName: "depositLiquidity",
        args: [amount],
        nonce: nonce++,
      })
      await publicClient.waitForTransactionReceipt({ hash: depositHash })
      console.log(`  [seeded] ${id} — approve ${approveHash.slice(0, 10)}... deposit ${depositHash.slice(0, 10)}...`)
      seeded.push(id)
    } catch (err) {
      console.error(`  [FAILED] ${id}:`, err instanceof Error ? err.message : String(err))
      failed.push({ id, error: err instanceof Error ? err.message : String(err) })
      // Re-sync nonce from chain in case the failure was a nonce mismatch,
      // so subsequent markets don't cascade-fail too.
      nonce = await publicClient.getTransactionCount({ address: account.address, blockTag: "pending" })
    }
  }

  console.log("\n=== Summary ===")
  console.log(`Seeded: ${seeded.length}`, seeded)
  console.log(`Already funded (skipped): ${skipped.length}`, skipped)
  console.log(`Failed: ${failed.length}`, failed)
}

main().catch((err) => { console.error(err); process.exit(1) })
