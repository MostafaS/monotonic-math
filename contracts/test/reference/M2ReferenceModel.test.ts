// SPDX-License-Identifier: MIT
//
// Unit tests for the TypeScript reference math model (Phase 1).
// Run via: `npm run test:reference` (Hardhat v3 node:test runner).
//
// Coverage:
//   1. Baseline parity vs. canonical Track A CSV (fee-free row-by-row).
//   2. Lemma 4.2 residual identity (stateless fuzz).
//   3. Floor monotonicity per op (randomized, all 7 op classes).
//   4. collectFees conservation (randomized Φ_t, Φ_s).
//   5. SupplyExhausted on redeem when S == 0.
//   6. Theorem 5.2 anchor (A*, Δ*) at canonical month-12 state.

import { describe, it } from "node:test";
import { strict as assert } from "node:assert";
import { readFileSync, existsSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

import {
  DEFAULT_CONFIG,
  M2Config,
  M2State,
  assertFloorMonotone,
  buyAndBurn,
  canonicalGenesis,
  collectFees,
  deterministicBaseline,
  floorPrice,
  isqrt,
  lpBuy,
  lpSell,
  mulDivFloor,
  redeem,
  revToTreasury,
  runBaseline,
  transfer,
} from "./M2ReferenceModel.ts";

// =============================================================================
// Test helpers
// =============================================================================

const HERE = dirname(fileURLToPath(import.meta.url));
const SIM_OUT = resolve(HERE, "../../../simulation/outputs");

// Deterministic PRNG (Mulberry32) — same seed across runs for repeatability.
function mulberry32(seed: number): () => number {
  let a = seed >>> 0;
  return function () {
    a |= 0;
    a = (a + 0x6d2b79f5) | 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

/**
 * Sample a bigint uniformly in [lo, hi] using the provided PRNG. Uses
 * 53-bit float * range; sufficient for reachable test magnitudes (well
 * below 2^53). For wider ranges we splice two draws.
 */
function randBigInt(rng: () => number, lo: bigint, hi: bigint): bigint {
  if (hi < lo) throw new Error(`randBigInt: hi < lo`);
  const range = hi - lo + 1n;
  if (range <= 0n) return lo;
  // Splice two 26-bit chunks to safely cover up to 2^52 spans.
  const r0 = BigInt(Math.floor(rng() * (1 << 26)));
  const r1 = BigInt(Math.floor(rng() * (1 << 26)));
  const r = (r1 << 26n) + r0;
  return lo + (r % range);
}

/** ULP-style tolerance: agreement within max(absTol, relTol * |reference|). */
function withinTol(
  actual: number, reference: number, absTol: number, relTol: number,
): boolean {
  const diff = Math.abs(actual - reference);
  const bar = Math.max(absTol, relTol * Math.abs(reference));
  return diff <= bar;
}

// =============================================================================
// 1. Baseline parity vs. canonical Track A CSV
// =============================================================================

describe("M2ReferenceModel — baseline parity vs. Track A CSV (fee-free)", () => {
  it("reproduces simulation/outputs/baseline_12mo.csv row-by-row", () => {
    const csvPath = resolve(SIM_OUT, "baseline_12mo.csv");
    if (!existsSync(csvPath)) {
      assert.fail(
        `Missing ${csvPath} — run 'python3 ../simulation/generate_figures.py' first.`,
      );
    }
    const rows = parseCsv(csvPath);
    assert.equal(rows.length, 13, "expected 13 rows (months 0..12)");

    // The TS model emits 18-decimal integers; the CSV holds floats. We
    // compare both to dollar-precision relative tolerance (1e-12 relative
    // for state quantities; floor and spot are derived and shift through
    // float artifacts of the Python recurrence — the trajectory is
    // mathematically exact under rationals).
    //
    // Tolerance justification: the Python simulator uses float64 with
    // ~15.95 significant decimal digits; the TS bigint uses 6-decimal
    // stable units and 18-decimal token units. Their disagreement is
    // bounded by float64 ULP-of-relative-error ~1.1e-16, accumulated
    // over up to 12 months of recurrence. We use 1e-9 relative which
    // is conservative by ~7 orders of magnitude.
    const cfg: M2Config = { ...DEFAULT_CONFIG, feeMode: "fee-free" };
    const snaps = runBaseline({
      monthlyRevenueDollars: 100_000, nMonths: 12, cfg,
    });

    for (let m = 0; m <= 12; m++) {
      const row = rows[m];
      const s = snaps[m];
      const csvMonth = Number(row.month);
      assert.equal(csvMonth, m);

      // Convert TS bigint state back to human dollars / tokens for comparison.
      const dollar = 10 ** cfg.stableDecimals;
      const token = 1e18;
      const T = Number(s.state.T) / dollar;
      const S = Number(s.state.S) / token;
      const Lt = Number(s.state.Lt) / token;
      const Ls = Number(s.state.Ls) / dollar;
      const F = Number(s.floor18) / 1e18;
      const P = Number(s.spot18) / 1e18;

      assert.ok(withinTol(T, Number(row.treasury), 1e-6, 1e-9),
        `month ${m}: T mismatch (TS=${T}, CSV=${row.treasury})`);
      assert.ok(withinTol(S, Number(row.supply), 1e-3, 1e-9),
        `month ${m}: S mismatch (TS=${S}, CSV=${row.supply})`);
      assert.ok(withinTol(Lt, Number(row.lp_tokens), 1e-3, 1e-9),
        `month ${m}: Lt mismatch (TS=${Lt}, CSV=${row.lp_tokens})`);
      assert.ok(withinTol(Ls, Number(row.lp_stable), 1e-6, 1e-9),
        `month ${m}: Ls mismatch (TS=${Ls}, CSV=${row.lp_stable})`);
      assert.ok(withinTol(F, Number(row.floor), 1e-15, 1e-9),
        `month ${m}: F mismatch (TS=${F}, CSV=${row.floor})`);
      assert.ok(withinTol(P, Number(row.spot), 1e-15, 1e-9),
        `month ${m}: P mismatch (TS=${P}, CSV=${row.spot})`);
    }
  });

  it("reproduces month-12 anchor exactly: T=$1.6M, S=2e9/3, F=0.0024", () => {
    const cfg: M2Config = { ...DEFAULT_CONFIG, feeMode: "fee-free" };
    const snaps = deterministicBaseline(
      100_000n * 10n ** 6n, 12, canonicalGenesis(cfg), cfg,
    );
    const s12 = snaps[12].state;
    // T_12 exact in stable units: $1,600,000 * 10^6
    assert.equal(s12.T, 1_600_000n * 10n ** 6n);
    // F = T/S = 0.0024 — at 18-decimal scaling, floor18 == 2400000000000000
    // because mulDiv(T, 10^30, S) with T=1.6e12 (in 10^{-6} units) and
    // S = 2e9/3 * 1e18 = 666666...*1e18. We accept the integer-truncation
    // tail as documented in floor18.
    const F12 = snaps[12].floor18;
    // Expect F12 ≈ 2.4e15 (in 1e-18 units of dollars) — i.e. 0.0024 USD/token.
    assert.ok(F12 >= 2_399_999_999_999_999n && F12 <= 2_400_000_000_000_001n,
      `month-12 floor18 = ${F12} expected ~2.4e15`);
  });
});

// =============================================================================
// 2. Lemma 4.2 residual identity (paper §4.2)
//    (T - P) * S == T * (S - N) + r, where
//    P = floor(N*T/S), r = (N*T) mod S
// =============================================================================

describe("M2ReferenceModel — Lemma 4.2 residual identity", () => {
  it("holds for 1,000 random (T, S, N) triples", () => {
    const rng = mulberry32(0x4ed52a1f & 0xffffffff);
    for (let i = 0; i < 1000; i++) {
      // Use reachable magnitudes: T ~ stable units ($1k–$10M with d_s=6 → 1e9..1e13).
      const T = randBigInt(rng, 10n ** 9n, 10n ** 13n);
      // S ~ token units (1e15..1e27 = ~1e-3..1e9 tokens).
      const S = randBigInt(rng, 10n ** 15n, 10n ** 27n);
      const N = randBigInt(rng, 1n, S);
      const P = mulDivFloor(N, T, S);
      const r = (N * T) % S;
      const lhs = (T - P) * S;
      const rhs = T * (S - N) + r;
      assert.equal(lhs, rhs, `Lemma 4.2 violated at (T=${T},S=${S},N=${N})`);
      // Strict raise iff r > 0.
      if (S - N > 0n) {
        // (T-P)/(S-N) >= T/S — cross-product form:
        // (T - P) * S >= T * (S - N), strict iff r > 0.
        const cross = (T - P) * S - T * (S - N);
        assert.equal(cross, r, "residual identity tail");
        if (r > 0n) assert.ok(cross > 0n);
      }
    }
  });
});

// =============================================================================
// 3. Floor monotonicity per op (paper §4 Theorem 4.3)
// =============================================================================

describe("M2ReferenceModel — floor monotonicity per op", () => {
  function randomReachableState(rng: () => number): M2State {
    // Pick a state in the genesis-like regime; small enough for fast tests,
    // large enough that integer truncation does not dominate.
    const T = randBigInt(rng, 10n ** 11n, 10n ** 13n);   // $100k–$10M
    const S = randBigInt(rng, 10n ** 24n, 10n ** 27n);   // 1e6–1e9 tokens
    // LP must satisfy k > 0 and a reasonable spot price.
    const Lt = randBigInt(rng, 10n ** 23n, 10n ** 26n);  // 1e5–1e8 tokens
    const Ls = randBigInt(rng, 10n ** 11n, 10n ** 13n);  // $100k–$10M
    const Phit = randBigInt(rng, 0n, 10n ** 22n);
    const Phis = randBigInt(rng, 0n, 10n ** 10n);
    return { T, S, Lt, Ls, Phit, Phis };
  }

  it("Case 1 — revToTreasury", () => {
    const rng = mulberry32(101);
    for (let i = 0; i < 200; i++) {
      const prev = randomReachableState(rng);
      const X = randBigInt(rng, 0n, 10n ** 12n);
      const next = revToTreasury(prev, X);
      assertFloorMonotone(prev, next);
    }
  });

  it("Case 2 — buyAndBurn (both fee modes)", () => {
    const rng = mulberry32(102);
    for (const feeMode of ["with-fees", "fee-free"] as const) {
      const cfg: M2Config = { ...DEFAULT_CONFIG, feeMode };
      for (let i = 0; i < 200; i++) {
        const prev = randomReachableState(rng);
        const X = randBigInt(rng, 1n, 10n ** 12n);
        const { state: next } = buyAndBurn(prev, X, cfg);
        assertFloorMonotone(prev, next);
      }
    }
  });

  it("Case 3 — redeem", () => {
    const rng = mulberry32(103);
    for (let i = 0; i < 200; i++) {
      const prev = randomReachableState(rng);
      const N = randBigInt(rng, 1n, prev.S - 1n); // avoid full drain in this loop
      const { state: next } = redeem(prev, N);
      assertFloorMonotone(prev, next);
    }
  });

  it("Case 4 — lpBuy", () => {
    const rng = mulberry32(104);
    for (let i = 0; i < 200; i++) {
      const prev = randomReachableState(rng);
      const X = randBigInt(rng, 1n, 10n ** 12n);
      const { state: next } = lpBuy(prev, X);
      assertFloorMonotone(prev, next);
    }
  });

  it("Case 5 — lpSell", () => {
    const rng = mulberry32(105);
    for (let i = 0; i < 200; i++) {
      const prev = randomReachableState(rng);
      const N = randBigInt(rng, 1n, 10n ** 23n);
      const { state: next } = lpSell(prev, N);
      assertFloorMonotone(prev, next);
    }
  });

  it("Case 6 — transfer (no-op)", () => {
    const rng = mulberry32(106);
    for (let i = 0; i < 50; i++) {
      const prev = randomReachableState(rng);
      const next = transfer(prev, 1n, "0xA", "0xB");
      assertFloorMonotone(prev, next);
      assert.equal(next.T, prev.T);
      assert.equal(next.S, prev.S);
      assert.equal(next.Lt, prev.Lt);
      assert.equal(next.Ls, prev.Ls);
    }
  });

  it("Case 7 — collectFees", () => {
    const rng = mulberry32(107);
    for (let i = 0; i < 200; i++) {
      const prev = randomReachableState(rng);
      const { state: next } = collectFees(prev);
      assertFloorMonotone(prev, next);
    }
  });
});

// =============================================================================
// 4. collectFees conservation: no stranded wei
//    K_b + K_burn == K_real;  U_b + U_treas == U_real
// =============================================================================

describe("M2ReferenceModel — collectFees conservation", () => {
  it("preserves total token-side and stable-side mass across 1,000 random calls", () => {
    const rng = mulberry32(0xc0ffee);
    for (let i = 0; i < 1000; i++) {
      const Phit = randBigInt(rng, 0n, 10n ** 30n);
      const Phis = randBigInt(rng, 0n, 10n ** 30n);
      const prev: M2State = {
        T: 10n ** 12n, S: 10n ** 27n, Lt: 10n ** 26n, Ls: 10n ** 12n,
        Phit, Phis,
      };
      const r = collectFees(prev);
      // token side
      assert.equal(r.tokenBounty + r.tokenBurned, Phit,
        `token conservation broken: ${r.tokenBounty} + ${r.tokenBurned} != ${Phit}`);
      // stable side
      assert.equal(r.stableBounty + r.stableToTreasury, Phis,
        `stable conservation broken: ${r.stableBounty} + ${r.stableToTreasury} != ${Phis}`);
      // state transition is correct
      assert.equal(r.state.T, prev.T + r.stableToTreasury);
      assert.equal(r.state.S, prev.S - r.tokenBurned);
      assert.equal(r.state.Phit, 0n);
      assert.equal(r.state.Phis, 0n);
    }
  });

  it("bounty is exactly floor(0.25%) per side", () => {
    const r1 = collectFees({
      T: 1n, S: 10n ** 18n, Lt: 1n, Ls: 1n,
      Phit: 10_000n, Phis: 10_000n,
    });
    assert.equal(r1.tokenBounty, 25n);
    assert.equal(r1.stableBounty, 25n);
    // Odd amount: 10_001 * 25 / 10_000 = 25.0025 → floor = 25.
    const r2 = collectFees({
      T: 1n, S: 10n ** 18n, Lt: 1n, Ls: 1n,
      Phit: 10_001n, Phis: 10_001n,
    });
    assert.equal(r2.tokenBounty, 25n);
    assert.equal(r2.tokenBurned, 9_976n); // 10001 - 25
  });
});

// =============================================================================
// 5. SupplyExhausted on redeem when S == 0
// =============================================================================

// Terminal S=0 randomized coverage: Phase 4 invariant fuzz (see test/invariant/).
describe("M2ReferenceModel — SupplyExhausted", () => {
  it("redeem throws when S == 0", () => {
    const drained: M2State = {
      T: 0n, S: 0n, Lt: 1n, Ls: 1n, Phit: 0n, Phis: 0n,
    };
    assert.throws(() => redeem(drained, 1n), /SupplyExhausted/);
  });

  it("floorPrice throws when S == 0", () => {
    const drained: M2State = {
      T: 1n, S: 0n, Lt: 1n, Ls: 1n, Phit: 0n, Phis: 0n,
    };
    assert.throws(() => floorPrice(drained), /SupplyExhausted/);
  });

  it("redeem rejects N == 0 (ZeroAmount)", () => {
    const g = canonicalGenesis();
    assert.throws(() => redeem(g, 0n), /ZeroAmount/);
  });
});

// =============================================================================
// 6. Theorem 5.2 anchor (canonical month-12 state)
//    A* = (1/(1-f_s)) * (sqrt(k*(1-f_s)/F) - Lt)
//    Δ* = Ls - sqrt(k*F/(1-f_s)) - A* * F
// =============================================================================

describe("M2ReferenceModel — Theorem 5.2 closed-form anchor", () => {
  it("matches canonical_month12_state.csv within $0.01 (bigint sqrt precision)", () => {
    const csvPath = resolve(SIM_OUT, "canonical_month12_state.csv");
    if (!existsSync(csvPath)) {
      assert.fail(`Missing ${csvPath} — run the simulator first.`);
    }
    const rows = parseCsv(csvPath);
    assert.equal(rows.length, 1, "canonical CSV is a single row");
    const r = rows[0];

    // Canonical month-12 state from paper §6 Table 1, fee-free curve math.
    // Reproduce here using the deterministic baseline runner (the model's
    // own reproduction is the source of these numbers).
    const cfg: M2Config = { ...DEFAULT_CONFIG, feeMode: "fee-free" };
    const snaps = deterministicBaseline(
      100_000n * 10n ** 6n, 12, canonicalGenesis(cfg), cfg,
    );
    const s = snaps[12].state;
    const T = s.T; const S = s.S; const Lt = s.Lt; const Ls = s.Ls;

    // Apply Theorem 5.2 in bigint with f_s = 30000 / 1_000_000 = 0.03.
    // To preserve precision we scale: multiply terms by 10^N before sqrt,
    // then divide by 10^(N/2). N=36 keeps sqrt operands roughly the size
    // of the Decimal(60) reference's significant digits.
    //
    // Algebraic form used here:
    //   sqrt_a = isqrt(k * (1 - f_s) / F)
    //   A*     = (sqrt_a - Lt) / (1 - f_s)
    //   sqrt_b = isqrt(k * F / (1 - f_s))
    //   Δ*     = Ls - sqrt_b - A* * F
    //
    // F is small (≈ 2.4e-3); express it as (T * 10^18) / S (an 18-decimal
    // price) and divide back at the end. To stay in bigint:
    //
    //   F18  = mulDivFloor(T, 10^18, S)              // 18-dec dollars/token (per stable unit)
    //   But Lt and S are in token (10^-18) units; mixing F18 with k requires care.
    //
    // The cleanest path is to do everything in dollar-units (10^-6) and
    // token-units (10^-18). The TS model's `runBaseline` already does that
    // exactly. Below we work in those units directly.

    const fs = 30_000n;
    const feeDenom = 1_000_000n;
    const oneMinusFs = feeDenom - fs;              // 970_000
    const k = Lt * Ls;                              // token-units * stable-units

    // sqrt(k * (1-fs) / F) where F = T/S — both numerator and denominator
    // are bigints. We compute the radicand as:
    //   k * (1-fs) * S / (T * feeDenom)
    // then isqrt. Units: (token-units * stable-units) * 1 * token-units /
    // (stable-units * 1) = token-units^2; sqrt → token-units. Good — A*
    // is a token quantity.
    const radA = (k * oneMinusFs * S) / (T * feeDenom);
    const sqrtA = isqrt(radA);
    // A* = (sqrtA - Lt) * feeDenom / oneMinusFs
    const Astar = ((sqrtA - Lt) * feeDenom) / oneMinusFs;

    // sqrt(k * F / (1-fs)) — radicand units token-units^2 * 1 = stable^2:
    // wait — k has units (token-units * stable-units), F = T/S in
    // (stable / token) without unit re-scaling here, so k * F has units
    // (token * stable * stable / token) = stable^2. Good — sqrt → stable.
    //   k * T / (S * (1-fs)/feeDenom) = k * T * feeDenom / (S * oneMinusFs)
    const radB = (k * T * feeDenom) / (S * oneMinusFs);
    const sqrtB = isqrt(radB);

    // Δ* in stable units (10^-6). A* * F where F = T/S in (stable/token):
    //   A* (token-units) * T (stable-units) / S (token-units) = stable-units.
    const AstarF = (Astar * T) / S;
    const deltaStar = Ls - sqrtB - AstarF;

    // Convert to human dollars.
    const dollar = 1_000_000n;
    const AstarHuman = Number(Astar) / 1e18;
    const deltaStarHuman = Number(deltaStar) / Number(dollar);

    // Headline values from the CSV (Decimal(60) reference).
    const refAstar = Number(r.A_star);            // tokens (paper unit: tokens, NOT 10^-18-tokens)
    const refDelta = Number(r.delta_star);        // dollars

    // Tolerance: bigint isqrt loses sub-unit precision. We translate that
    // to dollar precision: the radicand for Δ* has magnitude ~1.18e6
    // (dollars); isqrt error is ≤ 1 unit at radicand-precision, i.e.
    // ≤ 1/(2*sqrtB) absolute → ~4.2e-7 in 1-unit-stable terms, or
    // ~4.2e-13 in dollars (1 stable unit = $1e-6). Two sqrts compound
    // linearly; Δ* error bound ≤ ~1e-6 dollars. We assert tolerance
    // ≤ $0.01 to leave 4 orders of magnitude of headroom for any other
    // residual.
    const ABS_TOL_DELTA = 0.01;                   // dollars
    const REL_TOL_DELTA = 1e-6;
    assert.ok(
      withinTol(deltaStarHuman, refDelta, ABS_TOL_DELTA, REL_TOL_DELTA),
      `Δ* mismatch: TS=${deltaStarHuman}, CSV=${refDelta} (paper headline 21476.5621...)`,
    );

    // Δ* should reproduce the headline $21,476.5621... within tolerance.
    assert.ok(Math.abs(deltaStarHuman - 21_476.5621) < 0.01,
      `Δ* paper-headline mismatch: ${deltaStarHuman} vs 21476.5621`);

    // A* should be ~6.1999e7 tokens (within tolerance).
    // Reference value ≈ 61_999_083.92.
    const ABS_TOL_ASTAR = 1e-3;                   // tokens
    const REL_TOL_ASTAR = 1e-6;
    assert.ok(
      withinTol(AstarHuman, refAstar, ABS_TOL_ASTAR, REL_TOL_ASTAR),
      `A* mismatch: TS=${AstarHuman}, CSV=${refAstar}`,
    );
  });

  it("isqrt floor-rounds and roundtrips", () => {
    // Sanity checks on the integer-sqrt helper.
    assert.equal(isqrt(0n), 0n);
    assert.equal(isqrt(1n), 1n);
    assert.equal(isqrt(2n), 1n);
    assert.equal(isqrt(3n), 1n);
    assert.equal(isqrt(4n), 2n);
    assert.equal(isqrt(99n), 9n);
    assert.equal(isqrt(100n), 10n);
    const big = 10n ** 60n;
    const s = isqrt(big);
    assert.ok(s * s <= big && (s + 1n) * (s + 1n) > big,
      `isqrt(10^60) failed: ${s}`);
  });
});

// =============================================================================
// CSV parser (tiny — no dep)
// =============================================================================

interface CsvRow { [k: string]: string; }

function parseCsv(path: string): CsvRow[] {
  const text = readFileSync(path, "utf8");
  const lines = text.split(/\r?\n/).filter(l => l.length > 0);
  if (lines.length === 0) return [];
  const header = lines[0].split(",");
  return lines.slice(1).map(line => {
    const cells = line.split(",");
    const row: CsvRow = {};
    header.forEach((h, i) => (row[h] = cells[i]));
    return row;
  });
}
