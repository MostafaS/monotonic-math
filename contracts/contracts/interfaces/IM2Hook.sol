// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title IM2Hook
/// @notice External surface of the M² V4 hook contract. The hook (a) implements
/// `IHooks.beforeSwap` with asymmetric dynamic fees (buy 0.10%, sell 3.00%),
/// (b) owns the V4 LP position permanently, (c) implements `IUnlockCallback`
/// for V4 flash-accounting, and (d) exposes `collectFees()`.
/// The full V4 hook interface lives in the uniswap/v4-core package; this
/// interface covers only the M²-specific external surface.
interface IM2Hook {
    /// @notice Realize accrued V4 fees: routes through `poolManager.unlock`,
    /// calls `modifyLiquidity(..., liquidityDelta: 0, ...)`, settles deltas,
    /// distributes the 0.25%-per-side caller bounty, sends 99.75% of the
    /// stable-side to treasury, burns 99.75% of the token-side.
    /// Permissionless.
    function collectFees() external returns (uint256 stableOut, uint256 tokenOut);

    /// @notice Immutable M² token.
    function token() external view returns (address);

    /// @notice Immutable backing stablecoin.
    function stable() external view returns (address);

    /// @notice Immutable treasury.
    function treasury() external view returns (address);

    /// @notice Immutable V4 PoolManager.
    function poolManager() external view returns (address);
}
