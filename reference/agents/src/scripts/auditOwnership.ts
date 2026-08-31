/**
 * Audits every product's PVTToken.owner() to confirm it equals its market
 * address. Written after discovering deployDemoProducts.ts's transferOwnership
 * step never checked the receipt status — a reverted transfer would silently
 * log "success" and leave the PVTToken permanently un-mintable by its market.
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

const OWNER_ABI = [{
  name: "owner", type: "function", stateMutability: "view",
  inputs: [], outputs: [{ name: "", type: "address" }],
}] as const

function loadDemoContracts(): { id: string; pvtAddress: Address; marketAddress: Address }[] {
  const src = readFileSync(path.resolve(__dir, "../../../app/constants/productContracts.ts"), "utf8")
  const out: { id: string; pvtAddress: Address; marketAddress: Address }[] = []
  const re = /"([\w-]+)":\s*\{\s*pvtAddress:\s*"(0x[0-9a-fA-F]+)",\s*marketAddress:\s*"(0x[0-9a-fA-F]+)"\s*\}/g
  for (const m of src.matchAll(re)) out.push({ id: m[1], pvtAddress: m[2] as Address, marketAddress: m[3] as Address })
  return out
}

function loadCampaignContracts(): { id: string; pvtAddress: Address; marketAddress: Address }[] {
  const data = JSON.parse(readFileSync(path.resolve(__dir, "../../data/campaigns.json"), "utf8"))
  return data.map((c: any) => ({ id: c.productName, pvtAddress: c.pvtAddress, marketAddress: c.marketAddress }))
}

async function main() {
  const publicClient = createPublicClient({ chain: baseSepolia, transport: http(RPC_URL, { retryCount: 10, retryDelay: 3000 }) })
  const all = [...loadDemoContracts(), ...loadCampaignContracts()]
  console.log(`Auditing ${all.length} products...\n`)

  const broken: { id: string; pvtAddress: Address; marketAddress: Address; actualOwner: Address }[] = []

  for (const p of all) {
    try {
      const owner = await publicClient.readContract({
        address: p.pvtAddress, abi: OWNER_ABI, functionName: "owner",
      }) as Address
      if (owner.toLowerCase() !== p.marketAddress.toLowerCase()) {
        console.log(`  [BROKEN] ${p.id} — owner=${owner}, expected market=${p.marketAddress}`)
        broken.push({ ...p, actualOwner: owner })
      }
    } catch (err) {
      console.log(`  [ERROR] ${p.id} — ${err instanceof Error ? err.message : String(err)}`)
    }
  }

  console.log(`\n=== ${broken.length} of ${all.length} products have wrong PVTToken ownership ===`)
  console.log(JSON.stringify(broken, null, 2))
}

main().catch((err) => { console.error(err); process.exit(1) })
