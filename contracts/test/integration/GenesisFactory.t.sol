// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

import {TestBase} from "../helpers/TestBase.sol";
import {M2Token} from "../../contracts/token/M2Token.sol";
import {M2Treasury} from "../../contracts/treasury/M2Treasury.sol";
import {M2RevenueRouter} from "../../contracts/router/M2RevenueRouter.sol";
import {M2V4Hook} from "../../contracts/hook/M2V4Hook.sol";
import {MockStable} from "../../contracts/mocks/MockStable.sol";
import {M2GenesisFactory} from "../../contracts/genesis/M2GenesisFactory.sol";
import {M2Constants} from "../../contracts/libraries/M2Constants.sol";
import {M2Errors} from "../../contracts/libraries/M2Errors.sol";

import {VestingWallet} from "@openzeppelin/contracts/finance/VestingWallet.sol";

// =====================================================================
// Vm extension: getCode (EDR-supported Foundry cheatcode)
// =====================================================================

interface VmGetCodeGenesis {
    function getCode(string calldata artifactPath) external view returns (bytes memory);
}

// =====================================================================
// GenesisFactoryIntegration — exercises M2GenesisFactory.execute()
// against a real V4 PoolManager + MockStable, under BOTH paired
// address-sort orderings (FINAL_REPORT H4).
// =====================================================================
//
// Sequence per test:
//   1. Deploy MockStable (CREATE2 via in-test deployer, with mined salt
//      chosen so the address sort matches `_wantTokenLowerThanStable`).
//   2. Deploy V4 PoolManager (via a 0.8.26 helper, since v4-core pins
//      pragma 0.8.26 — see `test/helpers/V4PoolManagerDeployer.sol`).
//   3. Deploy M2GenesisFactory.
//   4. Mine the hook salt for the predicted (factory, token, stable,
//      treasury) tuple. The predicted token + treasury depend on the
//      factory's CREATE nonces 1 and 2.
//   5. Build GenesisParams; mint stable to `address(this)` and approve
//      the factory.
//   6. Call factory.execute(params); assert addresses, balances,
//      events, post-state.
//
// Most assertions are state-level (balances, totalSupply, immutable
// getters). The hook's BEFORE_SWAP_FLAG mask is asserted directly on
// the deployed hook address.

abstract contract GenesisFactoryIntegrationBase is TestBase {
    VmGetCodeGenesis internal constant vmCheats =
        VmGetCodeGenesis(address(uint160(uint256(keccak256("hevm cheat code")))));

    // Locked design parameters (mirrors M2Constants).
    uint256 internal constant S0 = 1_000_000_000 * 1e18;
    uint256 internal constant LT0 = 750_000_000 * 1e18;
    uint256 internal constant VESTING_TOTAL = 250_000_000 * 1e18;
    uint256 internal constant T0 = 1_000_000 * 1e6; // $1M, 6 dec
    uint256 internal constant LS0 = 750_000 * 1e6; // $750k, 6 dec

    address internal constant DEPOSITOR = address(0xDE9051704);
    address internal constant VESTING_BENEFICIARY_A = address(0xBE9EF1C1A);
    address internal constant VESTING_BENEFICIARY_B = address(0xBE9EF1C2B);

    // Deployed system handles.
    MockStable internal stableTok;
    IPoolManager internal pm;
    address internal pmDeployer;
    M2GenesisFactory internal factory;

    M2Token internal token;
    M2Treasury internal treasury;
    M2RevenueRouter internal router;
    M2V4Hook internal hook;
    address[] internal vestingWallets;
    PoolKey internal poolKey;
    bool internal stableIs0;

    function _wantTokenLowerThanStable() internal pure virtual returns (bool);

    // ---- Address-prediction helpers ---------------------------------

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

    function _mineStableSalt(
        address deployer,
        bytes32 initCodeHash,
        address tokenAddr,
        bool wantBelow
    ) internal pure returns (bytes32, address) {
        uint160 tk = uint160(tokenAddr);
        for (uint256 i = 0; i < 200_000; ++i) {
            bytes32 salt = bytes32(i);
            address addr = _predictCreate2(deployer, salt, initCodeHash);
            uint160 a = uint160(addr);
            if (wantBelow ? (a < tk) : (a > tk)) {
                return (salt, addr);
            }
        }
        revert("stable salt mine exhausted");
    }

    // ---- In-test CREATE2 helper (only used for MockStable in tests) ---

    function _create2Deploy(bytes32 salt, bytes memory code)
        internal
        returns (address d)
    {
        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            d := create2(0, add(code, 0x20), mload(code), salt)
        }
        require(d != address(0), "test CREATE2 failed");
    }

    // ---- setUp ------------------------------------------------------

    function setUp() public {
        // Test contract nonce ledger:
        //   nonce 1: pmDeployer (a 0.8.26 PoolManager deployer)
        //   nonce 2: M2GenesisFactory
        //   nonce 3: (CREATE2 for MockStable — does bump nonce)
        //   nonce 4+ on inner factory calls (factory's own nonces)

        // 1. Deploy the 0.8.26 PoolManager deployer (nonce 1).
        bytes memory deployerCode = vmCheats.getCode(
            "V4PoolManagerDeployer.sol:V4PoolManagerDeployer"
        );
        address da;
        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            da := create(0, add(deployerCode, 0x20), mload(deployerCode))
        }
        require(da != address(0), "pmDeployer deploy failed");
        pmDeployer = da;

        // 2. Deploy the M2GenesisFactory (nonce 2).
        factory = new M2GenesisFactory();

        // 3. Predict factory's CREATE nonces 1, 2, 4 → treasury, token, router.
        address predictedTreasury = _predictCreate(address(factory), 1);
        address predictedToken = _predictCreate(address(factory), 2);
        address predictedRouter = _predictCreate(address(factory), 4);

        // 4. Mine MockStable salt for the desired ordering vs. predictedToken.
        //    (CREATE2 deploys use `address(this)` as the deployer.)
        bytes memory stableInitCode = type(MockStable).creationCode;
        bytes32 stableInitHash = keccak256(stableInitCode);
        (bytes32 stableSalt, address stableAddr) = _mineStableSalt(
            address(this),
            stableInitHash,
            predictedToken,
            /*wantBelow=*/ !_wantTokenLowerThanStable()
        );

        // 5. Deploy V4 PoolManager (via pmDeployer.deploy() — no nonce bump
        //    on the test contract; bumps pmDeployer's nonce instead).
        (bool ok, bytes memory ret) = pmDeployer.call(
            abi.encodeWithSignature("deploy(address)", address(this))
        );
        require(ok, "pmDeployer.deploy failed");
        pm = IPoolManager(abi.decode(ret, (address)));

        // 6. Compute the hook init code with the (predicted) token, stable,
        //    treasury, plus the actual deployed pmAddr; mine the hook salt.
        bytes memory hookCreationCode = type(M2V4Hook).creationCode;
        bytes memory hookInit = abi.encodePacked(
            hookCreationCode,
            abi.encode(address(pm), predictedToken, stableAddr, predictedTreasury)
        );
        bytes32 hookInitHash = keccak256(hookInit);
        (bytes32 hookSalt, address predictedHook) = _mineHookSalt(
            address(factory),
            hookInitHash
        );

        // 7. Deploy MockStable via the test contract's CREATE2 (nonce bumps
        //    here too, but we no longer care — we already predicted the
        //    factory's nonces from address(factory), not address(this)).
        address sDeployed = _create2Deploy(stableSalt, stableInitCode);
        require(sDeployed == stableAddr, "stable addr mined");
        stableTok = MockStable(sDeployed);

        // 8. Verify ordering matches what was requested.
        if (_wantTokenLowerThanStable()) {
            require(uint160(predictedToken) < uint160(stableAddr), "ordering: token<stable");
        } else {
            require(uint160(predictedToken) > uint160(stableAddr), "ordering: token>stable");
        }
        stableIs0 = uint160(stableAddr) < uint160(predictedToken);

        // 9. Build genesis params + execute.
        M2GenesisFactory.GenesisParams memory params = _buildGenesisParams(
            stableAddr,
            address(pm),
            hookSalt,
            hookCreationCode
        );

        // 10. Mint stable to `address(this)` and approve the factory for
        //     the LP+treasury seed (T0 + LS0).
        stableTok.mint(address(this), T0 + LS0);
        stableTok.approve(address(factory), T0 + LS0);

        // 11. Execute the genesis transaction.
        M2GenesisFactory.Addresses memory addrs = factory.execute(params);
        token = M2Token(addrs.token);
        treasury = M2Treasury(addrs.treasury);
        router = M2RevenueRouter(addrs.router);
        hook = M2V4Hook(addrs.hook);
        vestingWallets = addrs.vestingWallets;

        // 12. Build the canonical pool key for view assertions.
        poolKey = PoolKey({
            currency0: stableIs0
                ? Currency.wrap(address(stableTok))
                : Currency.wrap(address(token)),
            currency1: stableIs0
                ? Currency.wrap(address(token))
                : Currency.wrap(address(stableTok)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: int24(60),
            hooks: IHooks(address(hook))
        });

        // Sanity: predicted addresses matched.
        require(address(treasury) == predictedTreasury, "treasury matches predicted");
        require(address(token) == predictedToken, "token matches predicted");
        require(address(router) == predictedRouter, "router matches predicted");
        require(address(hook) == predictedHook, "hook matches predicted");
    }

    /// @dev Build a vesting schedule with 2 recipients, each receiving half
    ///      of the 250M VESTING_TOTAL. Test config uses `duration = 0` so
    ///      `release()` immediately drains the full balance — the §3.7
    ///      mass-dump pattern.
    function _buildGenesisParams(
        address stableAddr,
        address poolManagerAddr,
        bytes32 hookSalt,
        bytes memory hookCreationCode
    ) internal view returns (M2GenesisFactory.GenesisParams memory params) {
        address[] memory recipients = new address[](2);
        recipients[0] = VESTING_BENEFICIARY_A;
        recipients[1] = VESTING_BENEFICIARY_B;
        uint64[] memory starts = new uint64[](2);
        starts[0] = uint64(block.timestamp);
        starts[1] = uint64(block.timestamp);
        uint64[] memory durations = new uint64[](2);
        // duration = 0 → immediately releasable (test/§3.7 mass-dump row).
        durations[0] = 0;
        durations[1] = 0;
        uint256[] memory allocs = new uint256[](2);
        allocs[0] = VESTING_TOTAL / 2;
        allocs[1] = VESTING_TOTAL - allocs[0]; // catches the +/- 1 wei case

        params = M2GenesisFactory.GenesisParams({
            stable: IERC20(stableAddr),
            poolManager: poolManagerAddr,
            depositor: DEPOSITOR,
            treasurySeed: T0,
            lpStableSeed: LS0,
            lpLiquidity: uint128(1e6), // minimal — sized for tick tolerance
            sqrtPriceX96Initial: uint160(1) << 96,
            tickSpacing: int24(60),
            hookSalt: hookSalt,
            hookCreationCode: hookCreationCode,
            vestingRecipients: recipients,
            vestingStarts: starts,
            vestingDurations: durations,
            vestingAllocations: allocs
        });
    }

    // -----------------------------------------------------------------
    // Tests — wiring + genesis invariants
    // -----------------------------------------------------------------

    function test_DeploysAllFourContractsInOneTx() public view {
        assertNotEq(address(token), address(0));
        assertNotEq(address(treasury), address(0));
        assertNotEq(address(router), address(0));
        assertNotEq(address(hook), address(0));
        assertEq(vestingWallets.length, 2);

        // Token wiring
        assertEq(token.stable(), address(stableTok));
        assertEq(token.treasury(), address(treasury));
        assertEq(token.router(), address(router));
        assertEq(token.hook(), address(hook));
        assertEq(token.INITIAL_SUPPLY(), S0);

        // Treasury wiring
        assertEq(treasury.token(), address(token));
        assertEq(treasury.stable(), address(stableTok));

        // Router wiring
        assertEq(router.stable(), address(stableTok));
        assertEq(router.token(), address(token));
        assertEq(router.treasury(), address(treasury));
        assertEq(router.depositor(), DEPOSITOR);
        assertEq(router.poolManager(), address(pm));
        assertEq(router.hook(), address(hook));

        // Hook wiring
        assertEq(hook.token(), address(token));
        assertEq(hook.stable(), address(stableTok));
        assertEq(hook.treasury(), address(treasury));
        assertEq(hook.poolManager(), address(pm));
        assertTrue(hook.isInitialized());
    }

    function test_GenesisConstraintIntact() public view {
        // Paper eq. 12: T0 * Lt0 == Ls0 * S0
        assertEq(T0 * LT0, LS0 * S0, "T0*Lt0 == Ls0*S0");
    }

    function test_FactoryBalanceZeroAfterGenesis() public view {
        // Stable: pulled-through; factory holds nothing.
        assertEq(stableTok.balanceOf(address(factory)), 0);
        // Token: full S0 minted to factory, then 75% to hook, 25% to vesting.
        assertEq(token.balanceOf(address(factory)), 0);
    }

    function test_TokenDistribution() public view {
        // Hook holds the LP seed (some consumed by initializePool, rest is
        // available as the protocol-owned LP position inside the V4 manager).
        // For the minimal liquidity = 1e6 used in setUp, almost all 7.5e26
        // tokens remain on the hook directly. We just check the hook +
        // pool manager + vesting wallets together hold the full LP_SEED.
        uint256 hookBal = token.balanceOf(address(hook));
        uint256 pmBal = token.balanceOf(address(pm));
        uint256 wA = token.balanceOf(vestingWallets[0]);
        uint256 wB = token.balanceOf(vestingWallets[1]);
        assertEq(wA, VESTING_TOTAL / 2);
        assertEq(wB, VESTING_TOTAL - VESTING_TOTAL / 2);
        // hook + pool manager holds the LP_SEED_RAW; the split between them
        // depends on V4's tick math but the total should be exactly LT0.
        assertEq(hookBal + pmBal, LT0);
        // total supply unchanged (no burns happened during genesis).
        assertEq(token.totalSupply(), S0);
    }

    function test_TreasurySeeded() public view {
        assertEq(stableTok.balanceOf(address(treasury)), T0);
    }

    function test_HookHasBeforeSwapFlag() public view {
        uint160 lowBits = uint160(address(hook)) & Hooks.ALL_HOOK_MASK;
        assertEq(uint256(lowBits), uint256(Hooks.BEFORE_SWAP_FLAG));
    }

    function test_ExecuteIsOneShot() public {
        M2GenesisFactory.GenesisParams memory params = _buildGenesisParams(
            address(stableTok),
            address(pm),
            bytes32(0), // doesn't matter — will revert AlreadyExecuted first
            type(M2V4Hook).creationCode
        );
        vm.expectRevert(M2GenesisFactory.AlreadyExecuted.selector);
        factory.execute(params);
    }

    function test_FactoryReportsExecutedFlag() public view {
        assertTrue(factory.executed());
    }

    function test_VestingWalletRelease_TestConfig() public {
        // duration = 0 → entire allocation is immediately releasable.
        // Release as the beneficiary (any caller can trigger release; the
        // tokens always flow to the beneficiary).
        VestingWallet vw = VestingWallet(payable(vestingWallets[0]));
        assertEq(token.balanceOf(VESTING_BENEFICIARY_A), 0);

        vw.release(address(token));

        uint256 expected = VESTING_TOTAL / 2;
        assertEq(token.balanceOf(VESTING_BENEFICIARY_A), expected);
        assertEq(token.balanceOf(address(vw)), 0);
    }

    function test_RouterPoolKeyMatchesGenesisPoolKey() public view {
        PoolKey memory rk = router.poolKey();
        assertEq(Currency.unwrap(rk.currency0), Currency.unwrap(poolKey.currency0));
        assertEq(Currency.unwrap(rk.currency1), Currency.unwrap(poolKey.currency1));
        assertEq(uint256(rk.fee), uint256(LPFeeLibrary.DYNAMIC_FEE_FLAG));
        assertEq(int256(rk.tickSpacing), int256(int24(60)));
        assertEq(address(rk.hooks), address(hook));
    }

    function test_HookPoolKeyMatchesGenesisPoolKey() public view {
        PoolKey memory hk = hook.poolKey();
        assertEq(Currency.unwrap(hk.currency0), Currency.unwrap(poolKey.currency0));
        assertEq(Currency.unwrap(hk.currency1), Currency.unwrap(poolKey.currency1));
        assertEq(uint256(hk.fee), uint256(LPFeeLibrary.DYNAMIC_FEE_FLAG));
        assertEq(int256(hk.tickSpacing), int256(int24(60)));
        assertEq(address(hk.hooks), address(hook));
    }
}

// =====================================================================
// Concrete paired subclasses (FINAL_REPORT H4)
// =====================================================================

contract GenesisFactoryIntegrationLowAddrTest is GenesisFactoryIntegrationBase {
    function _wantTokenLowerThanStable() internal pure override returns (bool) {
        return true;
    }
}

contract GenesisFactoryIntegrationHighAddrTest is GenesisFactoryIntegrationBase {
    function _wantTokenLowerThanStable() internal pure override returns (bool) {
        return false;
    }
}

// =====================================================================
// Revert-path tests — fresh factory per test
// =====================================================================
//
// These tests deploy a fresh M2GenesisFactory each time so the one-shot
// `_executed` flag isn't already tripped. They cover the four narrow
// failure modes of `execute()`:
//   - VestingAllocationMismatch
//   - VestingArrayLengthMismatch
//   - HookSaltInvalid
//   - GenesisConstraintViolated

contract GenesisFactoryRevertTest is TestBase {
    VmGetCodeGenesis internal constant vmCheats =
        VmGetCodeGenesis(address(uint160(uint256(keccak256("hevm cheat code")))));

    uint256 internal constant S0 = 1_000_000_000 * 1e18;
    uint256 internal constant LT0 = 750_000_000 * 1e18;
    uint256 internal constant T0 = 1_000_000 * 1e6;
    uint256 internal constant LS0 = 750_000 * 1e6;
    address internal constant DEPOSITOR = address(0xDE9051704);

    function _deployPmAndStable()
        internal
        returns (address pmAddr, address stableAddr)
    {
        bytes memory deployerCode = vmCheats.getCode(
            "V4PoolManagerDeployer.sol:V4PoolManagerDeployer"
        );
        address da;
        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            da := create(0, add(deployerCode, 0x20), mload(deployerCode))
        }
        (bool ok, bytes memory ret) = da.call(
            abi.encodeWithSignature("deploy(address)", address(this))
        );
        require(ok, "pm deploy failed");
        pmAddr = abi.decode(ret, (address));

        MockStable s = new MockStable();
        stableAddr = address(s);
    }

    function test_RevertsOnVestingSumMismatch() public {
        M2GenesisFactory factory = new M2GenesisFactory();
        (address pmAddr, address stableAddr) = _deployPmAndStable();

        address[] memory recipients = new address[](1);
        recipients[0] = address(0xBEEF);
        uint64[] memory starts = new uint64[](1);
        starts[0] = uint64(block.timestamp);
        uint64[] memory durations = new uint64[](1);
        durations[0] = 0;
        uint256[] memory allocs = new uint256[](1);
        allocs[0] = 1; // WRONG — should sum to VESTING_SEED_RAW

        M2GenesisFactory.GenesisParams memory params = M2GenesisFactory
            .GenesisParams({
                stable: IERC20(stableAddr),
                poolManager: pmAddr,
                depositor: DEPOSITOR,
                treasurySeed: T0,
                lpStableSeed: LS0,
                lpLiquidity: uint128(1e6),
                sqrtPriceX96Initial: uint160(1) << 96,
                tickSpacing: int24(60),
                hookSalt: bytes32(0),
                hookCreationCode: type(M2V4Hook).creationCode,
                vestingRecipients: recipients,
                vestingStarts: starts,
                vestingDurations: durations,
                vestingAllocations: allocs
            });

        vm.expectRevert(M2GenesisFactory.VestingAllocationMismatch.selector);
        factory.execute(params);
    }

    function test_RevertsOnVestingArrayLengthMismatch() public {
        M2GenesisFactory factory = new M2GenesisFactory();
        (address pmAddr, address stableAddr) = _deployPmAndStable();

        address[] memory recipients = new address[](2);
        recipients[0] = address(0xBEEF1);
        recipients[1] = address(0xBEEF2);
        uint64[] memory starts = new uint64[](1); // WRONG length
        starts[0] = 0;
        uint64[] memory durations = new uint64[](2);
        durations[0] = 0;
        durations[1] = 0;
        uint256[] memory allocs = new uint256[](2);
        allocs[0] = M2Constants.VESTING_SEED_RAW / 2;
        allocs[1] = M2Constants.VESTING_SEED_RAW - allocs[0];

        M2GenesisFactory.GenesisParams memory params = M2GenesisFactory
            .GenesisParams({
                stable: IERC20(stableAddr),
                poolManager: pmAddr,
                depositor: DEPOSITOR,
                treasurySeed: T0,
                lpStableSeed: LS0,
                lpLiquidity: uint128(1e6),
                sqrtPriceX96Initial: uint160(1) << 96,
                tickSpacing: int24(60),
                hookSalt: bytes32(0),
                hookCreationCode: type(M2V4Hook).creationCode,
                vestingRecipients: recipients,
                vestingStarts: starts,
                vestingDurations: durations,
                vestingAllocations: allocs
            });

        vm.expectRevert(M2GenesisFactory.VestingArrayLengthMismatch.selector);
        factory.execute(params);
    }

    function test_RevertsOnFloorSpotMismatch() public {
        M2GenesisFactory factory = new M2GenesisFactory();
        (address pmAddr, address stableAddr) = _deployPmAndStable();

        address[] memory recipients = new address[](1);
        recipients[0] = address(0xBEEF);
        uint64[] memory starts = new uint64[](1);
        starts[0] = uint64(block.timestamp);
        uint64[] memory durations = new uint64[](1);
        durations[0] = 0;
        uint256[] memory allocs = new uint256[](1);
        allocs[0] = M2Constants.VESTING_SEED_RAW;

        // T0 * Lt0 != Ls0' * S0 if we use LS0 + 1.
        M2GenesisFactory.GenesisParams memory params = M2GenesisFactory
            .GenesisParams({
                stable: IERC20(stableAddr),
                poolManager: pmAddr,
                depositor: DEPOSITOR,
                treasurySeed: T0,
                lpStableSeed: LS0 + 1, // violates the constraint
                lpLiquidity: uint128(1e6),
                sqrtPriceX96Initial: uint160(1) << 96,
                tickSpacing: int24(60),
                hookSalt: bytes32(0),
                hookCreationCode: type(M2V4Hook).creationCode,
                vestingRecipients: recipients,
                vestingStarts: starts,
                vestingDurations: durations,
                vestingAllocations: allocs
            });

        vm.expectRevert(M2Errors.GenesisConstraintViolated.selector);
        factory.execute(params);
    }

    function test_RevertsOnUnminedHookSalt() public {
        M2GenesisFactory factory = new M2GenesisFactory();
        (address pmAddr, address stableAddr) = _deployPmAndStable();

        address[] memory recipients = new address[](1);
        recipients[0] = address(0xBEEF);
        uint64[] memory starts = new uint64[](1);
        starts[0] = uint64(block.timestamp);
        uint64[] memory durations = new uint64[](1);
        durations[0] = 0;
        uint256[] memory allocs = new uint256[](1);
        allocs[0] = M2Constants.VESTING_SEED_RAW;

        // Use salt 0 — overwhelmingly likely NOT to satisfy the flag mask.
        M2GenesisFactory.GenesisParams memory params = M2GenesisFactory
            .GenesisParams({
                stable: IERC20(stableAddr),
                poolManager: pmAddr,
                depositor: DEPOSITOR,
                treasurySeed: T0,
                lpStableSeed: LS0,
                lpLiquidity: uint128(1e6),
                sqrtPriceX96Initial: uint160(1) << 96,
                tickSpacing: int24(60),
                hookSalt: bytes32(0), // not mined
                hookCreationCode: type(M2V4Hook).creationCode,
                vestingRecipients: recipients,
                vestingStarts: starts,
                vestingDurations: durations,
                vestingAllocations: allocs
            });

        vm.expectRevert(M2GenesisFactory.HookSaltInvalid.selector);
        factory.execute(params);
    }
}

