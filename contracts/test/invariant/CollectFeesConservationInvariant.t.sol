// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {InvariantFixture} from "./handlers/InvariantFixture.sol";

/// @title CollectFeesConservationInvariant
/// @notice Paper §3.5 (Audit FINAL_REPORT L4 "no-stranded-wei"):
///           stableBounty + stableToTreasury == stableRealized
///           tokenBounty  + tokenBurned      == tokenRealized
///         These conservation identities hold EXACTLY (subtraction-based
///         residuals in the hook bytecode).
/// @dev    The handler records the last collectFees distribution in ghost
///         slots; we assert the sum equality on every observed call.
contract CollectFeesConservationInvariantTest is InvariantFixture {
    function setUp() public {
        _deployInvariantFixture();
        targetContract(address(handler));
    }

    /// @notice After every collectFees call, the stable side conservation
    ///         identity must hold exactly.
    function invariant_StableConservation() public view {
        if (handler.collectFeesCount() == 0) return;
        require(
            handler.lastCollectStableBounty() +
                handler.lastCollectStableToTreasury() ==
                handler.lastCollectStableRealized(),
            "stable conservation violated"
        );
    }

    /// @notice After every collectFees call, the token side conservation
    ///         identity must hold exactly.
    function invariant_TokenConservation() public view {
        if (handler.collectFeesCount() == 0) return;
        require(
            handler.lastCollectTokenBounty() +
                handler.lastCollectTokenBurned() ==
                handler.lastCollectTokenRealized(),
            "token conservation violated"
        );
    }

    /// @notice The caller bounty cannot exceed 0.25% (one bps round-up
    ///         would overpay the caller). Asserts the floor rounding is
    ///         protocol-protective.
    function invariant_BountyAtMostQuarterPercent() public view {
        if (handler.collectFeesCount() == 0) return;
        // bounty * 10_000 <= realized * 25
        require(
            handler.lastCollectStableBounty() * 10_000 <=
                handler.lastCollectStableRealized() * 25,
            "stable bounty exceeds 0.25%"
        );
        require(
            handler.lastCollectTokenBounty() * 10_000 <=
                handler.lastCollectTokenRealized() * 25,
            "token bounty exceeds 0.25%"
        );
    }
}
