# Uniswap V4 ↔ M² Model Correspondence

This document reconciles the raw-token framing used throughout the paper
with Uniswap V4's `Q128.128` fee-growth bookkeeping and lock-based
`unlock` / `take` / `settle` flow.

## State variables — paper vs. V4

| Paper symbol | Description | V4 source |
|---|---|---|
| `T` | Treasury stable balance | `stable.balanceOf(treasury)` — outside V4 entirely. |
| `S` | M² total supply | `token.totalSupply()` — outside V4 entirely. |
| `L_t` | Token reserve of the protocol-owned full-range position | Derived from the position's `liquidity` and the pool's `sqrtPriceX96` via the standard full-range identities (V2-style `x · y = k`). |
| `L_s` | Stable reserve of the protocol-owned full-range position | Same derivation as `L_t`. |
| `Φ_t` | Token-side raw fee mass accrued since last `collectFees` | V4 internally stores `feeGrowthGlobal0X128` (Q128.128). The realized token amount on `collectFees` equals `Δ feeGrowthGlobal0X128 · liquidity / 2^128`. |
| `Φ_s` | Stable-side raw fee mass accrued since last `collectFees` | Same as `Φ_t` but with `feeGrowthGlobal1X128`. |
| `Spot = L_s / L_t` | AMM spot price | Equivalent to the pool's `(sqrtPriceX96 / 2^96)^2`, modulo the token/stable currency ordering. |

## Why V2-style algebra is exact for the protocol-owned position

The protocol-owned position is initialized as a **single full-range
position** spanning `[MIN_TICK, MAX_TICK]` at the pool's tick spacing
(paper §3.4). Under this configuration the pool has exactly one
piecewise-constant liquidity segment, so V4's *active liquidity* equals
the position's liquidity at every reachable spot price. The per-tick
bookkeeping V4 uses to support concentrated liquidity (tick-crossing,
partial-range positions, segmented liquidity profiles) does not engage at
any state the protocol can reach. Therefore the active reserves
`(L_t, L_s)` ARE the V2-style `x · y = k` reserves of a single pool,
computed from the position's `liquidity` and the current `sqrtPriceX96`
via the standard full-range identities.

The constant-product invariant `k = L_t · L_s` is **exact** at every
reachable state, not an approximation. The per-swap update preserves
`k` exactly modulo the asymmetric-fee deduction described in paper
§3.4 (Equation 2).

V4 is retained for:

1. its per-swap hook-fee primitive (`beforeSwap` returning a
   `OVERRIDE_FEE_FLAG`-OR'd fee, paper Equation 2),
2. the position-locking semantics that make the LP unwithdrawable
   (the hook owns the position and exposes no removal interface).

No concentrated-liquidity feature is used.

## Fee growth → realized amount (`collectFees`)

V4 stores per-currency fee growth as a `Q128.128` per-liquidity quantity
in `feeGrowthGlobalNX128`. The realizable fee at the position holder's
next `collectFees` call equals:

```
K_real (tokens)  = (Δ feeGrowthGlobal0X128) · liquidity / 2^128
U_real (stable)  = (Δ feeGrowthGlobal1X128) · liquidity / 2^128
```

where `Δ` is measured between the last `modifyLiquidity(..., 0, ...)`
call and the current one, and `liquidity` is the position's liquidity at
the time of the call (which is constant for the protocol-owned position
in M²'s setup — there are no liquidity additions or removals post-genesis).

These `(K_real, U_real)` are the same `(Φ_t, Φ_s)` used in the paper's
formal proofs. Conservation is exact in the absence of rounding (and the
Q128.128 representation is sufficiently wide to make rounding loss
negligible for any realistic fee-growth magnitude over the protocol's
lifetime).

## V4 `unlock` / `IUnlockCallback` / `take` / `settle` flow

Both the router's buy-and-burn leg and the hook's `collectFees` operate
under V4's flash-accounting model:

```
[caller]                                 [PoolManager]                     [hook / router]
    |                                          |                                  |
    | unlock(callbackData) ───────────────────▶|                                  |
    |                                          | unlockCallback(callbackData) ──▶ |
    |                                          |                                  |
    |                                          |◀── modifyLiquidity(..., 0, ...) (collectFees)
    |                                          |   OR swap(...)                  (router buy)
    |                                          |                                  |
    |                                          |── BalanceDelta returned ─────▶ |
    |                                          |                                  |
    |                                          |◀── take(currency, recipient, amount)
    |                                          |◀── settle(currency)
    |                                          |                                  |
    |                                          | (BalanceDeltas net to 0) ◀────|
    |                                          |                                  |
    | unlock returns ◀─────────────────────────|                                  |
```

Within `unlockCallback`:

- `take(currency, recipient, amount)` instructs the PoolManager to
  transfer `amount` of `currency` to `recipient` (the M² treasury for
  stable-side fees; the hook itself for token-side fees prior to burn).
- `settle(currency)` informs the PoolManager that the caller has paid in
  `currency` (used on the router's stable-input side when executing the
  buy).
- After all `take`/`settle` calls, the net `BalanceDelta` for each
  currency MUST be zero, or the PoolManager reverts the entire unlock.

`unlockCallback` MUST reject calls where `msg.sender != poolManager`.
This is the only entry point through which the PoolManager calls back
into the hook / router; an unauthenticated caller pretending to be the
PoolManager could otherwise inject false `BalanceDelta` values.

## Direction-determination helper

V4 pools sort currencies by address: `currency0 < currency1`. Hardcoding
"buy" or "sell" as `zeroForOne` is forbidden because the M² token's
address relative to the backing stable's address is deployment-dependent.

Correct direction determination:

```solidity
Currency inputCurrency = params.zeroForOne ? key.currency0 : key.currency1;
uint24 fee;
if (Currency.unwrap(inputCurrency) == address(stable)) {
    fee = M2Constants.BUY_FEE;          // stable input → buy
} else if (Currency.unwrap(inputCurrency) == address(token)) {
    fee = M2Constants.SELL_FEE;         // token input → sell
} else {
    revert M2Errors.InvalidPool();
}
```

Paired test fixtures (`test/fixtures/deployCanonical_lowAddr.ts` and
`deployCanonical_highAddr.ts`) run the full invariant suite under both
`tokenAddr < stableAddr` and `tokenAddr > stableAddr` orderings.

## Tolerance band for differential tests

V4 tick-rounding and Q128.128 representation introduce small numerical
deltas between the paper's `Decimal(prec=60)` reference computation and
the on-chain Solidity implementation. These deltas are concentrated in:

- the `sqrtPriceX96 → (L_t, L_s)` conversion (rounding to the nearest
  ticked sqrt-price),
- the `Δ feeGrowthGlobalNX128 · liquidity / 2^128` realization (Q128.128
  truncation).

**Phase 6 calibration (measured):**

The differential test for Theorem 5.2 (`test/integration/Theorem5_2BankRun.t.sol`)
runs the closed-form `Δ* = Ls − √(k·F/(1 − f_s)) − A*·F` in Solidity
bytecode using `Math.mulDiv` (512-bit intermediate) + a Newton integer
sqrt, against the hard-coded canonical month-12 state from
`simulation/outputs/canonical_month12_state.csv`. The Python reference
computes `Δ* = $21,476.5621327029763205920169281383101491742571` via
`Decimal(prec=60)`; the on-chain bytecode reproduces the same value as
`Δ* = $21,476.5621... (× 10^6 stable units = 21_476_562_132)`.

| Quantity | Measured deviation | Tolerance band |
|---|---:|---:|
| **Δ\*** vs Python `Decimal(60)` reference | **< 0.1 bps (sub-stable-wei)** | 0.5% (load-bearing); 0.1 bps (empirical band test) |
| **A\*** vs reference anchor `61_999_083.92` tokens | ≤ 1 token (= 1e18 of the 10^-18 grid) | 1 token |
| Canonical month-12 anchor (TS driver, T at month 12) | ≤ 3 bps | 50 bps (TS driver) |

**Empirical band selection:** the dominant residual is the Newton-isqrt
floor rounding at the two sqrt-steps. The radicand of `√(k·F/(1 − f_s))`
has magnitude ≈ 1.18·10⁶ stable-units² (at canonical month-12); the
isqrt residual is therefore ≤ 1 stable-unit (≤ $1·10⁻⁶), with the two
sqrt calls compounding to ≤ $2·10⁻⁶. Relative to the headline
`Δ* = $21,476`, that is `≤ 1·10⁻¹⁰ relative` — five orders of magnitude
below the 0.5% gate.

**Load-bearing CI gate (`test_DeltaStar_MatchesPaperHeadlineWithinTolerance`):**
relative tolerance 50 bps (= 0.5%). 100× safety headroom above the
empirical band. This is the gate Phase 8 enforces.

**Empirical-band probe (`test_DeltaStar_EmpiricalBand_LE_0_1bps`):**
relative tolerance 0.1 bps (10 ppm). A regression in the Newton-isqrt
or mulDiv chain (or a drift in the canonical-state constants) trips
this tighter assertion before the load-bearing one fires.

**Differential-trajectory band (`scripts/diff/run_differential.ts`):**

The TS driver runs `routeRevenue($100k/mo) + collectFees()` for 12 months
on a canonical genesis (V4 PoolManager + M2GenesisFactory) against the
TS reference. Measured trajectory deviation:

| Quantity | Per-month deviation | Tolerance |
|---|---:|---:|
| Treasury T (protocol-edge) | **0 bps** across all 12 months | 50 bps |
| Supply S (protocol-edge) | not point-wise compared¹ | n/a |
| Floor cross-product `T·S_prev ≥ T_prev·S` | holds at every month | required |
| Canonical month-12 T anchor | 3 bps vs CSV `T = $1.6M` | 50 bps |

¹ The on-chain V4 LP at `sqrtPriceX96 = 1<<96` with `lpLiquidity = 1e11`
holds raw reserves `Lt ≈ Ls ≈ 1e11`, which differ from the canonical
paper genesis `Lt₀ = 7.5·10²⁶`, `Ls₀ = 7.5·10¹¹`. The on-chain
buy-and-burn therefore burns less S per month than the canonical
reference. The differential validates SHAPE (T agreement + floor
monotonicity) under common V4 tick-rounding; the bank-run headline test
pins the actual paper number separately and is the load-bearing claim
for §5.2.

## Phase 6 — Theorem 5.2 bytecode differential (post-Round 1 rewrite)

Round 1 reviewer A (defi-math-expert) flagged that the original
`Theorem5_2BankRun.t.sol` body was `pure` and asserted a closed-form
algebra-vs-truncated-constant identity rather than a bytecode
differential. The Round 3 rewrite replaces that with a TWO-LAYER
differential:

1. **Bytecode layer (`test_DeltaStar_OnChainAttack_MatchesClosedForm`).**
   After 3 routeRevenue + collectFees cycles on a deep V4 LP
   (`LP_LIQ = 1e15`, `ROUTE_AMOUNT = $200k`), snapshot the LIVE on-chain
   `(T, S, Lt, Ls)` from `M2Treasury`, `M2Token.totalSupply`, and the
   V4 PoolManager balances. Compute `A*` and `Δ_closed` from those LIVE
   values via `Math.mulDiv` + a Newton integer-sqrt. Mint `N = A* + ε`
   M² tokens to an ATTACKER address, then execute the saturated mixed
   strategy ON-CHAIN:

      a. `attackRouter.swap(poolKey, !stableIs0, A*)` — token-input swap
         through the real V4 hook (3% sell fee applied via `beforeSwap`),
      b. `M2Token.redeem(N - A*)` — Lemma 4.2 floor-rounded burn-leg
         against the treasury.

   Sum the attacker's stable balance change `Π_realized`; compute
   `Δ_realized = Π_realized - mulDiv(N, T_pre, S_pre)`. Assert
   `|Δ_realized - Δ_closed| / Δ_closed ≤ 50 bps` and the cross-product
   floor invariant `T_post · S_pre ≥ T_pre · S_post`.

   Tolerance band: 0.5% relative. This absorbs the V4 tick-rounding
   residual + the buy-fee fold-in into `Φ_s` that affects the pre-attack
   state.

2. **Paper-headline state-only anchor (`test_DeltaStar_ClosedForm_MatchesPaperHeadline`).**
   Asserts that the closed-form `Δ*` at the canonical paper state
   `(CANON_T, CANON_S, CANON_LT, CANON_LS)` reproduces the
   `Decimal(prec=60)` paper number `$21,476.5621...` within 0.1 bps.

By transitivity, (1) + (2) gives the FINAL_REPORT H2 claim: the M²
bytecode driven to canonical state would yield the paper number within
the 0.5% V4-tick-rounding band. Driving to EXACT canonical paper state
at full scale in EDR is infeasible (the 18/6-decimal raw-price gap
sends canonical `sqrtPriceX96` ~15 orders of magnitude away from the
LP-friendly `1<<96` seed); the brief explicitly permits adjusting the
on-chain anchor to whatever state is reachable while preserving the
mathematical Δ* relation.

**Fail-injection sanity check (verified in Round 3 implementation).**
Temporarily added a 10 bps bonus to `M2Token.redeem` (`stableOut +=
stableOut / 1000`); the on-chain attack test FAILED with
"floor monotonicity violated during attack" — proving the bytecode test
catches real-world redemption-math regressions. (The previous `pure`
test would have ignored such a change entirely.)

## Phase 6 — Theorem 5.3(2) caveat (post-Round 1)

Round 1 reviewer A correctly observed that
`Theorem5_3SpotFloorArbitragePin.t.sol` cannot drive `Spot < Floor` at
the canonical 18/6-decimal config in EDR. The raw-decimal gap:

   - genesis floor T0/S0 = 10^-15 raw-stable per raw-token,
   - LP seed `sqrtPriceX96 = 1<<96` ⇒ V4-price = 1 raw-currency1 per
     raw-currency0,

is ~15 orders of magnitude. Crossing it on-chain in a single test would
require either a multi-tick-spacing swap (which `tickSpacing = 60` makes
prohibitively expensive at EDR scale) or a 12+ month operating-point
drift with deep LP under realistic revenue.

What the local-tier test ASSERTS INSTEAD:

1. **Structural equivalence** of the integer-form profitability predicate
   `mulDiv(Y, T, S) > X` with the redemption inequality `redeem(Y) > X`.
   The bytecode reproduces this equivalence exactly.
2. **Constructed-(X, Y) demo** that, given inputs satisfying the
   predicate, `redeem(Y) > X`. The redeem bytecode is exercised; the
   live LP state is not driven into the `Spot < Floor` regime.

The full convergence claim (Spot < Floor cannot persist) is exercised
on the MAINNET-FORK tier
(`test/integration/MainnetFork12MonthRouteRevenue.t.sol` + companion
mass-dump variant) where realistic-scale operating-point drift can drive
the system into the relevant regime. The bytecode-level convergence in
EDR remains a paper-only proof.

## Phase 3 — MockAMM divergences from real V4

Phase 3 substitutes `contracts/mocks/MockAMM.sol` + `contracts/mocks/MockHook.sol`
for the real V4 PoolManager + `M2V4Hook`. The substitution exists solely so the
real router/token/treasury bytecode can be exercised under randomized op
sequences before Phase 5 wires the real V4 stack. Documented divergences:

- **No tick math.** MockAMM stores reserves as plain `(Lt, Ls)` integers. V4's
  `sqrtPriceX96` and tick-rounding are absent. The constant-product update
  `LtNew = k / LsNew` uses simple integer floor division (`mulDiv` floor),
  matching `M2ReferenceModel.ts` "with-fees" mode. Phase 5 must re-calibrate
  any test that depends on exact (`Lt`, `Ls`) endpoints because V4's
  `getNextSqrtPriceFromAmountIn` rounds at the sqrt-price level, not the
  reserve level.

- **No `BalanceDelta` Q128.128 truncation.** MockAMM accumulates `Phi_t` /
  `Phi_s` as raw `uint256` (no Q128.128 packing). Phase 5 must verify
  realized amounts under `Δ feeGrowthGlobalNX128 · liquidity / 2^128`
  truncation matches MockAMM's raw accumulation within the documented
  tolerance band. Conservation (`bounty + treasury == realized`) holds
  exactly under both models — only the magnitude differs.

- **`collectFees` bypasses `unlock`/`modifyLiquidity`.** In Phase 3 the
  `MockHook.collectFees` calls `MockAMM.drainAccumulators(address(this))`
  directly (a custom hook-only entry point), then distributes per the
  0.25%/99.75% rule. Phase 4 will replace this with the real V4 pattern:
  `PoolManager.unlock(callbackData)` → `modifyLiquidity(..., liquidityDelta:
  0, ...)` → `take` / `settle`. The distribution code (bounty rounding,
  treasury transfer, token burn) is identical and survives the swap.

- **`unlock`-based router swap path is preserved.** The router's
  buy-and-burn leg DOES go through `PoolManager.unlock` → `swap` → `sync`
  → `settle` → `take` (no Phase-3-specific shortcut). MockAMM implements
  enough of the V4 surface (`unlock`, `swap`, `sync`, `settle`, `take`,
  `initialize`, `modifyLiquidity` with `liquidityDelta == 0`) to satisfy
  the real `M2RevenueRouter` bytecode without modification.

- **`modifyLiquidity` only supports `liquidityDelta == 0` ("poke").** Any
  non-zero delta reverts; the Phase 3 hook does not call it (drains via
  `drainAccumulators` instead). Phase 4 enables full modifyLiquidity.

Phase 4 replaces `MockAMM` + `MockHook` with the real V4 PoolManager + the
real `M2V4Hook`. The router and token bytecode are unchanged; the test fixture
swaps in `deployV4Fixture.ts` (which deploys the real V4 PoolManager and
mines the hook salt) and the invariant suite re-runs against the real V4 stack.

## Ops-7 ↔ handler-6 mapping (paper §4.1 vs. invariant handler)

Paper §4.1 enumerates 7 protocol operation classes `Ops = {RevToTreasury,
BuyAndBurn, Redeem, LPBuy, LPSell, Transfer, CollectFees}`. The invariant
handler exposes 6 entry points; the missing seventh class
(`RevToTreasury`/`BuyAndBurn` are kept algebraically separate in the paper
proofs but composed atomically in `routeRevenue` on-chain). This is paper-
authoritative — Corollary 4.4 (closure under composition) guarantees the
composition is floor-non-decreasing iff each half is.

| Paper op | Handler entry | Notes |
|---|---|---|
| 1. `RevToTreasury(X)` | `routeRevenue(amount, 0)` (first half) | Composed atomically with case 2 inside the same `routeRevenue` call. Per-half snapshot lives in `test/integration/RouteRevenueIntegration.test.ts` (Phase 5). |
| 2. `BuyAndBurn(X)` | `routeRevenue(amount, 0)` (second half) | Composed atomically with case 1. |
| 3. `Redeem(N)` | `redeem(actorSeed, amount)` | Bounded to `[1, handler.M2Balance]`. |
| 4. `LPBuy(X)` | `lpBuy(actorSeed, stableAmount)` | Routes through `MockAMM.lpBuyExactIn`; Phase 4 routes through real V4 `PoolManager.swap`. |
| 5. `LPSell(N)` | `lpSell(actorSeed, tokenAmount)` | Same routing note. |
| 6. `Transfer(N, a→b)` | `transfer(actorASeed, actorBSeed, amount)` | Algebraic no-op on `(T, S, Lt, Ls, Phi_t, Phi_s)`. Snapshot-only. |
| 7. `CollectFees()` | `collectFees(callerSeed)` | Drains `(Phi_t, Phi_s)`; distributes per 0.25%/99.75% rule. |

This mapping is also captured in `docs/invariants.md` "Ops-7 ↔ handler-6
mapping".

## M2V4Hook spec (Phase 4 — load-bearing)

This subsection documents the `M2V4Hook` contract's contract-level
behavior in enough detail that the test suite in
`test/unit/M2V4Hook.t.sol` and `test/integration/*.t.sol` can be read as
a specification, not just a regression net. The hook is the merged
"hook + LP owner" contract enumerated under paper §3.2's three burn
roles (FINAL_REPORT H5).

### Fee-direction rule (address-sort independent)

V4 sorts pool currencies by raw address: `currency0 < currency1`. The
M² token's address relative to the backing stable's address is
**deployment-dependent** (the genesis factory mines CREATE2 salts), so
the hook MUST NOT assume `zeroForOne` maps to "buy" or "sell". The
canonical decision rule (paper §3.4 eq. 2) is:

```text
inputCurrency = params.zeroForOne ? key.currency0 : key.currency1
if Currency.unwrap(inputCurrency) == address(stable):
    fee = BUY_FEE   (1_000 = 0.10%)
else if Currency.unwrap(inputCurrency) == address(token):
    fee = SELL_FEE  (30_000 = 3.00%)
else:
    revert InvalidPool()
```

The fee is OR'd with `LPFeeLibrary.OVERRIDE_FEE_FLAG (= 0x400000)`
before returning from `beforeSwap`. The OR is what tells the
PoolManager to override the pool's stored static fee for this swap;
without it, V4 silently falls back to the pool's stored fee (which is
zero for a `DYNAMIC_FEE_FLAG` pool). The override is enforced under
both address orderings; the paired CI suite is the structural protection.

**Solidity-side paired suite (load-bearing, FINAL_REPORT H4).** Each
of the three integration `.t.sol` files factors its setup into an
abstract `*Base` contract that inherits from
`test/integration/base/IntegrationFixtureBase.sol`. The base exposes a
`_deploy(bool wantTokenLowerThanStable)` helper that mines a CREATE2
salt for `MockStable` so the resulting address satisfies the requested
ordering against the test contract's deterministic CREATE-nonce
prediction of `M2Token`. Two concrete subclasses per file
(`*LowAddrTest` and `*HighAddrTest`) override
`_wantTokenLowerThanStable()` to lock in the orientation. `npm run
test:integration` therefore runs the SAME test bodies under
`address(token) < address(stable)` AND `address(token) > address(stable)`
in every CI invocation — 6 contracts, 32 test cases. The TS fixtures
in `test/fixtures/deployCanonical_{low,high}Addr.ts` are kept as
reference material for the Phase 5 genesis-factory flow but are no
longer load-bearing for the H4 paired matrix.

### V4 `BalanceDelta` packing for the realized fee extraction

`collectFees` realizes the protocol-owned position's accrued fees by
calling `PoolManager.modifyLiquidity(key, params, "")` with
`params.liquidityDelta == 0` (a "poke" of the position). The
PoolManager returns a pair:

```solidity
(BalanceDelta callerDelta, BalanceDelta feesAccrued) = poolManager.modifyLiquidity(...)
```

For a zero-delta poke, `callerDelta == feesAccrued` (no principal
change; the position is unchanged). Both pack the per-currency fee
amounts as **two int128s into a single int256**:

| Bits | Field |
|---|---|
| upper 128 | `amount0` (signed, fees on currency0 owed to position holder; **positive** since fees flow to the position) |
| lower 128 | `amount1` (signed, fees on currency1; positive) |

Extraction (see `node_modules/@uniswap/v4-core/src/types/BalanceDelta.sol`):

```solidity
int128 a0 = BalanceDeltaLibrary.amount0(feesAccrued);  // assembly: sar(128, delta)
int128 a1 = BalanceDeltaLibrary.amount1(feesAccrued);  // assembly: signextend(15, delta)
```

The hook converts to the paper's `(K_real, U_real)` per address sort:

```solidity
uint256 stableRealized = stableIsCurrency0 ? uint256(uint128(a0)) : uint256(uint128(a1));
uint256 tokenRealized  = stableIsCurrency0 ? uint256(uint128(a1)) : uint256(uint128(a0));
```

The cast `uint256(uint128(...))` is safe because (a) `amount0/amount1`
are non-negative on a zero-delta modifyLiquidity (the position is
collecting fees, not paying them); (b) the int128 → uint128 → uint256
chain preserves the value bit-for-bit. The hook MUST sanity-check
`a0 >= 0 && a1 >= 0` and revert otherwise — a negative side would
indicate the hook is being asked to settle a debit, which is
impossible for a fee-only poke and would point at a corrupted call.

### Unlock / take / settle flow inside `collectFees`

The pattern is identical to the router's buy-and-burn (already
documented above) modulo the inner operation: `modifyLiquidity(0)`
instead of `swap`. The full sequence:

```text
1. caller -> hook.collectFees()
2. hook -> poolManager.unlock(callbackData)
3. poolManager -> hook.unlockCallback(callbackData)
4. hook -> poolManager.modifyLiquidity(key, {liquidityDelta: 0, salt: 0}, "")
   poolManager -> hook receives (callerDelta, feesAccrued); both equal here.
5. hook -> poolManager.take(currency0, address(hook), uint128(a0))
   hook -> poolManager.take(currency1, address(hook), uint128(a1))
6. (no settle needed — take is sufficient because the hook is the
    position holder; no input side is being paid in)
7. unlockCallback returns; PoolManager verifies all deltas net to zero.
8. Back in collectFees: hook now holds (stableRealized, tokenRealized).
9. Compute bounty / treasury / burn split per paper §3.5:
     stableBounty    = floor(stableRealized * 25 / 10_000)
     stableToTreasury = stableRealized - stableBounty
     tokenBounty     = floor(tokenRealized  * 25 / 10_000)
     tokenToBurn     = tokenRealized - tokenBounty
10. Transfer stableBounty -> caller; stableToTreasury -> treasury.
11. Transfer tokenBounty -> caller; burn tokenToBurn via the M2Token's
    three-role authorized-burn path (hook is one of three).
12. Emit FeesCollected.
```

The hook's `unlockCallback` MUST revert if `msg.sender != poolManager`
(the only legitimate caller is the PoolManager itself, transitively
from step 2). This is the same `OnlyPoolManager` selector the router
uses.

### Q128.128 fee accumulator ↔ raw `(Φ_t, Φ_s)` correspondence

Paper §3.2 footnote and §4.1 explicitly call out that the proofs use
the raw-token framing `(Φ_t, Φ_s)` even though V4 stores the
accumulator as Q128.128 per-liquidity:

```text
feeGrowthGlobal0X128  // Q128.128, per unit liquidity
feeGrowthGlobal1X128  // Q128.128, per unit liquidity
```

The realized amount at a `modifyLiquidity(0)` poke is:

```text
amountN = (feeGrowthGlobalNX128_now - feeGrowthGlobalNX128_lastPoke) * liquidity / 2^128
```

For the protocol-owned full-range position, `liquidity` is constant
post-genesis (no add/remove ever happens). The truncation `/ 2^128`
introduces at most a sub-liquidity-unit residual per side per poke
(approximately one stable-decimal-smallest-unit; negligible for any
realistic accrual). Conservation (`bounty + dest == realized`) holds
exactly in Solidity because the hook computes `dest = realized -
bounty` by subtraction; no rounding is performed on the dest side, so
no wei is stranded.

The paper-side `(Φ_t, Φ_s)` are the **raw, fully realized** integer
amounts after the Q128.128 truncation; that is what the integration
tests assert against. The reference TS model in
`test/reference/M2ReferenceModel.ts` uses the same raw framing for
parity.

### CREATE2 salt-mining reproducibility procedure

V4 requires the hook contract to be deployed to an address whose lower
14 bits encode its hook permission flags
(`node_modules/@uniswap/v4-core/src/libraries/Hooks.sol`). For
M2V4Hook the required flag is exactly `BEFORE_SWAP_FLAG = 1 << 7`
(`0x80`). All other flags must be zero (no `afterSwap`, no
`beforeAddLiquidity`, no return-delta extensions).

Reproducibility procedure (Agent A's `scripts/deploy/mine_hook_salt.ts`):

1. Compute the M2V4Hook init code hash:
   `keccak256(concat(initCode, constructorArgs))` where
   `constructorArgs = abi.encode(poolManager, token, stable, treasury)`.
2. Iterate a `bytes32 salt` over `0, 1, 2, …` until
   `address = keccak256(0xff || deployer || salt || initCodeHash)[12:]`
   satisfies `(uint160(address) & ALL_HOOK_MASK) == BEFORE_SWAP_FLAG`,
   i.e. lower 14 bits are exactly `0b00000010000000` (binary 0x80).
3. Persist the chosen `salt` and the deployer address to
   `deploy/hook/hook_salt.json` along with the init-code hash. The JSON
   is committed to source control so any future agent (CI, audit,
   reproducibility check) can re-derive the exact hook address.
4. Salt re-mining is required if and only if: (a) the hook bytecode
   changes (any source edit, any compiler-setting change, any solc
   version bump — `0.8.34` exact pin matters here), or (b) the deployer
   address changes, or (c) any constructor argument changes (which
   transitively changes init code).

The paired-fixture mining problem is slightly different — Agent B's
`deployCanonical_{low,high}Addr.ts` must mine salts for the
`MockStable` and `M2Token` contracts so that `address(token) <
address(stable)` or `>` respectively. This is INDEPENDENT of the hook
salt: the hook salt is mined against the V4 permission-flag
requirement; the stable/token salts are mined against the
ordering-comparison requirement.

The fixture implementation iterates random `salt` values for
`MockStable` (deployed via a small `Create2Deployer` helper) until the
resulting address satisfies the ordering against the already-mined
`M2Token` address. This is documented in the fixture's header
comment.

## Open items

- Exact tolerance value for Theorem 5.2 differential (Phase 5/6).
- Whether `collectFees` realized amounts ever exhibit non-trivial Q128.128
  truncation under expected monthly fee accrual (calibrated empirically
  at Phase 5).
- Whether V4's `BalanceDelta` int128 packing introduces a precision
  ceiling on `K_real` / `U_real` at extreme fee-mass values (analytically
  bounded; empirical confirmation at Phase 5).

## V4 dependency choice (Phase 2, Agent B)

The Phase 2 router imports the **real V4 packages** rather than local
interface stubs:

- `@uniswap/v4-core@1.0.2` — exact pin (no caret, no tilde). Provides
  `IPoolManager`, `IUnlockCallback`, `PoolKey`, `Currency`, `BalanceDelta`,
  `SwapParams`, `LPFeeLibrary` (with `DYNAMIC_FEE_FLAG = 0x800000` and
  `MAX_LP_FEE = 1_000_000`), and `TickMath` (with `MIN_SQRT_PRICE` and
  `MAX_SQRT_PRICE`).
- `@uniswap/v4-periphery@1.0.3` — exact pin.

These resolve to real Solidity sources that compile cleanly under
`solc 0.8.34` via the hardhat-config remappings:

```text
"@uniswap/v4-core/=node_modules/@uniswap/v4-core/"
"@uniswap/v4-periphery/=node_modules/@uniswap/v4-periphery/"
```

V4's own sources use floating pragmas (`pragma solidity ^0.8.0` and
`^0.8.24`) — that is acceptable because `npm run check:pragma` only
scrutinizes `contracts/` and `test/`, not `node_modules/`. The exact-pin
discipline is preserved for everything M² authors.

No local `interfaces/v4/*.sol` stubs were introduced; if a future agent
needs to add stubs they MUST be in `contracts/contracts/interfaces/v4/`
and documented here, but the strong preference is to keep using the
upstream packages so the on-chain calldata layouts are guaranteed to
match the live V4 PoolManager.

---

## Phase 5 — Genesis gas benchmark

Single-transaction `M2GenesisFactory.execute()` (paper §3.6, 13 steps),
measured locally via `test/integration/GenesisFactoryGas.t.sol`:

| Configuration | Gas |
|---|---:|
| Canonical 2-recipient vesting, USDC-style (d_s = 6), minimal LP liquidity = 1e6 | **5,052,067** |

- **Acceptance criterion:** ≤ 30 000 000 gas (Ethereum mainnet block-gas
  limit). ✅ headroom ≈ 24 .9M gas (83 % of block limit unused).
- **Composition:** dominated by V4 PoolManager initialize (~1 .5M),
  the four CREATE / CREATE2 deploys (~2 .8M combined), and the V4
  `unlock + modifyLiquidity + sync/settle` LP-seed dance (~0 .5M). The
  two `VestingWallet` `new` calls + token transfers contribute ~0 .2M.
- **Scaling note:** each additional `VestingWallet` adds ≈ 100 k gas
  (CREATE + token transfer). A 20-recipient production schedule is
  expected to land near 7M gas (still well under 30M).
- **Refresh procedure:** uncomment the `require(false, ...)` line in
  `test/integration/GenesisFactoryGas.t.sol::test_GenesisExecuteGasBenchmark`
  to force the test to surface the latest measurement as a revert
  string; update the table above; then re-comment the line so the test
  passes again.
- **Factory bytecode size:** 19 062 bytes runtime (≪ 24 576-byte
  EIP-170 limit). The factory accepts the hook's creation bytecode as
  a `bytes` argument so it does NOT embed M2V4Hook's ~9 KiB creation
  code as a compile-time literal — that is what keeps the factory
  under the cap.

## Phase 5 — Genesis address-prediction sequence

The factory uses a hybrid CREATE / CREATE2 strategy chosen to avoid
the joint-fixed-point salt-mining problem that arises if all four
contracts were CREATE2-deployed:

```
nonce 1: M2Treasury        (CREATE)
nonce 2: M2Token           (CREATE)  ← mints S0 to factory
nonce 3: M2V4Hook          (CREATE2) ← mined salt → BEFORE_SWAP_FLAG
nonce 4: M2RevenueRouter   (CREATE)
nonce N: VestingWallet[i]  (CREATE)  N ≥ 5
```

- Treasury / Token / Router addresses are deterministic from the
  factory's CREATE nonce; predicted via the RLP nonce formula
  (`0xd6 0x94 <factory> <nonce>`).
- The hook's CREATE2 address depends on `(hookSalt, hookInitCode)`;
  the hook's init code includes the **predicted** token and treasury
  addresses (CREATE nonces 1 and 2), which are NOT a function of the
  hook salt — so the cycle is broken cleanly.
- The mined hook salt must satisfy
  `uint160(addr) & 0x3FFF == BEFORE_SWAP_FLAG = 0x80`; the factory
  pre-checks this before calling `Create2.deploy`.

`scripts/deploy/01_deploy_canonical.ts` re-mines the hook salt at
deploy time against the live (factory, token, stable, treasury)
4-tuple, then calls `factory.execute(params)`. The cached
`deploy/hook/hook_salt.json` exists for the Phase 7 audit-checklist
hash check (`npm run check:hook-salt`); it is informational only at
deploy time because the real factory address differs from the
manifest's placeholder.

**Vesting recipient cap.** Because each vesting wallet consumes one
sequential CREATE nonce and the factory predicts those addresses via
the short-form RLP encoding `0xd6 0x94 <factory> <nonce>` (only valid
for `nonce ∈ [1, 0x7f]`), the factory can deploy at most `0x7f − 4 =
123` vesting wallets in one ceremony (nonces 1–4 are spent on
treasury / token / hook / router). Production deployments with more
recipients than 123 must batch into multiple vesting wallets or use
a chain-of-wallets pattern; exceeding the cap reverts the entire
`execute()` call via the `require(nonce >= 1 && nonce <= 0x7f, ...)`
guard in `_predictCreate`.
