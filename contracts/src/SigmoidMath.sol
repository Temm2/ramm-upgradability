// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/// @title SigmoidMath
/// @notice Fixed-point implementation of the POPZ sigmoidal AMM pricing curve.
///
///   Price = a · (S − b) / √(c + (S − b)²) + P
///
///   Parameterized per-market (see CurveParams) — MVP1 shipped with one fixed
///   curve shared by every market regardless of supply cap or the brand's
///   chosen fast/medium/slow shape (captured in the campaign wizard but never
///   actually reaching the contract). This generalizes the same formula to
///   take real per-market parameters instead of hardcoded constants:
///
///     b = inflection supply           — scales with the market's actual
///                                        supply cap instead of a fixed 500
///                                        that most demo products (supplyCap
///                                        ~50) never get anywhere near
///     c = steepness                   — smaller c = steeper/"faster" curve
///     p = base price at inflection
///     aPrimary/aSecondary = amplitude below/at-or-above the inflection
///
///   See deriveCurveParams() (TS-side, agents/src/valet/curve.ts) for how
///   (minPrice, maxPrice, totalSupply, curveShape) — the brand's actual
///   inputs — turn into these five raw values: the "medium" shape at
///   totalSupply=1000, minPrice≈$916, maxPrice≈$1168 reproduces essentially
///   the same curve as the old fixed constants (a=100/200, b=500, c=100_000,
///   P=1000), up to integer rounding — not a bit-exact replay, but the same
///   shape at the same reference scale.
///
/// @dev All internal arithmetic uses WAD (1e18) fixed-point.
///      Key insight for correct sqrt:
///        - denominator_sq = c + (S-b)² in raw (non-WAD) space
///        - sqrt_wad(x_raw) = sqrt(x_raw · WAD²) = sqrt(x_raw) · WAD
///        - term_wad = diff · WAD² / sqrt_wad(denominator_sq)
///                   = diff / sqrt(denominator_sq) · WAD  ✓
library SigmoidMath {
    uint256 internal constant WAD = 1e18;

    /// @notice Per-market curve parameters, all in raw (non-WAD) integer
    ///         space — see derivation note above for how these are chosen.
    struct CurveParams {
        uint256 b;          // inflection supply
        uint256 c;          // steepness
        uint256 p;          // base price at inflection, USDC 6dp
        uint256 aPrimary;   // amplitude below the inflection (supply < b)
        uint256 aSecondary; // amplitude at/above the inflection (supply >= b)
    }

    /// @notice Compute price in USDC (6 decimals) for the token at position `supply`.
    ///         Amplitude switches at the inflection point for a steeper secondary curve.
    /// @param supply  Raw token count already sold (not WAD-scaled)
    /// @return price  USDC price with 6 decimals (e.g. 1_000_000_000 = $1000.00)
    function getPrice(uint256 supply, CurveParams memory params) internal pure returns (uint256 price) {
        // Amplitude doubles in the secondary zone — same formula, different A.
        uint256 a = supply >= params.b ? params.aSecondary : params.aPrimary;

        // ── Signed difference in raw space ───────────────────────────────────
        uint256 diff;
        bool negative;
        if (supply >= params.b) {
            diff = supply - params.b;
            negative = false;
        } else {
            diff = params.b - supply;
            negative = true;
        }

        // ── Denominator: sqrt(c + diff²) in WAD ──────────────────────────────
        uint256 diff_sq = diff * diff;
        uint256 denominator_raw_sq = params.c + diff_sq;
        uint256 denominator_wad = sqrt(denominator_raw_sq * WAD * WAD);

        // ── Term = diff / sqrt(c + diff²) in WAD ─────────────────────────────
        // Handle zero diff (exactly at inflection): term = 0, price = P.
        uint256 term_wad = diff == 0 ? 0 : (diff * WAD * WAD) / denominator_wad;

        // ── a · |term| in WAD ─────────────────────────────────────────────────
        uint256 a_term_wad = a * term_wad;

        // ── price_wad = (P ± a·|term|) in WAD ────────────────────────────────
        uint256 price_wad;
        if (!negative) {
            price_wad = params.p * WAD + a_term_wad;
        } else {
            price_wad = params.p * WAD - a_term_wad;
        }

        // ── Convert WAD → USDC 6 decimals ────────────────────────────────────
        price = price_wad / 1e12;
    }

    /// @notice Total USDC cost to buy `quantity` tokens starting at `supply`.
    ///         Discrete sum across consecutive positions (matches EVM gas model).
    function getTotalCost(uint256 supply, uint256 quantity, CurveParams memory params)
        internal
        pure
        returns (uint256 totalCost)
    {
        for (uint256 i = 0; i < quantity; i++) {
            totalCost += getPrice(supply + i, params);
        }
    }

    /// @notice Babylonian integer square root.
    function sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }
}
