// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title IM2Treasury
/// @notice Passive custody contract for the backing stablecoin. The only
/// privileged outflow is `payRedemption`, callable only by the token contract.
/// No admin, no sweep, no upgrade, no pause.
interface IM2Treasury {
    /// @notice Transfer `stableAmount` of the backing stable to `user`.
    /// Callable only by the immutable token address. Reverts `OnlyToken`
    /// for any other caller. Uses SafeERC20.
    function payRedemption(address user, uint256 stableAmount) external;

    /// @notice Convenience view returning `stable.balanceOf(address(this))`.
    function backingBalance() external view returns (uint256);

    /// @notice No-op for off-chain indexers; emits `DirectInflowObserved`.
    /// Mutates no state; not authoritative.
    function notifyDirectInflow() external;

    /// @notice Immutable token contract address (the only caller of payRedemption).
    function token() external view returns (address);

    /// @notice Immutable backing stablecoin address.
    function stable() external view returns (address);
}
