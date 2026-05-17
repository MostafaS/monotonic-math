// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {InvariantFixture} from "./handlers/InvariantFixture.sol";

/// @title FloorMonotonicityInvariant
/// @notice Paper Theorem 4.3 — the floor `F = T / S` is non-decreasing
///         after every protocol-defined operation. Asserted as the
///         integer cross-product `T_new * S_old >= T_old * S_new`
///         (avoids rounding loss).
/// @dev    Stateful fuzz: the EDR invariant runner picks random handler
///         method invocations from {M2InvariantHandler}. After each, this
///         test reads `(lastTBefore, lastSBefore, lastTAfter, lastSAfter)`
///         from the handler and asserts cross-product non-decrease.
contract FloorMonotonicityInvariantTest is InvariantFixture {
    function setUp() public {
        _deployInvariantFixture();
        targetContract(address(handler));
    }

    /// @notice Cross-product floor monotonicity, asserted after EVERY
    ///         handler call that produced a state change (lastOp != 0).
    function invariant_FloorNonDecreasing() public view {
        uint8 op = handler.lastOp();
        if (op == 0) return; // No op has run yet
        uint256 tBefore = handler.lastTBefore();
        uint256 sBefore = handler.lastSBefore();
        uint256 tAfter = handler.lastTAfter();
        uint256 sAfter = handler.lastSAfter();
        if (sBefore == 0 || sAfter == 0) return; // Floor undefined
        // T_new * S_old >= T_old * S_new
        require(
            tAfter * sBefore >= tBefore * sAfter,
            "floor monotonicity violated"
        );
    }
}
