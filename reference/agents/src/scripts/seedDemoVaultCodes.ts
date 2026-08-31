/**
 * Seeds real, distinct per-unit demo redemption codes for every static demo
 * catalog product (Agatha, Arisa, Astride, etc.) — these have no VALET
 * campaign record, so RIDIM falls back to a vault key derived from the PVT
 * address itself (see ridim/index.ts's confirmShopperRedemption). Without
 * this, every redemption on these products returns an empty code, since
 * nothing was ever deposited for them.
 *
 * Usage: cd agents && npx tsx src/scripts/seedDemoVaultCodes.ts
 */
import "dotenv/config"
import { randomUUID } from "crypto"
import { readFileSync } from "fs"
import { fileURLToPath } from "url"
import path from "path"
import { depositCodes, remainingCodes } from "../valet/vault.js"

const __dir = path.dirname(fileURLToPath(import.meta.url))
const CODES_PER_PRODUCT = 10

function loadDemoContracts(): { id: string; pvtAddress: string }[] {
  const src = readFileSync(path.resolve(__dir, "../../../app/constants/productContracts.ts"), "utf8")
  const out: { id: string; pvtAddress: string }[] = []
  const re = /"([\w-]+)":\s*\{\s*pvtAddress:\s*"(0x[0-9a-fA-F]+)"/g
  for (const m of src.matchAll(re)) out.push({ id: m[1], pvtAddress: m[2] })
  return out
}

function main() {
  const products = loadDemoContracts()
  console.log(`Seeding demo codes for ${products.length} products (${CODES_PER_PRODUCT} each)...\n`)

  let seeded = 0
  let skipped = 0

  for (const p of products) {
    const key = p.pvtAddress.toLowerCase()
    if (remainingCodes(key) > 0) {
      console.log(`  [skip] ${p.id} — already has ${remainingCodes(key)} codes`)
      skipped++
      continue
    }
    const codes = Array.from({ length: CODES_PER_PRODUCT }, () =>
      `DEMO-${p.id}-${randomUUID().split("-")[0].toUpperCase()}`
    )
    depositCodes(key, codes)
    console.log(`  [seeded] ${p.id} — ${codes.length} codes`)
    seeded++
  }

  console.log(`\n=== Seeded: ${seeded}, Skipped (already had codes): ${skipped} ===`)
}

main()
