# Invariants

This document enumerates the load-bearing invariants of the M² protocol
and maps each to (a) the paper claim it implements, (b) the on-chain
mechanism that enforces it, and (c) the test file (existing or planned)
that exercises it.

The non-negotiable core invariant is **floor monotonicity**: for every
protocol-defined state transition,

```
F_new >= F_old           where F = T / S
```

equivalently, in integer cross-product form (which the test suite
prefers because it has no rounding loss):

```
T_new * S_old >= T_old * S_new           given S_old > 0 and S_new > 0
```

---

## Floor monotonicity (paper Theorem 4.3)

| Aspect | Detail |
|---|---|
| Paper claim | Theorem 4.3: every operation in `Ops` is individually floor-non-decreasing; Corollary 4.4 is closure under composition. |
| Enforcement | Each of the seven `Ops` classes is implemented by a single bytecode path that, in isolation, is floor-non-decreasing by construction (e.g. `redeem` floor-rounds to the treasury's favor; router buy-and-burn strictly decreases `S`; `collectFees` strictly increases `T` and strictly decreases `S`). |
| On-chain check | None (the invariant is structural). |
| Tests | `test/invariant/FloorMonotonicityInvariant.t.sol` (Phase 4): stateful fuzz with ≥ 100k sequences × depth 200, each step asserting `T_new * S_old >= T_old * S_new`. |

## Supply cap (no post-genesis minting)

| Aspect | Detail |
|---|---|
| Paper claim | §3.2: total supply minted once at genesis; `mint` is sentinel-gated and blocks all further calls. |
| Enforcement | `M2Token` has no external `mint` function. The constructor performs the single `_mint` call. **Sentinel equivalence:** the paper uses a constructor-set sentinel that, once consumed, blocks further mints; this implementation uses the stronger formulation of having no external mint path at all. The two are functionally equivalent — no caller, internal or external, can reach `_mint` after the constructor returns. |
| On-chain check | Bytecode disassembly (Phase 7) confirms no opcode sequence reaches `_mint` from any external entry point. |
| Tests | `test/invariant/SupplyInvariant.t.sol` (Phase 4): asserts `S <= S0` and `S_new <= S_old` after every action. |

## Treasury one-way property

| Aspect | Detail |
|---|---|
| Paper claim | §3.3: stable can leave the treasury only via `payRedemption`; no admin withdraw, sweep, pause, or upgrade. |
| Enforcement | `M2Treasury` exposes exactly one privileged entry point (`payRedemption`), callable only by the token contract via an immutable address check. No setter for `token` or `stable`. |
| Tests | `test/invariant/TreasuryInvariant.t.sol` (Phase 4) plus unit tests in `test/unit/M2Treasury.t.sol`. |

## `collectFees` conservation (no stranded wei)

| Aspect | Detail |
|---|---|
| Paper claim | §3.5: token-side fees split 99.75% burn / 0.25% bounty; stable-side fees split 99.75% treasury / 0.25% bounty. |
| Enforcement | Bytecode computes `stableBounty = floor(U_real * 25 / 10_000)` and `stableToTreasury = U_real - stableBounty`; analogously for tokens. Subtraction-based residual guarantees no wei is stranded. |
| Conservation invariant | `stableBounty + stableToTreasury == U_real` and `tokenBounty + tokenBurned == K_real`, exactly. |
| Tests | `test/invariant/CollectFeesConservationInvariant.t.sol` (Phase 4) with randomized `U_real, K_real`. |

## Lemma 4.2 integer-residual identity

| Aspect | Detail |
|---|---|
| Paper claim | Lemma 4.2: redemption rounding raises the floor by exactly the integer residual `r = mulmod(N, T, S)`. |
| Identity | `(T - P) * S == T * (S - N) + r` where `P = mulDiv(N, T, S)` and `r = mulmod(N, T, S)`. When `r > 0`, the inequality is strict: `(T - P) * S > T * (S - N)`. |
| Tests | `test/invariant/Lemma4_2ResidualIdentity.t.sol` (Phase 4) — stateless fuzz with ≥ 10k runs. |

## Sentinel equivalence (no external mint path)

| Aspect | Detail |
|---|---|
| Paper formulation | §3.2: a sentinel set in the constructor blocks subsequent `mint` calls after the genesis mint consumes it. |
| Implementation | The token contract exposes no external `mint` function and the constructor is the only path that reaches `_mint`. This is **stronger** than the paper's sentinel — the path is not just gated, it does not exist. |
| Audit-checklist artifact | Phase 7 bytecode disassembly + Slither call graph confirms the strengthening. |

## Ops-7 ↔ handler-6 mapping

| Aspect | Detail |
|---|---|
| Paper claim | `Ops = {RevToTreasury, BuyAndBurn, Redeem, LPBuy, LPSell, Transfer, CollectFees}` — 7 classes. |
| Implementation | The invariant handler exposes 6 entry points: `routeRevenue`, `redeem`, `lpBuy`, `lpSell`, `transfer`, `collectFees`. `routeRevenue` is the **atomic composition** of `RevToTreasury` + `BuyAndBurn`. |
| Per-half snapshot | The V4 integration tier (`test/integration/RouteRevenueIntegration.t.sol`) captures snapshots inside the two halves to demonstrate each half is individually floor-non-decreasing, under real V4. The composed property is exercised by `test/invariant/FloorMonotonicityInvariant.t.sol` against the mock AMM. |
| Why this mapping is sound | Corollary 4.4 (closure under composition) implies that the atomic composition is floor-non-decreasing iff each half is. |

## Router invariants

| Aspect | Detail |
|---|---|
| Split | Always 50/50 — hardcoded constants `TREASURY_BPS = 5_000`, `BPS_DENOMINATOR = 10_000`. No setter. |
| Odd-amount rule | `treasuryIn = stableAmount / 2` (floor); `stableUsedForBuy = stableAmount - treasuryIn` (ceiling). Matches paper §3.5 `⌊·/2⌋` and `⌈·/2⌉`. |
| Depositor | Immutable. No setter. |
| `minTokensOut` | Mandatory parameter (sandwich defense in depth). Invariant tests pass with `minTokensOut = 0` to demonstrate floor monotonicity is not slippage-dependent. |
| Handler `routeRevenue` bound | The invariant handler clamps `stableAmount` to `min(depositorBal, Ls/100)`. The `Ls/100` upper cap is intentional at dev scale to keep the constant-product curve healthy across long sequences (100k×200) — it under-exercises the "large protocol buy depletes substantial LP" tail. The production-scale `test:invariant:nightly` run is what the floor-monotonicity headline relies on; the per-op bound has not been observed to mask a real handler-internal overflow. The asymmetry vs. `lpBuy`/`lpSell` (which cap at `Ls/10` / `Lt/10`) is by design: only the depositor calls `routeRevenue`, and a small per-call cap keeps LP state in the regime where Phase 5 V4 swap-out tick-rounding will introduce only O(1 wei) deltas. |

## Hook invariants

| Aspect | Detail |
|---|---|
| Buy fee | 0.10% (`BUY_FEE = 1_000` under V4 hundredths-of-a-bip units). |
| Sell fee | 3.00% (`SELL_FEE = 30_000`). Load-bearing for Theorem 5.2. |
| Fee unit lock | Constructor asserts `LPFeeLibrary.MAX_LP_FEE == 1_000_000`; reverts otherwise. |
| Direction determination | `inputCurrency = zeroForOne ? currency0 : currency1`; routed by address-sort, not assumption. Paired CI fixtures (`deployCanonical_lowAddr.ts` / `_highAddr.ts`) exercise both orderings. |
| LP unwithdrawability | Hook owns the LP position permanently; no externally callable removal interface exists. |
| `unlockCallback` | Reverts unless `msg.sender == poolManager`. |
| Bounty | 0.25% per side. |

## Genesis constraint (paper eq. 12)

| Aspect | Detail |
|---|---|
| Constraint | `T0 / S0 == Ls0 / Lt0` ⇔ `T0 * Lt0 == Ls0 * S0` (integer-faithful). |
| Enforcement | `M2GenesisFactory.execute()` step 12 asserts the integer equality; reverts with `GenesisConstraintViolated` if it fails. |
| Tests | `test/unit/M2GenesisFactory.t.sol` (Phase 5). |

## Scope of MEV claims

MEV claims in this protocol are **operator-level**, not bytecode-level.
Paper Theorem 5.6 bounds residual MEV leakage under three operational
mitigations:

1. private orderflow (Flashbots Protect on Ethereum mainnet; sequencer
   protection on L2s),
2. uniform random delay `τ ~ U[0, 12h]` between the monthly tick and
   the actual buy execution,
3. optional TWAP execution splitting the monthly buy into N sub-buys.

None of these are enforced by the four immutable contracts. The on-chain
invariant is Corollary 4.4 (closure under composition): no reordering of
operations in `Ops` can lower the floor. Operational mitigations are
documented in `docs/deployment_runbook.md`.

---

## Test mapping summary

| Invariant | Test file (planned or extant) | Phase |
|---|---|---|
| Floor monotonicity | `test/invariant/FloorMonotonicityInvariant.t.sol` | 4 |
| Supply cap | `test/invariant/SupplyInvariant.t.sol` | 4 |
| Treasury one-way | `test/invariant/TreasuryInvariant.t.sol` | 4 |
| `collectFees` conservation | `test/invariant/CollectFeesConservationInvariant.t.sol` | 4 |
| Lemma 4.2 residual | `test/invariant/Lemma4_2ResidualIdentity.t.sol` | 4 |
| Sentinel equivalence | Phase 7 audit-checklist disassembly | 7 |
| Ops-7 ↔ handler-6 per-half | `test/integration/RouteRevenueIntegration.test.ts` (planned, not yet present) | 5 |
| Router split | `test/unit/M2RevenueRouter.t.sol` | 3 |
| Hook fees | `test/unit/M2V4Hook.t.sol` | 5 |
| Genesis constraint | `test/unit/M2GenesisFactory.t.sol` | 5 |
