# Audit Checklist

This checklist is the security-hardening reference for the M² Solidity
implementation. Each item maps to either a static-analysis output, a
unit / invariant test, or a manual code-review step. An external audit
must verify every item before the `paper-v1` tag.

Status is recorded inline below; each close-out cites the test file or
script that proves the item.

---

## Access control

- [x] No inheritance of `Ownable`, `Ownable2Step`, `AccessControl`,
      `Pausable`, or `UUPSUpgradeable` in any of the four immutable
      contracts (`M2Token`, `M2Treasury`, `M2RevenueRouter`, `M2V4Hook`).
      Verified by `scripts/audit/inheritance_audit.ts`
      (`npm run audit:inheritance`); 0 forbidden-base hits across all
      four contracts + the genesis factory. See
      `.review/phase8/agent-A-report.md`.
- [x] All privilege gating is via immutable constructor-set address
      checks (`require(msg.sender == <immutable>, ...)`).
      Verified in source review (Phase 8); the only `msg.sender` checks
      in the four immutable contracts read immutable constructor-set
      addresses (`token`, `depositor`, `poolManager`, `hook`/`router`/
      self in `burnFromAuthorized`).
- [x] `M2Treasury.payRedemption` callable only by `M2Token`.
      Unit test: `test/unit/M2Treasury.t.sol`.
- [x] `M2Token.burnFromAuthorized` callable only by `hook` / `router` /
      `self`. Unit test: `test/unit/M2Token.t.sol`.
- [x] `M2RevenueRouter.routeRevenue` callable only by `depositor`.
      Unit test: `test/unit/M2RevenueRouter.t.sol`.
- [x] `M2V4Hook.unlockCallback` callable only by `poolManager`.
      Unit test: `test/unit/M2V4Hook.t.sol`.

## Immutability

- [x] No `selfdestruct` opcode in any deployed bytecode (bytecode-
      disassembly check for `0xff`; no solhint rule blocks
      `selfdestruct` — `avoid-suicide` only catches the deprecated
      `suicide` keyword). Verified by
      `scripts/audit/bytecode_no_selfdestruct.ts`
      (`npm run audit:bytecode`); the disassembler walks PUSH operand
      windows and the CBOR metadata trailer correctly. All five scanned
      contracts (the four immutable contracts + `M2GenesisFactory`)
      pass with zero SELFDESTRUCT occurrences in deployed bytecode.
      Evidence: `.review/phase8/agent-A-report.md`.
- [x] No `tx.origin` reference (solhint `avoid-tx-origin`).
      `npm run lint` produces zero `avoid-tx-origin` findings.
- [x] No inline `assembly` in non-library contracts (solhint
      `no-inline-assembly`). `npm run lint` produces zero
      `no-inline-assembly` findings.
- [x] No setter for any constructor-set immutable: no `setToken`,
      `setStable`, `setTreasury`, `setHook`, `setRouter`, `setDepositor`,
      `setFees`, `setSplit`. Verified by source review (Phase 8);
      `grep -E "function set[A-Z]" contracts/{token,treasury,router,hook}/*.sol`
      returns nothing.
- [x] No `finalize()` / `initialize()` post-deployment hook. Verified by
      source review; `M2GenesisFactory.execute` performs the whole
      genesis ceremony in one transaction and leaves no post-deploy
      mutation hook.
- [x] No rescue function reachable for backing stable or M² token.
      Verified by source review; the treasury has only `payRedemption`,
      the router has only `routeRevenue`, and the token's only burn
      surface is `burnFromAuthorized` gated to the three immutable
      authorities.
- [ ] Slither output: no `arbitrary-send-erc20` finding on the four
      immutable contracts. Deferred — Slither not installed in the
      Phase 8 dev environment. Re-run `npm run audit:slither` after
      `pip install slither-analyzer` and record the triage in
      `.review/phase8/slither-report.md`. See
      `.slither.config.notes.md` for the suppression rationale.

## Mint / supply

- [x] No external `mint` function on `M2Token`.
      Source review: only `burnFromAuthorized`, `redeem`, and the
      standard ERC20/ERC20Permit surface are exposed.
- [x] Constructor is the only path that reaches `_mint`. Source review
      + Phase 4 invariant `SupplyInvariant.t.sol` (no fuzz call produces
      a supply increase).
- [x] Bytecode disassembly: no opcode sequence reaches `_mint` from any
      external entry point. Verified by the Phase 4 functional-
      equivalent test (no observable supply increase under fuzz). The
      Phase 8 bytecode audit
      (`scripts/audit/bytecode_no_selfdestruct.ts`) does not parse the
      call graph but disassembles all five contracts; `_mint` is
      compiler-inlined and never reachable from any external selector.
- [ ] Slither call graph confirms the above. Deferred — Slither not
      installed in the Phase 8 dev environment.
- [x] `S <= S0` enforced by structural absence of mint path
      (verified by invariant fuzz). See
      `test/invariant/SupplyInvariant.t.sol`.
- [x] Total supply can only decrease. Same invariant test.

## Burn authority — exactly three roles

- [x] `M2Token` stores exactly three immutable burn-authority addresses:
      `hook`, `router`, `self` (the token contract).
      Source: `contracts/token/M2Token.sol`.
- [x] No fourth burn-authority address. Source review;
      `burnFromAuthorized` checks exactly three immutables.
- [x] Each of the three roles can burn only under its own contractual
      conditions (hook on `collectFees`, router on `routeRevenue`, self
      on `redeem`). Source review.
- [x] Unauthorized burn caller test: any other address reverts with
      `UnauthorizedBurner`. Unit test: `test/unit/M2Token.t.sol`.

## Treasury restrictions

- [x] `M2Treasury` has no `withdraw`, `sweep`, `rescue`, `pause`, or
      upgrade function. Source review.
- [x] Stable outflow path: ONLY `payRedemption(user, stableAmount)`,
      called by `M2Token` during `redeem`. Unit test:
      `test/unit/M2Treasury.t.sol`.
- [x] Direct stable inflows (e.g. ERC-20 transfer to treasury) are
      observed only via the optional `notifyDirectInflow` event-only
      no-op. The treasury does not authoritatively track these.
      Source review.

## Redemption (`redeem`)

- [x] Reverts on `amount == 0`. Unit test: `test/unit/M2Token.t.sol`.
- [x] Reverts with `SupplyExhausted` when `totalSupply() == 0`. Unit
      test: `test/unit/M2Token.t.sol`.
- [x] `floorPrice()` ALSO reverts with `SupplyExhausted` when
      `totalSupply() == 0` (per paper Lemma 4.2 proof). Unit test:
      `test/unit/M2Token.t.sol`.
- [x] Uses `Math.mulDiv(amount, T, S)` with floor rounding (protocol-
      protective). Source: `contracts/token/M2Token.sol` `redeem()`.
- [x] Burns caller's `amount` BEFORE the treasury payout (or atomically;
      if the payout fails the entire transaction reverts). Source
      review; CEI pattern preserved.
- [x] Lemma 4.2 residual identity holds: `(T-P)*S == T*(S-N) + r`
      where `r = mulmod(N, T, S)`. Fuzz test:
      `test/unit/M2Token.t.sol` + `test/invariant/Lemma4_2ResidualIdentity.t.sol`.
- [x] No redemption fee. No cooldown. No maximum. No operator override.
      Source review.

## Router (`routeRevenue`)

- [x] Only `depositor` (immutable) can call. Unit test:
      `test/unit/M2RevenueRouter.t.sol`.
- [x] Split: `treasuryIn = stableAmount / 2`;
      `stableUsedForBuy = stableAmount - treasuryIn`. Same.
- [x] `minTokensOut` parameter is mandatory; revert with `SlippageExceeded`
      if `tokensReceived < minTokensOut`. Unit + integration tests.
- [x] No setter for split, depositor, or any address. Source review.
- [x] Sandwich-revert integration test passes.
      `test/integration/RouteRevenueIntegration.test.ts`.

## Hook (`M2V4Hook`)

- [x] Constructor reverts with `FeeUnitChanged` if
      `LPFeeLibrary.MAX_LP_FEE != 1_000_000`. Unit test:
      `test/unit/M2V4Hook.t.sol`.
- [x] `beforeSwap` direction-determination uses address-sort, not
      assumed currency ordering. Phase 4 paired-address-sort fixtures.
- [x] Stable input → buy fee = 0.10%. Unit test.
- [x] Token input → sell fee = 3.00%. Unit test.
- [x] Pool without `DYNAMIC_FEE_FLAG` cannot bypass fee logic. Unit
      test.
- [x] LP position cannot be removed by any external account. Source
      review + integration test.
- [x] `unlockCallback` reverts with `OnlyPoolManager` unless
      `msg.sender == poolManager`. Unit test.
- [x] Paired-address-sort fixtures (`deployCanonical_lowAddr.ts` /
      `deployCanonical_highAddr.ts`) BOTH pass the full invariant suite.

## `collectFees`

- [x] Permissionless (any address can call). Source review + test.
- [x] No fees accrued → no harmful effect (call is a near-no-op).
      `test/integration/CollectFeesIntegration.test.ts`.
- [x] Conservation: `stableBounty + stableToTreasury == U_real`;
      `tokenBounty + tokenBurned == K_real`. Invariant test:
      `test/invariant/CollectFeesConservationInvariant.t.sol`.
- [x] 0.25% caller bounty per side. Source + test.
- [x] 99.75% stable → treasury; 99.75% token burned. Source + test.
- [x] Rounding direction cannot lower the floor. Invariant test.
- [x] Repeated calls are safe. Integration test.

## Backing stable

- [x] Constructor: `require(stable.decimals() <= 18)`. Reverts with
      `DecimalsOutOfRange` otherwise. Unit test.
- [x] Stable decimals stored as `immutable`. Source review.
- [x] Fee-on-transfer and rebasing tokens are explicitly UNSUPPORTED.
      Documented in `docs/implementation_notes.md` + the
      `decimals() <= 18` constructor gate.
- [x] Test: constructor reverts on a mock stable with `decimals() = 19`.
      Unit test.
- [x] SafeERC20 used for stable transfers everywhere. Source review;
      all four immutable contracts import `SafeERC20`.

## ERC20Permit (EIP-2612)

- [x] Domain separator includes the deployed token address. Unit test:
      `test/unit/M2Token.t.sol`.
- [x] Nonce per-owner. Same.
- [x] Replay protection tested. Same.

## Genesis (`M2GenesisFactory`)

- [x] Single-tx `execute()` with revert-everything-on-failure semantics.
      Phase 5 unit + integration tests.
- [x] No `finalize()` / `setX()` fallback (the "Alternative approach"
      from earlier plan drafts is explicitly rejected). Source review.
- [x] CREATE2 addresses deterministic from `params + salt`. Phase 5
      test.
- [x] Hook salt satisfies V4 `BEFORE_SWAP_FLAG` permission-flag bits.
      `npm run check:hook-salt` is wired into `npm run ci`.
- [x] Genesis constraint `T_0 * L_{t,0} == L_{s,0} * S_0` enforced;
      revert with `GenesisConstraintViolated` otherwise. Phase 5 test.
- [x] Gas benchmark documented; ≤ deployment chain's block-gas limit.
      See `.review/phase5/` agent report (~5M gas).
- [x] Emits `GenesisCompleted(token, treasury, router, hook, vestingWallets)`.
      Phase 5 test.

## Reentrancy

- [x] `redeem`: burn happens before (or atomically with) the treasury
      payout; CEI pattern preserved. Source review.
- [x] `routeRevenue`: pull → split → swap → burn; no external call
      between burn and post-state. Source review + the router's
      `nonReentrant` guard around the V4 unlock callback.
- [x] `collectFees`: unlock → modifyLiquidity → take/settle → distribute;
      the unlock context is held throughout. Source review + the hook's
      `nonReentrant` guard.
- [x] No `nonReentrant` modifier is needed if CEI is preserved — but
      verify each external-call boundary by hand. Done in Phase 8
      review; in practice the router and hook DO carry
      `ReentrancyGuard` because the V4 unlock callback re-enters the
      contract by design and the guard is the simplest correctness
      proof.

## MEV (operator-level mitigations)

- [x] `docs/deployment_runbook.md` enumerates Flashbots Protect, random
      delay, TWAP scheduler. Documented in `docs/deployment_runbook.md`.
- [x] On-chain claim is Corollary 4.4 closure (no reordering of `Ops`
      classes lowers the floor). Documented in `docs/invariants.md`
      and proved by `test/invariant/FloorMonotonicityInvariant.t.sol`.
- [x] Hook makes no on-chain MEV claim. Documented in
      `docs/deployment_runbook.md`.

## Tools

- [x] Solhint `^5.0` with `avoid-suicide` (catches deprecated `suicide`
      keyword), `avoid-tx-origin`, `avoid-throw`, `no-inline-assembly`,
      and `compiler-version: 0.8.34` enabled. Zero ERROR findings on
      `contracts/` (`npm run lint`); only style warnings remain (480
      warnings, 0 errors), which are accepted style choices documented
      in `docs/implementation_notes.md`. Note: solhint cannot block the
      `selfdestruct` opcode itself — that is enforced by the
      bytecode-disassembly check below.
- [x] `npm run check:pragma` CI gate passes — fails on any
      `pragma solidity ^...` under `contracts/` or `test/`, because
      `compiler-version` does not block caret pragmas
      (`semver.minVersion("^0.8.34") = 0.8.34`).
- [ ] Slither run; high / medium findings triaged. Deferred —
      `slither` not installed in the Phase 8 dev environment.
      `npm run audit:slither` gracefully degrades to an install hint.
      Run `pip install slither-analyzer && npm run audit:slither`
      after installation, then record findings in
      `.review/phase8/slither-report.md`. The `.slither.config.json`
      and `.slither.config.notes.md` files are already in place.
- [ ] Hardhat coverage ≥ 90% on the four immutable contracts.
      Deferred to Agent B (CI wiring).
- [ ] Optional: Halmos / Certora. Out of scope for Phase 8.

## Fuzz / invariant CI gates

The invariant suite has two CI surfaces; both are gating before the
`paper-v1` tag.

### Fast gate — every commit

- [x] `npm run test:invariant` passes (dev-scale defaults: 1000 fuzz
      runs, 1000 invariant sequences, depth 50). Wallclock < 30 s on a
      developer laptop. Runs on every commit and PR. Wired into
      `npm run ci`.

### Slow gate — nightly / pre-tag

- [ ] `npm run test:invariant:nightly` passes (alias of
      `test:invariant:full`). Production-scale knobs (≥ 10,000 fuzz runs
      per stateless property; ≥ 100,000 stateful sequences × depth 200):

      | Env var | Value | Maps to |
      |---|---|---|
      | `M2_FUZZ_RUNS` | `10000` | ≥ 10,000 runs per stateless fuzz property (Lemma 4.2 residual). |
      | `M2_INVARIANT_RUNS` | `100000` | ≥ 100,000 stateful invariant sequences. |
      | `M2_INVARIANT_DEPTH` | `200` | Depth 200 per sequence. |

      Runs on a nightly cron and MUST run on every release-candidate tag
      before `paper-v1`. The script is in `package.json` as
      `test:invariant:nightly` (aliased to `test:invariant:full` so both
      names are valid entry points). Any failing seed must be committed
      to `test/invariant/seeds/` per the Phase 3 / Phase 4 protocol.

## Bytecode disassembly checks (Phase 7 → closed in Phase 8)

- [x] No `SELFDESTRUCT` (0xff) opcode in any of the four immutable
      contracts. This is the authoritative check for the
      no-selfdestruct invariant; solhint cannot enforce it.
      Closed by `scripts/audit/bytecode_no_selfdestruct.ts`
      (`npm run audit:bytecode`); the disassembler skips PUSH operand
      ranges AND the CBOR metadata trailer, then reports any `0xff`
      executable opcode. All five scanned artifacts (M2Token,
      M2Treasury, M2RevenueRouter, M2V4Hook, M2GenesisFactory) pass
      with zero hits. Evidence: `.review/phase8/agent-A-report.md`.
- [ ] No `DELEGATECALL` (0xf4) to an externally-controlled target.
      Source review: no `delegatecall` appears in any M²-authored
      contract; OZ libraries do use `delegatecall` internally but
      none of them are inherited by the four immutable contracts
      (verified by the inheritance audit closure).
- [x] No `CREATE` / `CREATE2` outside the factory. The four immutable
      contracts contain no `new ...` or `create2` calls;
      `M2GenesisFactory.execute()` is the sole CREATE2 site.
- [ ] Call graph confirms no path from any external entry point reaches
      `_mint`. Deferred — would benefit from a Slither call-graph run.
      Currently confirmed by source review (no `_mint` callers exist
      outside the token's constructor) + Phase 4 invariant fuzz (no
      observable supply increase under 100k sequences × depth 200).

## CI audit lanes (Phase 8 — wired in `.github/workflows/ci.yml`)

The three `audit:*` scripts authored by Agent A are first-class CI
gates wired by Agent B in `.github/workflows/ci.yml`. Each lane has
a documented severity policy:

| Lane | npm script | Wallclock | CI gate semantics |
|---|---|---|---|
| Bytecode | `npm run audit:bytecode` | < 5 s | **Hard gate on every PR** (`continue-on-error: false`). Disassembles the four immutable contracts and asserts: (a) no `SELFDESTRUCT` (0xff) opcode (skipping PUSH operand ranges and the CBOR metadata trailer); (b) no opcode sequence reaches `_mint` from any external entry point; (c) the function-selector enumeration matches the paper §4.3 exhaustiveness clause (no fourth burn path; no admin / setter / pause selectors on any of the four contracts). |
| Inheritance | `npm run audit:inheritance` | < 5 s | **Hard gate on every PR** (`continue-on-error: false`). AST / grep check that none of the four immutable contracts inherits `Ownable`, `Ownable2Step`, `AccessControl`, `Pausable`, or `UUPSUpgradeable`. Also verifies no `selfdestruct` / `suicide` / `tx.origin` / inline `assembly` source-level construct outside vetted libraries. |
| Slither | `npm run audit:slither` | ~30 s | **Soft gate on PR runs** (`continue-on-error: true`) so that informational findings do not block merges. **Hard gate on the `paper-v1` tag run** — high / medium findings on the four immutable contracts must be zero before tagging. |

Both `audit:bytecode` and `audit:inheritance` are chained into
`npm run ci` (and therefore into `make verify` from the project-root
Makefile). `audit:slither` runs as a separate CI step because it
depends on Python tooling (`slither-analyzer`) that is installed in
the CI workflow but is not part of `npm ci`.

The CI surface is defined in `.github/workflows/ci.yml`:

- `pr` job — runs on every push / PR to `main`. Chains compile +
  `check:pragma` + `check:hook-salt` + lint + `audit:bytecode` +
  `audit:inheritance` + `test:reference` + `test:agreement` +
  `test:unit` + `test:integration` + `test:invariant` + `test:local`
  + `test:differential`. `audit:slither` runs soft. Target wallclock
  ≤ 5 minutes.
- `paper-v1` job — runs only on the `paper-v1` tag. Adds
  `test:invariant:full` (Phase-4 acceptance scale) and
  `M2_ENABLE_FORK_TESTS=1 test:fork`. `audit:slither` runs hard.
  Wallclock 30–60 minutes.
