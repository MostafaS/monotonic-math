// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {TestBase} from "../helpers/TestBase.sol";
import {M2Token} from "../../contracts/token/M2Token.sol";
import {M2Treasury} from "../../contracts/treasury/M2Treasury.sol";
import {M2Errors} from "../../contracts/libraries/M2Errors.sol";
import {M2Constants} from "../../contracts/libraries/M2Constants.sol";

// =====================================================================
// Local fixtures (test-only mocks; the canonical MockStable lives under
// contracts/mocks/ and is owned by Agent B). These are deliberately
// minimal — they exist only to satisfy the M2Token constructor's
// `decimals()` read and to mint backing stable into the treasury.
// =====================================================================

contract MockStable6 is ERC20 {
    constructor() ERC20("Mock USD", "mUSD") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract MockStable18 is ERC20 {
    constructor() ERC20("Mock 18", "m18") {}
    function decimals() public pure override returns (uint8) { return 18; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract MockStable19 is ERC20 {
    constructor() ERC20("Mock 19", "m19") {}
    function decimals() public pure override returns (uint8) { return 19; }
}

// =====================================================================
// M2Token unit tests
// =====================================================================
//
// Wiring note: The (Treasury, Token) pair has a circular reference — the
// treasury's `_TOKEN` must equal the token's deployed address, and the
// token's `_TREASURY` must equal the treasury's deployed address. In
// production this is resolved by the genesis factory using CREATE2 with
// pre-computed addresses. In these unit tests we resolve it by predicting
// the next CREATE address from this test contract's nonce: each `new X()`
// call increments the nonce by exactly 1 (contract-account nonces start
// at 1). We track this in `_nextNonce` for clarity and verify the
// prediction matches reality via an `assertEq` on every deployment.
// =====================================================================

contract M2TokenTest is TestBase {
    // ---- Constants ---------------------------------------------------

    address internal constant HOOK   = address(0xABCD1);
    address internal constant ROUTER = address(0xABCD2);
    address internal constant ALICE  = address(0xA11CE);
    address internal constant BOB    = address(0xB0B);

    uint256 internal constant INITIAL_SUPPLY  = 1_000_000_000 * 1e18;
    uint256 internal constant INITIAL_T_6DEC  = 1_000_000_000 * 1e6;
    uint256 internal constant INITIAL_T_18DEC = 1_000_000_000 * 1e18;

    // ---- Canonical (6-decimal) deployment ----------------------------

    MockStable6 internal stable6;
    M2Treasury  internal treasury6;
    M2Token     internal token6;

    // ---- Nonce-prediction state --------------------------------------

    /// @dev Tracks the test contract's CREATE nonce so we can predict the
    ///      address of the next `new`. Contract-account nonces start at 1
    ///      and increment by 1 per CREATE. We bump this counter on every
    ///      deployment helper invocation.
    uint64 internal _nextNonce = 1;

    // ---- Helpers -----------------------------------------------------

    /// @dev RLP-encodes (deployer, nonce) and returns the resulting CREATE
    ///      address. Only nonces 1..0x7f are supported — sufficient for any
    ///      reasonable test suite. Nonces are bumped via `_consumeNonce`.
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

    /// @dev Returns the next CREATE address and increments the counter.
    function _consumeNonce() internal returns (address) {
        address a = _predictCreate(address(this), _nextNonce);
        _nextNonce += 1;
        return a;
    }

    /// @dev Deploys a fresh (treasury, token) pair backed by `stable_`. The
    ///      treasury is deployed FIRST with the token's predicted address,
    ///      then the token is deployed with the treasury's actual address.
    function _deployPair(address stable_, address mintTo)
        internal
        returns (M2Treasury tr, M2Token tk)
    {
        // Step 1: predict treasury and token addresses.
        address trAddr = _consumeNonce(); // nonce N   -> treasury
        address tkAddr = _consumeNonce(); // nonce N+1 -> token
        // Step 2: deploy treasury bound to the predicted token address.
        tr = new M2Treasury(stable_, tkAddr);
        assertEq(address(tr), trAddr, "treasury address prediction");
        // Step 3: deploy token bound to the actual treasury address.
        tk = new M2Token(stable_, address(tr), ROUTER, HOOK, mintTo, INITIAL_SUPPLY);
        assertEq(address(tk), tkAddr, "token address prediction");
    }

    // ---- Setup -------------------------------------------------------

    function setUp() public {
        // Stand-alone stable deployment (consumes nonce 1).
        _consumeNonce();
        stable6 = new MockStable6();
        (treasury6, token6) = _deployPair(address(stable6), ALICE);
        stable6.mint(address(treasury6), INITIAL_T_6DEC);
    }

    // -----------------------------------------------------------------
    // Tests
    // -----------------------------------------------------------------

    function test_GenesisMintWiring() public view {
        assertEq(token6.totalSupply(), INITIAL_SUPPLY);
        assertEq(token6.balanceOf(ALICE), INITIAL_SUPPLY);
        assertEq(token6.stable(), address(stable6));
        assertEq(uint256(token6.stableDecimals()), 6);
        assertEq(token6.treasury(), address(treasury6));
        assertEq(token6.router(), ROUTER);
        assertEq(token6.hook(), HOOK);
        assertEq(token6.INITIAL_SUPPLY(), INITIAL_SUPPLY);
        assertEq(stable6.balanceOf(address(treasury6)), INITIAL_T_6DEC);
        // ERC20 metadata.
        assertEq(token6.name(), M2Constants.TOKEN_NAME);
        assertEq(token6.symbol(), M2Constants.TOKEN_SYMBOL);
        assertEq(uint256(token6.decimals()), 18);
    }

    function test_RedeemPreservesOrIncreasesFloor() public {
        uint256 N = 100 * 1e18;
        uint256 T0 = stable6.balanceOf(address(treasury6));
        uint256 S0 = token6.totalSupply();
        vm.prank(ALICE);
        uint256 stableOut = token6.redeem(N);
        uint256 T1 = stable6.balanceOf(address(treasury6));
        uint256 S1 = token6.totalSupply();
        assertEq(T1, T0 - stableOut);
        assertEq(S1, S0 - N);
        // Cross-product floor monotonicity (avoids fixed-point rounding).
        assertGe(T1 * S0, T0 * S1, "floor must be non-decreasing");
    }

    function test_FullRedemptionDrainsTreasuryExactly() public {
        // N == S -> stableOut = mulDiv(S, T, S) = T exactly. Treasury drains.
        vm.prank(ALICE);
        uint256 out = token6.redeem(INITIAL_SUPPLY);
        assertEq(out, INITIAL_T_6DEC);
        assertEq(stable6.balanceOf(address(treasury6)), 0);
        assertEq(token6.totalSupply(), 0);
    }

    function test_PartialRedemptionLeavesDustInTreasury() public {
        // Engineer (T, S, N) with non-zero residual r = (N*T) mod S.
        // Use a fresh deployment where T = 1_000_001 (raw 6-dec) so that
        // 7 * 1e18 redeemed against S = 1e27 gives a non-zero residual.
        MockStable6 s = new MockStable6();
        _consumeNonce(); // bump nonce for the stable deployment above.
        (M2Treasury tr, M2Token tk) = _deployPair(address(s), ALICE);

        s.mint(address(tr), 1_000_001);
        uint256 N  = 7 * 1e18;
        uint256 T0 = 1_000_001;
        uint256 S0 = INITIAL_SUPPLY;
        uint256 r  = mulmod(N, T0, S0);
        assertGt(r, 0, "setup: residual should be positive");
        uint256 expected = Math.mulDiv(N, T0, S0);

        vm.prank(ALICE);
        uint256 out = tk.redeem(N);
        assertEq(out, expected);
        // Dust = T0 - expected; must remain in treasury.
        assertEq(s.balanceOf(address(tr)), T0 - expected);
        // r > 0 implies strict floor increase in cross-product form.
        assertGt((T0 - expected) * S0, T0 * (S0 - N));
    }

    function test_Lemma4_2ExactIdentity() public pure {
        // 256 deterministic (T, S, N) triples; assert Lemma 4.2 identity:
        //   r = mulmod(N, T, S); P = mulDiv(N, T, S);
        //   (T - P) * S == T * (S - N) + r
        //   r > 0  =>  (T - P) * S >  T * (S - N)
        //   r == 0 =>  (T - P) * S == T * (S - N)
        //
        // Bound S, T <= 1e30 so that T * (S - N) and (T - P) * S fit in
        // uint256 (1e60 << 2^256).
        uint256 runs = 256;
        for (uint256 i = 0; i < runs; ++i) {
            uint256 seed = uint256(keccak256(abi.encode(i, "lemma42")));
            uint256 S = (seed % 1e30) + 1;
            uint256 N = (uint256(keccak256(abi.encode(seed, "N"))) % S) + 1;
            uint256 T = uint256(keccak256(abi.encode(seed, "T"))) % 1e30;

            uint256 r = mulmod(N, T, S);
            uint256 P = Math.mulDiv(N, T, S);

            require((T - P) * S == T * (S - N) + r, "Lemma 4.2 identity");
            if (r > 0) {
                require((T - P) * S > T * (S - N), "r > 0 => strict");
            } else {
                require((T - P) * S == T * (S - N), "r = 0 => eq");
            }
        }
    }

    function test_RedeemRevertsOnZeroAmount() public {
        vm.prank(ALICE);
        expectRevert(M2Errors.ZeroAmount.selector);
        token6.redeem(0);
    }

    function test_RedeemRevertsOnInsufficientBalance() public {
        // BOB holds 0 tokens; redeem must revert in the ERC20 _burn check.
        vm.prank(BOB);
        vm.expectRevert(); // OZ ERC20InsufficientBalance — selector not asserted.
        token6.redeem(1);
    }

    function test_FloorPriceRevertsWhenSupplyZero() public {
        vm.prank(ALICE);
        token6.redeem(INITIAL_SUPPLY);
        assertEq(token6.totalSupply(), 0);
        expectRevert(M2Errors.SupplyExhausted.selector);
        token6.floorPrice();
    }

    function test_RedeemRevertsWhenSupplyZero() public {
        vm.prank(ALICE);
        token6.redeem(INITIAL_SUPPLY);
        assertEq(token6.totalSupply(), 0);
        vm.prank(ALICE);
        expectRevert(M2Errors.SupplyExhausted.selector);
        token6.redeem(1);
    }

    function test_FloorPriceConsistency_6dec() public view {
        // For d_s = 6: floorPrice() = T * 10^30 / S (18-dec FP).
        // Identity: mulDiv(amount, T, S) == mulDiv(amount, fp * 10^6, 10^36).
        uint256 fp = token6.floorPrice();
        uint256 T  = stable6.balanceOf(address(treasury6));
        uint256 S  = token6.totalSupply();

        uint256[5] memory amounts = [
            uint256(1e18),
            uint256(123 * 1e18),
            uint256(987_654_321 * 1e18),
            uint256(7 * 1e15),
            uint256(1)
        ];
        for (uint256 i = 0; i < amounts.length; ++i) {
            uint256 lhs = Math.mulDiv(amounts[i], T, S);
            uint256 rhs = Math.mulDiv(amounts[i], fp * 1e6, 1e36);
            assertEq(lhs, rhs, "floorPrice consistency d_s=6");
        }
    }

    function test_FloorPriceConsistency_18dec() public {
        MockStable18 s18 = new MockStable18();
        _consumeNonce();
        (M2Treasury tr, M2Token tk) = _deployPair(address(s18), ALICE);
        s18.mint(address(tr), INITIAL_T_18DEC);

        uint256 fp = tk.floorPrice();
        uint256 T  = s18.balanceOf(address(tr));
        uint256 S  = tk.totalSupply();

        uint256[5] memory amounts = [
            uint256(1e18),
            uint256(123 * 1e18),
            uint256(50_000_000 * 1e18),
            uint256(1),
            uint256(1e9)
        ];
        for (uint256 i = 0; i < amounts.length; ++i) {
            uint256 lhs = Math.mulDiv(amounts[i], T, S);
            uint256 rhs = Math.mulDiv(amounts[i], fp * 1e18, 1e36);
            assertEq(lhs, rhs, "floorPrice consistency d_s=18");
        }
    }

    function test_UnauthorizedBurnerCannotBurn() public {
        vm.prank(BOB);
        expectRevert(M2Errors.UnauthorizedBurner.selector);
        token6.burnFromAuthorized(ALICE, 1);
    }

    function test_HookCanBurn() public {
        uint256 supplyBefore = token6.totalSupply();
        vm.prank(HOOK);
        token6.burnFromAuthorized(ALICE, 1e18);
        assertEq(token6.totalSupply(), supplyBefore - 1e18);
        assertEq(token6.balanceOf(ALICE), INITIAL_SUPPLY - 1e18);
    }

    function test_RouterCanBurn() public {
        uint256 supplyBefore = token6.totalSupply();
        vm.prank(ROUTER);
        token6.burnFromAuthorized(ALICE, 2e18);
        assertEq(token6.totalSupply(), supplyBefore - 2e18);
        assertEq(token6.balanceOf(ALICE), INITIAL_SUPPLY - 2e18);
    }

    function test_SelfRedeemBurnPath() public {
        // The `redeem` path uses `_burn` internally; the token contract
        // itself is the third authorized burner. Exercise it explicitly.
        uint256 amt = 5e18;
        uint256 sBefore = token6.totalSupply();
        vm.prank(ALICE);
        token6.redeem(amt);
        assertEq(token6.totalSupply(), sBefore - amt);
    }

    function test_ConstructorRevertsOnDecimals19() public {
        MockStable19 s19 = new MockStable19();
        _consumeNonce();
        // Predict treasury and token nonces but only treasury is deployed
        // successfully — the token deploy reverts.
        address trAddr = _consumeNonce();
        address tkAddr = _consumeNonce();
        M2Treasury tr = new M2Treasury(address(s19), tkAddr);
        assertEq(address(tr), trAddr);

        expectRevert(M2Errors.DecimalsOutOfRange.selector);
        new M2Token(address(s19), address(tr), ROUTER, HOOK, ALICE, INITIAL_SUPPLY);
    }

    function test_ConstructorRevertsOnZeroAddrs() public {
        // Each branch uses a fresh `new M2Token(...)` to verify the require.
        // stable=0
        vm.expectRevert();
        new M2Token(address(0), address(treasury6), ROUTER, HOOK, ALICE, 1);
        // treasury=0
        vm.expectRevert();
        new M2Token(address(stable6), address(0), ROUTER, HOOK, ALICE, 1);
        // router=0
        vm.expectRevert();
        new M2Token(address(stable6), address(treasury6), address(0), HOOK, ALICE, 1);
        // hook=0
        vm.expectRevert();
        new M2Token(address(stable6), address(treasury6), ROUTER, address(0), ALICE, 1);
        // mintRecipient=0
        vm.expectRevert();
        new M2Token(address(stable6), address(treasury6), ROUTER, HOOK, address(0), 1);
    }

    function test_PermitDomain() public view {
        // EIP-712 domain separator must use name="Monotonic Math", version="1",
        // chainId, and the token's deployed address.
        bytes32 ds = token6.DOMAIN_SEPARATOR();
        bytes32 typeHash = keccak256(
            "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
        );
        bytes32 expected = keccak256(
            abi.encode(
                typeHash,
                keccak256(bytes(M2Constants.TOKEN_NAME)),
                keccak256(bytes("1")),
                block.chainid,
                address(token6)
            )
        );
        assertEq(ds, expected);
    }
}
