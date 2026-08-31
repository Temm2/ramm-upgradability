/**
 * Safe JSON file store primitive.
 *
 * Every agent used to hand-roll its own readAll/writeAll pair around
 * fs.readFileSync/writeFileSync directly (8 copies of the same pattern
 * across valet/store.ts, valet/vault.ts, valet/brands.ts, valet/referrals.ts,
 * valet/attributions.ts, valet/dppStore.ts, folio/indexer.ts, nanda/registry.ts).
 * None of them were safe: agents run as separate OS processes, and some
 * (e.g. folio/indexer.ts) import and call another agent's store functions
 * directly on the same file, so two processes can race a read-modify-write
 * and silently clobber each other's change.
 *
 * This fixes both halves of that:
 *   - mutate() takes a cross-process lock around the WHOLE read-modify-write,
 *     not just the write, so a concurrent mutate() always sees the other's
 *     completed change before computing its own.
 *   - writes are atomic (write to a temp file, then rename onto the real
 *     path) so a reader never observes a partially-written file.
 */
import fs from "fs"
import path from "path"
import { randomUUID } from "crypto"

const LOCK_RETRY_MS = 25
const LOCK_TIMEOUT_MS = 5_000
const STALE_LOCK_MS = 15_000 // covers a crashed/restarted agent holding a lock forever

// Synchronous sleep without busy-spinning the CPU. mutate() must stay
// synchronous (its callers are, and making it async would cascade into an
// async rewrite of every store and skill handler) — Atomics.wait blocks this
// thread but actually yields to the OS scheduler while waiting, unlike a
// spin-loop on Date.now().
function sleepSync(ms: number): void {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms)
}

function acquireLock(filePath: string): string {
  const lockPath = `${filePath}.lock`
  const deadline = Date.now() + LOCK_TIMEOUT_MS
  for (;;) {
    try {
      fs.mkdirSync(lockPath) // atomic on POSIX — throws EEXIST if already held
      return lockPath
    } catch (err) {
      const code = (err as NodeJS.ErrnoException).code
      if (code !== "EEXIST") throw err

      // Stale-lock recovery: a crashed process can leave the lock dir behind
      // forever otherwise — common in this dev setup (agents get killed and
      // restarted a lot).
      try {
        const age = Date.now() - fs.statSync(lockPath).mtimeMs
        if (age > STALE_LOCK_MS) {
          fs.rmSync(lockPath, { recursive: true, force: true })
          continue
        }
      } catch {
        // lock disappeared between the failed mkdir and this check — fine, retry
        continue
      }

      if (Date.now() > deadline) {
        throw new Error(`Timed out waiting for lock on ${filePath}`)
      }
      sleepSync(LOCK_RETRY_MS)
    }
  }
}

function releaseLock(lockPath: string): void {
  fs.rmSync(lockPath, { recursive: true, force: true })
}

function readFresh<T>(filePath: string, defaultValue: T): T {
  if (!fs.existsSync(filePath)) return defaultValue
  try {
    return JSON.parse(fs.readFileSync(filePath, "utf8")) as T
  } catch {
    return defaultValue
  }
}

function atomicWrite<T>(filePath: string, value: T): void {
  fs.mkdirSync(path.dirname(filePath), { recursive: true })
  const tmpPath = `${filePath}.tmp-${randomUUID()}`
  fs.writeFileSync(tmpPath, JSON.stringify(value, null, 2))
  fs.renameSync(tmpPath, filePath) // atomic on the same filesystem
}

export interface JsonStore<T> {
  /** Point-in-time read. No lock needed — renameSync is atomic, so a reader
   *  never sees a half-written file, only the previous or the next full state. */
  read(): T
  /** Locks, re-reads fresh from disk (not your possibly-stale in-memory copy),
   *  applies fn, atomic-writes the result, unlocks, and returns the new value. */
  mutate(fn: (current: T) => T): T
}

export function createJsonStore<T>(filePath: string, defaultValue: T): JsonStore<T> {
  return {
    read(): T {
      return readFresh(filePath, defaultValue)
    },
    mutate(fn: (current: T) => T): T {
      const lockPath = acquireLock(filePath)
      try {
        const current = readFresh(filePath, defaultValue)
        const next = fn(current)
        atomicWrite(filePath, next)
        return next
      } finally {
        releaseLock(lockPath)
      }
    },
  }
}
