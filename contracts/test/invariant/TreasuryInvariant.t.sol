// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {InvariantFixture} from "./handlers/InvariantFixture.sol";

/// @title TreasuryInvariant
/// @notice Paper §3.3: stable can leave the treasury ONLY via
///         `payRedemption`. There is no admin withdraw, no sweep, no
///         pause, no upgrade.
/// @dev    The handler's ghost `treasuryWithdrawnExceptRedemption` is
///         wired inside `M2InvariantHandler._snapAfter`: any per-op
///         balance delta `T_before > T_after` with `lastOp != 2` (i.e.
///         not a redemption) is added to the ghost. The invariant then
///         asserts the running sum is zero. With the current bytecode
///         the ghost stays zero by construction (M2Treasury has no
///         non-`payRedemption` outflow path), but if a future refactor
///         introduced one the invariant would fire loudly. This is the
///         load-bearing form of the property — not a tautology.
///         The companion `invariant_TreasuryNonDecreasingOnNonRedeemOps`
///         is the per-op crisp form of the same property and provides
///         belt-and-suspenders coverage.
contract TreasuryInvariantTest is InvariantFixture {
    function setUp() public {
        _deployInvariantFixture();
        targetContract(address(handler));
    }

    /// @notice The ghost counter must remain zero — every wei that leaves
    ///         the treasury during the fuzz run was a redemption payout.
    function invariant_TreasuryOneWay() public view {
        require(
            handler.treasuryWithdrawnExceptRedemption() == 0,
            "treasury withdrawn except via redemption"
        );
    }

    /// @notice For non-redemption ops (lastOp != 2), the treasury balance
    ///         must be non-decreasing across the op. routeRevenue and
    ///         collectFees can only add to T; lpBuy / lpSell / transfer do
    ///         not touch T.
    function invariant_TreasuryNonDecreasingOnNonRedeemOps() public view {
        uint8 op = handler.lastOp();
        if (op == 0) return;
        if (op == 2) return; // redeem may decrease T
        require(
            handler.lastTAfter() >= handler.lastTBefore(),
            "treasury decreased on a non-redeem op"
        );
    }
}
