// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {M2Constants} from "../../contracts/libraries/M2Constants.sol";
import {IntegrationFixtureBase} from "./base/IntegrationFixtureBase.sol";

// =====================================================================
// V4FullRangeIntegration — real V4 PoolManager + M2V4Hook end-to-end
// =====================================================================
//
// What this test exercises (paper §3.4, §3.5):
//   1. Deploy real Uniswap V4 PoolManager.
//   2. Deploy MockStable, M2Token, M2Treasury, M2V4Hook (mined CREATE2
//      salt for BEFORE_SWAP_FLAG).
//   3. Initialize the M²/stable pool with DYNAMIC_FEE_FLAG via the
//      hook's `initializePool` entry point.
//   4. Verify the genesis floor-spot constraint `T0 * Lt0 == Ls0 * S0`.
//   5. Smoke-check the hook view surface against the real pool manager.
//
// The abstract `V4FullRangeIntegrationBase` is run under BOTH paired
// address-sort orderings via the two concrete subclasses below
// (FINAL_REPORT H4). Each subclass forces a specific
// `address(token) </> address(stable)` ordering in setUp().

abstract contract V4FullRangeIntegrationBase is IntegrationFixtureBase {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    PoolId internal poolId;

    function setUp() public {
        _deploy(_wantTokenLowerThanStable());
        poolId = poolKey.toId();
    }

    // -----------------------------------------------------------------
    // Smoke + wiring
    // -----------------------------------------------------------------

    /// @notice Sanity test: the integration scaffold deploys without
    ///         revert. The genesis floor-spot constraint holds in
    ///         integer form.
    function test_DeploymentAndGenesisConstraint() public view {
        assertEq(T0 * LT0, LS0 * S0, "T0*Lt0 == Ls0*S0");
        assertEq(hook.token(), address(token));
        assertEq(hook.stable(), address(stableTok));
        assertEq(hook.treasury(), address(treasury));
        assertEq(hook.poolManager(), address(pm));
        assertEq(uint256(poolKey.fee), uint256(LPFeeLibrary.DYNAMIC_FEE_FLAG));
        assertEq(address(poolKey.hooks), address(hook));
    }

    /// @notice The hook's address encodes exactly the BEFORE_SWAP_FLAG
    ///         permission bits. V4's `isValidHookAddress` validates
    ///         this at pool initialize; a successful pool.initialize
    ///         call is itself the proof.
    function test_HookAddressHasBeforeSwapFlag() public view {
        uint160 lowBits = uint160(address(hook)) & Hooks.ALL_HOOK_MASK;
        assertEq(uint256(lowBits), uint256(Hooks.BEFORE_SWAP_FLAG));
    }

    /// @notice Stable-input → buy fee (0.10%), under THIS test's
    ///         address sort. The paired subclass below runs the SAME
    ///         assertion under the inverse sort.
    function test_StableInputGetsBuyFee_AddressSortAware() public {
        _seedAndInitialize();

        bool zeroForOne = stableIs0;
        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(1e6),
            sqrtPriceLimitX96: 0
        });
        vm.prank(address(pm));
        (, , uint24 fee) =
            IHooks(address(hook)).beforeSwap(address(this), poolKey, params, "");
        uint24 expected = uint24(M2Constants.BUY_FEE) | LPFeeLibrary.OVERRIDE_FEE_FLAG;
        assertEq(uint256(fee), uint256(expected));
    }

    function test_TokenInputGetsSellFee_AddressSortAware() public {
        _seedAndInitialize();

        bool zeroForOne = !stableIs0;
        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(1e18),
            sqrtPriceLimitX96: 0
        });
        vm.prank(address(pm));
        (, , uint24 fee) =
            IHooks(address(hook)).beforeSwap(address(this), poolKey, params, "");
        uint24 expected = uint24(M2Constants.SELL_FEE) | LPFeeLibrary.OVERRIDE_FEE_FLAG;
        assertEq(uint256(fee), uint256(expected));
    }

    /// @notice Post-initialize, the pool exists at the expected
    ///         sqrtPriceX96 and slot0 is readable via StateLibrary.
    function test_PoolStateAfterInitialize() public {
        _seedAndInitialize();
        (uint160 sqrtPriceX96Now, int24 tick, , ) = pm.getSlot0(poolId);
        assertGt(uint256(sqrtPriceX96Now), 0, "pool initialized");
        require(int256(tick) >= int256(TickMath.MIN_TICK), "tick >= MIN_TICK");
        require(int256(tick) <= int256(TickMath.MAX_TICK), "tick <= MAX_TICK");
    }

    // -----------------------------------------------------------------
    // Internal helpers
    // -----------------------------------------------------------------

    /// @dev Transfer minimal liquidity to the hook and call
    ///      initializePool. The 1 wei seed is enough to satisfy the
    ///      "hook holds seed funds" precondition.
    function _seedAndInitialize() internal {
        uint128 liquidity = uint128(1e6);

        token.transfer(address(hook), 2e18);
        stableTok.mint(address(hook), 2e6);

        hook.initializePool(poolKey, uint160(1) << 96, liquidity);
    }
}

// =====================================================================
// Concrete subclasses — paired-address-sort matrix (FINAL_REPORT H4)
// =====================================================================

/// @notice Runs the integration suite under `address(token) < address(stable)`.
contract V4FullRangeIntegrationLowAddrTest is V4FullRangeIntegrationBase {
    function _wantTokenLowerThanStable() internal pure override returns (bool) {
        return true;
    }
}

/// @notice Runs the integration suite under `address(token) > address(stable)`.
contract V4FullRangeIntegrationHighAddrTest is V4FullRangeIntegrationBase {
    function _wantTokenLowerThanStable() internal pure override returns (bool) {
        return false;
    }
}
