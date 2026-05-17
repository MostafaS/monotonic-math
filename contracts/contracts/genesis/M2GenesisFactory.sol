// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {VestingWallet} from "@openzeppelin/contracts/finance/VestingWallet.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

import {M2Token} from "../token/M2Token.sol";
import {M2Treasury} from "../treasury/M2Treasury.sol";
import {M2RevenueRouter} from "../router/M2RevenueRouter.sol";

import {M2Constants} from "../libraries/M2Constants.sol";
import {M2Errors} from "../libraries/M2Errors.sol";
import {IM2Events} from "../libraries/M2Events.sol";

/// @dev Minimal subset of `M2V4Hook.initializePool` consumed by the factory.
///      Declared locally so the factory does not import the full hook
///      (which would bloat its runtime bytecode past EIP-170's 24 576-byte cap).
interface IHookInitializer {
    function initializePool(
        PoolKey calldata key_,
        uint160 sqrtPriceX96,
        uint128 liquidity
    ) external;
}

/// @title M2GenesisFactory — Single-transaction atomic genesis for the M² system
/// @author M² / Monotonic Math
/// @notice Deploys the four immutable contracts (treasury, token, hook, router)
///         and the vesting wallets in a SINGLE non-reentrant transaction. There
///         is NO finalize fallback, NO two-tx pattern, NO admin key, and NO
///         setter on any deployed contract (paper §3.1; FINAL_REPORT M2 + M5).
/// @dev    Deployment strategy:
///           - treasury, token, router: plain `new` (factory CREATE nonces
///             1, 2, 4). Each address is predicted via the RLP nonce formula
///             and asserted post-deploy. Embedding their creation code as
///             compile-time literals keeps the factory bytecode minimal AND
///             gives us the strongest typing on the constructor args.
///           - hook: CREATE2 with a mined salt that places the hook at an
///             address whose bottom-14 bits encode the V4 `BEFORE_SWAP_FLAG`
///             permission. The hook's creation code is passed in as `bytes`
///             so the factory does NOT have to embed M2V4Hook's full
///             creation bytecode (~9 KiB) — that keeps the factory under
///             the 24 576-byte EIP-170 limit.
///
///         Deployment order (each step reverts everything on failure):
///           1. Validate input shape (vesting sum, array lengths,
///              genesis floor-spot constraint, hook salt produces the
///              required flag mask).
///           2. Predict CREATE addresses for treasury (nonce 1), token
///              (nonce 2), router (nonce 4). The factory's nonce 3 is
///              consumed by the CREATE2 hook deploy.
///           3. Predict the hook's CREATE2 address from `hookSalt`,
///              `hookCreationCode`, and the four predicted constructor args.
///           4. Deploy treasury → token → hook (CREATE2) → router.
///              Each deploy is followed by an `addr == predicted` assert.
///           5. Pull `treasurySeed` stable from `msg.sender` to treasury.
///              Pull `lpStableSeed` stable to hook.
///           6. Transfer `Lt0 = 7.5e26` tokens from factory to hook.
///           7. Call `hook.initializePool(...)` (one-shot guard inside the
///              hook).
///           8. Deploy + fund one OZ `VestingWallet` per recipient.
///           9. Assert factory holds zero stable AND zero token (the genesis
///              mint was fully distributed: 75% LP, 25% vesting).
///          10. Emit `GenesisCompleted` and return the deployed addresses.
contract M2GenesisFactory is ReentrancyGuard, IM2Events {
    using SafeERC20 for IERC20;

    // -----------------------------------------------------------------
    // Types
    // -----------------------------------------------------------------

    /// @notice Genesis parameters passed in one shot to `execute()`.
    ///         All values are immutable in the deployed system.
    struct GenesisParams {
        // ----- wiring -----
        IERC20 stable;
        address poolManager;
        address depositor;
        // ----- seed amounts (paper §3.6) -----
        uint256 treasurySeed; // T0  — stable units
        uint256 lpStableSeed; // Ls0 — stable units
        uint128 lpLiquidity; // V4 liquidity for full-range LP seed
        uint160 sqrtPriceX96Initial; // V4 init price (Q64.96)
        int24 tickSpacing; // V4 tickSpacing (e.g., 60)
        // ----- hook CREATE2 inputs (off-chain mined, see mine_hook_salt.ts) -----
        bytes32 hookSalt;
        bytes hookCreationCode;
        // ----- vesting schedule (must sum to 2.5e26) -----
        address[] vestingRecipients;
        uint64[] vestingStarts;
        uint64[] vestingDurations;
        uint256[] vestingAllocations;
    }

    /// @notice Addresses of the deployed contracts returned by `execute()`.
    struct Addresses {
        address token;
        address treasury;
        address router;
        address hook;
        address[] vestingWallets;
    }

    // -----------------------------------------------------------------
    // Errors (factory-only; protocol errors live in M2Errors)
    // -----------------------------------------------------------------

    /// @notice Thrown when `execute()` is called a second time.
    error AlreadyExecuted();

    /// @notice Thrown when `sum(vestingAllocations) != VESTING_SEED_RAW`.
    error VestingAllocationMismatch();

    /// @notice Thrown when the four vesting input arrays have mismatched lengths.
    error VestingArrayLengthMismatch();

    /// @notice Thrown when the predicted hook address does not satisfy the
    ///         V4 permission-flag mask. The mined hook salt is wrong
    ///         (most commonly stale w.r.t. the current bytecode).
    error HookSaltInvalid();

    /// @notice Thrown when the deployed address does not match its
    ///         pre-computed prediction (CREATE nonce desync or CREATE2
    ///         init-code mismatch).
    error AddressPredictionFailed();

    /// @notice Thrown when the factory does not fully drain its token /
    ///         stable balance by the end of `execute()`. Post-condition
    ///         on the genesis mint + 75/25 LP/vesting split.
    error PostConditionResidualBalance();

    // -----------------------------------------------------------------
    // Storage (one-shot replay flag — no setters, no admin, no rescue)
    // -----------------------------------------------------------------

    /// @dev One-shot replay flag. Independent of OZ ReentrancyGuard
    ///      (which protects against intra-tx reentry); this blocks a
    ///      SECOND outer call that would otherwise succeed past the
    ///      reentrancy guard.
    bool private _executed;

    // -----------------------------------------------------------------
    // External: execute
    // -----------------------------------------------------------------

    /// @notice Atomic single-transaction genesis. Performs all paper §3.6
    ///         steps and reverts on any failure. A second call reverts
    ///         `AlreadyExecuted`.
    /// @param params Genesis parameters; see {GenesisParams}.
    /// @return out   Deployed addresses (token, treasury, router, hook,
    ///               vesting wallets).
    function execute(GenesisParams calldata params)
        external
        nonReentrant
        returns (Addresses memory out)
    {
        if (_executed) revert AlreadyExecuted();
        _executed = true;

        // ---------- Validate input shape ------------------------------

        _validateInputShape(params);

        // Paper eq. 12 integer form: T0 * Lt0 == Ls0 * S0.
        if (
            params.treasurySeed * M2Constants.LP_SEED_RAW !=
            params.lpStableSeed * M2Constants.TOTAL_SUPPLY_RAW
        ) revert M2Errors.GenesisConstraintViolated();

        // ---------- Predict addresses ---------------------------------
        //
        // Factory nonce progression inside this function:
        //   nonce 1: Treasury  (CREATE)
        //   nonce 2: Token     (CREATE)  — mints S0 to address(this)
        //   nonce 3: Hook      (CREATE2) — EIP-1014 bumps the nonce
        //   nonce 4: Router    (CREATE)
        //   nonce N: each VestingWallet (CREATE), N >= 5
        out.treasury = _predictCreate(address(this), 1);
        out.token = _predictCreate(address(this), 2);
        out.router = _predictCreate(address(this), 4);

        // The hook init code passed in MUST match the canonical
        // M2V4Hook constructor signature (poolManager, token, stable,
        // treasury); the factory tail-appends the actual predicted args.
        bytes memory hookInit = abi.encodePacked(
            params.hookCreationCode,
            abi.encode(
                params.poolManager,
                out.token,
                address(params.stable),
                out.treasury
            )
        );
        out.hook = Create2.computeAddress(
            params.hookSalt,
            keccak256(hookInit),
            address(this)
        );

        // ---------- Validate the hook flag mask ----------------------

        if (
            (uint160(out.hook) & Hooks.ALL_HOOK_MASK) !=
            Hooks.BEFORE_SWAP_FLAG
        ) revert HookSaltInvalid();

        // ---------- Build the pool key -------------------------------

        PoolKey memory poolKey = _buildPoolKey(
            address(params.stable),
            out.token,
            out.hook,
            params.tickSpacing
        );

        // ---------- Deploy: Treasury (nonce 1) -----------------------

        M2Treasury treasury = new M2Treasury(
            address(params.stable),
            out.token
        );
        if (address(treasury) != out.treasury) revert AddressPredictionFailed();

        // ---------- Deploy: Token (nonce 2) --------------------------
        //
        // Factory becomes the initial holder of S0; subsequent steps
        // distribute 75% to the hook (LP seed) and 25% to the vesting
        // wallets; post-condition asserts factory.balanceOf == 0.
        M2Token token = new M2Token(
            address(params.stable),
            address(treasury),
            out.router,
            out.hook,
            address(this),
            M2Constants.TOTAL_SUPPLY_RAW
        );
        if (address(token) != out.token) revert AddressPredictionFailed();

        // ---------- Deploy: Hook via CREATE2 (nonce 3) ---------------

        address deployedHook = Create2.deploy(0, params.hookSalt, hookInit);
        if (deployedHook != out.hook) revert AddressPredictionFailed();

        // ---------- Deploy: Router (nonce 4) -------------------------

        M2RevenueRouter router = new M2RevenueRouter(
            address(params.stable),
            out.token,
            address(treasury),
            params.depositor,
            params.poolManager,
            out.hook,
            poolKey
        );
        if (address(router) != out.router) revert AddressPredictionFailed();

        // ---------- Stage the seed funds ----------------------------
        //
        // `msg.sender` must have pre-approved this factory for
        // (treasurySeed + lpStableSeed) stable. The factory holds S0
        // tokens from the genesis mint; transfer Lt0 (75%) to the hook
        // here, and the loop below handles the vesting 25%.
        params.stable.safeTransferFrom(
            msg.sender,
            out.treasury,
            params.treasurySeed
        );
        params.stable.safeTransferFrom(
            msg.sender,
            out.hook,
            params.lpStableSeed
        );
        IERC20(out.token).safeTransfer(out.hook, M2Constants.LP_SEED_RAW);

        // ---------- Initialize V4 pool ------------------------------

        IHookInitializer(out.hook).initializePool(
            poolKey,
            params.sqrtPriceX96Initial,
            params.lpLiquidity
        );

        // ---------- Deploy + fund vesting wallets -------------------

        uint256 nRecipients = params.vestingRecipients.length;
        out.vestingWallets = new address[](nRecipients);
        for (uint256 i = 0; i < nRecipients; ) {
            VestingWallet wallet = new VestingWallet(
                params.vestingRecipients[i],
                params.vestingStarts[i],
                params.vestingDurations[i]
            );
            out.vestingWallets[i] = address(wallet);
            IERC20(out.token).safeTransfer(
                address(wallet),
                params.vestingAllocations[i]
            );
            unchecked {
                ++i;
            }
        }

        // ---------- Post-conditions --------------------------------

        if (
            params.stable.balanceOf(address(this)) != 0 ||
            IERC20(out.token).balanceOf(address(this)) != 0
        ) revert PostConditionResidualBalance();

        emit GenesisCompleted(
            out.token,
            out.treasury,
            out.router,
            out.hook,
            out.vestingWallets
        );
    }

    /// @notice Whether `execute()` has already been called. False = pristine.
    function executed() external view returns (bool) {
        return _executed;
    }

    // -----------------------------------------------------------------
    // Internal: input-shape validation
    // -----------------------------------------------------------------

    function _validateInputShape(GenesisParams calldata params) internal pure {
        if (address(params.stable) == address(0)) revert M2Errors.ZeroAddress();
        if (params.poolManager == address(0)) revert M2Errors.ZeroAddress();
        if (params.depositor == address(0)) revert M2Errors.ZeroAddress();
        if (params.hookCreationCode.length == 0)
            revert M2Errors.EmptyHookCreationCode();

        uint256 n = params.vestingRecipients.length;
        if (
            n != params.vestingStarts.length ||
            n != params.vestingDurations.length ||
            n != params.vestingAllocations.length
        ) revert VestingArrayLengthMismatch();

        uint256 sum;
        for (uint256 i = 0; i < n; ) {
            if (params.vestingRecipients[i] == address(0))
                revert M2Errors.ZeroAddress();
            sum += params.vestingAllocations[i];
            unchecked {
                ++i;
            }
        }
        if (sum != M2Constants.VESTING_SEED_RAW)
            revert VestingAllocationMismatch();
    }

    // -----------------------------------------------------------------
    // Internal: pool-key builder
    // -----------------------------------------------------------------

    /// @dev V4 PoolKey: address-sorted currencies, dynamic-fee flag,
    ///      `hooks == hookAddr`, deployment-specific `tickSpacing`.
    function _buildPoolKey(
        address stableAddr,
        address tokenAddr,
        address hookAddr,
        int24 tickSpacing
    ) internal pure returns (PoolKey memory) {
        bool stableIs0 = stableAddr < tokenAddr;
        return
            PoolKey({
                currency0: stableIs0
                    ? Currency.wrap(stableAddr)
                    : Currency.wrap(tokenAddr),
                currency1: stableIs0
                    ? Currency.wrap(tokenAddr)
                    : Currency.wrap(stableAddr),
                fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
                tickSpacing: tickSpacing,
                hooks: IHooks(hookAddr)
            });
    }

    // -----------------------------------------------------------------
    // Internal: CREATE address prediction (RLP-encoded for small nonces)
    // -----------------------------------------------------------------

    /// @dev Predicts the CREATE address of a contract deployed by `deployer`
    ///      at the given `nonce`. Supports nonces in `[1, 0x7f]` via the
    ///      short-form RLP encoding `0xd6 0x94 <addr> <nonce>`. The
    ///      factory's lifetime nonces are bounded by `4 + #vestingWallets`,
    ///      well below 127 for any realistic deployment.
    function _predictCreate(address deployer, uint64 nonce)
        internal
        pure
        returns (address)
    {
        require(nonce >= 1 && nonce <= 0x7f, "M2Factory: nonce range");
        bytes memory rlp = abi.encodePacked(
            bytes1(0xd6),
            bytes1(0x94),
            deployer,
            bytes1(uint8(nonce))
        );
        return address(uint160(uint256(keccak256(rlp))));
    }
}
