// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

import {TestBase} from "../../helpers/TestBase.sol";
import {M2Token} from "../../../contracts/token/M2Token.sol";
import {M2Treasury} from "../../../contracts/treasury/M2Treasury.sol";
import {M2RevenueRouter} from "../../../contracts/router/M2RevenueRouter.sol";
import {MockStable} from "../../../contracts/mocks/MockStable.sol";
import {MockAMM} from "../../../contracts/mocks/MockAMM.sol";
import {MockHook} from "../../../contracts/mocks/MockHook.sol";
import {M2InvariantHandler} from "./M2InvariantHandler.sol";

// =====================================================================
// PairedCreate2Deployer — minimal CREATE2 helper used by the paired
// invariant fixture to mine a MockStable address satisfying a given
// ordering predicate vs. the predicted M2Token CREATE address.
// =====================================================================

contract PairedCreate2Deployer {
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

/// @title InvariantFixturePaired
/// @notice Paired-address-sort variant of the canonical invariant fixture.
///         Identical wiring to {InvariantFixture} except the MockStable
///         is deployed via CREATE2 with a salt mined so that
///         `address(stable) < address(token)` (low-stable lane) or
///         `address(stable) > address(token)` (high-stable lane). Used by
///         {AddressOrderingInvariant_StableLowTest} +
///         {AddressOrderingInvariant_StableHighTest} to exercise
///         Theorem 4.3 floor monotonicity AND invariant (iv) redemption
///         solvency under BOTH orderings. The {V4FullRangeIntegration}
///         paired matrix covers the address-sort-sensitive HOOK direction
///         logic against a real V4 PoolManager; this fixture closes the
///         loop for the mock-AMM invariant lane (defense-in-depth: any
///         future drift in the four immutable contracts' bytecode that
///         silently depends on (stable, token) sort would be caught here).
abstract contract InvariantFixturePaired is TestBase {
    // -----------------------------------------------------------------
    // Canonical genesis parameters (mirror {InvariantFixture})
    // -----------------------------------------------------------------

    uint256 internal constant S0 = 1_000_000_000 * 1e18;
    uint256 internal constant LT0 = 750_000_000 * 1e18;
    uint256 internal constant NON_LP_SUPPLY = S0 - LT0;
    uint256 internal constant T0 = 1_000_000 * 1e6;
    uint256 internal constant LS0 = 750_000 * 1e6;
    uint256 internal constant DEPOSITOR_STABLE = 1_000_000_000 * 1e6;

    // -----------------------------------------------------------------
    // Deployed system
    // -----------------------------------------------------------------

    MockStable internal stableTok;
    MockAMM internal amm;
    MockHook internal hookContract;
    M2Treasury internal treasuryContract;
    M2Token internal tokenContract;
    M2RevenueRouter internal routerContract;
    M2InvariantHandler internal handler;
    PairedCreate2Deployer internal create2;
    bool internal stableIsCurrency0;

    /// @dev Subclasses override to pick the ordering:
    ///      `true`  → `address(stable) < address(token)` (stable is currency0)
    ///      `false` → `address(stable) > address(token)` (token is currency0)
    function _wantStableLowerThanToken() internal pure virtual returns (bool);

    // -----------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------

    function _predictCreate(address deployer, uint64 nonce)
        internal
        pure
        returns (address)
    {
        require(nonce >= 1 && nonce <= 0x7f, "InvariantFixturePaired: nonce range");
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

    /// @dev Mine a CREATE2 salt for the MockStable so its predicted
    ///      address sits below or above the predicted M2Token address.
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
        revert("InvariantFixturePaired: stable salt mine exhausted");
    }

    // -----------------------------------------------------------------
    // Deployment
    // -----------------------------------------------------------------
    //
    // Nonce layout (test contract):
    //   nonce 1 -> create2 helper
    //   nonce 2 -> amm
    //   nonce 3 -> hookContract
    //   nonce 4 -> treasuryContract
    //   nonce 5 -> tokenContract
    //   nonce 6 -> routerContract
    //   nonce 7 -> handler
    // The MockStable is deployed via CREATE2 from `create2` (so its address
    // does NOT consume a test-contract nonce).
    function _deployInvariantFixturePaired() internal {
        bool wantStableLower = _wantStableLowerThanToken();

        // 1. Predict CREATE-derived addresses.
        address create2Addr = _predictCreate(address(this), 1);
        address ammAddr = _predictCreate(address(this), 2);
        address hookAddr = _predictCreate(address(this), 3);
        address treasuryAddr = _predictCreate(address(this), 4);
        address tokenAddr = _predictCreate(address(this), 5);
        address routerAddr = _predictCreate(address(this), 6);
        address handlerAddr = _predictCreate(address(this), 7);

        // 2. Deploy Create2 helper (nonce 1).
        create2 = new PairedCreate2Deployer();
        require(address(create2) == create2Addr, "fixture: create2 addr");

        // 3. Mine MockStable salt for the desired ordering against the
        //    predicted tokenAddr.
        bytes memory stableInitCode = type(MockStable).creationCode;
        bytes32 stableInitHash = keccak256(stableInitCode);
        (bytes32 stableSalt, address stableAddr) = _mineStableSalt(
            create2Addr,
            stableInitHash,
            tokenAddr,
            wantStableLower
        );

        // 4. Deploy MockStable via CREATE2 (no test-contract nonce bump).
        address sDeployed = create2.deploy(stableSalt, stableInitCode);
        require(sDeployed == stableAddr, "fixture: stable addr mined");
        stableTok = MockStable(sDeployed);
        stableIsCurrency0 = wantStableLower;
        // Sanity check the mined ordering.
        if (wantStableLower) {
            require(uint160(stableAddr) < uint160(tokenAddr), "ordering: stable<token");
        } else {
            require(uint160(stableAddr) > uint160(tokenAddr), "ordering: stable>token");
        }

        // 5. MockAMM (nonce 2).
        amm = new MockAMM(stableAddr, tokenAddr, hookAddr);
        require(address(amm) == ammAddr, "fixture: amm addr");

        // 6. MockHook (nonce 3).
        hookContract = new MockHook(ammAddr, stableAddr, tokenAddr, treasuryAddr);
        require(address(hookContract) == hookAddr, "fixture: hook addr");

        // 7. M2Treasury (nonce 4).
        treasuryContract = new M2Treasury(stableAddr, tokenAddr);
        require(address(treasuryContract) == treasuryAddr, "fixture: treasury addr");

        // 8. M2Token (nonce 5) — genesis mint to this fixture.
        tokenContract = new M2Token(
            stableAddr,
            treasuryAddr,
            routerAddr,
            hookAddr,
            address(this),
            S0
        );
        require(address(tokenContract) == tokenAddr, "fixture: token addr");

        // 9. M2RevenueRouter (nonce 6) — depositor = handler.
        PoolKey memory key = PoolKey({
            currency0: wantStableLower
                ? Currency.wrap(stableAddr)
                : Currency.wrap(tokenAddr),
            currency1: wantStableLower
                ? Currency.wrap(tokenAddr)
                : Currency.wrap(stableAddr),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: int24(60),
            hooks: IHooks(hookAddr)
        });
        routerContract = new M2RevenueRouter(
            stableAddr,
            tokenAddr,
            treasuryAddr,
            handlerAddr,
            ammAddr,
            hookAddr,
            key
        );
        require(address(routerContract) == routerAddr, "fixture: router addr");

        // 10. Seed LP reserves.
        stableTok.mint(address(this), LS0);
        stableTok.approve(ammAddr, type(uint256).max);
        IERC20(tokenAddr).approve(ammAddr, type(uint256).max);
        amm.seedLiquidity(LT0, LS0);

        // 11. Seed treasury.
        stableTok.mint(treasuryAddr, T0);

        // 12. Build the actor list.
        address[7] memory actorsArr = [
            handlerAddr,             // 0 depositor
            address(0xA11CE),        // 1 holder1
            address(0xB0B),          // 2 holder2
            address(0xC0FFEE),       // 3 whale
            address(0xA4B5),         // 4 arbitrageur
            address(0xBABE),         // 5 randomCaller
            address(0xBEEF)          // 6 vestingRecipient
        ];

        // 13. M2InvariantHandler (nonce 7).
        handler = new M2InvariantHandler(
            stableAddr,
            tokenAddr,
            treasuryAddr,
            routerAddr,
            ammAddr,
            hookAddr,
            actorsArr,
            S0
        );
        require(address(handler) == handlerAddr, "fixture: handler addr");

        // 14. Distribute non-LP supply to the handler.
        IERC20(tokenAddr).transfer(handlerAddr, NON_LP_SUPPLY);
        // 15. Mint depositor stable to the handler.
        stableTok.mint(handlerAddr, DEPOSITOR_STABLE);

        // 16. Approve the router from the handler's context.
        vm.prank(handlerAddr);
        stableTok.approve(routerAddr, type(uint256).max);
        vm.prank(handlerAddr);
        stableTok.approve(ammAddr, type(uint256).max);
        vm.prank(handlerAddr);
        IERC20(tokenAddr).approve(ammAddr, type(uint256).max);

        // 17. Seed the redemption-solvency ghost.
        handler.seedMinFloor();
    }
}
