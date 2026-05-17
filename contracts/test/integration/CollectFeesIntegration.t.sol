// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

import {IntegrationFixtureBase} from "./base/IntegrationFixtureBase.sol";

// =====================================================================
// CollectFeesIntegration — deep coverage of collectFees end-to-end
// =====================================================================
//
// Coverage (paper §3.5, §4.1 Case 7):
//   - Hook permissions match BEFORE_SWAP_FLAG exactly.
//   - Permissionless: bytecode does not embed an `onlyOwner` /
//     `transferOwnership` / `pause` selector.
//   - Genesis floor-spot constraint intact.
//   - Hook wiring against the real V4 PoolManager.
//
// The fine-grained distribution / conservation / floor-monotonicity
// math is exercised in M2V4Hook.t.sol against a mock PoolManager
// (where we can drive arbitrary accrual values). This file's role is
// the wiring smoke check against the real V4 PoolManager + an audit
// of the deployed bytecode for forbidden ownership/pause selectors.
//
// The abstract `CollectFeesIntegrationBase` runs under BOTH paired
// address-sort orderings via the two concrete subclasses below
// (FINAL_REPORT H4).

abstract contract CollectFeesIntegrationBase is IntegrationFixtureBase {
    address internal constant CALLER_A = address(0xCAFE1);
    address internal constant CALLER_B = address(0xCAFE2);

    function setUp() public {
        _deploy(_wantTokenLowerThanStable());

        // Seed minimal LP so `initializePool` succeeds.
        token.transfer(address(hook), 2e18);
        stableTok.mint(address(hook), 2e6);
        hook.initializePool(poolKey, uint160(1) << 96, uint128(1e6));
    }

    // -----------------------------------------------------------------
    // Wiring smoke checks
    // -----------------------------------------------------------------

    function test_HookExposesCollectFees() public view {
        assertEq(hook.poolManager(), address(pm));
        assertEq(hook.token(), address(token));
        assertEq(hook.stable(), address(stableTok));
        assertEq(hook.treasury(), address(treasury));
    }

    /// @notice Bytecode audit: the hook MUST NOT expose any
    ///         ownership / pause / upgrade-style selectors.
    function test_CollectFeesIsPermissionless_BytecodeAudit() public view {
        bytes memory code = address(hook).code;
        bytes4[5] memory forbidden = [
            bytes4(keccak256("owner()")),
            bytes4(keccak256("transferOwnership(address)")),
            bytes4(keccak256("renounceOwnership()")),
            bytes4(keccak256("acceptOwnership()")),
            bytes4(keccak256("pause()"))
        ];
        for (uint256 i = 0; i < forbidden.length; ++i) {
            assertFalse(
                _bytecodeContainsSelector(code, forbidden[i]),
                "hook bytecode contains a forbidden ownership/pause selector"
            );
        }
    }

    /// @notice Genesis floor-spot constraint holds in integer form.
    function test_GenesisConstraintIntact() public pure {
        assertEq(T0 * LT0, LS0 * S0, "T0 * Lt0 == Ls0 * S0");
    }

    /// @notice The hook's flag address has BEFORE_SWAP_FLAG and no
    ///         other flag bits.
    function test_HookPermissionFlags() public view {
        uint160 lowBits = uint160(address(hook)) & Hooks.ALL_HOOK_MASK;
        assertEq(uint256(lowBits), uint256(Hooks.BEFORE_SWAP_FLAG));
        assertEq(uint256(lowBits & ~Hooks.BEFORE_SWAP_FLAG), 0, "no other flags set");
    }

    /// @notice `collectFees` is callable with zero accrued fees and is
    ///         a no-op (no revert, no state change).
    function test_CollectFeesNoFees_NoOp() public {
        uint256 sBefore = stableTok.balanceOf(address(treasury));
        uint256 supBefore = token.totalSupply();
        uint256 cABefore = stableTok.balanceOf(CALLER_A);
        uint256 cBTBefore = token.balanceOf(CALLER_A);

        vm.prank(CALLER_A);
        (uint256 sOut, uint256 tOut) = hook.collectFees();

        assertEq(sOut, 0, "no stable fees accrued");
        assertEq(tOut, 0, "no token fees accrued");
        assertEq(stableTok.balanceOf(address(treasury)), sBefore);
        assertEq(token.totalSupply(), supBefore);
        assertEq(stableTok.balanceOf(CALLER_A), cABefore);
        assertEq(token.balanceOf(CALLER_A), cBTBefore);
    }

    /// @notice Anyone can call collectFees — verified by calling from
    ///         multiple distinct addresses.
    function test_AnyoneCanCallCollectFees() public {
        vm.prank(CALLER_A);
        hook.collectFees();
        vm.prank(CALLER_B);
        hook.collectFees();
        vm.prank(address(this));
        hook.collectFees();
    }

    // -----------------------------------------------------------------
    // Internal helper
    // -----------------------------------------------------------------

    function _bytecodeContainsSelector(bytes memory code, bytes4 selector)
        internal
        pure
        returns (bool)
    {
        if (code.length < 4) return false;
        bytes1 s0 = bytes1(selector);
        bytes1 s1 = bytes1(selector << 8);
        bytes1 s2 = bytes1(selector << 16);
        bytes1 s3 = bytes1(selector << 24);
        uint256 end = code.length - 3;
        for (uint256 i = 0; i < end; i++) {
            if (
                code[i] == s0 &&
                code[i + 1] == s1 &&
                code[i + 2] == s2 &&
                code[i + 3] == s3
            ) {
                return true;
            }
        }
        return false;
    }
}

// =====================================================================
// Concrete subclasses — paired-address-sort matrix (FINAL_REPORT H4)
// =====================================================================

contract CollectFeesIntegrationLowAddrTest is CollectFeesIntegrationBase {
    function _wantTokenLowerThanStable() internal pure override returns (bool) {
        return true;
    }
}

contract CollectFeesIntegrationHighAddrTest is CollectFeesIntegrationBase {
    function _wantTokenLowerThanStable() internal pure override returns (bool) {
        return false;
    }
}
