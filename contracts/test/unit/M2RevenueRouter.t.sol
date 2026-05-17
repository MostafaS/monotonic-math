// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

import {TestBase} from "../helpers/TestBase.sol";
import {M2RevenueRouter} from "../../contracts/router/M2RevenueRouter.sol";
import {MockStable} from "../../contracts/mocks/MockStable.sol";
import {M2Errors} from "../../contracts/libraries/M2Errors.sol";

// =====================================================================
// Test-only mocks
// =====================================================================
//
// All mocks here are PHASE-2 STRUCTURAL stubs. They are intentionally
// minimal: just enough to exercise the router's depositor check, split
// arithmetic, slippage path, callback access control, and constructor
// validation. Real V4 PoolManager integration lands in Phase 4 (Phase 3
// tests against MockAMM).
//
// We deliberately do NOT inherit `IPoolManager` on the stub: implementing
// the full interface would require stubbing IERC6909Claims, IProtocolFees,
// IExtsload, IExttload, and many state-modifying functions that this
// phase's tests do not exercise. Instead, the router takes `address` in
// its constructor and casts internally; the stub only needs concrete
// functions matching the signatures the router actually calls.
// =====================================================================

/// @notice Minimal mock M² token used solely to (a) accept the router's
///         burn call and (b) be addressable as one of the pool's two
///         currencies. Mint is unrestricted for fixture setup.
contract MockM2Token is ERC20 {
    constructor() ERC20("Mock M2", "mM2") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @notice Mirrors `IM2Token.burnFromAuthorized`. The router-side check
    ///         that the caller is one of three burn authorities lives in the
    ///         real M2Token; here we accept any caller for fixture purposes.
    function burnFromAuthorized(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

/// @notice Minimal V4 PoolManager stub. Implements only the surface the
///         router invokes: `unlock`, `swap`, `sync`, `settle`, `take`.
///         All other V4 functions are absent — calling them would revert
///         with `function selector not found`.
///
///         Behavior:
///           - `unlock(data)` calls back `IUnlockCallback(msg.sender)`.
///           - `swap(...)` returns a configurable BalanceDelta. The test
///             sets `configuredTokensOut` and the stub mints the matching
///             stable debit / token credit.
///           - `sync` is a no-op.
///           - `settle` returns 0 (the test verifies the router actually
///             transferred stable to the stub by reading post-tx balances).
///           - `take(currency, to, amount)` transfers `amount` of `currency`
///             from the stub to `to` (pre-funded by the test).
contract MockPoolManagerStub {
    uint256 public configuredTokensOut;
    bool public stableIs0;
    address public stableAddr;
    address public tokenAddr;

    /// @notice Whether `unlockCallback` has been entered (used to assert
    ///         the router actually invoked the V4 lock flow).
    bool public callbackEntered;

    /// @notice Counters for V4 settlement-flow methods, used by tests to
    ///         verify the router executed every step of the unlock/swap/
    ///         settle/take cycle.
    uint256 public syncCalls;
    uint256 public settleCalls;
    uint256 public takeCalls;

    constructor(address stableAddr_, address tokenAddr_, bool stableIs0_) {
        stableAddr = stableAddr_;
        tokenAddr = tokenAddr_;
        stableIs0 = stableIs0_;
    }

    function setConfiguredTokensOut(uint256 v) external {
        configuredTokensOut = v;
    }

    // -- IPoolManager surface used by the router ----------------------

    function unlock(bytes calldata data) external returns (bytes memory) {
        callbackEntered = true;
        return IUnlockCallback(msg.sender).unlockCallback(data);
    }

    function swap(
        PoolKey memory /* key */,
        SwapParams memory params,
        bytes calldata /* hookData */
    ) external view returns (BalanceDelta) {
        // The router always submits exactInput of stable (negative
        // amountSpecified). The stub returns a BalanceDelta with the router
        // debited on the stable side and credited on the token side.
        require(params.amountSpecified < 0, "stub: only exact-input");
        uint256 stableIn = uint256(-params.amountSpecified);
        require(stableIn <= uint256(uint128(type(int128).max)), "stub: overflow");

        int128 stableDelta = -int128(uint128(stableIn));
        int128 tokenDelta = int128(uint128(configuredTokensOut));

        if (stableIs0) {
            // stable -> currency0, token -> currency1
            return toBalanceDelta(stableDelta, tokenDelta);
        } else {
            // stable -> currency1, token -> currency0
            return toBalanceDelta(tokenDelta, stableDelta);
        }
    }

    function sync(Currency /* currency */) external {
        syncCalls += 1;
    }

    function settle() external payable returns (uint256) {
        settleCalls += 1;
        return 0;
    }

    function take(Currency currency, address to, uint256 amount) external {
        takeCalls += 1;
        // Transfer pre-funded tokens out of the stub to mirror real V4 take.
        ERC20(Currency.unwrap(currency)).transfer(to, amount);
    }
}

// =====================================================================
// M2RevenueRouter unit tests (Phase 2 — STRUCTURAL only)
// =====================================================================

contract M2RevenueRouterTest is TestBase {
    // ---- Actors ------------------------------------------------------

    address internal constant DEPOSITOR = address(0xDE9051704);
    address internal constant TREASURY = address(0x7e459074); // EOA stand-in
    address internal constant HOOK = address(0xC0DE1);
    address internal constant ATTACKER = address(0xBAD);

    // ---- Fixtures ----------------------------------------------------

    MockStable internal stableTok;
    MockM2Token internal m2;
    MockPoolManagerStub internal pm;
    M2RevenueRouter internal router;
    bool internal stableIs0;
    PoolKey internal poolKey;

    // ---- Setup -------------------------------------------------------

    function setUp() public {
        stableTok = new MockStable();
        m2 = new MockM2Token();

        // Determine address sort once; the rest of the test logic flows
        // from this flag.
        stableIs0 = address(stableTok) < address(m2);

        pm = new MockPoolManagerStub(address(stableTok), address(m2), stableIs0);

        poolKey = PoolKey({
            currency0: stableIs0
                ? Currency.wrap(address(stableTok))
                : Currency.wrap(address(m2)),
            currency1: stableIs0
                ? Currency.wrap(address(m2))
                : Currency.wrap(address(stableTok)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(HOOK)
        });

        router = new M2RevenueRouter(
            address(stableTok),
            address(m2),
            TREASURY,
            DEPOSITOR,
            address(pm),
            HOOK,
            poolKey
        );

        // Default: stub will deliver 1e21 M² for any stable amount.
        pm.setConfiguredTokensOut(1e21);

        // Pre-fund the pool-manager stub with M² tokens so `take` can
        // transfer them out to the router.
        m2.mint(address(pm), 1_000_000_000 * 1e18);

        // Pre-fund the depositor with stable and have them approve the router.
        stableTok.mint(DEPOSITOR, 1_000_000_000 * 1e6);
        vm.prank(DEPOSITOR);
        stableTok.approve(address(router), type(uint256).max);
    }

    // -----------------------------------------------------------------
    // Constructor reverts
    // -----------------------------------------------------------------

    function test_ConstructorRevertsOnZeroStable() public {
        vm.expectRevert(M2Errors.ZeroAddress.selector);
        new M2RevenueRouter(
            address(0),
            address(m2),
            TREASURY,
            DEPOSITOR,
            address(pm),
            HOOK,
            poolKey
        );
    }

    function test_ConstructorRevertsOnZeroToken() public {
        vm.expectRevert(M2Errors.ZeroAddress.selector);
        new M2RevenueRouter(
            address(stableTok),
            address(0),
            TREASURY,
            DEPOSITOR,
            address(pm),
            HOOK,
            poolKey
        );
    }

    function test_ConstructorRevertsOnZeroTreasury() public {
        vm.expectRevert(M2Errors.ZeroAddress.selector);
        new M2RevenueRouter(
            address(stableTok),
            address(m2),
            address(0),
            DEPOSITOR,
            address(pm),
            HOOK,
            poolKey
        );
    }

    function test_ConstructorRevertsOnZeroDepositor() public {
        vm.expectRevert(M2Errors.ZeroAddress.selector);
        new M2RevenueRouter(
            address(stableTok),
            address(m2),
            TREASURY,
            address(0),
            address(pm),
            HOOK,
            poolKey
        );
    }

    function test_ConstructorRevertsOnZeroPoolManager() public {
        vm.expectRevert(M2Errors.ZeroAddress.selector);
        new M2RevenueRouter(
            address(stableTok),
            address(m2),
            TREASURY,
            DEPOSITOR,
            address(0),
            HOOK,
            poolKey
        );
    }

    function test_ConstructorRevertsOnZeroHook() public {
        vm.expectRevert(M2Errors.ZeroAddress.selector);
        new M2RevenueRouter(
            address(stableTok),
            address(m2),
            TREASURY,
            DEPOSITOR,
            address(pm),
            address(0),
            poolKey
        );
    }

    /// @notice Pool key's hook must match the configured hook address.
    function test_ConstructorRevertsOnHookMismatch() public {
        PoolKey memory bad = poolKey;
        bad.hooks = IHooks(address(0xBEEF));
        vm.expectRevert(M2Errors.InvalidPool.selector);
        new M2RevenueRouter(
            address(stableTok),
            address(m2),
            TREASURY,
            DEPOSITOR,
            address(pm),
            HOOK,
            bad
        );
    }

    /// @notice Pool fee field must be the DYNAMIC_FEE_FLAG sentinel.
    function test_PoolKeyHasDynamicFeeFlag() public {
        PoolKey memory bad = poolKey;
        bad.fee = 3000; // static 0.30% pool — invalid for the protocol
        vm.expectRevert(M2Errors.InvalidPool.selector);
        new M2RevenueRouter(
            address(stableTok),
            address(m2),
            TREASURY,
            DEPOSITOR,
            address(pm),
            HOOK,
            bad
        );
    }

    /// @notice A static fee with the high bit set is also invalid: the V4
    ///         convention requires `fee == DYNAMIC_FEE_FLAG` exactly.
    function test_ConstructorRevertsOnHighBitSetButNotDynamic() public {
        PoolKey memory bad = poolKey;
        // 0x800001 has the dynamic-fee bit set BUT is not exactly the flag.
        bad.fee = LPFeeLibrary.DYNAMIC_FEE_FLAG | uint24(1);
        vm.expectRevert(M2Errors.InvalidPool.selector);
        new M2RevenueRouter(
            address(stableTok),
            address(m2),
            TREASURY,
            DEPOSITOR,
            address(pm),
            HOOK,
            bad
        );
    }

    /// @notice Pool currencies must be exactly {token, stable} in some order.
    function test_ConstructorRevertsOnUnrelatedCurrencies() public {
        PoolKey memory bad = poolKey;
        bad.currency0 = Currency.wrap(address(0xDEADBEEF));
        bad.currency1 = Currency.wrap(address(0xC0FFEE));
        vm.expectRevert(M2Errors.InvalidPool.selector);
        new M2RevenueRouter(
            address(stableTok),
            address(m2),
            TREASURY,
            DEPOSITOR,
            address(pm),
            HOOK,
            bad
        );
    }

    // -----------------------------------------------------------------
    // Constructor success
    // -----------------------------------------------------------------

    function test_ConstructorWiring() public view {
        assertEq(router.stable(), address(stableTok));
        assertEq(router.token(), address(m2));
        assertEq(router.treasury(), TREASURY);
        assertEq(router.depositor(), DEPOSITOR);
        assertEq(router.poolManager(), address(pm));
        assertEq(router.hook(), HOOK);
        assertEq(router.stableIsCurrency0(), stableIs0);

        PoolKey memory k = router.poolKey();
        assertEq(uint256(k.fee), uint256(LPFeeLibrary.DYNAMIC_FEE_FLAG));
        assertEq(address(k.hooks), HOOK);
    }

    // -----------------------------------------------------------------
    // routeRevenue — access control
    // -----------------------------------------------------------------

    function test_OnlyDepositorCanCall() public {
        vm.prank(ATTACKER);
        vm.expectRevert(M2Errors.UnauthorizedDepositor.selector);
        router.routeRevenue(1_000_000, 0);
    }

    function test_OnlyDepositorCanCall_TreasuryNotAllowed() public {
        vm.prank(TREASURY);
        vm.expectRevert(M2Errors.UnauthorizedDepositor.selector);
        router.routeRevenue(1_000_000, 0);
    }

    function test_OnlyDepositorCanCall_HookNotAllowed() public {
        vm.prank(HOOK);
        vm.expectRevert(M2Errors.UnauthorizedDepositor.selector);
        router.routeRevenue(1_000_000, 0);
    }

    // -----------------------------------------------------------------
    // routeRevenue — zero amount
    // -----------------------------------------------------------------

    function test_RoutesZeroReverts() public {
        vm.prank(DEPOSITOR);
        vm.expectRevert(M2Errors.ZeroAmount.selector);
        router.routeRevenue(0, 0);
    }

    // -----------------------------------------------------------------
    // routeRevenue — split arithmetic
    // -----------------------------------------------------------------

    function test_SplitFloorCeil_Even() public {
        uint256 amt = 1_000_000; // even
        pm.setConfiguredTokensOut(1e18);

        uint256 treasuryBefore = stableTok.balanceOf(TREASURY);
        vm.prank(DEPOSITOR);
        (uint256 treasuryIn, uint256 stableUsedForBuy, uint256 tokensBurned) =
            router.routeRevenue(amt, 0);

        assertEq(treasuryIn, 500_000);
        assertEq(stableUsedForBuy, 500_000);
        assertEq(treasuryIn + stableUsedForBuy, amt);
        assertEq(tokensBurned, 1e18);
        assertEq(stableTok.balanceOf(TREASURY) - treasuryBefore, 500_000);
    }

    function test_SplitFloorCeil_Odd() public {
        uint256 amt = 1_000_001; // odd
        pm.setConfiguredTokensOut(1e18);

        uint256 treasuryBefore = stableTok.balanceOf(TREASURY);
        vm.prank(DEPOSITOR);
        (uint256 treasuryIn, uint256 stableUsedForBuy, ) =
            router.routeRevenue(amt, 0);

        // Paper §3.5: floor-to-treasury, ceil-to-buy.
        assertEq(treasuryIn, 500_000);
        assertEq(stableUsedForBuy, 500_001);
        assertEq(treasuryIn + stableUsedForBuy, amt);
        assertEq(stableTok.balanceOf(TREASURY) - treasuryBefore, 500_000);
    }

    function test_SplitFloorCeil_One() public {
        uint256 amt = 1;
        pm.setConfiguredTokensOut(1);

        vm.prank(DEPOSITOR);
        (uint256 treasuryIn, uint256 stableUsedForBuy, ) =
            router.routeRevenue(amt, 0);

        assertEq(treasuryIn, 0);
        assertEq(stableUsedForBuy, 1);
    }

    // -----------------------------------------------------------------
    // routeRevenue — treasury half
    // -----------------------------------------------------------------

    function test_TreasuryHalfTransferred() public {
        uint256 amt = 10_000_000; // 10 stable
        pm.setConfiguredTokensOut(1e18);

        uint256 treasuryBefore = stableTok.balanceOf(TREASURY);
        vm.prank(DEPOSITOR);
        router.routeRevenue(amt, 0);
        uint256 treasuryAfter = stableTok.balanceOf(TREASURY);

        assertEq(treasuryAfter - treasuryBefore, amt / 2);
    }

    // -----------------------------------------------------------------
    // routeRevenue — pull stable + burn token
    // -----------------------------------------------------------------

    function test_PullsCorrectAllowance() public {
        uint256 amt = 100_000;
        pm.setConfiguredTokensOut(1e18);

        uint256 depositorBefore = stableTok.balanceOf(DEPOSITOR);
        uint256 m2SupplyBefore = m2.totalSupply();

        vm.prank(DEPOSITOR);
        (uint256 treasuryIn, uint256 stableUsedForBuy, uint256 tokensBurned) =
            router.routeRevenue(amt, 0);

        assertEq(stableTok.balanceOf(DEPOSITOR), depositorBefore - amt);
        assertEq(treasuryIn + stableUsedForBuy, amt);
        assertEq(tokensBurned, 1e18);
        // The bought tokens are burned, so total supply must drop by the
        // exact amount the stub credited the router.
        assertEq(m2.totalSupply(), m2SupplyBefore - 1e18);
        // Router holds nothing post-tx.
        assertEq(stableTok.balanceOf(address(router)), 0);
        assertEq(m2.balanceOf(address(router)), 0);
    }

    /// @notice Confirms the router actually walked the V4 unlock/swap/
    ///         settle/take cycle on the stub (not a no-op shortcut).
    function test_TouchesFullV4SettlementCycle() public {
        pm.setConfiguredTokensOut(1e18);
        vm.prank(DEPOSITOR);
        router.routeRevenue(1_000_000, 0);

        assertTrue(pm.callbackEntered());
        assertEq(pm.syncCalls(), 1);
        assertEq(pm.settleCalls(), 1);
        assertEq(pm.takeCalls(), 1);
    }

    // -----------------------------------------------------------------
    // routeRevenue — slippage
    // -----------------------------------------------------------------

    function test_SlippageRevert() public {
        uint256 amt = 1_000_000;
        // Stub will deliver only 1e17 tokens, but caller demands 2e18.
        pm.setConfiguredTokensOut(1e17);
        vm.prank(DEPOSITOR);
        vm.expectRevert(M2Errors.SlippageExceeded.selector);
        router.routeRevenue(amt, 2e18);
    }

    function test_SlippageOk_ExactMatch() public {
        // minTokensOut == tokensReceived should NOT revert.
        pm.setConfiguredTokensOut(5e17);
        vm.prank(DEPOSITOR);
        (, , uint256 tokensBurned) = router.routeRevenue(1_000_000, 5e17);
        assertEq(tokensBurned, 5e17);
    }

    // -----------------------------------------------------------------
    // unlockCallback — access control
    // -----------------------------------------------------------------

    function test_UnlockCallbackRejectsNonPoolManager() public {
        bytes memory data = abi.encode(uint256(100), uint256(0));
        vm.prank(ATTACKER);
        vm.expectRevert(M2Errors.OnlyPoolManager.selector);
        router.unlockCallback(data);
    }

    function test_UnlockCallbackRejectsDepositor() public {
        bytes memory data = abi.encode(uint256(100), uint256(0));
        vm.prank(DEPOSITOR);
        vm.expectRevert(M2Errors.OnlyPoolManager.selector);
        router.unlockCallback(data);
    }

    function test_UnlockCallbackRejectsRouterSelf() public {
        bytes memory data = abi.encode(uint256(100), uint256(0));
        vm.prank(address(router));
        vm.expectRevert(M2Errors.OnlyPoolManager.selector);
        router.unlockCallback(data);
    }

    // -----------------------------------------------------------------
    // No setters — bytecode selector audit
    // -----------------------------------------------------------------
    //
    // The router has no `setX` function for any of its immutable
    // parameters. We confirm this by computing the 4-byte selector for
    // each forbidden setter signature and asserting it does NOT appear
    // anywhere in the deployed bytecode.
    //
    // This is a defense-in-depth check: the source clearly has no setters
    // (manual diff review is authoritative), but the bytecode probe makes
    // CI fail if a future refactor sneaks one in.

    function test_NoSetters_BytecodeAudit() public view {
        bytes memory code = address(router).code;

        bytes4[10] memory selectors = [
            bytes4(keccak256("setDepositor(address)")),
            bytes4(keccak256("setSplit(uint256)")),
            bytes4(keccak256("setSplit(uint256,uint256)")),
            bytes4(keccak256("setToken(address)")),
            bytes4(keccak256("setStable(address)")),
            bytes4(keccak256("setTreasury(address)")),
            bytes4(keccak256("setHook(address)")),
            bytes4(keccak256("setPoolManager(address)")),
            bytes4(keccak256("setPoolKey((address,address,uint24,int24,address))")),
            bytes4(keccak256("upgradeTo(address)"))
        ];

        for (uint256 i = 0; i < selectors.length; i++) {
            assertFalse(
                _bytecodeContainsSelector(code, selectors[i]),
                "router bytecode contains a forbidden setter selector"
            );
        }
    }

    /// @dev Naive bytewise scan for a 4-byte selector inside `code`.
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
