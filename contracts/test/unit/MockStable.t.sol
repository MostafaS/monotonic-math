// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {TestBase} from "../helpers/TestBase.sol";
import {MockStable} from "../../contracts/mocks/MockStable.sol";
import {M2Constants} from "../../contracts/libraries/M2Constants.sol";

/// @title MockStableTest
/// @notice Unit tests for the canonical test-only `MockStable` token.
///         Confirms ERC20 metadata pinned to `M2Constants.MOCK_STABLE_*` and
///         that the public test-only `mint` is unrestricted (as designed).
contract MockStableTest is TestBase {
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);

    MockStable internal s;

    function setUp() public {
        s = new MockStable();
    }

    // -----------------------------------------------------------------
    // Metadata
    // -----------------------------------------------------------------

    function test_NameSymbolDecimals() public view {
        assertEq(s.name(), M2Constants.MOCK_STABLE_NAME);
        assertEq(s.symbol(), M2Constants.MOCK_STABLE_SYMBOL);
        assertEq(uint256(s.decimals()), uint256(M2Constants.MOCK_STABLE_DECIMALS));
        assertEq(uint256(s.decimals()), 6);
        assertEq(s.name(), "Mock USD");
        assertEq(s.symbol(), "mUSD");
    }

    // -----------------------------------------------------------------
    // Public mint — test-only, unrestricted on purpose
    // -----------------------------------------------------------------

    function test_PublicMint_AffectsBalanceAndSupply() public {
        uint256 amt = 1_000_000 * 1e6;
        assertEq(s.balanceOf(ALICE), 0);
        assertEq(s.totalSupply(), 0);

        s.mint(ALICE, amt);

        assertEq(s.balanceOf(ALICE), amt);
        assertEq(s.totalSupply(), amt);
    }

    function test_PublicMint_AnyoneMayCall() public {
        // mint to ALICE while pretending to be BOB
        vm.prank(BOB);
        s.mint(ALICE, 42);
        assertEq(s.balanceOf(ALICE), 42);

        // mint to BOB while pretending to be ALICE
        vm.prank(ALICE);
        s.mint(BOB, 7);
        assertEq(s.balanceOf(BOB), 7);

        assertEq(s.totalSupply(), 49);
    }

    function test_PublicMint_AccumulatesAcrossCalls() public {
        s.mint(ALICE, 100);
        s.mint(ALICE, 250);
        s.mint(BOB, 50);
        assertEq(s.balanceOf(ALICE), 350);
        assertEq(s.balanceOf(BOB), 50);
        assertEq(s.totalSupply(), 400);
    }
}
