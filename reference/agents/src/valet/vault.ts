/**
 * Secret code vault.
 * Stub for ICP Swiss Subnet TEE + Threshold ECDSA (V2).
 *
 * V1 implementation: AES-256-GCM encrypted JSON on disk.
 * Each campaign gets an encrypted array of promo codes.
 * Codes are consumed in order (FIFO) on redeem.
 *
 * V2 replacement: RIDIM agent sends Threshold ECDSA request to ICP Swiss Subnet,
 * which verifies the PVT burn proof on Base L3 before releasing exactly one code.
 */
import path from "path"
import { fileURLToPath } from "url"
import crypto from "crypto"
import { createJsonStore } from "../state/jsonStore.js"

const __dir = path.dirname(fileURLToPath(import.meta.url))
const VAULT_PATH = path.resolve(__dir, "../../data/vault.json")

// Derive AES key from VAULT_SECRET env var (32 bytes for AES-256)
function getKey(): Buffer {
  const secret = process.env.VAULT_SECRET ?? "dev-secret-change-in-production-!!"
  return crypto.createHash("sha256").update(secret).digest()
}

function encrypt(plaintext: string): string {
  const iv = crypto.randomBytes(12)
  const cipher = crypto.createCipheriv("aes-256-gcm", getKey(), iv)
  const enc = Buffer.concat([cipher.update(plaintext, "utf8"), cipher.final()])
  const tag = cipher.getAuthTag()
  return [iv.toString("hex"), tag.toString("hex"), enc.toString("hex")].join(".")
}

function decrypt(token: string): string {
  const [ivHex, tagHex, encHex] = token.split(".")
  const iv  = Buffer.from(ivHex,  "hex")
  const tag = Buffer.from(tagHex, "hex")
  const enc = Buffer.from(encHex, "hex")
  const decipher = crypto.createDecipheriv("aes-256-gcm", getKey(), iv)
  decipher.setAuthTag(tag)
  return decipher.update(enc).toString("utf8") + decipher.final("utf8")
}

interface VaultData {
  [campaignId: string]: string  // encrypted JSON string of string[]
}

const store = createJsonStore<VaultData>(VAULT_PATH, {})

/** Deposit promo codes for a campaign. Overwrites any existing codes. */
export function depositCodes(campaignId: string, codes: string[]): void {
  store.mutate((vault) => {
    vault[campaignId] = encrypt(JSON.stringify(codes))
    return vault
  })
}

/** Claim one promo code for a campaign (FIFO). Returns null if exhausted.
 *  The read-decrypt-shift-encrypt-write sequence happens inside a single
 *  mutate() lock so two concurrent redemptions can never claim the same code. */
export function claimCode(campaignId: string): string | null {
  let claimed: string | null = null
  store.mutate((vault) => {
    const encrypted = vault[campaignId]
    if (!encrypted) return vault

    const codes: string[] = JSON.parse(decrypt(encrypted))
    if (codes.length === 0) return vault

    claimed = codes.shift()!
    vault[campaignId] = encrypt(JSON.stringify(codes))
    return vault
  })
  return claimed
}

/** Read current codes without consuming them — used by addSecretCodes to merge. */
export function readVaultCodes(campaignId: string): string[] {
  const vault = store.read()
  const encrypted = vault[campaignId]
  if (!encrypted) return []
  try {
    return JSON.parse(decrypt(encrypted))
  } catch {
    return []
  }
}

/** How many codes remain for a campaign. */
export function remainingCodes(campaignId: string): number {
  const vault = store.read()
  const encrypted = vault[campaignId]
  if (!encrypted) return 0
  try {
    const codes: string[] = JSON.parse(decrypt(encrypted))
    return codes.length
  } catch {
    return 0
  }
}
