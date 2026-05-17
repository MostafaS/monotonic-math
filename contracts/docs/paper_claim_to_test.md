# Paper Claim → Test Map

This document maps every paper-stated contract-behavior claim (in
`paper/sections/{03-protocol.tex, 04-formal-invariants.tex,
05-economic-analysis.tex, 06-numerical-results.tex}`) to the test
file that exercises it.

## Status legend

- `passing` — test file exists AND currently passes locally / in CI.
- `present` — test file exists; full pass requires a gated environment
  (mainnet fork via `MAINNET_RPC_URL`, or the production-scale
  `test:invariant:full` knobs).
- `present-but-skipped` — test exists locally and skips cleanly when its
  gate variable is unset (e.g. `@fork` tests skip without
  `MAINNET_RPC_URL`).
- `Track A` — claim is verified by the Python simulator at
  `../simulation/`, not by a Solidity test. Listed here for completeness.
- `runbook only` — claim is operator-level and is documented in
  `docs/deployment_runbook.md`; no on-chain test is possible.
- `deferred` — explicitly deferred, with link to the limitations row.

The Definition-of-Done gate is that every row reads `passing`,
`present` (gated), `Track A`, or `runbook only` before the `paper-v1`
tag.

The grep gate is:

```
grep -c "Paper" contracts/docs/paper_claim_to_test.md  # >= 25
```

(25 = 14 threat-model rows from paper §3.7 Table 1, plus every numbered
theorem/lemma/corollary/conjecture in §§4–5, plus the genesis /
asymmetric-fee / collectFees structural claims from §3.)

---

## Paper §3 — Protocol Specification (structural claims)

| Paper claim | Section | Test file | Status |
|---|---|---|---|
| Paper §3.1 — four immutable contracts; no admin, no upgrade, no proxy | §3.1 | `test/unit/M2Token.t.sol`, `test/unit/M2Treasury.t.sol`, `test/unit/M2RevenueRouter.t.sol`, `test/unit/M2V4Hook.t.sol` (each asserts no setter / no Ownable surface); `scripts/audit/audit_inheritance.ts` (`npm run audit:inheritance`) | passing |
| Paper §3.1 — no `selfdestruct` opcode in deployed bytecode | §3.1 | `scripts/audit/audit_bytecode.ts` (`npm run audit:bytecode` — bytecode disassembly check for `0xff`) | passing |
| Paper §3.1 — no `_mint` reachable from any external entry point | §3.1 / §3.2 | `scripts/audit/audit_bytecode.ts` (call-graph / opcode reachability check); `test/unit/M2Token.t.sol` (`test_NoPublicMintFunctionAfterGenesis`) | passing |
| Paper §3.2 — fixed-supply genesis mint `S0 = 10^9`; no post-genesis mint | §3.2 | `test/unit/M2Token.t.sol` (mint-once); `test/invariant/SupplyInvariant.t.sol` (≥ 100k seq × depth 200) | passing |
| Paper §3.2 — exactly 3 burn-authority roles (hook, router, self-redeem) | §3.2 | `test/unit/M2Token.t.sol` (`test_UnauthorizedBurnerReverts`, `test_HookCanBurn`, `test_RouterCanBurn`, `test_SelfRedeemCanBurn`) | passing |
| Paper §3.2 eq. (1) — `floorPrice() = T·10^{36−d_s}/S`, 18-decimal fixed point, view-only | §3.2 | `test/unit/M2Token.t.sol` (consistency under `d_s ∈ {6, 18}`); `test/reference/M2ReferenceModel.test.ts` | passing |
| Paper §3.2 (tightened by line 62) — `redeem` uses `mulDiv(amount, T, S)`, NOT `amount * floorPrice()` | §3.2 | `test/unit/M2Token.t.sol` (`test_RedeemPaysMulDivNotFloorPriceProduct` under `d_s ∈ {6, 18}`) | passing |
| Paper §3.2 — `S = 0` reverts both `redeem` and `floorPrice` with `SupplyExhausted` | §3.2 | `test/unit/M2Token.t.sol` (`test_FloorPriceRevertsOnSupplyExhausted`, `test_RedeemRevertsOnSupplyExhausted`) | passing |
| Paper §3.2 — constructor reverts on `stable.decimals() > 18` (overflow bound) | §3.2 | `test/unit/M2Token.t.sol` (`test_ConstructorRevertsOnDecimals19`) | passing |
| Paper §3.2 — redemption rounding is floor (protocol-protective dust to treasury) | §3.2 | `test/invariant/Lemma4_2ResidualIdentity.t.sol` (≥ 10k runs via `test:invariant:full`) | passing |
| Paper §3.3 — treasury stable can leave ONLY via `payRedemption` (one-way) | §3.3 | `test/unit/M2Treasury.t.sol`; `test/invariant/TreasuryInvariant.t.sol` | passing |
| Paper §3.3 — `payRedemption` callable only by token (`OnlyToken` revert) | §3.3 | `test/unit/M2Treasury.t.sol` (`test_OnlyTokenCanPayRedemption`) | passing |
| Paper §3.3 — treasury: no admin / sweep / rescue / pause / upgrade | §3.3 | `scripts/audit/audit_bytecode.ts` (function-selector enumeration); `test/unit/M2Treasury.t.sol` | passing |
| Paper §3.4 eq. (2) — buy fee 0.10%, sell fee 3.00% (asymmetric per direction) | §3.4 | `test/unit/M2V4Hook.t.sol` (`test_StableInputGetsBuyFee`, `test_TokenInputGetsSellFee`) | passing |
| Paper §3.4 — direction by address-sort (not assumed currency ordering) | §3.4 | Paired fixtures `test/fixtures/deployCanonical_{low,high}Addr.ts`; both run the full suite | passing |
| Paper §3.4 — pool initialized with `DYNAMIC_FEE_FLAG`; non-dynamic pools rejected | §3.4 | `test/unit/M2V4Hook.t.sol` (`test_PoolWithoutDynamicFeeFlagFails`) | passing |
| Paper §3.4 — full-range position; V2-style `k = L_t · L_s` exact | §3.4 | `test/integration/V4FullRangeIntegration.t.sol` | passing |
| Paper §3.4 — LP position unwithdrawable (no external removal interface) | §3.4 | `test/unit/M2V4Hook.t.sol` (`test_LPCannotBeRemovedExternally`); `scripts/audit/audit_bytecode.ts` (no `modifyLiquidity` with non-zero delta selector reachable from external surface) | passing |
| Paper §3.4 — `OVERRIDE_FEE_FLAG` returned by `beforeSwap` | §3.4 | `test/unit/M2V4Hook.t.sol` (`test_HookReturnsOverrideFeeFlag`) | passing |
| Paper §3.4 — anti-MEV mitigations (Flashbots / random delay / TWAP) | §3.4 | `docs/deployment_runbook.md`; no on-chain claim | runbook only |
| Paper §3.5 — router 50/50 split, hardcoded constant | §3.5 | `test/unit/M2RevenueRouter.t.sol` (`test_RouterSplitsRevenueEvenly`) | passing |
| Paper §3.5 — depositor immutable; only depositor can call | §3.5 | `test/unit/M2RevenueRouter.t.sol` (`test_OnlyDepositorCanCall`) | passing |
| Paper §3.5 — odd-amount rule: floor-to-treasury, ceil-to-buy | §3.5 | `test/unit/M2RevenueRouter.t.sol` (`test_OddAmountFloorToTreasury`) | passing |
| Paper §3.5 — `minTokensOut` slippage / sandwich defense | §3.5 + audit H1 | `test/integration/RouteRevenueIntegration.t.sol` (`test_SandwichRevertsOnMinTokensOut`) | passing |
| Paper §3.5 — per-half snapshot: Case 1 raises floor strictly; Case 2 raises weakly | §3.5 / §4 Cases 1,2 | `test/integration/RouteRevenueIntegration.t.sol` (`test_RevToTreasuryRaisesFloorStrictly`, `test_BuyAndBurnRaisesFloorWeakly_Algebraic`) | passing |
| Paper §3.5 — `collectFees` 0.25% / 99.75% split per side | §3.5 | `test/unit/M2V4Hook.t.sol` (`test_StableFeesIncreaseTreasury`, `test_TokenFeesReduceSupply`, `test_BountyAtMostQuarterPercent`); `test/integration/CollectFeesIntegration.t.sol` | passing |
| Paper §3.5 — `collectFees` conservation (no stranded wei) | §3.5 | `test/invariant/CollectFeesConservationInvariant.t.sol`; `test/unit/M2V4Hook.t.sol` (`test_ConservationStable`, `test_ConservationToken`); `test/integration/CollectFeesNoStrandedWei.t.sol` (paired-address-sort, fuzz ≥ 1k) | passing |
| Paper §3.5 — `collectFees` permissionless | §3.5 | `test/integration/CollectFeesIntegration.t.sol` (`test_CollectFeesIsPermissionless_BytecodeAudit`); `test/unit/M2V4Hook.t.sol` (`test_AnyoneCanCallCollectFees_NoEffectIfNoFees`) | passing |
| Paper §3.5 — V4 `unlock` / `modifyLiquidity(0,…)` / `take` / `settle` flow | §3.5 | `test/unit/M2V4Hook.t.sol` (`test_UnlockCallbackRejects*`); `test/integration/CollectFeesIntegration.t.sol` (full unlock path) | passing |
| Paper §3.5 — hook constructor reverts on `LPFeeLibrary.MAX_LP_FEE ≠ 1_000_000` | §3.5 + audit L1 | `test/unit/M2V4Hook.t.sol` (`test_ConstructorAssertsFeeUnit`) | passing |
| Paper §3.6 — genesis ceremony atomic single transaction (13 steps) | §3.6 | `test/integration/GenesisFactory.t.sol` (`test_ExecuteIsAtomic_RevertReverts`); `test/integration/GenesisFactoryGas.t.sol` (gas benchmark vs. mainnet block-gas limit) | passing |
| Paper §3.6 eq. (12) — floor-spot constraint `T_0 · L_{t,0} == L_{s,0} · S_0` | §3.6 | `test/integration/GenesisFactory.t.sol` (`test_GenesisConstraintViolatedReverts`) | passing |
| Paper §3.6 — 75/25 LP / vesting split (`Lt0 = 7.5·10^8`, vesting = `2.5·10^8`) | §3.6 | `test/integration/GenesisFactory.t.sol` (`test_LPVestingSplitIsExactly75_25`) | passing |
| Paper §3.6 — `F0 == P0` at launch | §3.6 | `test/integration/GenesisFactory.t.sol` (`test_FloorEqualsSpotAtGenesis`) | passing |

## Paper §3.7 Table 1 — Threat Model Rows (all 14 rows)

Each row carries a `Paper §3.7` citation that satisfies the
`grep -c "Paper §3.7" docs/threat_model.md ≥ 14` gate. Every row below
appears in `docs/threat_model.md` with the same row number.

| Paper claim | Section | Test file | Status |
|---|---|---|---|
| Paper §3.7 Table 1 row 1 — Rational holder (in scope) | §3.7 | `test/invariant/FloorMonotonicityInvariant.t.sol`; `test/integration/Theorem4_5RedemptionFairness.t.sol` | passing |
| Paper §3.7 Table 1 row 2 — Coordinated coalition / simultaneous strategies (in scope) | §3.7 | `test/integration/Theorem5_2BankRun.t.sol` (`@local` closed-form differential); `test/integration/M2Differential.t.sol` (12-month trajectory differential) | passing |
| Paper §3.7 Table 1 row 3 — MEV searcher single block, bounded leakage (in scope) | §3.7 | `test/integration/RouteRevenueIntegration.t.sol` (`test_SandwichRevertsOnMinTokensOut`); `docs/deployment_runbook.md` (Flashbots Protect / random delay / TWAP) | passing |
| Paper §3.7 Table 1 row 4 — `collectFees`-adjacent MEV single block (in scope) | §3.7 | `test/invariant/CollectFeesConservationInvariant.t.sol` (intra-block interleaving) | passing |
| Paper §3.7 Table 1 row 5 — `collectFees`-adjacent MEV cross block (out of scope) | §3.7 | `docs/threat_model.md` Row 5 — residual risk acknowledgement | deferred (paper §6.4 limitation P4) |
| Paper §3.7 Table 1 row 6 — MEV multi-block builder collusion (out of scope) | §3.7 | `docs/threat_model.md` Row 6 — residual risk acknowledgement | deferred (paper §6.4 limitations P2, P4) |
| Paper §3.7 Table 1 row 7 — Operator revenue depositor / cessation (partial) | §3.7 | `test/integration/RedemptionIntegration.t.sol` (via revenue-stop scenario in Test Matrix); `test/invariant/FloorMonotonicityInvariant.t.sol` (handler may issue zero `routeRevenue` calls) | passing |
| Paper §3.7 Table 1 row 8 — Operator strategic timing with vested holdings (partial) | §3.7 | `test/integration/MainnetForkVestingMassDump.t.sol` (`@fork`); skips cleanly when `MAINNET_RPC_URL` unset; `docs/deployment_runbook.md` (Flashbots / delay / TWAP / vesting cliff) | present (gated on `MAINNET_RPC_URL`) |
| Paper §3.7 Table 1 row 9 — Operator post-genesis bytecode change (N/A, structural) | §3.7 | `scripts/audit/audit_bytecode.ts`; `scripts/audit/audit_inheritance.ts` | passing |
| Paper §3.7 Table 1 row 10 — Vesting recipient mass dump (in scope) | §3.7 | `test/integration/MainnetForkVestingMassDump.t.sol` (`@fork`, 250M token mass-dump scenario); skips cleanly when `MAINNET_RPC_URL` unset | present (gated on `MAINNET_RPC_URL`) |
| Paper §3.7 Table 1 row 11 — Third-party oracle consumer (out of scope) | §3.7 | `docs/threat_model.md` Row 11 — residual risk acknowledgement; `docs/deployment_runbook.md` (downstream-consumer TWAP guidance) | deferred (paper §6.4 limitation P3) |
| Paper §3.7 Table 1 row 12 — Backing-stable issuer freeze / depeg (out of scope) | §3.7 | `docs/threat_model.md` Row 12 — residual risk acknowledgement | deferred (paper §6.4 limitation: USDC March-2023 depeg analog) |
| Paper §3.7 Table 1 row 13 — Smart-contract bug (out of scope: no upgrade path) | §3.7 | `npm run audit:slither`; Phase 4 invariant fuzz (≥ 100k seq × depth 200); external audit before `paper-v1` | passing (in-repo mitigations); audit deferred |
| Paper §3.7 Table 1 row 14 — L1/L2 consensus failure (out of scope, substrate) | §3.7 | `docs/threat_model.md` Row 14 — residual risk acknowledgement | deferred (paper §6.4 limitation: substrate assumption) |

## Paper §4 — Formal Invariants

| Paper claim | Section | Test file | Status |
|---|---|---|---|
| Paper Lemma 4.2 (Integer-Arithmetic Redemption) — `(T-P)·S == T·(S-N) + r`, `r = mulmod(N, T, S)` | §4.2 | `test/invariant/Lemma4_2ResidualIdentity.t.sol` (stateless fuzz; ≥ 10k runs via `test:invariant:full`); `test/reference/M2ReferenceModel.test.ts` (1k random triples) | passing |
| Paper Lemma 4.2 — terminal redemption (`N == S` drains exactly, `r == 0`) | §4.2 | `test/unit/M2Token.t.sol` (`test_FullRedemptionDrainsTreasuryExactly`) | passing |
| Paper Theorem 4.3 (Floor Monotonicity) — `Floor(σ′) ≥ Floor(σ)` for every `op ∈ Ops` | §4.3 | `test/invariant/FloorMonotonicityInvariant.t.sol` (≥ 100k seq × depth 200, all 7 Ops classes reachable) | passing |
| Paper Theorem 4.3 Case 1 — `RevToTreasury(X)` strictly raises floor for `X > 0` | §4.3 Case 1 | `test/integration/RouteRevenueIntegration.t.sol` (`test_RevToTreasuryRaisesFloorStrictly`) | passing |
| Paper Theorem 4.3 Case 2 — `BuyAndBurn(X)` weakly raises floor (strict iff `Y(X) > 0`) | §4.3 Case 2 | `test/integration/RouteRevenueIntegration.t.sol` (`test_BuyAndBurnRaisesFloorWeakly_Algebraic`) | passing |
| Paper Theorem 4.3 Case 3 — `Redeem(N)` preserves floor (weakly raises under integer truncation) | §4.3 Case 3 | `test/unit/M2Token.t.sol`; `test/invariant/Lemma4_2ResidualIdentity.t.sol` | passing |
| Paper Theorem 4.3 Case 4 — `LPBuy(X)` preserves floor (treasury/supply untouched) | §4.3 Case 4 | `test/integration/V4FullRangeIntegration.t.sol` (`test_LPBuyDoesNotMoveFloor`) | passing |
| Paper Theorem 4.3 Case 5 — `LPSell(N)` preserves floor at swap moment | §4.3 Case 5 | `test/integration/V4FullRangeIntegration.t.sol` (`test_LPSellDoesNotMoveFloorBeforeCollect`); `test/unit/M2V4Hook.t.sol` (`testFuzz_RoundingCannotReduceFloor`) | passing |
| Paper Theorem 4.3 Case 6 — `Transfer(N, a→b)` preserves floor trivially | §4.3 Case 6 | `test/invariant/FloorMonotonicityInvariant.t.sol` (handler emits `Transfer` in random sequences) | passing |
| Paper Theorem 4.3 Case 7 — `CollectFees()` weakly raises floor (strict if any swap occurred) | §4.3 Case 7 | `test/unit/M2V4Hook.t.sol` (`test_CallBeforeAndAfterRedemptionsPreservesInvariant`, `test_CallBeforeAndAfterLPSellPreservesInvariant`); `test/integration/CollectFeesIntegration.t.sol` | passing |
| Paper Theorem 4.3 — exhaustiveness over `Ops` (7 operation classes, no fourth burn path) | §4.3 | `test/invariant/handlers/M2InvariantHandler.sol` (all 7 classes reachable via 6 entry points; coverage report); `scripts/audit/audit_bytecode.ts` (no external selector outside the enumerated set) | passing |
| Paper Corollary 4.4 (Closure under Arbitrary Interleaving) — any composition preserves floor | §4.4 | `test/invariant/FloorMonotonicityInvariant.t.sol` (composition is the fuzzer's domain); `test/integration/M2Differential.t.sol` (Phase 6, 12-month paired-address-sort differential) | passing |
| Paper Theorem 4.5 (Redemption Fairness, No First-Mover Advantage) — per-token payout monotone in execution order | §4.5 | `test/integration/Theorem4_5RedemptionFairness.t.sol` (`@local`, paired-address-sort, two sequenced redeemers same block) | passing |
| Paper Conjecture 4.X (LVR / Floor-Capture Identity, directional) | §4 (LVR) | `simulation/generate_figures.py` (qualitative Δ-floor vs. fee-attributable LVR comparison via fee-attribution chart); not converted to a theorem | Track A (directional; conversion is paper §6.4 open problem P6) |

## Paper §5 — Economic Analysis

| Paper claim | Section | Test file | Status |
|---|---|---|---|
| Paper Theorem 5.2 (Composite-Strategy Bank Run with Saturation) — closed-form `Δ* ≈ $21,476.5621` at canonical month-12 state | §5.2 | `test/integration/Theorem5_2BankRun.t.sol` (`@local` Solidity closed-form check, paired-address-sort, ≤ 0.5% load-bearing tolerance, empirical band ≤ 0.1 bps); `scripts/diff/run_differential.ts` (`npm run test:differential`, trajectory differential); `test/reference/M2ReferenceModel.test.ts` (Decimal(60) anchor at `simulation/outputs/canonical_month12_state.csv`); mainnet-fork variant gated on `MAINNET_RPC_URL` | passing (`@local`); present on `@fork` |
| Paper Theorem 5.2 part (0) — pre-saturation regime (`(1-f_s)Spot ≤ Floor`): pure redemption optimal | §5.2 | `test/reference/M2ReferenceModel.test.ts` (`Pi*(N) = N·Floor` when `A* ≤ 0`) | passing |
| Paper Theorem 5.2 part (1) — pure-dump regime (`N ≤ A*`): pure LP dump optimal | §5.2 | `test/reference/M2ReferenceModel.test.ts` (`Pi*(N) = pi_LP(N)` when `N ≤ A*`) | passing |
| Paper Theorem 5.2 part (2) — mixed regime (`N > A*`): saturated mixed strategy | §5.2 | `test/integration/Theorem5_2BankRun.t.sol`; `test/reference/M2ReferenceModel.test.ts` (saturation locus `α* = A*/N`) | passing |
| Paper Theorem 5.2 part (3) — bounded run premium `Δ*` is a state-only constant, independent of `N` | §5.2 | `test/integration/Theorem5_2BankRun.t.sol` (sweep `N ∈ {A*, 2A*, 10A*, Sup}`; `Δ* = const`) | passing |
| Paper Theorem 5.2 part (4) — asymptotic redemption `Pi*(N)/N → Floor` as `N → ∞` | §5.2 | `test/reference/M2ReferenceModel.test.ts`; Track A sanity in `simulation/generate_figures.py` (Fig. attacker phase diagram) | passing |
| Paper §5.2 (Diamond–Dybvig contrast) — single-equilibrium game; no strategic-complementarity channel | §5.2 | Composition of Theorem 4.5 + Theorem 5.2 tests above; no separate Solidity test required | passing (composed) |
| Paper §5.3 (Terra–Luna disanalogy) — exogenous backing, one-way treasury inflow, no peg target | §5.3 | `test/unit/M2Treasury.t.sol` (one-way inflow); `test/unit/M2Token.t.sol` (no peg / no minting after genesis); structural — no separate test needed | passing (composed) |
| Paper Theorem 5.3 (Spot–Floor Convergence under Zero Revenue) part (1) — floor stickiness under zero revenue | §5.4 | `test/integration/RedemptionIntegration.t.sol` (revenue-stop trajectory); `test/invariant/FloorMonotonicityInvariant.t.sol` | passing |
| Paper Theorem 5.3 part (2) — spot floor via arbitrage (`Spot ≥ Floor`) | §5.4 | `test/integration/Theorem5_3SpotFloorArbitragePin.t.sol` (`@local`, paired-address-sort; structural; mainnet-fork demonstrates full convergence) | passing (`@local`); `@fork` extension present |
| Paper Theorem 5.3 part (3) — convergence under net-sell pressure (`D(t) → ≤ f_b·Floor`) | §5.4 | `test/integration/Theorem5_3SpotFloorArbitragePin.t.sol` (multi-step trajectory); `simulation/generate_figures.py` (Track A monotone convergence on Fig. floor-trajectory) | passing |
| Paper Theorem 5.4 (LP Half-Life) — `n_{1/2} = L_{s,0}/B` (Python recurrence) | §5.5 | `simulation/generate_figures.py` (Track A Fig. revenue-sweep right axis); `scripts/agreement_gate.{ts,py}` cross-validates multi-month LP state vs. recurrence | Track A only |
| Paper Theorem 5.5 (Calling Equilibrium under Atomless Competition) — `Δt* = g/(0.0025·β)` Bertrand break-even | §5.6 | `docs/deployment_runbook.md` (operator-cadence guidance); no on-chain mechanism enforces calling cadence | runbook only |
| Paper Theorem 5.6 (MEV Leakage Upper Bound) — operator-level bound under Flashbots Protect + random delay + TWAP | §5.7 | `docs/deployment_runbook.md` (operator-level mitigation runbook); on-chain claim is Corollary 4.4 closure (no test) | runbook only |

## Paper §6 — Numerical Results

| Paper claim | Section | Test file | Status |
|---|---|---|---|
| Paper §6.1 — two-track methodology (Track A Python + Track B Hardhat invariant) bit-exact agreement | §6.1 | `scripts/agreement_gate.ts` (`npm run test:agreement`); `scripts/agreement_gate.py` (`python3 scripts/agreement_gate.py`); CSV consumer in `simulation/outputs/baseline_{12,36}mo.csv` | passing |
| Paper §6.2 Table 1 — baseline projection (12-month, $100k/mo) reproduces canonical state | §6.2 | `simulation/generate_figures.py`; `simulation/outputs/baseline_12mo.csv`; `test/reference/M2ReferenceModel.test.ts` (closed-form recurrence parity) | Track A + reference parity (passing) |
| Paper §6.2 Fig. floor-trajectory — 36-month floor/spot/supply trajectory | §6.2 | `simulation/generate_figures.py` (deterministic; `make reproduce` regenerates bit-stably) | Track A |
| Paper §6.3 Fig. revenue-sweep — sensitivity sweep on monthly revenue R | §6.3 | `simulation/generate_figures.py` (Fig. revenue-sweep) | Track A |
| Paper §6.4 Fig. lp-frontier — sensitivity sweep on LP/vesting split | §6.4 | `simulation/generate_figures.py` (Fig. lp-frontier) | Track A |
| Paper §6.5 Fig. fee-attribution — sensitivity sweep on sell-side fee `f_s` | §6.5 | `simulation/generate_figures.py` (Fig. fee-attribution) | Track A |
| Paper §6.6 S2 (revenue stops) — floor constant from `t_stop` onward | §6.6 | `simulation/generate_figures.py`; `test/integration/RedemptionIntegration.t.sol` | passing |
| Paper §6.6 S3 (mass redemption) — floor invariant under 25/50/75% redemption | §6.6 | `simulation/generate_figures.py` (Track A sanity); `test/integration/RedemptionIntegration.t.sol`; `test/integration/MainnetFork12MonthRouteRevenue.t.sol` (`@fork` end-to-end) | passing (`@local`); present on `@fork` |
| Paper §6.6 S4 (mass dump) — floor step-up after `collectFees` realization | §6.6 | `test/integration/MainnetForkVestingMassDump.t.sol` (`@fork`); skips cleanly when `MAINNET_RPC_URL` unset | present (gated on `MAINNET_RPC_URL`) |
| Paper §6.6 S5 (adversarial-mixed) — yield surface `Π*(α, N)` matches saturation locus | §6.6 | `test/integration/Theorem5_2BankRun.t.sol`; `simulation/generate_figures.py` (Fig. attacker-phasediagram) | passing |
| Paper §6.6 S6 (organic-volume regimes) — floor growth by source decomposition | §6.6 | `simulation/generate_figures.py` (Fig. organic-volume) | Track A |
| Paper §6.7 Fig. montecarlo-bands — Monte Carlo 5/50/95 floor bands under stochastic revenue | §6.7 | `simulation/generate_figures.py` (Fig. montecarlo-bands; seed 42) | Track A |
| Paper §6.8 Reproducibility — `make reproduce` regenerates every figure | §6.8 | `Makefile` (project root); `simulation/generate_figures.py`; CI gates regeneration on every PR | passing |

## Phase 1 — TS Reference Model & Agreement Gate (infrastructure)

| Artifact | File | Status |
|---|---|---|
| TS reference model (state tuple, 7 ops, helpers, baseline runner) | `test/reference/M2ReferenceModel.ts` | passing |
| TS reference unit tests (parity, residual, monotonicity, conservation, anchor) | `test/reference/M2ReferenceModel.test.ts` | passing (17 tests; `npm run test:reference`) |
| Agreement gate (TS side) | `scripts/agreement_gate.ts` | passing (`npm run test:agreement`) |
| Agreement gate (Python sibling) | `scripts/agreement_gate.py` | passing (`python3 scripts/agreement_gate.py`) |
| Canonical Track A CSV outputs (consumed by both gates) | `../simulation/outputs/baseline_{12,36}mo.csv`, `canonical_month12_state.csv` | emitted (`python3 ../simulation/generate_figures.py`) |
| Phase 7 audit scripts (bytecode / inheritance / slither lanes) | `scripts/audit/{audit_bytecode.ts, audit_inheritance.ts}` + `npm run audit:slither` | wired in CI (Agent A authors the scripts; Agent B wires the lanes) |

---

## Notes

- **Theorem 5.4** is intentionally `Track A` only — it is a property of
  the deterministic Python recurrence over the LP state and does not
  require a Solidity test. The agreement gate (Phase 6) cross-validates
  the multi-month LP state against the Python recurrence via CSV diff.
- **Theorem 5.5** and **Theorem 5.6** are operator-level claims; the
  protocol bytecode makes no on-chain MEV claim. The on-chain invariant
  is Corollary 4.4 closure (no reordering of `Ops` classes lowers the
  floor), which is covered by the floor-monotonicity invariant fuzz.
- **Conjecture 4.X** (LVR / Floor-Capture Identity) is directional, not
  a theorem. The directional intuition is exhibited by the Track A
  fee-attribution chart in `simulation/generate_figures.py`. Conversion
  to a theorem is paper §6.4 open problem P6.
- The release gate requires every row above to be `passing`, `present`
  (with the gate documented), `Track A`, `runbook only`, or `deferred`
  (with the limitations row linked) before the `paper-v1` tag.
- The grep gate `grep -c "Paper" contracts/docs/paper_claim_to_test.md`
  must return ≥ 25; the gate above the §3.7 Table 1 block enumerates
  the 14 threat-model rows individually, plus the §3 structural claims,
  plus every numbered theorem/lemma/corollary/conjecture in §§4–5.
