/**
 * Audits every product's market against VestingVault.authorizedMarkets() —
 * written after discovering that trusting a migration script's own success
 * logs isn't enough (see auditOwnership.ts's history this session).
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
const VAULT_ADDRESS = process.env.VESTING_VAULT_ADDRESS as Address

const AUTH_ABI = [{
  name: "authorizedMarkets", type: "function", stateMutability: "view",
  inputs: [{ name: "", type: "address" }], outputs: [{ name: "", type: "bool" }],
}] as const

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
  const publicClient = createPublicClient({ chain: baseSepolia, transport: http(RPC_URL) })
  const all = [...loadDemoContracts(), ...loadCampaignContracts()]
  console.log(`Auditing VestingVault authorization for ${all.length} products...\n`)

  const broken: string[] = []
  for (const p of all) {
    const authorized = await publicClient.readContract({
      address: VAULT_ADDRESS, abi: AUTH_ABI, functionName: "authorizedMarkets", args: [p.marketAddress],
    }) as boolean
    if (!authorized) {
      console.log(`  [NOT AUTHORIZED] ${p.id} — ${p.marketAddress}`)
      broken.push(p.id)
    }
  }

  console.log(`\n=== ${broken.length} of ${all.length} products NOT authorized on VestingVault ===`)
}

main().catch((err) => { console.error(err); process.exit(1) })
