// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IM2Treasury} from "../interfaces/IM2Treasury.sol";
import {M2Errors} from "../libraries/M2Errors.sol";
import {IM2Events} from "../libraries/M2Events.sol";

/// @title M2Treasury — Passive stable-coin custody for the M² protocol
/// @author M² / Monotonic Math
/// @notice Holds the backing stablecoin. The ONLY privileged outflow is
///         `payRedemption`, callable only by the immutable token address.
///         No admin withdraw, no sweep, no rescue, no pause, no upgrade.
/// @dev    NO inheritance of Ownable / AccessControl / Pausable / UUPSUpgradeable.
///         All stable transfers use OZ SafeERC20 to tolerate non-standard
///         ERC20 return conventions (e.g. USDT).
contract M2Treasury is IM2Treasury, IM2Events {
    using SafeERC20 for IERC20;

    // -----------------------------------------------------------------
    // Immutable state (paper §3.3 — passive custody)
    // -----------------------------------------------------------------

    /// @dev The backing stablecoin held by this contract.
    IERC20 private immutable _STABLE;

    /// @dev The immutable M² token contract — the SOLE authorized caller of
    ///      `payRedemption`.
    address private immutable _TOKEN;

    // -----------------------------------------------------------------
    // Constructor
    // -----------------------------------------------------------------

    /// @notice Deploy the treasury bound to a stable and a token address.
    /// @param stable_ Backing ERC-20 stablecoin (non-rebasing).
    /// @param token_  Immutable M² token contract; only authorized caller of
    ///                `payRedemption`.
    constructor(address stable_, address token_) {
        if (stable_ == address(0) || token_ == address(0)) {
            revert M2Errors.ZeroAddress();
        }
        _STABLE = IERC20(stable_);
        _TOKEN = token_;
    }

    // -----------------------------------------------------------------
    // External: redemption payout (token-only)
    // -----------------------------------------------------------------

    /// @inheritdoc IM2Treasury
    /// @dev Reverts `OnlyToken` for any caller other than `_TOKEN`. Uses
    ///      SafeERC20.safeTransfer to tolerate ERC20s that return no boolean.
    function payRedemption(address user, uint256 stableAmount) external {
        if (msg.sender != _TOKEN) revert M2Errors.OnlyToken();
        _STABLE.safeTransfer(user, stableAmount);
        emit RedemptionPaid(user, stableAmount);
    }

    // -----------------------------------------------------------------
    // External: views and indexer convenience
    // -----------------------------------------------------------------

    /// @inheritdoc IM2Treasury
    function backingBalance() external view returns (uint256) {
        return _STABLE.balanceOf(address(this));
    }

    /// @inheritdoc IM2Treasury
    /// @dev Pure event emitter for off-chain indexers. Mutates no state and
    ///      is not authoritative; direct inflows (revenue router, hook fee
    ///      forwarding) are already observable via this contract's stable
    ///      balance changes.
    function notifyDirectInflow() external {
        emit DirectInflowObserved(_STABLE.balanceOf(address(this)));
    }

    /// @inheritdoc IM2Treasury
    function token() external view returns (address) {
        return _TOKEN;
    }

    /// @inheritdoc IM2Treasury
    function stable() external view returns (address) {
        return address(_STABLE);
    }
}
