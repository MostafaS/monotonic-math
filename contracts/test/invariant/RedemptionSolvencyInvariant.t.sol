// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {InvariantFixture} from "./handlers/InvariantFixture.sol";

/// @title RedemptionSolvencyInvariant
/// @notice Paper §6 numerical results enumerate four invariants; (i)–(iii)
///         are wired in {FloorMonotonicityInvariant}, {SupplyInvariant}, and
///         {TreasuryInvariant}. This test wires invariant (iv): the
///         redemption-solvency lower bound
///
///             T * SCALE >= S * minFloor
///
///         where `minFloor = min_t F(t)` is the lower envelope of the
///         floor `F = T * SCALE / S` (paper §3.2 eq. 1) observed across
///         every reached state, and `SCALE = 10^(36 - d_s)`.
/// @dev    The ghost `minFloor` is maintained by {M2InvariantHandler}: the
///         constructor sets it to `type(uint256).max`; the fixture calls
///         `seedMinFloor()` once post-deploy to set it to the genesis
///         floor `F_0`; every `_snapAfter` refines it via
///         `_refineMinFloor`. Because Theorem 4.3 already guarantees `F`
///         is non-decreasing, the lower envelope coincides with `F_0`
///         under correct execution and the assertion below should never
///         strictly tighten — a refinement that lowers `minFloor` below
///         `F_0` would itself be a Theorem-4.3 violation. The invariant
///         is therefore both a redemption-solvency lower bound AND a
///         belt-and-suspenders check on floor monotonicity from the
///         opposite direction (per-state vs. per-transition).
///
///         The cross-product form `T * SCALE >= S * minFloor` avoids
///         rounding loss (no floor-divide in the assertion) and uses
///         `SCALE = 1e30` — the fixture's mock backing stable has
///         `decimals() == 6`, so SCALE = 10^(36-6). The constant is
///         exported from the handler as `FLOOR_SCALE` and re-used here.
contract RedemptionSolvencyInvariantTest is InvariantFixture {
    function setUp() public {
        _deployInvariantFixture();
        targetContract(address(handler));
    }

    /// @notice Paper invariant (iv): the cross-product redemption-solvency
    ///         lower bound. Asserted after EVERY handler call that
    ///         produced a state change (lastOp != 0).
    function invariant_RedemptionSolvencyLowerBound() public view {
        uint8 op = handler.lastOp();
        if (op == 0) return; // No op has run yet
        uint256 S = handler.lastSAfter();
        if (S == 0) return; // Floor undefined at supply zero
        uint256 T = handler.lastTAfter();
        uint256 m = handler.minFloor();
        // `minFloor` is seeded to the genesis floor by the fixture; if it
        // is still the sentinel `type(uint256).max`, skip (no observation
        // has been recorded yet — defensive guard, should not trigger
        // because the fixture seeds before the runner picks up).
        if (m == type(uint256).max) return;
        // T * SCALE >= S * minFloor
        require(
            T * handler.FLOOR_SCALE() >= S * m,
            "redemption-solvency lower bound violated"
        );
    }

    /// @notice Companion: the lower envelope is itself bounded below by the
    ///         genesis floor. Equivalent to Theorem 4.3 read in the
    ///         minFloor direction.
    function invariant_MinFloorAtLeastGenesis() public view {
        uint8 op = handler.lastOp();
        if (op == 0) return;
        uint256 m = handler.minFloor();
        if (m == type(uint256).max) return;
        // Genesis floor: T0 * FLOOR_SCALE / S0 with T0 = 1e6 * 1e6 = 1e12,
        // FLOOR_SCALE = 1e30, S0 = 1e9 * 1e18 = 1e27. Genesis floor =
        // (1e12 * 1e30) / 1e27 = 1e15.
        uint256 genesisFloor = (T0 * handler.FLOOR_SCALE()) / S0;
        require(m >= genesisFloor, "minFloor dropped below genesis F_0");
    }
}
