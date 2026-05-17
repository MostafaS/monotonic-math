# Implementation Notes

A running log of implementation-level decisions and tooling quirks
discovered while building the M² Solidity reference. Each entry should
include (a) what was decided, (b) why, and (c) any pointer to the
acceptance criterion that the entry resolves.

---

## 2026-05-17 — Phase 0 bootstrap

### Library file for events: `interface IM2Events`

**Decision:** Events live in `interface IM2Events` (file
`contracts/libraries/M2Events.sol`).

**Why:** Historically, Solidity disallowed event declarations inside
`library` contracts. While Solidity 0.8.22+ relaxed this restriction
(libraries can declare events that internal functions then emit), an
interface is the simpler, more conventional pattern for "the canonical
list of event signatures that several contracts may emit". Implementations
re-declare the same event on the emitting contract so it appears in that
contract's ABI; the interface is the single source of truth for naming,
indexed fields, and data layout.

### Solhint compiler-version rule

**Decision:** `.solhint.json` pins `compiler-version` to `0.8.34`.

**Why:** Solhint's default `compiler-version` rule emits a warning for
any pragma that doesn't match an allowed semver. Pinning to `0.8.34`
means a future `pragma solidity ^0.8.34;` (forbidden by plan) will
trigger a solhint error, providing belt-and-suspenders on top of the
manual grep gate.

### Hardhat keystore + `MAINNET_RPC_URL` at config-load time

**Quirk:** `hardhat.config.ts` declares `networks.hardhatFork.forking.url
= configVariable("MAINNET_RPC_URL")`. Hardhat v3 resolves `configVariable`
at config-load time, so even running `npm run test:local` requires
`MAINNET_RPC_URL` to be set in the keystore (or the hardhatFork network
block to be commented out).

**Resolution:** `KEYSTORE.md` documents this. Future agents who hit a
"missing key" error on first compile should set the key (recommended) or
temporarily comment out the `hardhatFork` block (do NOT commit the
change).

### `forking.blockNumber` placeholder

**Decision:** `hardhat.config.ts` uses `blockNumber: 21000000n` as a
placeholder for the mainnet fork. The real block will be selected at
Phase 5 once `@fork` tests are wired up; the choice must (a) be recent
enough that the canonical V4 PoolManager is deployed and (b) be stable
across CI runs.

### Track A simulator location

**Decision:** No `contracts/simulations/` directory exists. The canonical
Python simulator lives at `../simulation/` (project root). The agreement
gate at `scripts/agreement_gate.{ts,py}` (Phase 6) consumes CSVs from
`../simulation/outputs/`.

**Why:** Per FINAL_REPORT.md blocker B2.

### `forge-std` strictly absent

**Decision:** `test/helpers/TestBase.sol` declares a local `Vm` interface
and a complete assertion-helper suite. There is NO `forge-std` import
anywhere; the `.solhint.json` ruleset and the project's no-third-party-Vm
convention enforce this.

**Why:** Hardhat v3 EDR exposes the same cheatcode address Foundry uses
but is a separate runtime; `forge-std` would pull in a tree of helpers
that may or may not be compatible. Locally-declared cheatcode interface
is the load-bearing decision for the Hardhat-v3-only path.

### SPDX license: MIT

**Decision:** Every `.sol` file uses `// SPDX-License-Identifier: MIT`.
The project locked to MIT to match the project-root `LICENSE` and the
`check:pragma` CI gate's expectations.

**Reversibility:** If owner picks a different license post-`paper-v1`,
the SPDX strings across the four immutable contracts AND
`M2Constants.sol` / `M2Errors.sol` / `M2Events.sol` / `TestBase.sol`
must be updated together. The bytecode hash is unaffected by SPDX
comments.

## Future entries

Phase 1+ work that surfaces tooling quirks, Hardhat-v3-specific gotchas,
or paper-vs-code judgment calls should append to this file. Keep entries
in reverse-chronological order (most recent at top).

---

## 2026-05-17 — Phase 3 — Invariant handler + Mock AMM

### MockAMM design (combined PoolManager + LP)

**Decision:** `contracts/mocks/MockAMM.sol` implements both the V4
`IPoolManager`-like surface (`unlock`, `swap`, `sync`, `settle`, `take`,
`initialize`, `modifyLiquidity`) AND the LP reserve bookkeeping. The
hook (`contracts/mocks/MockHook.sol`) is a separate contract that owns
the LP position virtually (its address is `MockAMM.HOOK`) and exposes
`collectFees()`.

**Why:** The real `M2RevenueRouter` was built in Phase 2 to drive the
real Uniswap V4 unlock/swap/settle/take flow against the V4 PoolManager.
For Phase 3 we want to exercise that real bytecode (no test-only
sub-classing) under randomized op sequences. The simplest substitution
is a contract implementing just enough of the V4 surface — `MockAMM`. We
combine the LP into the same contract because the V4 model has the
PoolManager custody all LP balances; separating them would need an extra
authorization dance.

### MockHook drains via dedicated entry point (Phase 3 only)

**Decision:** `MockHook.collectFees()` calls `MockAMM.drainAccumulators(
address(this))` directly, then distributes per the 0.25%/99.75% rule.
There is no `PoolManager.unlock + modifyLiquidity(0) + take/settle` flow
in Phase 3.

**Why:** Implementing the full unlock+modifyLiquidity dance in MockAMM
would re-create most of V4 PoolManager — wasted effort because Phase 4
replaces both with real V4. The distribution code (bounty rounding,
treasury transfer, burn) is identical to the real Phase 4 hook and
survives the swap.

**How to apply at Phase 4:** Replace `MockHook.sol` with `M2V4Hook.sol`
(real); replace `MockAMM.sol` with the real V4 PoolManager deployment.
The router and token bytecode are unchanged.

### Invariant handler: unified-holder partition

**Decision:** The handler holds all non-LP token balance and all
depositor stable. Per-actor seeds in `redeem`, `lpBuy`, `lpSell` are
preserved on the handler surface but unused in Phase 3.

**Why:** Per-actor isolation requires a proxy-per-actor pattern (each
actor's address as `msg.sender` to the four immutable contracts). The
invariants asserted (floor monotonicity, supply cap, treasury one-way,
collectFees conservation) are PER-OP DELTAS on global `(T, S, Lt, Ls,
PhiT, PhiS)` state — not per-actor balance properties — so the
unified-holder partition does not weaken the invariant suite. Phase 4
or later may refactor to per-actor proxies if integration tests need
distinct senders (e.g., redemption fairness Theorem 4.5 with two
holders in the same block).

### Fuzz/invariant runner config

**Decision:** `hardhat.config.ts` exposes `test.solidity.fuzz.runs` and
`test.solidity.invariant.{runs,depth,failOnRevert,callOverride}` via
environment variables `M2_FUZZ_RUNS`, `M2_INVARIANT_RUNS`,
`M2_INVARIANT_DEPTH`. Defaults (development): `1000 / 1000 / 50`.
Production scale: `10000 / 100000 / 200` (the `test:invariant:full`
npm script).

**Why:** The Phase 4 acceptance criterion is `100,000 sequences × depth
200`; that takes many hours on a developer laptop. Allowing the
defaults to be development-scale (`1000 × 50`) keeps the local cycle
fast while the production-grade gate is a single env-var flip.

### Bound helper added to TestBase.sol

**Decision:** `TestBase.bound(uint256 x, uint256 min_, uint256 max_)`
mirrors Foundry's `forge-std/StdUtils.bound` semantics: modular-wrap
clamp into `[min_, max_]`.

**Why:** The invariant handler needs Foundry-style bounding to keep
randomized inputs in physical ranges. The project does not import
`forge-std`, so the helper lives in the local `TestBase.sol`
(consistent with the project's "no third-party Vm" discipline).

### StdInvariant-compatible target surface in TestBase

**Decision:** `TestBase.sol` declares the `targetContract` /
`targetSelector` / `excludeContract` / `targetSender` /
`excludeSender` getters + helpers Foundry's `StdInvariant.sol` uses,
without importing forge-std.

**Why:** EDR's invariant runner reads `targetContracts()` etc. via the
same protocol Foundry uses. The Phase 4 fuzz harness needs to target
the handler exclusively (the four immutable contracts have no
non-handler entry points the runner should pick at random); the
clean implementation is to inherit `TestBase` and call
`targetContract(address(handler))` in `setUp()`.

### Phase 5 — M2GenesisFactory deployment strategy

**Decision:** the genesis factory uses **plain CREATE for treasury,
token, router** (factory nonces 1, 2, 4) and **CREATE2 only for the
hook** (nonce 3, EIP-1014 bumps the deployer nonce). The hook's
creation bytecode is supplied as a `bytes` argument to `execute()`,
NOT embedded as a `type(M2V4Hook).creationCode` literal.

**Why:** an all-CREATE2 design would require the off-chain miner to
solve a four-way joint fixed-point in the salt space (each contract's
salt + initCode depends on the others' predicted addresses, with
cycles through token-burn-authority slots and the router's pool key).
The hybrid CREATE / CREATE2 layout breaks the cycle cleanly:
treasury/token/router addresses are pure functions of the factory's
nonce (RLP), and the hook's address is a function of `(hookSalt,
poolManager, predictedToken, stable, predictedTreasury)` — none of
which depend on the hook's own address.

Embedding the hook's creation bytecode as a `type(...).creationCode`
literal would push the factory's runtime size to ~27 KiB, over the
EIP-170 24 576-byte cap; passing `hookCreationCode` as `bytes`
trims the factory to 19 062 bytes (default optimizer settings,
`runs: 200`). The deployer script reads the compiled `M2V4Hook`
artifact and supplies the bytecode at call time.

**How to apply:** future changes to the factory MUST keep the hook's
creation code out of the factory's compile-time literals. Adding a
fifth child contract (e.g., a new vesting class) requires careful
size accounting — if it pushes the factory over the cap, externalize
its creation code the same way.

### Phase 5 — Factory replay protection

**Decision:** the factory uses BOTH an OZ `nonReentrant` modifier AND
a one-shot `_executed` boolean storage flag. The modifier blocks
intra-tx reentry (the V4 PoolManager + VestingWallet calls open
external surfaces during `execute()`); the boolean blocks a second
outer call that would otherwise succeed past the reentrancy guard.

**Why:** the factory is itself NOT one of the four immutable
contracts (paper §3.1 enumerates token, treasury, router, hook). It
is a one-shot orchestrator; adding the `_executed` flag adds a
single SSTORE (~20k gas first-time) and gives operators a clean
revert (`AlreadyExecuted`) if a faulty automation pipeline retries
the genesis transaction. The CREATE2 hook collision would catch a
second call too, but the flag surfaces the failure earlier with a
clearer error code.

**How to apply:** the four immutable protocol contracts MUST NOT
adopt this pattern (no admin state, no setters, no replay flags
beyond the structural one-shot guards already in `M2V4Hook` for
`initializePool`). Replay protection is appropriate on the factory
only because the factory has no post-genesis surface.
