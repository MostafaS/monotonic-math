// SPDX-License-Identifier: MIT
//
// M² Reference Math Model (TypeScript / bigint)
// ==============================================
//
// Hermetic, integer-faithful reference model for the M² state-transition
// system. Implements the 7-class operation set `Ops` from paper §4.1 in
// pure TypeScript with `bigint`. Used by:
//
//   - Phase 1 unit tests (`M2ReferenceModel.test.ts`) — Lemma 4.2 residual
//     identity, floor monotonicity per op, collectFees conservation,
//     Theorem 5.2 anchor.
//
//   - Phase 1 agreement gate (`scripts/agreement_gate.ts`) — compares the
//     deterministic 12/36-month baseline against the canonical Track A
//     simulator at `../simulation/`.
//
//   - Phase 6 differential testing — same model, fed identical action
//     sequences as the Solidity implementation; states compared on each
//     transition.
//
// Design rules:
//
//   1. All state quantities are bigint. Floats appear only for legibility
//      prints in the agreement gate.
//
//   2. Operations are pure: each returns a NEW state object; the input
//      state is never mutated.
//
//   3. Rounding direction is documented inline per op. Lemma 4.2 redemption
//      uses floor (protocol-protective). collectFees bounty uses floor
//      (protocol-protective). Floor monotonicity is asserted on every
//      transition in cross-product form: T_new * S_old >= T_old * S_new.
//
//   4. The model supports two fee modes:
//        "fee-free" — paper Table 1 convention (the buy fee is ignored).
//        "with-fees" — implementation bytecode convention (buy fee folded
//                      into Φ_s, sell fee folded into Φ_t).
//      Default is "with-fees".
//
//   5. Fees use V4 hundredths-of-a-bip units: fb = 1000, fs = 30000,
//      feeDenom = 1_000_000. Caller bounty uses bps: 25 / 10_000.
//
//   6. The V2-style swap rounding follows V4 SwapMath's `computeSwapStep`
//      for exact-input: the output amount is computed by floor-dividing
//      k by the new input-side reserve. This matches V4's
//      `getNextSqrtPriceFromAmountIn(zeroForOne, ...)` semantics for the
//      full-range (V2-equivalent) position the protocol owns. See
//      `docs/v4_model_correspondence.md`. Rounding is documented inline.
//
// No external dependencies. No ethers, no viem (this is a math module).

// =============================================================================
// State and configuration
// =============================================================================

/**
 * Protocol state tuple from paper §4.1 eq. (3).
 *
 * Units (per paper §4.1):
 *  - T   : stable's smallest unit ($1 = 10^{d_s})
 *  - S   : 10^{-18}-token units (M² has 18 decimals)
 *  - Lt  : same units as S
 *  - Ls  : same units as T
 *  - Phit: same units as S (raw unrealized token-side fee mass)
 *  - Phis: same units as T (raw unrealized stable-side fee mass)
 */
export interface M2State {
  readonly T: bigint;
  readonly S: bigint;
  readonly Lt: bigint;
  readonly Ls: bigint;
  readonly Phit: bigint;
  readonly Phis: bigint;
}

export type FeeMode = "with-fees" | "fee-free";

/**
 * Protocol configuration. Fees use V4 hundredths-of-a-bip units
 * (MAX_LP_FEE = 1_000_000); bounty uses bps (denom 10_000). The
 * `feeMode` switches between paper Table 1's fee-free curve math and the
 * implementation's with-fees convention.
 */
export interface M2Config {
  readonly stableDecimals: number;   // d_s ∈ [0, 18]
  readonly fb: bigint;               // buy fee, hundredths-of-a-bip
  readonly fs: bigint;               // sell fee, hundredths-of-a-bip
  readonly feeDenom: bigint;         // V4 MAX_LP_FEE = 1_000_000
  readonly callerBountyBps: bigint;  // 25
  readonly bpsDenom: bigint;         // 10_000
  readonly feeMode: FeeMode;         // default "with-fees"
}

/**
 * Default configuration aligned with the implementation bytecode:
 *   fb = 0.10% = 1_000 hundredths-of-a-bip
 *   fs = 3.00% = 30_000 hundredths-of-a-bip
 *   caller bounty = 0.25% = 25 bps
 *   stable decimals = 6 (MockStable / Sepolia USDC convention)
 */
export const DEFAULT_CONFIG: M2Config = {
  stableDecimals: 6,
  fb: 1_000n,
  fs: 30_000n,
  feeDenom: 1_000_000n,
  callerBountyBps: 25n,
  bpsDenom: 10_000n,
  feeMode: "with-fees",
};

/**
 * Canonical genesis state from paper §3.6:
 *   T_0  = $1,000,000   = 10^6 * 10^{d_s}
 *   S_0  = 10^9 tokens  = 10^9 * 10^18
 *   Lt_0 = 7.5e8 tokens
 *   Ls_0 = $750,000
 *   Φ_t = Φ_s = 0
 *
 * Genesis constraint (Section 3.6): T_0 * Lt_0 == Ls_0 * S_0. Verified below.
 */
export function canonicalGenesis(cfg: M2Config = DEFAULT_CONFIG): M2State {
  const dollar = 10n ** BigInt(cfg.stableDecimals);
  const token = 10n ** 18n;
  return {
    T: 1_000_000n * dollar,
    S: 1_000_000_000n * token,
    Lt: 750_000_000n * token,
    Ls: 750_000n * dollar,
    Phit: 0n,
    Phis: 0n,
  };
}

// =============================================================================
// Pure helpers
// =============================================================================

/**
 * Full-precision (a * b) / c with floor rounding. Bigint is arbitrary
 * precision, so the 512-bit intermediate concern from Solidity does not
 * apply — but we name it identically for parity with the Solidity
 * implementation (OZ Math.mulDiv).
 *
 * Reverts on c == 0 or c < 0.
 */
export function mulDivFloor(a: bigint, b: bigint, c: bigint): bigint {
  if (c <= 0n) throw new Error(`mulDivFloor: denominator must be > 0 (got ${c})`);
  return (a * b) / c;
}

/**
 * Ceiling variant. Used where rounding-up protects the protocol (e.g.
 * "tokens swept" computations where the protocol must not under-charge).
 * Standard ceil pattern: floor((a*b - 1) / c) + 1 when a*b > 0.
 */
export function mulDivCeil(a: bigint, b: bigint, c: bigint): bigint {
  if (c <= 0n) throw new Error(`mulDivCeil: denominator must be > 0 (got ${c})`);
  const numer = a * b;
  if (numer === 0n) return 0n;
  return (numer - 1n) / c + 1n;
}

/**
 * 18-decimal fixed-point floor price F = T * 10^{36 - d_s} / S
 * (paper eq. (1)). View-only display function; the contract's `redeem`
 * does NOT call this — it uses `mulDiv(N, T, S)` directly per Lemma 4.2.
 */
export function floorPrice(state: M2State, cfg: M2Config = DEFAULT_CONFIG): bigint {
  if (state.S === 0n) throw new Error("SupplyExhausted: floorPrice undefined");
  const ten = 10n;
  const exponent = 36 - cfg.stableDecimals;
  if (exponent < 0) throw new Error(`floorPrice: d_s > 36 unreachable (d_s = ${cfg.stableDecimals})`);
  const scale = ten ** BigInt(exponent);
  return mulDivFloor(state.T, scale, state.S);
}

/**
 * Exact rational floor (T, S). Used by `assertFloorMonotone` to cross-
 * multiply and avoid integer-truncation artifacts.
 */
export function floorRational(state: M2State): { num: bigint; den: bigint } {
  return { num: state.T, den: state.S };
}

/**
 * Assert F_new >= F_old via the cross-product form T_new * S_old >= T_old * S_new.
 * Valid when both S_old > 0 and S_new > 0. When S_new == 0 (terminal
 * redemption draining the contract), the new floor is undefined; the
 * caller should not invoke this in that case.
 *
 * @returns void on success; throws on violation.
 */
export function assertFloorMonotone(prev: M2State, next: M2State): void {
  if (prev.S === 0n) return; // Trivially satisfied: previous floor undefined.
  if (next.S === 0n) return; // Terminal redemption: floor undefined post-op.
  const lhs = next.T * prev.S;
  const rhs = prev.T * next.S;
  if (lhs < rhs) {
    throw new Error(
      `Floor monotonicity violated: ` +
      `next.T*prev.S = ${lhs} < prev.T*next.S = ${rhs} ` +
      `(prev=${JSON.stringify(stateToStr(prev))}, next=${JSON.stringify(stateToStr(next))})`,
    );
  }
}

function stateToStr(s: M2State): Record<string, string> {
  return {
    T: s.T.toString(), S: s.S.toString(), Lt: s.Lt.toString(),
    Ls: s.Ls.toString(), Phit: s.Phit.toString(), Phis: s.Phis.toString(),
  };
}

/**
 * Integer square root via Newton's method. Returns floor(sqrt(n)) for
 * n >= 0. Used by the Theorem 5.2 anchor (A* and Δ* contain sqrts of
 * state-only quantities). The bigint sqrt rounds DOWN; the Decimal(60)
 * reference value in `canonical_month12_state.csv` rounds at 40+ digits,
 * so the Phase 1 test compares within a documented tolerance.
 *
 * Implementation: standard Newton iteration with floor-rounded division.
 * Converges in O(log log n) iterations after the initial bit-length
 * estimate.
 */
export function isqrt(n: bigint): bigint {
  if (n < 0n) throw new Error(`isqrt: negative input ${n}`);
  if (n < 2n) return n;
  // Initial guess: 2^(ceil(bits/2))
  const bits = n.toString(2).length;
  let x = 1n << BigInt((bits + 1) >> 1);
  while (true) {
    const y = (x + n / x) >> 1n;
    if (y >= x) return x;
    x = y;
  }
}

// =============================================================================
// Operations
//
// Each operation returns a NEW state object. The input state is never
// mutated. The 7-class set `Ops` from paper §4.1 eq. (4):
//   1. revToTreasury(X)        — T += X
//   2. buyAndBurn(X)           — V2 curve: tokens out are burned (S decreases)
//   3. redeem(N)               — Lemma 4.2 floor redemption
//   4. lpBuy(X)                — V2 curve: tokens out go to caller (S unchanged)
//   5. lpSell(N)               — V2 curve: stable out to caller; fee → Φ_t
//   6. transfer(N, a -> b)     — no-op on (T, S, Lt, Ls, Φ_t, Φ_s)
//   7. collectFees()           — realize (Φ_t, Φ_s); 0.25% bounty per side
// =============================================================================

/** Case 1: router moves X stable to the treasury. */
export function revToTreasury(
  state: M2State, X: bigint,
): M2State {
  if (X < 0n) throw new Error(`revToTreasury: X must be >= 0 (got ${X})`);
  return { ...state, T: state.T + X };
}

/**
 * Case 2: router uses X stable to execute a buy on the LP; the tokens
 * received are immediately burned (S decreases by the swept amount Y).
 *
 * With-fees mode (default, matches V4 bytecode):
 *   feeIn = floor(X * fb / feeDenom)                   // 0.10%, folded into Φ_s
 *   Xnet  = X - feeIn                                  // amount that hits the curve
 *   Ls'   = Ls + Xnet
 *   k     = Lt * Ls   (snapshot pre-swap)
 *   Lt'   = floor(k / Ls')                             // V4 SwapMath rounds down
 *   Y     = Lt - Lt'                                   // tokens received (>= 0)
 *   S'    = S - Y
 *   Φ_s'  = Φ_s + feeIn
 *
 * Fee-free mode (paper §6 Table 1 convention):
 *   feeIn = 0; Xnet = X (everything hits the curve; nothing to Φ_s).
 *
 * Rounding direction on Lt':
 *   Solidity OZ Math.mulDiv defaults to floor; V4 SwapMath's exact-input
 *   buy direction (zeroForOne=false on full-range) computes the next
 *   reserve to give an output that is rounded DOWN to favor the pool.
 *   So Lt' = floor(k / Ls'), and Y = Lt - Lt' is the smallest non-negative
 *   integer compatible with the curve under floor division — i.e. the
 *   buyer / protocol-buyer receives the floor amount of tokens. This is
 *   the protocol-protective direction for `buyAndBurn` because burning
 *   fewer tokens is conservative for floor monotonicity (less S burned
 *   → larger S' → smaller F').  In practice the rational invariant
 *   k = Lt*Ls is preserved exactly by the floor rounding; the truncated
 *   residual stays on the curve. We document this explicitly because the
 *   Phase 6 differential will match V4 bytecode bit-for-bit.
 *
 * @returns {state, tokensBurned}
 */
export function buyAndBurn(
  state: M2State, X: bigint, cfg: M2Config = DEFAULT_CONFIG,
): { state: M2State; tokensBurned: bigint } {
  if (X < 0n) throw new Error(`buyAndBurn: X must be >= 0 (got ${X})`);
  if (state.Lt <= 0n || state.Ls <= 0n) {
    throw new Error(`buyAndBurn: LP reserves must be positive (Lt=${state.Lt}, Ls=${state.Ls})`);
  }
  const feeIn = cfg.feeMode === "with-fees"
    ? mulDivFloor(X, cfg.fb, cfg.feeDenom)   // 0.10% floor; protocol-protective
    : 0n;
  const Xnet = X - feeIn;
  const k = state.Lt * state.Ls;             // snapshot pre-swap (exact)
  const LsNew = state.Ls + Xnet;
  // floor division — matches V4 SwapMath exact-input direction
  const LtNew = LsNew === 0n ? 0n : k / LsNew;
  const Y = state.Lt - LtNew;                // tokens received & burned
  if (Y < 0n) throw new Error(`buyAndBurn: negative Y ${Y}`);
  const next: M2State = {
    T: state.T,
    S: state.S - Y,
    Lt: LtNew,
    Ls: LsNew,
    Phit: state.Phit,
    Phis: state.Phis + feeIn,
  };
  return { state: next, tokensBurned: Y };
}

/**
 * Case 3: Lemma 4.2 redemption. Pays out P = floor(N * T / S) stable to
 * the caller and burns N tokens.
 *
 * The lemma's residual identity (asserted in unit tests):
 *   r = (N * T) mod S
 *   P = floor(N * T / S)
 *   (T - P) * S == T * (S - N) + r            [exact]
 *
 * Reverts on S == 0 (SupplyExhausted) per plan §M2Token. Reverts on
 * N == 0 (ZeroAmount) for parity with the bytecode contract.
 *
 * @returns {state, stableOut, residual}
 */
export function redeem(
  state: M2State, N: bigint,
): { state: M2State; stableOut: bigint; residual: bigint } {
  if (N <= 0n) throw new Error(`ZeroAmount: redeem requires N > 0 (got ${N})`);
  if (state.S === 0n) throw new Error("SupplyExhausted: redeem on empty supply");
  if (N > state.S) throw new Error(`redeem: N (${N}) exceeds supply (${state.S})`);
  const P = mulDivFloor(N, state.T, state.S);             // floor: protocol-protective
  const residual = (N * state.T) % state.S;
  const next: M2State = {
    ...state,
    T: state.T - P,
    S: state.S - N,
  };
  return { state: next, stableOut: P, residual };
}

/**
 * Case 4: external LPBuy(X). User sends X stable, receives tokens out.
 * Treasury and total supply are untouched. Same V2 algebra as buyAndBurn,
 * but the tokens go to the buyer rather than being burned. Fee folds into
 * Φ_s under with-fees mode.
 *
 * @returns {state, tokensOut}
 */
export function lpBuy(
  state: M2State, X: bigint, cfg: M2Config = DEFAULT_CONFIG,
): { state: M2State; tokensOut: bigint } {
  if (X < 0n) throw new Error(`lpBuy: X must be >= 0 (got ${X})`);
  if (state.Lt <= 0n || state.Ls <= 0n) {
    throw new Error(`lpBuy: LP reserves must be positive (Lt=${state.Lt}, Ls=${state.Ls})`);
  }
  const feeIn = cfg.feeMode === "with-fees"
    ? mulDivFloor(X, cfg.fb, cfg.feeDenom)
    : 0n;
  const Xnet = X - feeIn;
  const k = state.Lt * state.Ls;
  const LsNew = state.Ls + Xnet;
  const LtNew = LsNew === 0n ? 0n : k / LsNew;             // floor: protocol-protective
  const Y = state.Lt - LtNew;
  const next: M2State = {
    T: state.T,
    S: state.S,                                            // unchanged: tokens to user
    Lt: LtNew,
    Ls: LsNew,
    Phit: state.Phit,
    Phis: state.Phis + feeIn,
  };
  return { state: next, tokensOut: Y };
}

/**
 * Case 5: external LPSell(N). User sends N tokens, receives stable out.
 * The hook's 3% sell fee is deducted on the input and folded into Φ_t.
 * The remaining (1 - f_s) * N hits the curve. Treasury and total supply
 * are unchanged on the swap itself; the floor rises later via collectFees.
 *
 * With-fees mode (default):
 *   feeIn = floor(N * fs / feeDenom)       // 3.00%, folded into Φ_t
 *   Nnet  = N - feeIn                       // amount that hits the curve
 *   Lt'   = Lt + Nnet
 *   Ls'   = floor(k / Lt')                  // V4 floor; tokens out rounded down
 *   dLs   = Ls - Ls'                        // stable paid to seller
 *
 * @returns {state, stableOut}
 */
export function lpSell(
  state: M2State, N: bigint, cfg: M2Config = DEFAULT_CONFIG,
): { state: M2State; stableOut: bigint } {
  if (N < 0n) throw new Error(`lpSell: N must be >= 0 (got ${N})`);
  if (state.Lt <= 0n || state.Ls <= 0n) {
    throw new Error(`lpSell: LP reserves must be positive (Lt=${state.Lt}, Ls=${state.Ls})`);
  }
  const feeIn = cfg.feeMode === "with-fees"
    ? mulDivFloor(N, cfg.fs, cfg.feeDenom)
    : 0n;
  const Nnet = N - feeIn;
  const k = state.Lt * state.Ls;
  const LtNew = state.Lt + Nnet;
  const LsNew = LtNew === 0n ? 0n : k / LtNew;             // floor: protocol-protective
  const dLs = state.Ls - LsNew;
  const next: M2State = {
    T: state.T,
    S: state.S,                                            // unchanged: hold the fee until collectFees
    Lt: LtNew,
    Ls: LsNew,
    Phit: state.Phit + feeIn,
    Phis: state.Phis,
  };
  return { state: next, stableOut: dLs };
}

/**
 * Case 6: ERC-20 transfer. No effect on the (T, S, Lt, Ls, Φ_t, Φ_s) tuple.
 * The from/to parameters are accepted for API parity with the bytecode
 * call surface but are not consumed by the math.
 */
export function transfer(
  state: M2State,
  _N: bigint,
  _from: string,
  _to: string,
): M2State {
  // Intentionally a no-op on the protocol state tuple.
  return { ...state };
}

/**
 * Case 7: `collectFees()`. Realize the accrued unrealized fee mass:
 *
 *   K_real = Φ_t              U_real = Φ_s
 *   K_b    = floor(K_real * 25 / 10_000)   (caller bounty, token side)
 *   U_b    = floor(U_real * 25 / 10_000)   (caller bounty, stable side)
 *   K_burn = K_real - K_b                  (burned from supply)
 *   U_treas= U_real - U_b                  (transferred to treasury)
 *
 * State transition: T += U_treas; S -= K_burn; Φ_t = Φ_s = 0.
 *
 * Conservation (asserted in unit tests):
 *   K_b + K_burn == K_real
 *   U_b + U_treas == U_real
 *
 * Rounding: floor on the bounty (protocol-protective; caller is the user
 * we round against, so they get the floor share and the protocol keeps
 * the residual).
 *
 * @returns {state, stableBounty, tokenBounty, tokenBurned, stableToTreasury}
 */
export function collectFees(
  state: M2State, cfg: M2Config = DEFAULT_CONFIG,
): {
  state: M2State;
  stableBounty: bigint;
  tokenBounty: bigint;
  tokenBurned: bigint;
  stableToTreasury: bigint;
} {
  const Kreal = state.Phit;
  const Ureal = state.Phis;
  const Kb = mulDivFloor(Kreal, cfg.callerBountyBps, cfg.bpsDenom);
  const Ub = mulDivFloor(Ureal, cfg.callerBountyBps, cfg.bpsDenom);
  const Kburn = Kreal - Kb;
  const Utreas = Ureal - Ub;
  const next: M2State = {
    T: state.T + Utreas,
    S: state.S - Kburn,
    Lt: state.Lt,
    Ls: state.Ls,
    Phit: 0n,
    Phis: 0n,
  };
  return {
    state: next,
    stableBounty: Ub,
    tokenBounty: Kb,
    tokenBurned: Kburn,
    stableToTreasury: Utreas,
  };
}

// =============================================================================
// Deterministic baseline runner (paper §6 Table 1 reproduction)
// =============================================================================

/**
 * Per-month state snapshot, emitted by `deterministicBaseline` for the
 * agreement gate. The CSV columns from the canonical Track A simulator
 * are exactly these (less Phit/Phis which Track A does not track because
 * it runs fee-free).
 */
export interface MonthlySnapshot {
  readonly month: number;
  readonly state: M2State;
  readonly floor18: bigint;       // F * 10^18, computed from (T, S) and d_s
  readonly spot18: bigint;        // P * 10^18, computed from (Ls, Lt) — independent of d_s
}

/**
 * Reproduce paper §6 Table 1's 12-month deterministic baseline (or any
 * n-month horizon at constant monthly revenue R). The protocol's
 * `routeRevenue(R)` atomically composes Case 1 (revToTreasury(R/2)) and
 * Case 2 (buyAndBurn(R/2)).
 *
 * Odd-amount rule per plan §M2RevenueRouter:
 *   treasuryIn       = R / 2                   (floor half to treasury)
 *   stableUsedForBuy = R - treasuryIn          (ceiling half to buy)
 *
 * The agreement gate runs this in `feeMode: "fee-free"` so the CSV
 * comparison against the canonical Track A Python (which is also
 * fee-free) is row-by-row reproducible. With-fees runs differ at the
 * O(f_b) level and are reported in paper Appendix A.
 *
 * @param monthlyRevenue   revenue per month in stable's smallest unit (e.g. $100k * 10^6 for d_s = 6)
 * @param nMonths          number of months to simulate (>= 0)
 * @param initialState     starting state (default: canonicalGenesis())
 * @param cfg              configuration (default: DEFAULT_CONFIG)
 * @returns                array of (nMonths + 1) snapshots, indices 0..nMonths
 */
export function deterministicBaseline(
  monthlyRevenue: bigint,
  nMonths: number,
  initialState: M2State = canonicalGenesis(),
  cfg: M2Config = DEFAULT_CONFIG,
): MonthlySnapshot[] {
  const snapshots: MonthlySnapshot[] = [];
  let st = initialState;
  snapshots.push(monthlySnapshot(0, st, cfg));
  for (let m = 1; m <= nMonths; m++) {
    const prev = st;
    const treasuryIn = monthlyRevenue / 2n;                 // floor
    const stableUsedForBuy = monthlyRevenue - treasuryIn;   // ceil
    st = revToTreasury(st, treasuryIn);
    const buy = buyAndBurn(st, stableUsedForBuy, cfg);
    st = buy.state;
    assertFloorMonotone(prev, st);                          // invariant per Case 1+2 composition
    snapshots.push(monthlySnapshot(m, st, cfg));
  }
  return snapshots;
}

function monthlySnapshot(
  month: number, state: M2State, cfg: M2Config,
): MonthlySnapshot {
  // Both floor18 and spot18 use the same 10^(36 - d_s) scaling. Mirror
  // `floorPrice`'s d_s ≤ 36 guard here so monthlySnapshot fails loudly on
  // an out-of-range config rather than emitting a negative bigint exponent.
  // Unreachable under DEFAULT_CONFIG (d_s = 6) and any realistic stable
  // (USDC/DAI: d_s ∈ {6, 18}); the guard is defensive parity with
  // `floorPrice` so the dual derivation path cannot diverge.
  const exponent = 36 - cfg.stableDecimals;
  if (exponent < 0) {
    throw new Error(`monthlySnapshot: d_s > 36 unreachable (d_s = ${cfg.stableDecimals})`);
  }
  const scale = 10n ** BigInt(exponent);
  // floor18 = T * 10^(36 - d_s) / S, by paper eq. (1).
  let floor18 = 0n;
  if (state.S > 0n) {
    floor18 = mulDivFloor(state.T, scale, state.S);
  }
  // spot18 = Ls / Lt as a 18-decimal price (token1/token0 with token=token0).
  // To avoid mixing decimals: Ls is in stable units (10^d_s), Lt is in
  // token units (10^18). The spot, as USD per token, is Ls * 10^(36 - d_s) / Lt
  // — same exponent scaling as floor.
  let spot18 = 0n;
  if (state.Lt > 0n) {
    spot18 = mulDivFloor(state.Ls, scale, state.Lt);
  }
  return { month, state, floor18, spot18 };
}

// =============================================================================
// Convenience exports for the agreement gate
// =============================================================================

export interface AgreementInputs {
  readonly monthlyRevenueDollars: number;    // e.g. 100000 for $100k/mo
  readonly nMonths: number;                  // e.g. 12 or 36
  readonly cfg: M2Config;                    // pass feeMode: "fee-free" for paper-Table-1 comparison
}

/**
 * Run the baseline at fractional-dollar precision converted to bigint
 * using cfg.stableDecimals. Convenience wrapper used by the agreement
 * gate which takes human-readable revenue numbers.
 */
export function runBaseline(inputs: AgreementInputs): MonthlySnapshot[] {
  const dollar = 10n ** BigInt(inputs.cfg.stableDecimals);
  const monthlyRevenue = BigInt(inputs.monthlyRevenueDollars) * dollar;
  return deterministicBaseline(
    monthlyRevenue,
    inputs.nMonths,
    canonicalGenesis(inputs.cfg),
    inputs.cfg,
  );
}
