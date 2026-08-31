/**
 * Derives per-market SigmoidMath.CurveParams (contracts/src/SigmoidMath.sol)
 * from what a brand actually configures in the campaign wizard: a price
 * range (basePriceUsdc/maxPriceUsdc, raw 6-decimal USDC) and a curve shape
 * (fast/medium/slow — see app-brand's DynamicPricingInput.tsx). Neither of
 * those ever reached the contract before this — every market read the same
 * five hardcoded constants regardless of its own supply cap or the brand's
 * chosen shape (captured for display only, see CampaignRecord.curveShape).
 *
 * Unit note: `p`/`aPrimary`/`aSecondary` are PLAIN DOLLAR magnitudes, not
 * raw 6-decimal USDC — matching the original hardcoded constants' own units
 * (P_RAW = 1_000 meant $1000, not $0.001). SigmoidMath.getPrice() converts
 * to 6-decimal USDC internally via the WAD/1e12 step at the end. `b`/`c` are
 * plain raw token-count magnitudes (no currency conversion).
 */

export type CurveShape = "fast" | "medium" | "slow"

export interface CurveParams {
  b: bigint
  c: bigint
  p: bigint
  aPrimary: bigint
  aSecondary: bigint
}

// c = k · b² for each shape. Smaller k = steeper/"faster" transition around
// the inflection; larger k = more gradual/"slower" ramp. k=0.4 is the exact
// ratio the original fixed constants used (C_RAW=100_000, B_RAW=500 →
// 100_000/500² = 0.4) — kept as "medium" so a market whose brand picks the
// default shape at the original reference scale (totalSupply=1000,
// ~$916–$1168) reproduces essentially the same curve, not a new one.
const K_BY_SHAPE: Record<CurveShape, number> = {
  fast: 0.15,
  medium: 0.4,
  slow: 1.0,
}

/**
 * @param minPriceUsdc   Raw 6-decimal USDC price at supply=0 (basePriceUsdc)
 * @param maxPriceUsdc   Raw 6-decimal USDC price at supply=totalSupply
 * @param totalSupply    The market's actual supply cap — the inflection now
 *                        scales to this instead of a fixed 500 that most
 *                        demo products (supplyCap ~50) never got near,
 *                        making the two-zone amplitude switch meaningless
 *                        for them in practice.
 * @param curveShape     Brand's chosen fast/medium/slow (defaults "medium")
 */
export function deriveCurveParams(
  minPriceUsdc: number,
  maxPriceUsdc: number,
  totalSupply: number,
  curveShape: CurveShape = "medium"
): CurveParams {
  const k = K_BY_SHAPE[curveShape] ?? K_BY_SHAPE.medium

  const b = Math.max(1, Math.round(totalSupply / 2))
  const c = Math.max(1, Math.round(k * b * b))
  // term = b / sqrt(c + b²) — with c = k·b² this reduces to a scale-invariant
  // 1/sqrt(k+1), independent of the actual supply cap.
  const term = 1 / Math.sqrt(k + 1)

  const minPrice = minPriceUsdc / 1e6
  const maxPrice = Math.max(maxPriceUsdc / 1e6, minPrice) // flat pricing sends max === min

  // Solve for P and the two amplitudes so that:
  //   price(0)           = minPrice
  //   price(totalSupply)  = maxPrice
  //   aSecondary = 2 · aPrimary   (preserves the original design's "price
  //                                rises steeper past the midpoint," not
  //                                derived from min/max — a deliberate
  //                                asymmetry, not an artifact)
  // => P = (maxPrice + 2·minPrice) / 3
  const p = Math.round((maxPrice + 2 * minPrice) / 3)
  const aPrimary = Math.max(0, Math.round((p - minPrice) / term))
  const aSecondary = aPrimary * 2

  return {
    b: BigInt(b),
    c: BigInt(c),
    p: BigInt(Math.max(1, p)),
    aPrimary: BigInt(aPrimary),
    aSecondary: BigInt(aSecondary),
  }
}

/** As a tuple in the exact order SigmoidMath.CurveParams / the constructor expects. */
export function curveParamsTuple(params: CurveParams): [bigint, bigint, bigint, bigint, bigint] {
  return [params.b, params.c, params.p, params.aPrimary, params.aSecondary]
}
