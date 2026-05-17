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
import {M2Constants} from "../../../contracts/libraries/M2Constants.sol";
import {M2InvariantHandler} from "./M2InvariantHandler.sol";

/// @title InvariantFixture
/// @notice Shared deployment fixture for the Phase 3 invariant suite.
///         Wires real {M2Token}, {M2Treasury}, {M2RevenueRouter} bytecode
///         against {MockAMM} + {MockHook} stand-ins (Phase 4 swaps the
///         mocks for real V4 PoolManager + {M2V4Hook}). Predicts CREATE
///         addresses via the test contract's nonce so the four mutually-
///         immutable contracts (treasury, token, router, hook) can be
///         linked in a single deployment pass.
abstract contract InvariantFixture is TestBase {
    // -----------------------------------------------------------------
    // Canonical genesis parameters (mock environment uses 6-decimal stable)
    // -----------------------------------------------------------------

    /// @notice Total genesis supply (raw 18-decimal units).
    uint256 internal constant S0 = 1_000_000_000 * 1e18;
    /// @notice LP token seed (raw 18-decimal units).
    uint256 internal constant LT0 = 750_000_000 * 1e18;
    /// @notice Non-LP supply (held initially by the handler).
    uint256 internal constant NON_LP_SUPPLY = S0 - LT0;
    /// @notice Treasury seed in stable units. With d_s=6, T0 = $1,000,000.
    uint256 internal constant T0 = 1_000_000 * 1e6;
    /// @notice LP stable seed. With d_s=6, Ls0 = $750,000.
    uint256 internal constant LS0 = 750_000 * 1e6;
    /// @notice Stable allocation to the handler for routeRevenue / lpBuy
    ///         during fuzz runs. Generous enough that 100,000 bounded
    ///         sequences cannot deplete it.
    uint256 internal constant DEPOSITOR_STABLE = 1_000_000_000 * 1e6; // $1B

    // -----------------------------------------------------------------
    // Deployed system (populated by `_deployInvariantFixture`)
    // -----------------------------------------------------------------

    MockStable internal stableTok;
    MockAMM internal amm;
    MockHook internal hookContract;
    M2Treasury internal treasuryContract;
    M2Token internal tokenContract;
    M2RevenueRouter internal routerContract;
    M2InvariantHandler internal handler;

    // -----------------------------------------------------------------
    // Nonce-prediction helpers
    // -----------------------------------------------------------------

    function _predictCreate(address deployer, uint64 nonce)
        internal
        pure
        returns (address)
    {
        require(nonce >= 1 && nonce <= 0x7f, "InvariantFixture: nonce range");
        bytes memory rlp = abi.encodePacked(
            bytes1(0xd6),
            bytes1(0x94),
            deployer,
            bytes1(uint8(nonce))
        );
        return address(uint160(uint256(keccak256(rlp))));
    }

    // -----------------------------------------------------------------
    // Deployment (single-pass, all nonces pre-computed)
    // -----------------------------------------------------------------

    function _deployInvariantFixture() internal {
        // Predict every address from this contract's CREATE nonces. The
        // ordering is:
        //   nonce 1 -> stableTok
        //   nonce 2 -> amm
        //   nonce 3 -> hookContract
        //   nonce 4 -> treasuryContract
        //   nonce 5 -> tokenContract
        //   nonce 6 -> routerContract
        //   nonce 7 -> handler
        address stableAddr = _predictCreate(address(this), 1);
        address ammAddr = _predictCreate(address(this), 2);
        address hookAddr = _predictCreate(address(this), 3);
        address treasuryAddr = _predictCreate(address(this), 4);
        address tokenAddr = _predictCreate(address(this), 5);
        address routerAddr = _predictCreate(address(this), 6);
        address handlerAddr = _predictCreate(address(this), 7);

        // 1. MockStable (no deps).
        stableTok = new MockStable();
        require(address(stableTok) == stableAddr, "fixture: stable addr");

        // 2. MockAMM (depends on token, hook by address only).
        amm = new MockAMM(stableAddr, tokenAddr, hookAddr);
        require(address(amm) == ammAddr, "fixture: amm addr");

        // 3. MockHook.
        hookContract = new MockHook(ammAddr, stableAddr, tokenAddr, treasuryAddr);
        require(address(hookContract) == hookAddr, "fixture: hook addr");

        // 4. M2Treasury.
        treasuryContract = new M2Treasury(stableAddr, tokenAddr);
        require(address(treasuryContract) == treasuryAddr, "fixture: treasury addr");

        // 5. M2Token — genesis mint to this fixture; we redistribute.
        tokenContract = new M2Token(
            stableAddr,
            treasuryAddr,
            routerAddr,
            hookAddr,
            address(this),
            S0
        );
        require(address(tokenContract) == tokenAddr, "fixture: token addr");

        // 6. M2RevenueRouter — depositor = handler.
        PoolKey memory key = _buildPoolKey(stableAddr, tokenAddr, hookAddr);
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

        // Seed LP reserves.
        stableTok.mint(address(this), LS0);
        stableTok.approve(ammAddr, type(uint256).max);
        IERC20(tokenAddr).approve(ammAddr, type(uint256).max);
        amm.seedLiquidity(LT0, LS0);

        // Seed treasury.
        stableTok.mint(treasuryAddr, T0);

        // Build the actor list.
        address[7] memory actorsArr = [
            handlerAddr,             // 0 depositor
            address(0xA11CE),        // 1 holder1
            address(0xB0B),          // 2 holder2
            address(0xC0FFEE),       // 3 whale
            address(0xA4B5),         // 4 arbitrageur
            address(0xBABE),         // 5 randomCaller
            address(0xBEEF)          // 6 vestingRecipient
        ];

        // 7. M2InvariantHandler.
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

        // Distribute non-LP supply to the handler (acts as the unified
        // holder partition for all actor seeds).
        IERC20(tokenAddr).transfer(handlerAddr, NON_LP_SUPPLY);
        // Mint depositor stable to the handler.
        stableTok.mint(handlerAddr, DEPOSITOR_STABLE);

        // Approve the router from the handler's context so routeRevenue
        // can pull stable.
        vm.prank(handlerAddr);
        stableTok.approve(routerAddr, type(uint256).max);
        // Approve the AMM from the handler's context so lpBuy/lpSell can
        // transferFrom the handler's balance.
        vm.prank(handlerAddr);
        stableTok.approve(ammAddr, type(uint256).max);
        vm.prank(handlerAddr);
        IERC20(tokenAddr).approve(ammAddr, type(uint256).max);
    }

    // -----------------------------------------------------------------
    // Internal helpers
    // -----------------------------------------------------------------

    function _buildPoolKey(
        address stableAddr,
        address tokenAddr,
        address hookAddr
    ) internal pure returns (PoolKey memory) {
        bool stableIs0 = stableAddr < tokenAddr;
        return PoolKey({
            currency0: stableIs0
                ? Currency.wrap(stableAddr)
                : Currency.wrap(tokenAddr),
            currency1: stableIs0
                ? Currency.wrap(tokenAddr)
                : Currency.wrap(stableAddr),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: int24(60),
            hooks: IHooks(hookAddr)
        });
    }
}
