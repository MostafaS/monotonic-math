// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

import {TestBase} from "../../helpers/TestBase.sol";
import {M2Token} from "../../../contracts/token/M2Token.sol";
import {M2Treasury} from "../../../contracts/treasury/M2Treasury.sol";
import {M2RevenueRouter} from "../../../contracts/router/M2RevenueRouter.sol";
import {MockStable} from "../../../contracts/mocks/MockStable.sol";
import {M2V4Hook} from "../../../contracts/hook/M2V4Hook.sol";

// =====================================================================
// Vm extension: getCode (EDR-supported Foundry cheatcode)
// =====================================================================

interface VmGetCodeFixture {
    function getCode(string calldata artifactPath) external view returns (bytes memory);
}

// =====================================================================
// In-test CREATE2 deployer shared by all integration tests
// =====================================================================

contract IntegrationCreate2Deployer {
    // solhint-disable-next-line no-inline-assembly
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
// IntegrationFixtureBase — shared deployment plumbing for the paired
// integration suite. Subclasses pick the address-sort ordering by
// overriding `_wantTokenLowerThanStable()`.
// =====================================================================
//
// Deployment order:
//   - test contract CREATE nonce 1: IntegrationCreate2Deployer
//   - test contract CREATE nonce 2: V4PoolManagerDeployer (via vm.getCode)
//   - test contract CREATE nonce 3: M2Treasury
//   - test contract CREATE nonce 4: M2Token (predicts router @ nonce 5)
//   - test contract CREATE nonce 5: M2RevenueRouter
//   - CREATE2 (via IntegrationCreate2Deployer): MockStable at mined salt
//   - CREATE2 (via IntegrationCreate2Deployer): M2V4Hook at mined salt
//   - CALL into pmDeployer: V4 PoolManager
//
// The MockStable salt is mined so that `address(stable) < address(token)`
// when `_wantTokenLowerThanStable() == false`, or
// `address(stable) > address(token)` when `_wantTokenLowerThanStable() == true`.
// The hook salt is mined for the BEFORE_SWAP_FLAG bottom-14-bit pattern.

abstract contract IntegrationFixtureBase is TestBase {
    VmGetCodeFixture internal constant vmCheats =
        VmGetCodeFixture(address(uint160(uint256(keccak256("hevm cheat code")))));

    // ---- Genesis params ---------------------------------------------
    uint256 internal constant S0 = 1_000_000_000 * 1e18;
    uint256 internal constant LT0 = 750_000_000 * 1e18;
    uint256 internal constant T0 = 1_000_000 * 1e6;
    uint256 internal constant LS0 = 750_000 * 1e6;

    /// @dev Authorized depositor used in the router constructor. Tests
    ///      that need to drive `routeRevenue` should prank as this
    ///      address (and fund it with stable via `stableTok.mint(...)`).
    address internal constant DEPOSITOR = address(0xDE9051704);

    // ---- Deployed system --------------------------------------------
    IPoolManager internal pm;
    address internal pmDeployer;
    MockStable internal stableTok;
    M2Treasury internal treasury;
    M2Token internal token;
    M2V4Hook internal hook;
    M2RevenueRouter internal router;
    IntegrationCreate2Deployer internal create2;
    PoolKey internal poolKey;
    bool internal stableIs0;

    /// @dev Override in subclasses to pick the desired ordering.
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

    /// @dev Mine a CREATE2 salt for which the resulting address satisfies
    ///      the BEFORE_SWAP_FLAG hook flag pattern.
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

    /// @dev Mine a CREATE2 salt for the MockStable's address so it sits
    ///      below (`wantBelow == true`) or above (`wantBelow == false`)
    ///      the supplied token address.
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

    // ---- Shared deploy routine --------------------------------------

    /// @dev Deploys the canonical M² system with the chosen address
    ///      ordering. `wantTokenLowerThanStable == true` ⇒
    ///      `address(token) < address(stable)`. The hook is deployed via
    ///      CREATE2 in either case (with a freshly mined salt). The
    ///      router is deployed at test-contract nonce 5 and exposed via
    ///      `router` for the route-revenue suite; the other integration
    ///      suites simply ignore it.
    function _deploy(bool wantTokenLowerThanStable) internal {
        // 1. Predict CREATE addresses by nonce.
        address create2Addr = _predictCreate(address(this), 1);
        address pmDeployerAddr = _predictCreate(address(this), 2);
        address trAddr = _predictCreate(address(this), 3);
        address tkAddr = _predictCreate(address(this), 4);
        address rtAddr = _predictCreate(address(this), 5);
        address pmPredicted = _predictCreate(pmDeployerAddr, 1);

        // 2. Deploy Create2 helper (nonce 1).
        create2 = new IntegrationCreate2Deployer();
        require(address(create2) == create2Addr, "create2 addr");

        // 3. Deploy V4PoolManagerDeployer (nonce 2).
        bytes memory deployerCode = vmCheats.getCode(
            "V4PoolManagerDeployer.sol:V4PoolManagerDeployer"
        );
        address da;
        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            da := create(0, add(deployerCode, 0x20), mload(deployerCode))
        }
        require(da != address(0) && da == pmDeployerAddr, "pmDeployer addr");
        pmDeployer = da;

        // 4. Mine MockStable salt for the desired ordering against the
        //    predicted token address.
        bytes memory stableInitCode = type(MockStable).creationCode;
        bytes32 stableInitHash = keccak256(stableInitCode);
        (bytes32 stableSalt, address stableAddr) = _mineStableSalt(
            create2Addr,
            stableInitHash,
            tkAddr,
            /*wantBelow=*/ !wantTokenLowerThanStable
        );

        // 5. Mine hook salt — depends on (poolManager, token, stable,
        //    treasury), all known at this point.
        bytes memory hookInitCode = abi.encodePacked(
            type(M2V4Hook).creationCode,
            abi.encode(pmPredicted, tkAddr, stableAddr, trAddr)
        );
        bytes32 hookInitHash = keccak256(hookInitCode);
        (bytes32 hookSalt, address hookAddr) = _mineHookSalt(
            create2Addr,
            hookInitHash
        );

        // 6. Deploy MockStable via CREATE2.
        address sDeployed = create2.deploy(stableSalt, stableInitCode);
        require(sDeployed == stableAddr, "stable addr mined");
        stableTok = MockStable(sDeployed);

        // 7. Sanity: the ordering matches what was requested.
        if (wantTokenLowerThanStable) {
            require(uint160(tkAddr) < uint160(stableAddr), "ordering: token<stable");
        } else {
            require(uint160(tkAddr) > uint160(stableAddr), "ordering: token>stable");
        }
        stableIs0 = uint160(stableAddr) < uint160(tkAddr);

        // 8. Treasury (nonce 3).
        treasury = new M2Treasury(stableAddr, tkAddr);
        require(address(treasury) == trAddr, "treasury addr");

        // 9. Token (nonce 4) — wired to predicted router address at
        //    nonce 5.
        token = new M2Token(
            stableAddr,
            address(treasury),
            rtAddr,
            hookAddr,
            address(this),
            S0
        );
        require(address(token) == tkAddr, "token addr");
        stableTok.mint(address(treasury), T0);

        // 10. Deploy V4 PoolManager via pmDeployer (CALL: no nonce bump).
        (bool ok, bytes memory ret) = pmDeployer.call(
            abi.encodeWithSignature("deploy(address)", address(this))
        );
        require(ok, "pmDeployer.deploy failed");
        pm = IPoolManager(abi.decode(ret, (address)));
        require(address(pm) == pmPredicted, "pm addr prediction");

        // 11. Pool key (built before router so the router's poolKey arg
        //     is internally consistent with the hook + currencies).
        poolKey = PoolKey({
            currency0: stableIs0
                ? Currency.wrap(address(stableTok))
                : Currency.wrap(address(token)),
            currency1: stableIs0
                ? Currency.wrap(address(token))
                : Currency.wrap(address(stableTok)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: int24(60),
            hooks: IHooks(hookAddr)
        });

        // 12. Router (nonce 5).
        router = new M2RevenueRouter(
            address(stableTok),
            address(token),
            address(treasury),
            DEPOSITOR,
            address(pm),
            hookAddr,
            poolKey
        );
        require(address(router) == rtAddr, "router addr");

        // 13. Hook via CREATE2.
        address deployed = create2.deploy(hookSalt, hookInitCode);
        require(deployed == hookAddr, "hook addr matches mined");
        hook = M2V4Hook(deployed);
    }
}
