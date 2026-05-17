// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {TestBase} from "../helpers/TestBase.sol";
import {M2Treasury} from "../../contracts/treasury/M2Treasury.sol";
import {M2Token} from "../../contracts/token/M2Token.sol";
import {M2Errors} from "../../contracts/libraries/M2Errors.sol";

// =====================================================================
// Local fixtures
// =====================================================================

contract MockStable6 is ERC20 {
    constructor() ERC20("Mock USD", "mUSD") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

/// @notice ERC20 whose `transfer` returns no boolean (non-standard like USDT).
///         Used to verify that the treasury's SafeERC20 wrapper tolerates the
///         deviant return type.
contract NonStandardStable {
    string public constant name = "NonStd";
    string public constant symbol = "NSTD";
    uint8 public constant decimals = 6;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply  += amount;
        emit Transfer(address(0), to, amount);
    }

    /// @dev DELIBERATELY returns nothing (no `returns (bool)`). Tests
    ///      SafeERC20's tolerance for non-standard ERC20 implementations.
    function transfer(address to, uint256 amount) external {
        require(balanceOf[msg.sender] >= amount, "balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to]         += amount;
        emit Transfer(msg.sender, to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "balance");
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= amount, "allowance");
            allowance[from][msg.sender] = allowed - amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to]   += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}

// =====================================================================
// M2Treasury unit tests
// =====================================================================

contract M2TreasuryTest is TestBase {
    // ---- Constants ---------------------------------------------------

    address internal constant HOOK   = address(0xABCD1);
    address internal constant ROUTER = address(0xABCD2);
    address internal constant ALICE  = address(0xA11CE);
    address internal constant BOB    = address(0xB0B);

    uint256 internal constant INITIAL_SUPPLY = 1_000_000_000 * 1e18;
    uint256 internal constant INITIAL_T_6DEC = 1_000_000_000 * 1e6;

    // ---- State -------------------------------------------------------

    MockStable6 internal stable6;
    M2Treasury  internal treasury6;
    M2Token     internal token6;

    uint64 internal _nextNonce = 1;

    // ---- Nonce-prediction helpers (same pattern as M2Token tests) ----

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

    // ---- Setup -------------------------------------------------------

    function setUp() public {
        _consumeNonce();
        stable6 = new MockStable6();

        address trAddr = _consumeNonce();
        address tkAddr = _consumeNonce();
        treasury6 = new M2Treasury(address(stable6), tkAddr);
        assertEq(address(treasury6), trAddr, "treasury prediction");
        token6 = new M2Token(
            address(stable6), address(treasury6), ROUTER, HOOK, ALICE, INITIAL_SUPPLY
        );
        assertEq(address(token6), tkAddr, "token prediction");
        stable6.mint(address(treasury6), INITIAL_T_6DEC);
    }

    // -----------------------------------------------------------------
    // Tests
    // -----------------------------------------------------------------

    function test_GettersAndWiring() public view {
        assertEq(treasury6.stable(), address(stable6));
        assertEq(treasury6.token(), address(token6));
        assertEq(treasury6.backingBalance(), INITIAL_T_6DEC);
    }

    function test_ConstructorRevertsOnZeroAddrs() public {
        // stable=0
        vm.expectRevert();
        new M2Treasury(address(0), address(0xDEAD));
        // token=0
        vm.expectRevert();
        new M2Treasury(address(stable6), address(0));
    }

    function test_OnlyTokenCanCallPayRedemption() public {
        // BOB tries to call payRedemption directly — must revert OnlyToken.
        vm.prank(BOB);
        expectRevert(M2Errors.OnlyToken.selector);
        treasury6.payRedemption(BOB, 1);
        // ALICE (a holder, not the token contract) is equally rejected.
        vm.prank(ALICE);
        expectRevert(M2Errors.OnlyToken.selector);
        treasury6.payRedemption(ALICE, 1);
    }

    function test_TreasuryStableDecreasesOnlyOnRedemption() public {
        uint256 before_ = stable6.balanceOf(address(treasury6));
        uint256 N = 1234 * 1e18;
        vm.prank(ALICE);
        uint256 out = token6.redeem(N);
        uint256 after_ = stable6.balanceOf(address(treasury6));
        assertEq(after_, before_ - out, "treasury delta = payout");
        // The user receives exactly the payout.
        assertEq(stable6.balanceOf(ALICE), out);
    }

    function test_DirectInflowEvent() public {
        // Transfer stable directly into the treasury (revenue router, hook,
        // or external donation). `notifyDirectInflow` emits the post-call
        // balance for off-chain indexers.
        uint256 donation = 500_000 * 1e6;
        stable6.mint(address(treasury6), donation);
        uint256 expectedBal = INITIAL_T_6DEC + donation;

        // Verify the post-call balance matches; the event itself carries the
        // same value and is asserted via `expectEmit`.
        vm.expectEmit(false, false, false, true);
        emit IM2EventsLocal.DirectInflowObserved(expectedBal);
        treasury6.notifyDirectInflow();

        // Treasury balance unchanged by the call itself.
        assertEq(treasury6.backingBalance(), expectedBal);
    }

    /// @dev Sanity: there is no `withdraw`, `sweep`, `rescue`, `setX`,
    ///      `pause`, or `upgradeTo` on M2Treasury. We can't reflectively grep
    ///      Solidity selectors from inside the EVM cleanly, but the unit
    ///      contract surface IS exactly the four IM2Treasury functions plus
    ///      OZ-derived stable/token getters; this is enforced at compile
    ///      time by `solc` (a missing function is a compile error if called).
    ///      Concretely: calling any common admin selector should fail at the
    ///      call site since the function does not exist.
    function test_NoAdminWithdraw() public {
        // Call a non-existent `withdraw(address,uint256)` via low-level call.
        bytes memory data = abi.encodeWithSignature(
            "withdraw(address,uint256)", address(this), 1
        );
        (bool ok,) = address(treasury6).call(data);
        assertFalse(ok, "withdraw selector should not exist");

        data = abi.encodeWithSignature("sweep(address)", address(stable6));
        (ok,) = address(treasury6).call(data);
        assertFalse(ok, "sweep selector should not exist");

        data = abi.encodeWithSignature("rescueStable()");
        (ok,) = address(treasury6).call(data);
        assertFalse(ok, "rescueStable selector should not exist");

        data = abi.encodeWithSignature("pause()");
        (ok,) = address(treasury6).call(data);
        assertFalse(ok, "pause selector should not exist");

        data = abi.encodeWithSignature("upgradeTo(address)", address(0xBEEF));
        (ok,) = address(treasury6).call(data);
        assertFalse(ok, "upgradeTo selector should not exist");

        data = abi.encodeWithSignature("setToken(address)", address(0xBEEF));
        (ok,) = address(treasury6).call(data);
        assertFalse(ok, "setToken selector should not exist");
    }

    function test_SafeERC20Handles_NonStandard_Return() public {
        // Build a fresh treasury backed by a NonStandardStable. We can't use
        // M2Token here because the constructor requires `decimals() <= 18`
        // via IERC20Metadata, which the NonStandardStable satisfies. We DO
        // build a token-backed pair so that `payRedemption` is reachable via
        // a legitimate token caller.
        NonStandardStable ns = new NonStandardStable();
        _consumeNonce();

        address trAddr = _consumeNonce();
        address tkAddr = _consumeNonce();
        M2Treasury tr = new M2Treasury(address(ns), tkAddr);
        assertEq(address(tr), trAddr);
        // The token's constructor reads decimals() from IERC20Metadata; our
        // NonStandardStable exposes `decimals` as a public uint8 state var
        // which Solidity surfaces as the same selector. So the token deploys.
        M2Token tk = new M2Token(
            address(ns), address(tr), ROUTER, HOOK, ALICE, INITIAL_SUPPLY
        );
        assertEq(address(tk), tkAddr);

        // Mint backing into the treasury directly and execute a redemption.
        ns.mint(address(tr), 1_000_000);
        vm.prank(ALICE);
        uint256 out = tk.redeem(1e18);
        // Payout is mulDiv(1e18, 1_000_000, 1e27) = 0 (below 1 stable wei).
        // Repeat with a much larger redemption so payout > 0.
        vm.prank(ALICE);
        out = tk.redeem(100_000 * 1e18);
        assertGt(out, 0);
        // The non-standard transfer succeeded under SafeERC20.
        assertEq(ns.balanceOf(ALICE), out);
    }
}

// ---------------------------------------------------------------------
// Local event-decl helper: re-declares DirectInflowObserved so the test
// file can call `emit IM2EventsLocal.DirectInflowObserved(...)` inside
// `vm.expectEmit`. (Solidity requires the event to be in scope at the
// emit site; we don't inherit IM2Events here because the test contract
// is not the event emitter.)
// ---------------------------------------------------------------------
interface IM2EventsLocal {
    event DirectInflowObserved(uint256 balance);
}
