// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {VestingWallet} from "@openzeppelin/contracts/finance/VestingWallet.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";

import {TestBase} from "../helpers/TestBase.sol";
import {M2Token} from "../../contracts/token/M2Token.sol";
import {M2Treasury} from "../../contracts/treasury/M2Treasury.sol";
import {M2RevenueRouter} from "../../contracts/router/M2RevenueRouter.sol";
import {M2V4Hook} from "../../contracts/hook/M2V4Hook.sol";
import {M2GenesisFactory} from "../../contracts/genesis/M2GenesisFactory.sol";
import {M2Constants} from "../../contracts/libraries/M2Constants.sol";

// =====================================================================
// Test-only swap router (identical to the one in
// Theorem5_3SpotFloorArbitragePin.t.sol — duplicated to keep this file
// self-contained for the fork environment).
// =====================================================================

contract MassDumpSwapRouter is IUnlockCallback {
    using SafeERC20 for IERC20;

    IPoolManager public immutable POOL_MANAGER;

    constructor(IPoolManager poolManager_) {
        POOL_MANAGER = poolManager_;
    }

    struct SwapCallbackData {
        address payer;
        PoolKey poolKey;
        bool zeroForOne;
        int256 amountSpecified;
    }

    function swap(
        PoolKey calldata key,
        bool zeroForOne,
        int256 amountSpecified
    ) external returns (BalanceDelta) {
        bytes memory result = POOL_MANAGER.unlock(
            abi.encode(
                SwapCallbackData({
                    payer: msg.sender,
                    poolKey: key,
                    zeroForOne: zeroForOne,
                    amountSpecified: amountSpecified
                })
            )
        );
        return abi.decode(result, (BalanceDelta));
    }

    function unlockCallback(bytes calldata data)
        external
        override
        returns (bytes memory)
    {
        require(msg.sender == address(POOL_MANAGER), "MassDumpSwapRouter: not PM");
        SwapCallbackData memory d = abi.decode(data, (SwapCallbackData));

        uint160 sqrtPriceLimitX96 = d.zeroForOne
            ? TickMath.MIN_SQRT_PRICE + 1
            : TickMath.MAX_SQRT_PRICE - 1;

        BalanceDelta delta = POOL_MANAGER.swap(
            d.poolKey,
            SwapParams({
                zeroForOne: d.zeroForOne,
                amountSpecified: d.amountSpecified,
                sqrtPriceLimitX96: sqrtPriceLimitX96
            }),
            ""
        );

        int128 d0 = BalanceDeltaLibrary.amount0(delta);
        int128 d1 = BalanceDeltaLibrary.amount1(delta);

        if (d0 < 0) {
            uint256 owed = uint256(uint128(-d0));
            POOL_MANAGER.sync(d.poolKey.currency0);
            IERC20(Currency.unwrap(d.poolKey.currency0)).safeTransferFrom(
                d.payer,
                address(POOL_MANAGER),
                owed
            );
            POOL_MANAGER.settle();
        } else if (d0 > 0) {
            POOL_MANAGER.take(d.poolKey.currency0, d.payer, uint256(uint128(d0)));
        }

        if (d1 < 0) {
            uint256 owed = uint256(uint128(-d1));
            POOL_MANAGER.sync(d.poolKey.currency1);
            IERC20(Currency.unwrap(d.poolKey.currency1)).safeTransferFrom(
                d.payer,
                address(POOL_MANAGER),
                owed
            );
            POOL_MANAGER.settle();
        } else if (d1 > 0) {
            POOL_MANAGER.take(d.poolKey.currency1, d.payer, uint256(uint128(d1)));
        }

        return abi.encode(delta);
    }
}

// =====================================================================
// MainnetForkVestingMassDump — paper §3.7 Table 1 row "Vesting recipient"
// =====================================================================
//
// Scenario (paper §3.7 14-row threat model, "Vesting recipient" row):
//   Dump vested tokens to LP after cliff. In scope.
//
// Test design:
//   1. Mainnet fork at a pinned block (V4 PoolManager deployed; USDC
//      live). If MAINNET_RPC_URL is unset, the test is SKIPPED via the
//      bytecode-presence check on USDC / PoolManager.
//   2. Deploy the canonical M² system via M2GenesisFactory against
//      REAL mainnet USDC and REAL mainnet V4 PoolManager. Vesting
//      config: a single beneficiary, full 250M allocation,
//      `start = block.timestamp`, `duration = 0` (immediate vest).
//   3. Beneficiary calls vestingWallet.release(); obtains 250M tokens.
//   4. Beneficiary dumps the entire 250M into the LP across N sub-swaps.
//      (N chosen to keep each step within V4 tick-bounds; see comment.)
//   5. After the dump, accumulated Φ_t (sell-side fees) is realized
//      via permissionless `collectFees`. 99.75% of the token side is
//      burned (supply decreases); 99.75% of any stable side goes to
//      treasury.
//   6. Assert:
//      - Floor invariant: each step has `T_new * S_old ≥ T_old * S_new`.
//      - Post-collect floor STRICTLY > pre-dump floor.
//      - Beneficiary's net stable proceeds ≤ Theorem 5.2 attacker yield
//        `N * F0 + Δ*` with `N = 250M` (sanity bound).
// =====================================================================

/// @dev Mainnet addresses for the fork environment.
///
///   USDC:        0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48 (6 decimals)
///   V4 PoolMgr:  0x000000000004444c5dc75cB358380D2e3dE08A90
///                (canonical CREATE2 deployment per
///                 https://docs.uniswap.org/contracts/v4/deployments)
///
/// Pinned fork block:
///   blockNumber = 22_000_000 (chosen so V4 PoolManager is deployed and
///   USDC is live; documented in `hardhat.config.ts`).
///
/// TODO(deployer): if a future audit pins a different block for
///   reproducibility, update `hardhat.config.ts > test.solidity.forking`
///   and this comment in lockstep.
contract MainnetForkVestingMassDumpTest is TestBase {
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    address internal constant MAINNET_USDC =
        0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant MAINNET_V4_POOL_MANAGER =
        0x000000000004444c5dc75cB358380D2e3dE08A90;

    /// @dev Vesting beneficiary used in this scenario.
    address internal constant BENEFICIARY = address(0xBE9EF1C1A);
    address internal constant DEPOSITOR = address(0xDE9051704);

    // Locked design parameters (mirror M2Constants).
    uint256 internal constant S0 = 1_000_000_000 * 1e18;
    uint256 internal constant LT0 = 750_000_000 * 1e18;
    uint256 internal constant VESTING_TOTAL = 250_000_000 * 1e18;
    uint256 internal constant T0 = 1_000_000 * 1e6;
    uint256 internal constant LS0 = 750_000 * 1e6;

    /// @dev Number of sub-swaps the dump is split into. Splitting keeps
    ///      each step's tick movement bounded so we don't hit the V4
    ///      MIN_SQRT_PRICE limit prematurely. 25 batches of 10M tokens.
    uint256 internal constant DUMP_BATCHES = 25;

    // Deployed system handles
    M2GenesisFactory internal factory;
    M2Token internal token;
    M2Treasury internal treasury;
    M2RevenueRouter internal router;
    M2V4Hook internal hook;
    VestingWallet internal vestingWallet;
    MassDumpSwapRouter internal swapRouter;
    PoolKey internal poolKey;
    bool internal stableIs0;
    bool internal _skipped;

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

    function _predictCreate2(
        address deployer,
        bytes32 salt,
        bytes32 initCodeHash
    ) internal pure returns (address) {
        return address(uint160(uint256(keccak256(
            abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)
        ))));
    }

    function _mineHookSalt(address deployer, bytes32 initCodeHash)
        internal
        pure
        returns (bytes32, address)
    {
        for (uint256 i = 0; i < 200_000; ++i) {
            bytes32 salt = bytes32(i);
            address addr = _predictCreate2(deployer, salt, initCodeHash);
            if ((uint160(addr) & Hooks.ALL_HOOK_MASK) == Hooks.BEFORE_SWAP_FLAG) {
                return (salt, addr);
            }
        }
        revert("hook salt mine exhausted");
    }

    /// @dev `true` if the current environment is a mainnet fork:
    ///      we detect this by checking the canonical USDC and V4
    ///      PoolManager addresses have runtime bytecode. If not, the
    ///      test gracefully skips (per the acceptance criteria).
    function _isForkAvailable() internal view returns (bool) {
        return MAINNET_USDC.code.length > 0 && MAINNET_V4_POOL_MANAGER.code.length > 0;
    }

    /// @dev Mint USDC to `to` by overwriting USDC's `_balances[to]`
    ///      storage slot. USDC is a proxy whose implementation stores
    ///      balances at slot 9 of the EIP-1967 logic contract — the
    ///      underlying storage of the proxy is at the same physical
    ///      slot. Verified by reading the existing balance pattern on
    ///      mainnet and confirmed in the Circle USDC implementation
    ///      source. The slot index 9 is the well-known balances slot.
    function _mintUsdc(address to, uint256 amount) internal {
        bytes32 slot = keccak256(abi.encode(to, uint256(9)));
        vm.store(MAINNET_USDC, slot, bytes32(amount));
    }

    function setUp() public {
        if (!_isForkAvailable()) {
            _skipped = true;
            return;
        }

        // 1. Deploy M2GenesisFactory.
        factory = new M2GenesisFactory();

        // 2. Predict factory CREATE nonces.
        address predictedTreasury = _predictCreate(address(factory), 1);
        address predictedToken = _predictCreate(address(factory), 2);

        // 3. Compute USDC < token ordering (USDC is at 0xA0b8... which
        //    is mid-range; we let the factory choose based on the
        //    predicted token addr).
        stableIs0 = uint160(MAINNET_USDC) < uint160(predictedToken);

        // 4. Mine the hook salt for the (PoolManager, token, stable,
        //    treasury) tuple. Reuses the same algorithm the factory
        //    uses internally.
        bytes memory hookCreationCode = type(M2V4Hook).creationCode;
        bytes memory hookInit = abi.encodePacked(
            hookCreationCode,
            abi.encode(
                MAINNET_V4_POOL_MANAGER,
                predictedToken,
                MAINNET_USDC,
                predictedTreasury
            )
        );
        bytes32 hookInitHash = keccak256(hookInit);
        (bytes32 hookSalt, ) = _mineHookSalt(address(factory), hookInitHash);

        // 5. Build genesis params with a SINGLE vesting recipient
        //    holding the full 250M and `duration = 0`.
        address[] memory recipients = new address[](1);
        recipients[0] = BENEFICIARY;
        uint64[] memory starts = new uint64[](1);
        starts[0] = uint64(block.timestamp);
        uint64[] memory durations = new uint64[](1);
        durations[0] = 0;
        uint256[] memory allocs = new uint256[](1);
        allocs[0] = VESTING_TOTAL;

        M2GenesisFactory.GenesisParams memory params = M2GenesisFactory
            .GenesisParams({
                stable: IERC20(MAINNET_USDC),
                poolManager: MAINNET_V4_POOL_MANAGER,
                depositor: DEPOSITOR,
                treasurySeed: T0,
                lpStableSeed: LS0,
                lpLiquidity: uint128(1e15), // deep LP for mass-dump test
                sqrtPriceX96Initial: uint160(1) << 96,
                tickSpacing: int24(60),
                hookSalt: hookSalt,
                hookCreationCode: hookCreationCode,
                vestingRecipients: recipients,
                vestingStarts: starts,
                vestingDurations: durations,
                vestingAllocations: allocs
            });

        // 6. Fund this contract with USDC and approve the factory.
        _mintUsdc(address(this), T0 + LS0);
        IERC20(MAINNET_USDC).approve(address(factory), T0 + LS0);

        // 7. Execute the genesis.
        M2GenesisFactory.Addresses memory addrs = factory.execute(params);
        token = M2Token(addrs.token);
        treasury = M2Treasury(addrs.treasury);
        router = M2RevenueRouter(addrs.router);
        hook = M2V4Hook(addrs.hook);
        vestingWallet = VestingWallet(payable(addrs.vestingWallets[0]));

        // 8. Build the canonical pool key (for the swap router).
        poolKey = PoolKey({
            currency0: stableIs0
                ? Currency.wrap(MAINNET_USDC)
                : Currency.wrap(address(token)),
            currency1: stableIs0
                ? Currency.wrap(address(token))
                : Currency.wrap(MAINNET_USDC),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: int24(60),
            hooks: IHooks(address(hook))
        });

        // 9. Deploy the test swap router and approve it as the
        //    beneficiary's spender for both token and USDC sides.
        swapRouter = new MassDumpSwapRouter(IPoolManager(MAINNET_V4_POOL_MANAGER));

        vm.prank(BENEFICIARY);
        IERC20(address(token)).approve(address(swapRouter), type(uint256).max);
        vm.prank(BENEFICIARY);
        IERC20(MAINNET_USDC).approve(address(swapRouter), type(uint256).max);
    }

    // -----------------------------------------------------------------
    // The mass-dump test
    // -----------------------------------------------------------------

    /// @notice Paper §3.7 Table 1 "Vesting recipient" — full scenario.
    /// @dev Tagged `@fork` for the test:fork script; tagged in the
    ///      function name to be greppable.
    function test_fork_VestingMassDump_FloorMonotoneAndStrictlyRaisedPostCollect()
        public
    {
        if (_skipped) {
            // Fork not available; record a deterministic no-op pass and
            // surface the skip via a no-revert path. The acceptance
            // criteria explicitly allow gracefully skipping when
            // MAINNET_RPC_URL is unset.
            return;
        }

        // 1. Beneficiary calls release() — receives the full 250M.
        assertEq(token.balanceOf(BENEFICIARY), 0);
        vestingWallet.release(address(token));
        assertEq(
            token.balanceOf(BENEFICIARY),
            VESTING_TOTAL,
            "beneficiary holds full 250M post-release"
        );

        // 2. Snapshot pre-dump state.
        uint256 T_pre = IERC20(MAINNET_USDC).balanceOf(address(treasury));
        uint256 S_pre = token.totalSupply();
        uint256 beneStableBefore = IERC20(MAINNET_USDC).balanceOf(BENEFICIARY);

        // 3. Dump the entire 250M into the LP across DUMP_BATCHES
        //    sub-swaps. The floor invariant is checked after each batch
        //    in cross-product form.
        //
        //    direction: token in → stable out. With `stableIs0`:
        //      zeroForOne = !stableIs0
        bool zeroForOne = !stableIs0;
        uint256 perBatch = VESTING_TOTAL / DUMP_BATCHES;

        for (uint256 i = 0; i < DUMP_BATCHES; ++i) {
            uint256 T_before = IERC20(MAINNET_USDC).balanceOf(address(treasury));
            uint256 S_before = token.totalSupply();

            vm.prank(BENEFICIARY);
            try swapRouter.swap(poolKey, zeroForOne, -int256(perBatch)) {
                // ok
            } catch {
                // The pool may exhaust its stable reserve well before
                // 250M tokens are absorbed (the LP's Ls is only $750k).
                // Stop the loop on first revert; the floor invariant
                // still holds for the batches that DID execute.
                break;
            }

            // Floor monotonicity in cross-product form: lp swaps do
            // NOT touch the treasury (T) or the supply (S), so the
            // floor is preserved exactly at this step.
            uint256 T_after = IERC20(MAINNET_USDC).balanceOf(address(treasury));
            uint256 S_after = token.totalSupply();
            assertEq(T_after, T_before, "lp swap: treasury unchanged");
            assertEq(S_after, S_before, "lp swap: supply unchanged");
            // Cross-product form: equality holds.
            assertEq(
                T_after * S_before,
                T_before * S_after,
                "lp swap: floor invariant (exact)"
            );
        }

        // 4. Snapshot post-dump, pre-collect.
        uint256 T_post_dump = IERC20(MAINNET_USDC).balanceOf(address(treasury));
        uint256 S_post_dump = token.totalSupply();
        assertEq(T_post_dump, T_pre, "treasury untouched by dumps");
        assertEq(S_post_dump, S_pre, "supply untouched by dumps");

        // 5. Permissionless collectFees — anyone can call. This realizes
        //    the accumulated Φ_t (sell-side token fees). 99.75% of the
        //    token leg is BURNED (supply decreases); 0.25% to caller.
        address collector = address(0xC011EC102);
        vm.prank(collector);
        (uint256 stableOut, uint256 tokenOut) = hook.collectFees();

        // We expect strictly positive token-side fees from the dumps.
        assertGt(tokenOut, 0, "collectFees realized non-zero token fees");

        // 6. Snapshot post-collect.
        uint256 T_post_collect = IERC20(MAINNET_USDC).balanceOf(address(treasury));
        uint256 S_post_collect = token.totalSupply();

        // Floor invariant across collectFees (non-decreasing).
        assertGe(
            T_post_collect * S_post_dump,
            T_post_dump * S_post_collect,
            "collectFees: floor non-decreasing"
        );

        // STRICTLY raised: tokenOut > 0 ⇒ supply strictly decreased ⇒
        // floor strictly raised (Theorem 4.3 Case 7).
        assertLt(
            S_post_collect,
            S_post_dump,
            "collectFees: supply strictly decreased"
        );
        assertGt(
            T_post_collect * S_pre,
            T_pre * S_post_collect,
            "post-collect floor STRICTLY > pre-dump floor"
        );

        // 7. Beneficiary's net stable proceeds — sanity-bounded.
        //    Theorem 5.2 caps the attacker's total yield at
        //    `Π*(N) = N * F0 + Δ*`. The closed-form Δ* differential
        //    lives in `MainnetForkBankRunDifferential_Thm5_2`. Here we
        //    only assert the LOOSE structural bound:
        //      beneficiary's stable proceeds < N * F_pre + LS0
        //    (the LP's stable side is bounded by LS0, so the attacker
        //    can never extract more than LS0 from the LP regardless of
        //    redemption strategy).
        uint256 beneStableAfter = IERC20(MAINNET_USDC).balanceOf(BENEFICIARY);
        uint256 beneProceeds = beneStableAfter - beneStableBefore;
        uint256 F_pre_scaled = Math.mulDiv(VESTING_TOTAL, T_pre, S_pre);
        // proceeds ≤ N * F_pre + LS0 in raw stable units.
        assertLe(
            beneProceeds,
            F_pre_scaled + LS0,
            "beneficiary proceeds bounded by Pi* + LS0"
        );

        // 8. Silence unused-warnings.
        stableOut;
        collector;
    }
}
