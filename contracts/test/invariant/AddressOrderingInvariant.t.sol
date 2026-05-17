// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {AddressOrderingInvariantBase} from "./handlers/AddressOrderingInvariantBase.sol";

// =====================================================================
// AddressOrderingInvariant — concrete subclasses for the paired
// address-sort invariant lane. The shared abstract base (which carries
// the three invariant-check helpers and the paired fixture wiring)
// lives in `./handlers/AddressOrderingInvariantBase.sol` and exposes
// only `internal` helpers. The two concrete subclasses below re-expose
// those helpers as `setUp()` + public `invariant_*` selectors, which
// is what the Hardhat-v3 EDR invariant runner discovers via the
// compiled artifacts.
//
// Both subclasses inherit the SAME invariant assertions from the base
// and run them against the SAME bytecode, differing only in the
// CREATE2-mined MockStable address ordering vs. the M2Token address.
//
// Heavy-lane gating:
// This lane is the heaviest in the suite — it requires CREATE2 salt
// mining for both orderings AND runs the full paired-ordering
// cross-product. To keep the per-PR CI wallclock under 5 min, the
// `pr` job sets `M2_SKIP_HEAVY_INVARIANTS=1`, which triggers the
// `vm.skip(true)` branch in `setUp()`. The full lane still runs in:
//   * `npm run test:invariant`  (local; env var unset)
//   * `npm run test:invariant:full` (on the `v0.1.x-paper-v1` tag job)
// =====================================================================

/// @notice Runs Theorem 4.3 + invariant (iv) under
///         `address(stable) < address(token)` (stable is currency0).
contract AddressOrderingInvariant_StableLowTest is AddressOrderingInvariantBase {
    function _wantStableLowerThanToken() internal pure override returns (bool) {
        return true;
    }

    function setUp() public {
        // Heavy lane — CREATE2 mining + paired-ordering cross-product. Skipped
        // on the PR CI gate (M2_SKIP_HEAVY_INVARIANTS=1) to keep wallclock under
        // 5 min; runs locally via `npm run test:invariant` and on the
        // `v0.1.x-paper-v1` release tag via `test:invariant:full`.
        if (vm.envOr("M2_SKIP_HEAVY_INVARIANTS", false)) {
            vm.skip(true);
            return;
        }
        _setUpPaired();
    }

    function invariant_FloorNonDecreasing_PairedSort() public view {
        _check_FloorNonDecreasing_PairedSort();
    }

    function invariant_RedemptionSolvencyLowerBound_PairedSort() public view {
        _check_RedemptionSolvencyLowerBound_PairedSort();
    }

    function invariant_OrderingMatchesRequested() public view {
        _check_OrderingMatchesRequested();
    }
}

/// @notice Runs Theorem 4.3 + invariant (iv) under
///         `address(stable) > address(token)` (token is currency0).
contract AddressOrderingInvariant_StableHighTest is AddressOrderingInvariantBase {
    function _wantStableLowerThanToken() internal pure override returns (bool) {
        return false;
    }

    function setUp() public {
        // Heavy lane — CREATE2 mining + paired-ordering cross-product. Skipped
        // on the PR CI gate (M2_SKIP_HEAVY_INVARIANTS=1) to keep wallclock under
        // 5 min; runs locally via `npm run test:invariant` and on the
        // `v0.1.x-paper-v1` release tag via `test:invariant:full`.
        if (vm.envOr("M2_SKIP_HEAVY_INVARIANTS", false)) {
            vm.skip(true);
            return;
        }
        _setUpPaired();
    }

    function invariant_FloorNonDecreasing_PairedSort() public view {
        _check_FloorNonDecreasing_PairedSort();
    }

    function invariant_RedemptionSolvencyLowerBound_PairedSort() public view {
        _check_RedemptionSolvencyLowerBound_PairedSort();
    }

    function invariant_OrderingMatchesRequested() public view {
        _check_OrderingMatchesRequested();
    }
}
