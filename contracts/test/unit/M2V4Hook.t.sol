// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta, BalanceDeltaLibrary}
    from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary}
    from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams, ModifyLiquidityParams}
    from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

import {TestBase} from "../helpers/TestBase.sol";
import {M2Token} from "../../contracts/token/M2Token.sol";
import {M2Treasury} from "../../contracts/treasury/M2Treasury.sol";
import {MockStable} from "../../contracts/mocks/MockStable.sol";
import {M2Constants} from "../../contracts/libraries/M2Constants.sol";
import {M2Errors} from "../../contracts/libraries/M2Errors.sol";
import {IM2Hook} from "../../contracts/interfaces/IM2Hook.sol";
import {M2V4Hook} from "../../contracts/hook/M2V4Hook.sol";

// =====================================================================
// In-test Create2 deployer (helper)
// =====================================================================
//
// V4 requires the hook's deployed address to encode its permission
// flags in the lower 14 bits. The hook's constructor reverts
// otherwise. We provide a tiny CREATE2 helper here so tests can mine a
// salt against the BEFORE_SWAP_FLAG predicate and deploy the real
// `M2V4Hook` to a flag-compliant address.
//
// Mining cost: BEFORE_SWAP_FLAG is a 14-bit predicate, so the expected
// number of salt iterations is ~16,384. This runs inside `setUp` once
// per test contract instance.
// =====================================================================

contract TestCreate2Deployer {
    /// @notice Deploy `initCode` at the CREATE2 address derived from
    ///         (this, salt). Reverts if the deploy fails.
    function deploy(bytes32 salt, bytes calldata initCode)
        external
        returns (address deployed)
    {
        bytes memory code = initCode;
        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            deployed := create2(0, add(code, 0x20), mload(code), salt)
        }
        require(deployed != address(0), "CREATE2 failed");
    }
}

// =====================================================================
// Test-only mock PoolManager
// =====================================================================
//
// Implements the subset of IPoolManager that M2V4Hook touches inside
// collectFees and initializePool:
//   - unlock(data)             → call back caller's unlockCallback
//   - initialize(key, sqrtPx)  → no-op marker
//   - modifyLiquidity(...)     → returns configured BalanceDelta
//   - sync / settle / take     → standard V4 flash-accounting surface
// =====================================================================

contract MockPoolManagerForHook {
    int128 public configuredStableFees;
    int128 public configuredTokenFees;
    bool public unlockCalled;
    bool public initialized;
    bool public stableIs0;
    address public stableAddr;
    address public tokenAddr;

    constructor(address stableAddr_, address tokenAddr_, bool stableIs0_) {
        stableAddr = stableAddr_;
        tokenAddr = tokenAddr_;
        stableIs0 = stableIs0_;
    }

    function setFees(int128 stableFees_, int128 tokenFees_) external {
        configuredStableFees = stableFees_;
        configuredTokenFees = tokenFees_;
    }

    function initialize(PoolKey memory /* key */, uint160 /* sqrtPriceX96 */)
        external
        returns (int24)
    {
        initialized = true;
        return int24(0);
    }

    function unlock(bytes calldata data) external returns (bytes memory) {
        unlockCalled = true;
        return IUnlockCallback(msg.sender).unlockCallback(data);
    }

    /// @dev For our unit tests, `modifyLiquidity` is invoked only with
    ///      `liquidityDelta == 0` (collectFees poke) or with a small
    ///      seed liquidity during initializePool. The LP-seed path
    ///      returns zero deltas — the mock does not actually require
    ///      the hook to hold seed funds.
    function modifyLiquidity(
        PoolKey memory /* key */,
        ModifyLiquidityParams memory params,
        bytes calldata /* hookData */
    ) external view returns (BalanceDelta, BalanceDelta) {
        if (params.liquidityDelta == 0) {
            int128 a0;
            int128 a1;
            if (stableIs0) {
                a0 = configuredStableFees;
                a1 = configuredTokenFees;
            } else {
                a0 = configuredTokenFees;
                a1 = configuredStableFees;
            }
            BalanceDelta packed = toBalanceDelta(a0, a1);
            return (packed, packed);
        }
        // LP-add path: zero deltas, allowing hook to skip settle.
        return (toBalanceDelta(0, 0), toBalanceDelta(0, 0));
    }

    function sync(Currency /* currency */) external {}
    function settle() external payable returns (uint256) { return 0; }

    function take(Currency currency, address to, uint256 amount) external {
        ERC20(Currency.unwrap(currency)).transfer(to, amount);
    }
}

// =====================================================================
// M2V4Hook unit tests
// =====================================================================
//
// Construction strategy: mine a BEFORE_SWAP_FLAG-compatible CREATE2
// salt inside setUp, then deploy via the TestCreate2Deployer helper.
// The hook's constructor calls `Hooks.validateHookPermissions` against
// the deployed address; the mined salt guarantees this passes.

contract M2V4HookUnitTest is TestBase {
    address internal constant ALICE = address(0xA11CE);
    address internal constant ROUTER = address(0xABCD2);
    uint256 internal constant INITIAL_SUPPLY = 1_000_000_000 * 1e18;
    uint256 internal constant TREASURY_SEED = 1_000_000 * 1e6;

    MockStable internal stableTok;
    M2Treasury internal treasury;
    M2Token internal token;
    MockPoolManagerForHook internal pm;
    TestCreate2Deployer internal create2;
    M2V4Hook internal hook;
    bool internal stableIs0;
    PoolKey internal poolKey;

    uint64 internal _nextNonce = 1;

    function _predictCreate(address deployer, uint64 nonce)
        internal
        pure
        returns (address)
    {
        require(nonce >= 1 && nonce <= 0x7f, "nonce range");
        bytes memory rlp = abi.encodePacked(
            bytes1(0xd6),
            bytes1(0x94),
            deployer,
            bytes1(uint8(nonce))
        );
        return address(uint160(uint256(keccak256(rlp))));
    }

    function _consumeNonce() internal returns (address) {
        address a = _predictCreate(address(this), _nextNonce);
        _nextNonce += 1;
        return a;
    }

    function _makePoolKey(
        address stableAddr,
        address tokenAddr,
        address hookAddr,
        uint24 fee
    ) internal pure returns (PoolKey memory) {
        bool s0 = stableAddr < tokenAddr;
        return PoolKey({
            currency0: s0 ? Currency.wrap(stableAddr) : Currency.wrap(tokenAddr),
            currency1: s0 ? Currency.wrap(tokenAddr) : Currency.wrap(stableAddr),
            fee: fee,
            tickSpacing: int24(60),
            hooks: IHooks(hookAddr)
        });
    }

    /// @dev Mine a salt s.t. CREATE2 address has lower 14 bits ==
    ///      BEFORE_SWAP_FLAG. Expected iterations: 2^14 = 16,384.
    function _mineSalt(address deployer, bytes32 initCodeHash)
        internal
        pure
        returns (bytes32, address)
    {
        for (uint256 i = 0; i < 200_000; ++i) {
            bytes32 salt = bytes32(i);
            address addr = address(uint160(uint256(keccak256(
                abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)
            ))));
            if ((uint160(addr) & Hooks.ALL_HOOK_MASK) == Hooks.BEFORE_SWAP_FLAG) {
                return (salt, addr);
            }
        }
        revert("salt mine exhausted");
    }

    function setUp() public {
        // Nonce 1: MockStable.
        _consumeNonce();
        stableTok = new MockStable();

        // Nonce 2: predicted treasury (CREATE).
        // Nonce 3: predicted token (CREATE).
        // Nonce 4: predicted PoolManager mock (CREATE).
        // Nonce 5: predicted Create2 helper (CREATE).
        // The hook is deployed via CREATE2 from the helper, NOT via the
        // test contract's CREATE nonce.
        address trAddr = _consumeNonce();
        address tkAddr = _consumeNonce();
        address pmAddr = _consumeNonce();
        address create2Addr = _consumeNonce();

        stableIs0 = address(stableTok) < tkAddr;

        // Build the hook's init code with the predicted (pm, token,
        // stable, treasury) constructor args. The hook's address is a
        // function of (create2Addr, salt, initCodeHash); pre-compute
        // initCodeHash, then mine salt.
        bytes memory hookInitCode = abi.encodePacked(
            type(M2V4Hook).creationCode,
            abi.encode(pmAddr, tkAddr, address(stableTok), trAddr)
        );
        bytes32 hookInitHash = keccak256(hookInitCode);

        (bytes32 hookSalt, address hookAddr) =
            _mineSalt(create2Addr, hookInitHash);

        // Deploy treasury (actual nonce 2) with the predicted token addr.
        treasury = new M2Treasury(address(stableTok), tkAddr);
        require(address(treasury) == trAddr, "treasury addr");

        // Deploy token (actual nonce 3) with the predicted hook addr.
        token = new M2Token(
            address(stableTok),
            address(treasury),
            ROUTER,
            hookAddr,
            address(this),
            INITIAL_SUPPLY
        );
        require(address(token) == tkAddr, "token addr");

        stableTok.mint(address(treasury), TREASURY_SEED);

        // Deploy mock PoolManager (actual nonce 4).
        pm = new MockPoolManagerForHook(address(stableTok), address(token), stableIs0);
        require(address(pm) == pmAddr, "pm addr prediction");

        // Deploy Create2 helper (actual nonce 5).
        create2 = new TestCreate2Deployer();
        require(address(create2) == create2Addr, "create2 addr prediction");

        // Deploy the hook via CREATE2 with the mined salt.
        address deployed = create2.deploy(hookSalt, hookInitCode);
        require(deployed == hookAddr, "hook addr matches mined");
        hook = M2V4Hook(deployed);

        // Initialize the hook's pool / position via the mock PoolManager.
        // The mock's modifyLiquidity returns zero deltas on the LP-add
        // path, so no settle is required — this lets the hook reach
        // `_initialized = true` without holding seed funds.
        poolKey = _makePoolKey(
            address(stableTok),
            address(token),
            hookAddr,
            LPFeeLibrary.DYNAMIC_FEE_FLAG
        );
        hook.initializePool(poolKey, uint160(1) << 96, uint128(1));

        // Pre-fund the mock PoolManager so its `take` can deliver fees.
        token.transfer(address(pm), 100_000_000 * 1e18);
        stableTok.mint(address(pm), 100_000_000 * 1e6);
    }

    // -----------------------------------------------------------------
    // Constructor wiring + permission bits
    // -----------------------------------------------------------------

    function test_ConstructorWiring() public view {
        assertEq(hook.token(), address(token), "token wired");
        assertEq(hook.stable(), address(stableTok), "stable wired");
        assertEq(hook.treasury(), address(treasury), "treasury wired");
        assertEq(hook.poolManager(), address(pm), "poolManager wired");
    }

    function test_HookAddressHasBeforeSwapFlag() public view {
        uint160 lowBits = uint160(address(hook)) & Hooks.ALL_HOOK_MASK;
        assertEq(uint256(lowBits), uint256(Hooks.BEFORE_SWAP_FLAG));
    }

    function test_ConstructorAssertsFeeUnit() public pure {
        assertEq(
            uint256(LPFeeLibrary.MAX_LP_FEE),
            uint256(M2Constants.V4_MAX_LP_FEE),
            "V4 fee-unit assumption -- bumping V4 must update M2Constants"
        );
    }

    // -----------------------------------------------------------------
    // beforeSwap — fee direction
    // -----------------------------------------------------------------

    function test_StableInputGetsBuyFee() public {
        bool zeroForOne = stableIs0;
        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(1e6),
            sqrtPriceLimitX96: 0
        });
        vm.prank(address(pm));
        (bytes4 sel, BeforeSwapDelta delta, uint24 fee) =
            IHooks(address(hook)).beforeSwap(address(this), poolKey, params, "");
        assertEq(uint256(uint32(sel)), uint256(uint32(IHooks.beforeSwap.selector)), "selector");
        assertEq(int256(BeforeSwapDeltaLibrary.getSpecifiedDelta(delta)), int256(0));
        assertEq(int256(BeforeSwapDeltaLibrary.getUnspecifiedDelta(delta)), int256(0));
        uint24 expected = uint24(M2Constants.BUY_FEE) | LPFeeLibrary.OVERRIDE_FEE_FLAG;
        assertEq(uint256(fee), uint256(expected), "buy fee OR'd with override flag");
    }

    function test_TokenInputGetsSellFee() public {
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
        assertEq(uint256(fee), uint256(expected), "sell fee OR'd with override flag");
    }

    function test_HookReturnsOverrideFlag() public {
        vm.prank(address(pm));
        (, , uint24 fee) = IHooks(address(hook)).beforeSwap(
            address(this),
            poolKey,
            SwapParams({zeroForOne: stableIs0, amountSpecified: -1, sqrtPriceLimitX96: 0}),
            ""
        );
        assertTrue((fee & LPFeeLibrary.OVERRIDE_FEE_FLAG) != 0, "override flag set");
    }

    /// @notice The hook's `_requirePoolKeyMatch` rejects a pool key that
    ///         doesn't match the one registered at `initializePool`. A
    ///         static-fee key (without DYNAMIC_FEE_FLAG) must not
    ///         succeed in applying an override.
    function test_PoolWithoutDynamicFeeFlagFails() public {
        PoolKey memory staticKey = _makePoolKey(
            address(stableTok),
            address(token),
            address(hook),
            uint24(3000)
        );
        vm.prank(address(pm));
        try IHooks(address(hook)).beforeSwap(
            address(this),
            staticKey,
            SwapParams({zeroForOne: true, amountSpecified: -1, sqrtPriceLimitX96: 0}),
            ""
        ) returns (bytes4, BeforeSwapDelta, uint24 fee) {
            assertTrue(
                (fee & LPFeeLibrary.OVERRIDE_FEE_FLAG) == 0,
                "must not override on a non-dynamic pool"
            );
        } catch {
            assertTrue(true, "reverted on non-dynamic pool -- acceptable");
        }
    }

    // -----------------------------------------------------------------
    // unlockCallback access control
    // -----------------------------------------------------------------

    function test_UnlockCallbackRejectsNonPoolManager() public {
        bytes memory data = abi.encode(uint8(0), bytes(""));
        vm.prank(ALICE);
        vm.expectRevert(M2Errors.OnlyPoolManager.selector);
        IUnlockCallback(address(hook)).unlockCallback(data);
    }

    function test_UnlockCallbackRejectsRandomCaller() public {
        bytes memory data = abi.encode(uint8(0), bytes(""));
        vm.prank(address(0xBADBEEF));
        vm.expectRevert(M2Errors.OnlyPoolManager.selector);
        IUnlockCallback(address(hook)).unlockCallback(data);
    }

    function test_UnlockCallbackRejectsHookSelf() public {
        bytes memory data = abi.encode(uint8(0), bytes(""));
        vm.prank(address(hook));
        vm.expectRevert(M2Errors.OnlyPoolManager.selector);
        IUnlockCallback(address(hook)).unlockCallback(data);
    }

    // -----------------------------------------------------------------
    // collectFees — permissionless, harmless on empty
    // -----------------------------------------------------------------

    function test_AnyoneCanCallCollectFees_NoEffectIfNoFees() public {
        pm.setFees(int128(0), int128(0));

        uint256 sBefore = stableTok.balanceOf(address(treasury));
        uint256 tBefore = token.totalSupply();
        uint256 aliceStableBefore = stableTok.balanceOf(ALICE);
        uint256 aliceTokenBefore = token.balanceOf(ALICE);

        vm.prank(ALICE);
        (uint256 sOut, uint256 tOut) = hook.collectFees();

        assertEq(sOut, 0, "no stable fees");
        assertEq(tOut, 0, "no token fees");
        assertEq(stableTok.balanceOf(address(treasury)), sBefore, "treasury unchanged");
        assertEq(token.totalSupply(), tBefore, "supply unchanged");
        assertEq(stableTok.balanceOf(ALICE), aliceStableBefore);
        assertEq(token.balanceOf(ALICE), aliceTokenBefore);
    }

    // -----------------------------------------------------------------
    // collectFees — distribution math
    // -----------------------------------------------------------------

    function test_StableFeesIncreaseTreasury() public {
        uint256 stableFees = 10_000 * 1e6;
        pm.setFees(int128(uint128(stableFees)), int128(0));

        uint256 sTreasuryBefore = stableTok.balanceOf(address(treasury));
        uint256 sAliceBefore = stableTok.balanceOf(ALICE);

        vm.prank(ALICE);
        (uint256 sOut, ) = hook.collectFees();

        assertEq(sOut, stableFees, "stableRealized == accrued");

        uint256 expectedBounty = (stableFees * M2Constants.CALLER_BOUNTY_BPS) /
            M2Constants.BPS_DENOMINATOR;
        uint256 expectedTreasury = stableFees - expectedBounty;

        assertEq(
            stableTok.balanceOf(address(treasury)) - sTreasuryBefore,
            expectedTreasury,
            "treasury += 99.75% stable fees"
        );
        assertEq(
            stableTok.balanceOf(ALICE) - sAliceBefore,
            expectedBounty,
            "alice += 0.25% stable bounty"
        );
    }

    function test_TokenFeesReduceSupply() public {
        uint256 tokenFees = 100 * 1e18;
        pm.setFees(int128(0), int128(uint128(tokenFees)));

        uint256 supplyBefore = token.totalSupply();
        uint256 tAliceBefore = token.balanceOf(ALICE);

        vm.prank(ALICE);
        (, uint256 tOut) = hook.collectFees();

        assertEq(tOut, tokenFees, "tokenRealized == accrued");

        uint256 expectedBounty = (tokenFees * M2Constants.CALLER_BOUNTY_BPS) /
            M2Constants.BPS_DENOMINATOR;
        uint256 expectedBurn = tokenFees - expectedBounty;

        assertEq(
            supplyBefore - token.totalSupply(),
            expectedBurn,
            "supply decreased by 99.75% token fees"
        );
        assertEq(
            token.balanceOf(ALICE) - tAliceBefore,
            expectedBounty,
            "alice += 0.25% token bounty"
        );
    }

    function test_BountyAtMostQuarterPercent() public {
        uint256 stableFees = 1_234_567;
        uint256 tokenFees = 9_876_543_210;
        pm.setFees(int128(uint128(stableFees)), int128(uint128(tokenFees)));

        uint256 sAliceBefore = stableTok.balanceOf(ALICE);
        uint256 tAliceBefore = token.balanceOf(ALICE);

        vm.prank(ALICE);
        hook.collectFees();

        uint256 sBounty = stableTok.balanceOf(ALICE) - sAliceBefore;
        uint256 tBounty = token.balanceOf(ALICE) - tAliceBefore;

        assertEq(sBounty, (stableFees * 25) / 10_000, "stable bounty exact floor");
        assertEq(tBounty, (tokenFees * 25) / 10_000, "token bounty exact floor");
        assertLe(sBounty * 10_000, stableFees * 25, "stable bounty <= 0.25%");
        assertLe(tBounty * 10_000, tokenFees * 25, "token bounty <= 0.25%");
    }

    // -----------------------------------------------------------------
    // Conservation (FINAL_REPORT L4)
    // -----------------------------------------------------------------

    function test_ConservationStable() public {
        uint256 stableFees = 7_777_777;
        pm.setFees(int128(uint128(stableFees)), int128(0));

        uint256 sTBefore = stableTok.balanceOf(address(treasury));
        uint256 sABefore = stableTok.balanceOf(ALICE);

        vm.prank(ALICE);
        (uint256 sOut, ) = hook.collectFees();

        uint256 toTreasury = stableTok.balanceOf(address(treasury)) - sTBefore;
        uint256 bounty = stableTok.balanceOf(ALICE) - sABefore;

        assertEq(sOut, stableFees, "realized matches accrued");
        assertEq(bounty + toTreasury, sOut, "no-stranded-wei stable");
    }

    function test_ConservationToken() public {
        uint256 tokenFees = 13_579_111_315;
        pm.setFees(int128(0), int128(uint128(tokenFees)));

        uint256 supplyBefore = token.totalSupply();
        uint256 tABefore = token.balanceOf(ALICE);

        vm.prank(ALICE);
        (, uint256 tOut) = hook.collectFees();

        uint256 burned = supplyBefore - token.totalSupply();
        uint256 bounty = token.balanceOf(ALICE) - tABefore;

        assertEq(tOut, tokenFees, "realized matches accrued");
        assertEq(bounty + burned, tOut, "no-stranded-wei token");
    }

    // -----------------------------------------------------------------
    // Floor monotonicity under random accruals
    // -----------------------------------------------------------------

    function testFuzz_RoundingCannotReduceFloor(uint96 stableFees, uint96 tokenFees) public {
        uint256 sFees = uint256(stableFees) % (10_000_000 * 1e6 + 1);
        uint256 kFees = uint256(tokenFees) % (10_000_000 * 1e18 + 1);
        if (stableTok.balanceOf(address(pm)) < sFees) {
            stableTok.mint(address(pm), sFees);
        }
        if (token.balanceOf(address(pm)) < kFees) {
            uint256 need = kFees - token.balanceOf(address(pm));
            if (token.balanceOf(address(this)) < need) return;
            token.transfer(address(pm), need);
        }

        pm.setFees(int128(uint128(sFees)), int128(uint128(kFees)));

        uint256 tBefore = stableTok.balanceOf(address(treasury));
        uint256 sBefore = token.totalSupply();

        vm.prank(ALICE);
        hook.collectFees();

        uint256 tAfter = stableTok.balanceOf(address(treasury));
        uint256 sAfter = token.totalSupply();

        if (sBefore == 0 || sAfter == 0) return;
        assertGe(tAfter * sBefore, tBefore * sAfter, "floor must be non-decreasing");
    }

    // -----------------------------------------------------------------
    // Repeated calls + composition
    // -----------------------------------------------------------------

    function test_RepeatedCalls() public {
        uint256[3] memory stableAccrual = [uint256(1_000_000), uint256(500_000), uint256(2_500_000)];
        uint256[3] memory tokenAccrual = [uint256(100 * 1e18), uint256(50 * 1e18), uint256(250 * 1e18)];

        for (uint256 i = 0; i < 3; ++i) {
            pm.setFees(int128(uint128(stableAccrual[i])), int128(uint128(tokenAccrual[i])));
            uint256 tBefore = stableTok.balanceOf(address(treasury));
            uint256 sBefore = token.totalSupply();
            vm.prank(ALICE);
            (uint256 sOut, uint256 kOut) = hook.collectFees();
            assertEq(sOut, stableAccrual[i], "stable realized i");
            assertEq(kOut, tokenAccrual[i], "token realized i");
            assertGe(
                stableTok.balanceOf(address(treasury)) * sBefore,
                tBefore * token.totalSupply(),
                "floor monotone across repeated call"
            );
        }
    }

    function test_CallBeforeAndAfterRedemption_PreservesInvariant() public {
        pm.setFees(int128(uint128(uint256(1_000_000))), int128(uint128(uint256(100 * 1e18))));
        uint256 tA = stableTok.balanceOf(address(treasury));
        uint256 sA = token.totalSupply();
        vm.prank(ALICE);
        hook.collectFees();
        uint256 tB = stableTok.balanceOf(address(treasury));
        uint256 sB = token.totalSupply();
        assertGe(tB * sA, tA * sB, "floor monotone after first collectFees");

        token.redeem(1e18);
        uint256 tC = stableTok.balanceOf(address(treasury));
        uint256 sC = token.totalSupply();
        assertGe(tC * sB, tB * sC, "floor monotone after redeem");

        pm.setFees(int128(uint128(uint256(500_000))), int128(uint128(uint256(50 * 1e18))));
        vm.prank(ALICE);
        hook.collectFees();
        uint256 tD = stableTok.balanceOf(address(treasury));
        uint256 sD = token.totalSupply();
        assertGe(tD * sC, tC * sD, "floor monotone after second collectFees");
    }

    function test_CallBeforeAndAfterLPSell_PreservesInvariant() public {
        pm.setFees(int128(0), int128(0));
        uint256 tA = stableTok.balanceOf(address(treasury));
        uint256 sA = token.totalSupply();
        vm.prank(ALICE);
        hook.collectFees();
        assertEq(stableTok.balanceOf(address(treasury)), tA, "no change pre-LP-sell");
        assertEq(token.totalSupply(), sA, "no supply change pre-LP-sell");

        // LP sell of N=10 tokens with 3% sell fee accrues 0.3 token to Φ_t.
        uint256 sellFeeAccrued = (10 * 1e18 * uint256(M2Constants.SELL_FEE)) /
            M2Constants.V4_MAX_LP_FEE;
        pm.setFees(int128(0), int128(uint128(sellFeeAccrued)));

        vm.prank(ALICE);
        hook.collectFees();
        uint256 tB = stableTok.balanceOf(address(treasury));
        uint256 sB = token.totalSupply();
        assertEq(tB, tA, "treasury unchanged on token-only collectFees");
        assertLt(sB, sA, "supply decreased on token-only collectFees");
        assertGt(tB * sA, tA * sB, "floor strictly raised");
    }

    // -----------------------------------------------------------------
    // LP unwithdrawability — bytecode audit
    // -----------------------------------------------------------------

    function test_LPCannotBeRemovedExternally() public view {
        bytes memory code = address(hook).code;
        bytes4[8] memory selectors = [
            bytes4(keccak256("removeLiquidity(uint256)")),
            bytes4(keccak256("removeLiquidity(int128)")),
            bytes4(keccak256("withdraw()")),
            bytes4(keccak256("withdraw(uint256)")),
            bytes4(keccak256("withdrawLP(uint256)")),
            bytes4(keccak256("decreaseLiquidity(uint256)")),
            bytes4(keccak256("burnPosition()")),
            bytes4(keccak256("destroyPosition()"))
        ];
        for (uint256 i = 0; i < selectors.length; ++i) {
            assertFalse(
                _bytecodeContainsSelector(code, selectors[i]),
                "hook bytecode contains a forbidden LP-removal selector"
            );
        }
    }

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
