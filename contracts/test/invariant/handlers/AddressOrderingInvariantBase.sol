// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {InvariantFixturePaired} from "./InvariantFixturePaired.sol";

// =====================================================================
// AddressOrderingInvariant — paired address-sort lane for the mock-AMM
// invariant suite. Mirrors the {V4FullRangeIntegration} paired matrix
// (FINAL_REPORT H4) but at the invariant-fuzz tier: Theorem 4.3 floor
// monotonicity AND paper invariant (iv) redemption solvency must hold
// uniformly under BOTH `address(stable) < address(token)` and
// `address(stable) > address(token)`.
//
// Why this matters: the four immutable contracts (M2Token, M2Treasury,
// M2RevenueRouter, M2V4Hook) MUST NOT silently depend on the address
// sort of (stable, token). The V4 hook's direction logic is sort-aware
// (verified by the V4FullRangeIntegration paired matrix); none of the
// other three contracts is allowed to be. The paired invariant lane
// is defense-in-depth: a regression that, e.g., introduces an
// address-comparison ordering assumption into the token or the router
// would break here even if it slipped past the per-call assertions.
//
// Both subclasses inherit the SAME invariant assertions (floor
// monotonicity cross-product + redemption-solvency cross-product) and
// run them against the SAME bytecode, differing only in the CREATE2-mined
// MockStable address. The EDR invariant runner picks targets via the
// fixture's `targetContract(handler)` and the assertions are stateless
// (read-only) post-condition checks.
//
// NOTE: This abstract base lives under `handlers/` and uses a plain
// `.sol` extension (not `.t.sol`) so the Hardhat-v3 EDR invariant
// test-discovery glob (`test/invariant/*.t.sol`) does NOT pick it up
// as a concrete test contract. The two concrete subclasses live in
// the sibling `.t.sol` file and import this base.
// =====================================================================

abstract contract AddressOrderingInvariantBase is InvariantFixturePaired {
    function setUp() public {
        _deployInvariantFixturePaired();
        targetContract(address(handler));
    }

    // ---- floor monotonicity (Theorem 4.3) -----------------------------

    /// @notice Cross-product floor monotonicity, asserted after EVERY
    ///         handler call that produced a state change. Same form as
    ///         {FloorMonotonicityInvariantTest.invariant_FloorNonDecreasing}.
    function invariant_FloorNonDecreasing_PairedSort() public view {
        uint8 op = handler.lastOp();
        if (op == 0) return;
        uint256 tBefore = handler.lastTBefore();
        uint256 sBefore = handler.lastSBefore();
        uint256 tAfter = handler.lastTAfter();
        uint256 sAfter = handler.lastSAfter();
        if (sBefore == 0 || sAfter == 0) return;
        require(
            tAfter * sBefore >= tBefore * sAfter,
            "paired-sort: floor monotonicity violated"
        );
    }

    // ---- redemption-solvency lower bound (paper invariant (iv)) -------

    /// @notice Cross-product redemption-solvency lower bound. Same form
    ///         as
    ///         {RedemptionSolvencyInvariantTest.invariant_RedemptionSolvencyLowerBound}.
    function invariant_RedemptionSolvencyLowerBound_PairedSort() public view {
        uint8 op = handler.lastOp();
        if (op == 0) return;
        uint256 S = handler.lastSAfter();
        if (S == 0) return;
        uint256 T = handler.lastTAfter();
        uint256 m = handler.minFloor();
        if (m == type(uint256).max) return;
        require(
            T * handler.FLOOR_SCALE() >= S * m,
            "paired-sort: redemption-solvency lower bound violated"
        );
    }

    // ---- ordering check (sanity) --------------------------------------

    /// @notice Stateless: the recorded `stableIsCurrency0` flag matches
    ///         the requested ordering. A regression in the CREATE2 salt
    ///         mine would break the paired-lane matrix; this assertion
    ///         catches such a regression at runtime.
    function invariant_OrderingMatchesRequested() public view {
        require(
            stableIsCurrency0 == _wantStableLowerThanToken(),
            "paired-sort: stable/token ordering drifted from requested predicate"
        );
    }
}
