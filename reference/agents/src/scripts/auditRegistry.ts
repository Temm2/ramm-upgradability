/**
 * Audits every product's IMPXMarket.registry() to confirm it equals
 * REGISTRY_ADDRESS, and that RammRegistry's four pointers match the expected
 * shared-contract addresses. Doesn't trust the migration scripts' own "wired
 * up" log lines — this session already proved once (the 31/49 silent
 * transferOwnership failure) that a logged success can lie.
 */
import "dotenv/config"
import { createPublicClient, http } from "viem"
import type { Address } from "viem"
import { baseSepolia } from "viem/chains"
import { readFileSync } from "fs"
import { fileURLToPath } from "url"
import path from "path"

const __dir = path.dirname(fileURLToPath(import.meta.url))
const RPC_URL = process.env.BASE_SEPOLIA_RPC_URL!
const REGISTRY_ADDRESS = process.env.REGISTRY_ADDRESS as Address
const RAMM_ADDRESS = process.env.RAMM_TOKEN_ADDRESS as Address
const NFT_ADDRESS = process.env.REDEMPTION_NFT_ADDRESS as Address
const VAULT_ADDRESS = process.env.VESTING_VAULT_ADDRESS as Address
const STAKING_ADDRESS = process.env.PROMO_STAKING_ADDRESS as Address

const MARKET_REGISTRY_ABI = [{
  name: "registry", type: "function", stateMutability: "view",
  inputs: [], outputs: [{ name: "", type: "address" }],
}] as const

const REGISTRY_READ_ABI = [
  { name: "rammToken", type: "function", stateMutability: "view", inputs: [], outputs: [{ name: "", type: "address" }] },
  { name: "redemptionNFT", type: "function", stateMutability: "view", inputs: [], outputs: [{ name: "", type: "address" }] },
  { name: "vestingVault", type: "function", stateMutability: "view", inputs: [], outputs: [{ name: "", type: "address" }] },
  { name: "promoStaking", type: "function", stateMutability: "view", inputs: [], outputs: [{ name: "", type: "address" }] },
] as const

function loadDemoContracts(): { id: string; marketAddress: Address }[] {
  const src = readFileSync(path.resolve(__dir, "../../../app/constants/productContracts.ts"), "utf8")
  const out: { id: string; marketAddress: Address }[] = []
  const re = /"([\w-]+)":\s*\{\s*pvtAddress:\s*"0x[0-9a-fA-F]+",\s*marketAddress:\s*"(0x[0-9a-fA-F]+)"\s*\}/g
  for (const m of src.matchAll(re)) out.push({ id: m[1], marketAddress: m[2] as Address })
  return out
}

function loadCampaignContracts(): { id: string; marketAddress: Address }[] {
  const data = JSON.parse(readFileSync(path.resolve(__dir, "../../data/campaigns.json"), "utf8"))
  return data.map((c: any) => ({ id: c.productName, marketAddress: c.marketAddress }))
}

async function main() {
  if (!REGISTRY_ADDRESS) throw new Error("REGISTRY_ADDRESS not set in agents/.env")
  const publicClient = createPublicClient({ chain: baseSepolia, transport: http(RPC_URL, { retryCount: 10, retryDelay: 3000 }) })

  console.log("=== RammRegistry's own pointers ===")
  const [rammToken, redemptionNFT, vestingVault, promoStaking] = await Promise.all([
    publicClient.readContract({ address: REGISTRY_ADDRESS, abi: REGISTRY_READ_ABI, functionName: "rammToken" }),
    publicClient.readContract({ address: REGISTRY_ADDRESS, abi: REGISTRY_READ_ABI, functionName: "redemptionNFT" }),
    publicClient.readContract({ address: REGISTRY_ADDRESS, abi: REGISTRY_READ_ABI, functionName: "vestingVault" }),
    publicClient.readContract({ address: REGISTRY_ADDRESS, abi: REGISTRY_READ_ABI, functionName: "promoStaking" }),
  ])
  const checks: [string, string, string][] = [
    ["rammToken", rammToken as string, RAMM_ADDRESS],
    ["redemptionNFT", redemptionNFT as string, NFT_ADDRESS],
    ["vestingVault", vestingVault as string, VAULT_ADDRESS],
    ["promoStaking", promoStaking as string, STAKING_ADDRESS],
  ]
  let registryOk = true
  for (const [name, actual, expected] of checks) {
    const ok = actual.toLowerCase() === expected.toLowerCase()
    if (!ok) registryOk = false
    console.log(`  ${ok ? "OK" : "MISMATCH"}  ${name}: ${actual} ${ok ? "" : `(expected ${expected})`}`)
  }

  const all = [...loadDemoContracts(), ...loadCampaignContracts()]
  console.log(`\n=== ${all.length} markets — registry() pointer ===`)
  const bad: string[] = []
  for (const { id, marketAddress } of all) {
    try {
      const reg = await publicClient.readContract({ address: marketAddress, abi: MARKET_REGISTRY_ABI, functionName: "registry" })
      const ok = (reg as string).toLowerCase() === REGISTRY_ADDRESS.toLowerCase()
      if (!ok) { bad.push(id); console.log(`  MISMATCH  ${id}: registry()=${reg}`) }
    } catch (e) {
      bad.push(id)
      console.log(`  ERROR  ${id}: ${e instanceof Error ? e.message.split("\n")[0] : String(e)}`)
    }
  }

  console.log(`\n${bad.length === 0 && registryOk ? "ALL GOOD" : "PROBLEMS FOUND"} — ${all.length - bad.length}/${all.length} markets correctly wired to the registry`)
  if (bad.length > 0) console.log("Bad:", bad)
}

main().catch((e) => { console.error("FAILED:", e); process.exit(1) })
