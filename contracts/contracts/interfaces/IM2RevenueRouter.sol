// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title IM2RevenueRouter
/// @notice Single-function revenue router. Pulls `stableAmount` from the
/// immutable depositor, deposits `floor(stableAmount / 2)` into the treasury,
/// uses the remainder (`ceil(stableAmount / 2)`) to buy M² from the V4 LP,
/// and burns the tokens received. Reverts on `tokensReceived < minTokensOut`.
interface IM2RevenueRouter {
    /// @notice Route business revenue per the 50/50 split. Depositor-only.
    /// @param stableAmount Amount of backing stable to route.
    /// @param minTokensOut Minimum tokens that must be received from the
    /// protocol buy; defense-in-depth slippage check.
    /// @return treasuryIn Stable amount sent to treasury (floor half).
    /// @return stableUsedForBuy Stable amount used for the protocol buy (ceil half).
    /// @return tokensBurned Tokens received and burned in the same tx.
    function routeRevenue(uint256 stableAmount, uint256 minTokensOut)
        external
        returns (uint256 treasuryIn, uint256 stableUsedForBuy, uint256 tokensBurned);

    /// @notice Immutable backing stablecoin.
    function stable() external view returns (address);

    /// @notice Immutable M² token.
    function token() external view returns (address);

    /// @notice Immutable treasury.
    function treasury() external view returns (address);

    /// @notice Immutable authorized depositor (only caller of routeRevenue).
    function depositor() external view returns (address);

    /// @notice Immutable V4 PoolManager.
    function poolManager() external view returns (address);

    /// @notice Immutable V4 hook contract owning the LP.
    function hook() external view returns (address);
}
