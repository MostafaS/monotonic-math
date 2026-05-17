// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IM2Token} from "../interfaces/IM2Token.sol";
import {IM2Treasury} from "../interfaces/IM2Treasury.sol";
import {IM2Events} from "../libraries/M2Events.sol";
import {M2Constants} from "../libraries/M2Constants.sol";

/// @title MockHook — Phase 3 stand-in for M2V4Hook
/// @author M² / Monotonic Math
/// @notice TEST-ONLY companion to {MockAMM}. Owns the LP position via
///         {MockAMM} and exposes a permissionless `collectFees()` mirroring
///         the real {M2V4Hook} (paper §3.5). For Phase 3 the AMM is
///         {MockAMM} (constant-product, asymmetric fees); for Phase 4 this
///         contract is REPLACED by the real {M2V4Hook} driving the real V4
///         {PoolManager}. The external surface (`collectFees()` returning
///         `(stableOut, tokenOut)`) is preserved across the swap.
/// @dev    NOT deployed on any real network. The wiring (immutables, three
///         burn-authority enumeration on the token side, treasury one-way
///         flow) matches the real hook so that all four immutable contracts
///         remain real bytecode in the Phase 3 invariant suite.
contract MockHook is IM2Events {
    using SafeERC20 for IERC20;

    // -----------------------------------------------------------------
    // Errors
    // -----------------------------------------------------------------

    error ZeroAddress();

    // -----------------------------------------------------------------
    // Immutable wiring
    // -----------------------------------------------------------------

    /// @dev The mock AMM contract owning the LP position. Phase 4 replaces
    ///      this with the V4 PoolManager.
    IMockAMMDrain private immutable _AMM;
    /// @dev Backing stable.
    IERC20 private immutable _STABLE;
    /// @dev M² token. Used for the 99.75% burn on the token side.
    IM2Token private immutable _TOKEN;
    /// @dev Treasury. Receives 99.75% of stable-side fees.
    IM2Treasury private immutable _TREASURY;

    // -----------------------------------------------------------------
    // Constructor
    // -----------------------------------------------------------------

    constructor(
        address amm_,
        address stable_,
        address token_,
        address treasury_
    ) {
        if (
            amm_ == address(0) ||
            stable_ == address(0) ||
            token_ == address(0) ||
            treasury_ == address(0)
        ) revert ZeroAddress();
        _AMM = IMockAMMDrain(amm_);
        _STABLE = IERC20(stable_);
        _TOKEN = IM2Token(token_);
        _TREASURY = IM2Treasury(treasury_);
    }

    // -----------------------------------------------------------------
    // collectFees — permissionless (paper §3.5)
    // -----------------------------------------------------------------

    /// @notice Realize the AMM's accrued asymmetric-fee accumulators and
    ///         distribute per the 0.25% / 99.75% rule. Conservation:
    ///         `stableBounty + stableToTreasury == stableRealized`
    ///         `tokenBounty  + tokenBurned      == tokenRealized`
    ///         Enforced by subtraction (the residual cannot be stranded).
    /// @return stableRealized The full stable-side fee amount drained from AMM.
    /// @return tokenRealized  The full token-side fee amount drained from AMM.
    function collectFees()
        external
        returns (uint256 stableRealized, uint256 tokenRealized)
    {
        // Drain. After this call, this contract holds tokenRealized M² and
        // stableRealized stable received from the AMM.
        (tokenRealized, stableRealized) = _AMM.drainAccumulators(address(this));

        // Compute distribution. Floor-rounding the bounty is protocol-
        // protective (caller gets the floor share; protocol keeps the
        // residual).
        uint256 stableBounty = (stableRealized * M2Constants.CALLER_BOUNTY_BPS) /
            M2Constants.BPS_DENOMINATOR;
        uint256 stableToTreasury = stableRealized - stableBounty;
        uint256 tokenBounty = (tokenRealized * M2Constants.CALLER_BOUNTY_BPS) /
            M2Constants.BPS_DENOMINATOR;
        uint256 tokenToBurn = tokenRealized - tokenBounty;

        // Distribute stable side.
        if (stableBounty > 0) _STABLE.safeTransfer(msg.sender, stableBounty);
        if (stableToTreasury > 0) {
            _STABLE.safeTransfer(address(_TREASURY), stableToTreasury);
        }

        // Distribute token side. Token bounty transferred; rest burned via
        // the M2Token's three-role burn authority (hook is one of three).
        if (tokenBounty > 0) IERC20(address(_TOKEN)).safeTransfer(msg.sender, tokenBounty);
        if (tokenToBurn > 0) _TOKEN.burnFromAuthorized(address(this), tokenToBurn);

        emit FeesCollected(
            msg.sender,
            stableRealized,
            tokenRealized,
            stableBounty,
            tokenBounty,
            tokenToBurn,
            stableToTreasury
        );
    }

    // -----------------------------------------------------------------
    // View surface
    // -----------------------------------------------------------------

    function amm() external view returns (address) {
        return address(_AMM);
    }

    function stable() external view returns (address) {
        return address(_STABLE);
    }

    function token() external view returns (address) {
        return address(_TOKEN);
    }

    function treasury() external view returns (address) {
        return address(_TREASURY);
    }
}

/// @dev Minimal interface for the MockAMM drain entry point. Inlined so the
///      hook does not depend on the full MockAMM type (cleaner test surface).
interface IMockAMMDrain {
    function drainAccumulators(address recipient)
        external
        returns (uint256 tokenRealized, uint256 stableRealized);
}
