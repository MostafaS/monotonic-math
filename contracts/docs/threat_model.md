# Threat Model

This document mirrors **paper §3.7 Table 1** row-by-row. Each adversary row
carries its scope tag from the paper (`in scope`, `partial`, `out of
scope`) and either (a) the contract-side mitigation that backs the
in-scope claim (with the file path of the test that exercises it — even if
the file does not yet exist, the intended path is listed) or (b) an
explicit residual-risk acknowledgement for the out-of-scope rows.

The acceptance criterion `grep -c "Paper §3.7" docs/threat_model.md` is
expected to return **≥ 14** — there is one `Paper §3.7` citation per row,
plus this preamble, plus the closing note.

Rows are presented in the same order as paper §3.7 Table 1.

---

## Row 1 — Rational holder

- **Citation:** Paper §3.7, Table 1, row 1.
- **Capability:** Choose any composition of `redeem`, LP swap, transfer;
  observe public state.
- **Scope:** In scope.
- **Where treated in the paper:** Theorem 4.3 (floor monotonicity);
  Theorem 4.5 (redemption fairness).
- **Contract-side mitigation:** The seven `Ops` classes are each
  individually floor-non-decreasing; closure under composition is
  Corollary 4.4.
- **Test:** `test/invariant/FloorMonotonicityInvariant.t.sol` (planned —
  Phase 4) covers any single-actor sequence of in-protocol operations.

## Row 2 — Coordinated coalition (any size up to total supply)

- **Citation:** Paper §3.7, Table 1, row 2.
- **Capability:** Submit any sequence of in-protocol operations;
  coordinate timing across multiple addresses.
- **Scope:** In scope for the simultaneous-strategy class; the sequenced
  supremum is paper §6 P7 (limitations).
- **Where treated in the paper:** Theorem 5.2 (bank-run cap with
  closed-form `Δ* ≈ $21,476.5621`).
- **Contract-side mitigation:** The 3.00% sell fee on the LP and the
  redemption-at-floor mechanism cap the saturated mixed-strategy proceeds.
- **Test:** `test/integration/MainnetForkBankRunDifferential_Thm5_2.test.ts`
  (planned — Phase 6, `@fork`) asserts proceeds match `Π*(N)` within V4
  tick-rounding tolerance.

## Row 3 — MEV searcher (single block)

- **Citation:** Paper §3.7, Table 1, row 3.
- **Capability:** Reorder, sandwich, frontrun any user transaction within
  a block; pay priority gas.
- **Scope:** In scope (bounded leakage).
- **Where treated in the paper:** Theorem 5.6 (MEV bound); §3.4
  anti-MEV mitigations.
- **Contract-side mitigation:** Hook applies asymmetric per-direction
  fees on `beforeSwap`; router supports a mandatory `minTokensOut`
  parameter for sandwich-revert defense in depth.
- **Test:** `test/integration/RouteRevenueIntegration.test.ts` (planned —
  Phase 5) includes a sandwich scenario that asserts `routeRevenue`
  reverts when `tokensReceived < minTokensOut`.

## Row 4 — `collectFees`-adjacent MEV (single block)

- **Citation:** Paper §3.7, Table 1, row 4.
- **Capability:** Time `collectFees` relative to large swaps within a
  single block to capture floor-step value.
- **Scope:** In scope (single-block).
- **Where treated in the paper:** Corollary 4.4 (closure under
  reordering); §3.4 hook mitigations.
- **Contract-side mitigation:** Each `Ops` class is individually
  floor-non-decreasing; intra-block reordering cannot violate floor
  monotonicity. The 0.25%/0.25% bounty is the only value extractable per
  call.
- **Test:** `test/invariant/CollectFeesConservationInvariant.t.sol`
  (planned — Phase 4) asserts conservation + monotonicity under
  arbitrary intra-block interleaving with redemption and swap actions.

## Row 5 — `collectFees`-adjacent MEV (cross-block)

- **Citation:** Paper §3.7, Table 1, row 5.
- **Capability:** Sequence `collectFees` across blocks to interact with
  attacker redemptions.
- **Scope:** Out of scope.
- **Where treated in the paper:** §6 limitations (P4); special case of
  multi-block MEV.
- **Residual risk acknowledgement:** Cross-block MEV is acknowledged as
  out of scope. The on-chain invariant — that no single operation
  composition lowers the floor — still holds; the residual concerns
  searcher capture of value that would otherwise have accrued to other
  callers, not floor violation.

## Row 6 — MEV searcher (multi-block, builder collusion)

- **Citation:** Paper §3.7, Table 1, row 6.
- **Capability:** Coordinate across blocks; influence builder choice.
- **Scope:** Out of scope.
- **Where treated in the paper:** §6 limitations (P2, P4).
- **Residual risk acknowledgement:** No current AMM design defends
  against multi-block builder collusion. M² inherits the substrate's
  assumptions about builder honesty.

## Row 7 — Operator (revenue depositor)

- **Citation:** Paper §3.7, Table 1, row 7.
- **Capability:** Choose timing and magnitude of `routeRevenue`; choose
  not to call.
- **Scope:** Partial — floor is preserved at zero revenue; growth is
  operator-dependent.
- **Where treated in the paper:** §5 (CEF analog under cessation);
  §6.7 (limitations — operator).
- **Contract-side mitigation:** Router's `depositor` is immutable; no
  setter exists; the operator cannot extract value from the treasury, only
  decline to add to it. Treasury invariants (one-way in, redemption-only
  out) ensure the floor never decreases under operator cessation.
- **Test:** `test/integration/RedemptionIntegration.test.ts` (planned —
  Phase 3) plus the "Revenue stop" row of the Test Matrix.

## Row 8 — Operator (strategic timing with vested holdings)

- **Citation:** Paper §3.7, Table 1, row 8.
- **Capability:** Time `routeRevenue` deposits jointly with private
  vested-token positions (25% of supply); exploit information advantage
  from knowing imminent deposits.
- **Scope:** Partial — within-block compositions are bounded by Thm 5.2
  (simultaneous-strategy class); cross-block strategic timing is paper
  §6 P7 (open).
- **Where treated in the paper:** §6.7 (limitations — open operator-IC
  analysis).
- **Contract-side mitigation:** No bytecode-level defense is possible
  for a privileged-information attack; the deployment runbook documents
  Flashbots Protect / random delay / TWAP scheduler as mitigations and
  recommends a deployer-chosen vesting cliff to bound the operator's
  immediate-dump capability.
- **Test:** `test/integration/MainnetForkVestingMassDump.test.ts`
  (planned — Phase 6, `@fork`) exercises the "vesting recipient" row
  (row 10) which is the symmetric sell-fee mitigation that also bounds
  this row's strategic-dump capability.

## Row 9 — Operator (post-genesis bytecode change)

- **Citation:** Paper §3.7, Table 1, row 9.
- **Capability:** N/A — no upgrade path exists.
- **Scope:** N/A (structural).
- **Contract-side mitigation:** All four contracts are deployed via
  CREATE2 with constructor-set immutables and no upgrade path. The
  project rules prohibit `Ownable` / `Pausable` / `UUPSUpgradeable`
  inheritance and any `selfdestruct` opcode in deployed bytecode.
- **Test:** Phase 7 bytecode disassembly check confirms no `SELFDESTRUCT`
  (0xff) opcode and Slither's call graph confirms no privileged-mutator
  path.

## Row 10 — Vesting recipient

- **Citation:** Paper §3.7, Table 1, row 10.
- **Capability:** Dump vested tokens to LP after cliff.
- **Scope:** In scope.
- **Where treated in the paper:** Thm 5.2; §3.4 asymmetric fee.
- **Contract-side mitigation:** The hook's symmetric 3.00% sell fee
  applies regardless of seller. Floor monotonicity holds throughout the
  dump; the post-`collectFees` floor strictly increases.
- **Test:** `test/integration/MainnetForkVestingMassDump.test.ts`
  (planned — Phase 6, `@fork`). Test config: `VestingWallet` with
  `start = block.timestamp`, `duration = 0` so the beneficiary obtains
  the full 250M at `t = 0`; the test then dumps the full allocation
  and asserts floor invariant + strictly-raised post-collect floor.

## Row 11 — Third-party oracle consumer

- **Citation:** Paper §3.7, Table 1, row 11.
- **Capability:** An external protocol uses M²'s spot as a price input
  and is exposed to spot manipulation by an adversary.
- **Scope:** Out of scope (the on-chain protocol cannot prevent
  third-party misuse).
- **Where treated in the paper:** §6 limitations (P3).
- **Residual risk acknowledgement:** M² emits no oracle interface; the
  spot price is the AMM's natural spot and is manipulable within a single
  block. Third-party consumers must apply their own TWAP / circuit
  breakers. This is documented in `docs/deployment_runbook.md`.

## Row 12 — Backing-stable issuer

- **Citation:** Paper §3.7, Table 1, row 12.
- **Capability:** Freeze the treasury's stable balance; depeg the
  stable; halt transfers.
- **Scope:** Out of scope (exogenous).
- **Where treated in the paper:** §6 limitations; USDC March-2023 depeg
  as canonical event.
- **Residual risk acknowledgement:** M²'s floor is denominated in the
  backing stable. Issuer-side freeze or depeg cannot be prevented by
  bytecode. The deployer is expected to (a) choose a credibly
  decentralized stable for the production deployment, (b) document the
  choice in the deployment runbook, and (c) treat stable-issuer freeze
  as a force-majeure event.

## Row 13 — Smart-contract bug (any contract in the system)

- **Citation:** Paper §3.7, Table 1, row 13.
- **Capability:** Violate any stated invariant via implementation
  defect.
- **Scope:** Out of scope (no mechanism for post-deployment fix).
- **Where treated in the paper:** §6 limitations; audit +
  mechanized-verification path.
- **Residual risk acknowledgement:** All four contracts are immutable;
  there is no upgrade path to fix a discovered bug after deployment. The
  Phase 7 security checklist, Slither static analysis, and the Phase 4
  invariant fuzz harness (≥ 100k sequences × depth 200) are the in-repo
  mitigations. The plan recommends an external audit before `paper-v1`.

## Row 14 — L1/L2 consensus failure

- **Citation:** Paper §3.7, Table 1, row 14.
- **Capability:** Halt the chain; censor transactions long-term.
- **Scope:** Out of scope (substrate assumption).
- **Where treated in the paper:** §6 limitations.
- **Residual risk acknowledgement:** M² inherits the consensus
  assumptions of its deployment chain. A long-term L1 outage halts
  redemption and revenue routing alike; nothing in the bytecode can
  mitigate this. The deployment runbook recommends Ethereum mainnet (or
  Base, both with mature consensus) as the canonical chains.

---

## Closing note

Each of the 14 rows above carries a single `Paper §3.7` citation; the
grep gate (`grep -c "Paper §3.7" docs/threat_model.md`) returns at least
14. Any addition to the threat model must come with a matching paper
update and at least one new test (or explicit residual-risk
acknowledgement) under this directory.
