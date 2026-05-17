// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title M2Errors
/// @author M² / Monotonic Math
/// @notice Centralized custom errors for the M² protocol. Custom errors are
///         used in preference to `require(..., "string")` for gas efficiency
///         and ABI clarity. Importers reference these as
///         `M2Errors.SupplyExhausted.selector` (or equivalent) in tests.
/// @dev    Declared in a library so each contract can `using` or
///         fully-qualify them. Errors are addressed by selector at the ABI
///         level, so the library has zero runtime cost.
library M2Errors {
    // -----------------------------------------------------------------
    // Shared wiring errors (used across token, treasury, router, hook)
    // -----------------------------------------------------------------

    /// @notice Thrown by any constructor when a wiring address is zero.
    ///         Centralized here so all four immutable contracts share the
    ///         same selector for zero-address rejection.
    error ZeroAddress();

    // -----------------------------------------------------------------
    // Token (paper §3.2)
    // -----------------------------------------------------------------

    /// @notice Thrown by `redeem` and `floorPrice` when total supply is 0.
    ///         Paper Lemma 4.2 attaches the revert to the "next `floorPrice`
    ///         call"; both entry points enforce the boundary.
    error SupplyExhausted();

    /// @notice Thrown when a state-mutating call is invoked with a
    ///         zero-amount argument that would otherwise be a no-op.
    error ZeroAmount();

    /// @notice Thrown when a non-authorized address calls a token-burn
    ///         entry point. Paper §3.2 enumerates exactly three burn roles:
    ///         hook, router, self (`redeem`).
    error UnauthorizedBurner();

    /// @notice Thrown when the constructor receives a backing stable with
    ///         `decimals() > MAX_STABLE_DECIMALS`. Paper §3.2 overflow bound.
    error DecimalsOutOfRange();

    // -----------------------------------------------------------------
    // Treasury (paper §3.3)
    // -----------------------------------------------------------------

    /// @notice Thrown when any caller other than the token contract attempts
    ///         to invoke `payRedemption`.
    error OnlyToken();

    /// @notice Thrown when the treasury balance is too low to satisfy a
    ///         redemption payout (should be unreachable under the floor
    ///         invariant; included as a defense-in-depth check).
    error InsufficientBalance();

    // -----------------------------------------------------------------
    // Router (paper §3.5)
    // -----------------------------------------------------------------

    /// @notice Thrown when any caller other than the immutable `depositor`
    ///         attempts to invoke `routeRevenue`.
    error UnauthorizedDepositor();

    /// @notice Thrown when the buy-and-burn leg of `routeRevenue` receives
    ///         fewer tokens than the caller-provided `minTokensOut`. Defense
    ///         in depth against sandwiching of the protocol buy.
    error SlippageExceeded();

    /// @notice Thrown by `unlockCallback` when a V4 swap returns a
    ///         `BalanceDelta` with the wrong sign for either side (router
    ///         debit must be nonpositive on the stable side and router credit
    ///         must be nonnegative on the token side).
    error UnexpectedSwapSign();

    // -----------------------------------------------------------------
    // Hook (paper §3.4 / §3.5)
    // -----------------------------------------------------------------

    /// @notice Thrown by `unlockCallback` when the caller is not the
    ///         configured V4 PoolManager.
    error OnlyPoolManager();

    /// @notice Thrown by the hook's constructor when
    ///         `LPFeeLibrary.MAX_LP_FEE != M2Constants.V4_MAX_LP_FEE`.
    ///         Locks the V4 fee-unit assumption at deploy time.
    error FeeUnitChanged();

    /// @notice Thrown when the hook is invoked against a pool that does
    ///         not pair the protocol's token and configured backing stable.
    error InvalidPool();

    // -----------------------------------------------------------------
    // Genesis (paper §3.6)
    // -----------------------------------------------------------------

    /// @notice Thrown by the factory when the genesis floor-spot constraint
    ///         `T0 * Lt0 == Ls0 * S0` (paper eq. 12) is violated.
    error GenesisConstraintViolated();

    /// @notice Thrown by the factory when `GenesisParams.hookCreationCode` is
    ///         a zero-length byte array. Distinct from {ZeroAddress} so a
    ///         confused operator gets a signal-specific revert reason
    ///         instead of a misleading "zero address" message.
    error EmptyHookCreationCode();
}
