// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title IM2Events
/// @author M² / Monotonic Math
/// @notice Canonical event signatures emitted by the M² protocol. Declared
///         in an interface so any contract (or off-chain indexer) can
///         reference the exact event topic / ABI without inheriting state.
/// @dev    Implementations re-declare the same events on the emitting
///         contract so they appear in that contract's ABI; this interface
///         is the single source of truth for the canonical names, indexed
///         fields, and data layout. Keeping events in an interface (rather
///         than a library) sidesteps any historical Solidity restriction on
///         declaring events inside libraries and works under 0.8.34.
interface IM2Events {
    // -----------------------------------------------------------------
    // Token (paper §3.2)
    // -----------------------------------------------------------------

    /// @notice Emitted when a holder redeems M² for the backing stable.
    /// @param user      The redeeming address (also the stable recipient).
    /// @param amount    Token amount burned, raw (18-decimal) units.
    /// @param stableOut Stable amount paid, raw (stable-decimal) units.
    event Redeemed(address indexed user, uint256 amount, uint256 stableOut);

    // -----------------------------------------------------------------
    // Treasury (paper §3.3)
    // -----------------------------------------------------------------

    /// @notice Emitted by the treasury when it pays out a redemption.
    /// @param user         The stable recipient.
    /// @param stableAmount Stable amount transferred.
    event RedemptionPaid(address indexed user, uint256 stableAmount);

    /// @notice Emitted by the optional `notifyDirectInflow` no-op for
    ///         indexer convenience. The treasury does not authoritatively
    ///         track direct inflows; the event mirrors the post-call balance.
    /// @param balance The treasury's stable balance immediately after the
    ///                no-op was invoked.
    event DirectInflowObserved(uint256 balance);

    // -----------------------------------------------------------------
    // Revenue router (paper §3.5)
    // -----------------------------------------------------------------

    /// @notice Emitted by `routeRevenue` after the 50/50 split has been
    ///         applied, the buy-and-burn leg has settled, and tokens have
    ///         been burned.
    /// @param stableAmount      Total stable pulled from the depositor.
    /// @param treasuryIn        Stable transferred to the treasury
    ///                          (`stableAmount / 2`, floor-rounded).
    /// @param stableUsedForBuy  Stable consumed by the LP buy
    ///                          (`stableAmount - treasuryIn`, ceil-rounded).
    /// @param tokensBurned      Tokens received from the LP buy and burned.
    event RevenueRouted(
        uint256 stableAmount,
        uint256 treasuryIn,
        uint256 stableUsedForBuy,
        uint256 tokensBurned
    );

    // -----------------------------------------------------------------
    // Hook / collectFees (paper §3.4 / §3.5)
    // -----------------------------------------------------------------

    /// @notice Emitted by `collectFees` after both fee sides have been
    ///         realized and distributed. Conservation invariants
    ///         (enforced at compile-time-equivalent test time):
    ///           stableBounty + stableToTreasury == stableRealized
    ///           tokenBounty  + tokenBurned      == tokenRealized
    /// @param caller            The address that invoked `collectFees`.
    /// @param stableRealized    Total stable-side fees realized (Ureal).
    /// @param tokenRealized     Total token-side fees realized (Kreal).
    /// @param stableBounty      Stable paid to the caller (0.25% of Ureal).
    /// @param tokenBounty       Tokens paid to the caller (0.25% of Kreal).
    /// @param tokenBurned       Tokens burned (99.75% of Kreal).
    /// @param stableToTreasury  Stable forwarded to the treasury
    ///                          (99.75% of Ureal).
    event FeesCollected(
        address indexed caller,
        uint256 stableRealized,
        uint256 tokenRealized,
        uint256 stableBounty,
        uint256 tokenBounty,
        uint256 tokenBurned,
        uint256 stableToTreasury
    );

    // -----------------------------------------------------------------
    // Genesis (paper §3.6)
    // -----------------------------------------------------------------

    /// @notice Emitted by the genesis factory at the end of `execute()` once
    ///         all 13 steps have completed atomically.
    /// @param token           The deployed M² token address.
    /// @param treasury        The deployed treasury address.
    /// @param router          The deployed revenue router address.
    /// @param hook            The deployed V4 hook address (LP owner).
    /// @param vestingWallets  The set of OZ `VestingWallet` addresses created
    ///                        for the vesting allocation.
    event GenesisCompleted(
        address token,
        address treasury,
        address router,
        address hook,
        address[] vestingWallets
    );
}
