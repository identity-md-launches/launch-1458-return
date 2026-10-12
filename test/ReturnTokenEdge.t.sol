// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ReturnToken} from "../src/ReturnToken.sol";

/// @dev Deploys raw creation code the way the launch factory does, with CREATE2 and no helpers,
/// optionally forwarding native currency to the constructor. Test-only.
contract RawCreationDeployer {
    receive() external payable {}

    function create2(bytes memory code, bytes32 salt) external returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create2(0, add(code, 32), mload(code), salt)
        }
    }

    function createWithValue(bytes memory code, uint256 value) external returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create(value, add(code, 32), mload(code))
        }
    }

    function move(ReturnToken token, address to, uint256 amount) external returns (bool) {
        return token.transfer(to, amount);
    }
}

/// @notice Inputs the implementation did not necessarily consider: the zero deployer, a paid
/// constructor, a redeployment at the same salt, selectors it does not declare, recipients it
/// cannot refuse, allowances at and one past their limits, and the admin calls the protected
/// launch harness tries, encoded exactly as that harness encodes them.
contract ReturnTokenEdgeTest is Test {
    uint256 private constant SUPPLY = 1_000_000_000 * 1e18;
    uint256 private constant EIP170_RUNTIME_LIMIT = 24_576;
    uint256 private constant EIP3860_INITCODE_LIMIT = 49_152;

    address private constant HOLDER = address(0x401D);
    address private constant OTHER = address(0x07E5);
    address private constant ATTACKER = address(0xBEEF);

    ReturnToken private token;
    RawCreationDeployer private factory;
    address private deployer;
    address private alice;
    address private bob;
    address private spender;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        deployer = makeAddr("deployer");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        spender = makeAddr("spender");
        factory = new RawCreationDeployer();
        vm.prank(deployer);
        token = new ReturnToken();
    }

    // ----------------------------------------------------------------- construction

    function test_CreationCodeNeedsNoArgumentsAndLandsAtThePredictedCreate2Address() public {
        bytes memory code = type(ReturnToken).creationCode;
        assertLe(code.length, EIP3860_INITCODE_LIMIT, "creation code exceeds the EIP-3860 limit");

        uint64 launchNumber = 42;
        bytes32 salt = bytes32(uint256(launchNumber));
        address predicted = address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(factory), salt, keccak256(code)))))
        );
        address deployed = factory.create2(code, salt);

        assertEq(deployed, predicted, "the token did not land where the factory predicts");
        ReturnToken launched = ReturnToken(deployed);
        assertEq(launched.totalSupply(), SUPPLY);
        assertEq(launched.balanceOf(address(factory)), SUPPLY, "the factory does not hold the whole supply");
        assertEq(launched.balanceOf(address(this)), 0);
        assertEq(launched.balanceOf(deployer), 0);
        assertLe(deployed.code.length, EIP170_RUNTIME_LIMIT);
    }

    function testFuzz_AnyLaunchNumberSaltDeploysOnceAndNeverTwice(uint64 launchNumber) public {
        bytes memory code = type(ReturnToken).creationCode;
        bytes32 salt = bytes32(uint256(launchNumber));

        address first = factory.create2(code, salt);
        assertTrue(first != address(0), "first deployment failed");
        assertEq(ReturnToken(first).balanceOf(address(factory)), SUPPLY);

        // The same salt is taken: CREATE2 yields the zero address and nothing is minted twice.
        address second = factory.create2(code, salt);
        assertEq(second, address(0), "a second deployment at the same salt succeeded");
        assertEq(ReturnToken(first).totalSupply(), SUPPLY);
        assertEq(ReturnToken(first).balanceOf(address(factory)), SUPPLY);
    }

    function testFuzz_AnyNonZeroDeployerReceivesTheWholeSupply(address anyDeployer) public {
        address who = address(uint160(bound(uint256(uint160(anyDeployer)), 1, type(uint160).max)));
        vm.prank(who);
        ReturnToken fresh = new ReturnToken();
        assertEq(fresh.totalSupply(), SUPPLY);
        assertEq(fresh.balanceOf(who), SUPPLY);
        assertEq(fresh.balanceOf(deployer), 0);
        assertEq(fresh.balanceOf(tx.origin), who == tx.origin ? SUPPLY : 0);
    }

    function test_RevertConstructorFromTheZeroAddress() public {
        // The mint target is msg.sender; ERC-20 refuses to mint to the zero address, so a
        // deployment with no sender cannot exist rather than creating a token nobody holds.
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(address(0));
        new ReturnToken();
    }

    function test_ConstructorRefusesNativeCurrency() public {
        bytes memory code = type(ReturnToken).creationCode;
        vm.deal(address(factory), 1 ether);

        assertEq(factory.createWithValue(code, 1 wei), address(0), "a paid constructor succeeded");
        assertEq(factory.createWithValue(code, 1 ether), address(0), "a paid constructor succeeded");
        assertEq(address(factory).balance, 1 ether, "a failed deployment kept the value");

        address free = factory.createWithValue(code, 0);
        assertTrue(free != address(0), "an unpaid deployment failed");
        assertEq(free.balance, 0);
        assertEq(ReturnToken(free).balanceOf(address(factory)), SUPPLY);
    }

    function test_RuntimeDoesNotDependOnWhoDeployed() public {
        vm.prank(alice);
        ReturnToken byAlice = new ReturnToken();
        vm.prank(bob);
        ReturnToken byBob = new ReturnToken();
        assertEq(address(byAlice).codehash, address(byBob).codehash, "the runtime bakes in the deployer");
        assertEq(address(byAlice).codehash, address(token).codehash);
        assertEq(byAlice.balanceOf(alice), SUPPLY);
        assertEq(byBob.balanceOf(bob), SUPPLY);
        assertEq(byAlice.balanceOf(bob), 0);
        assertEq(byBob.balanceOf(alice), 0);
    }

    // ----------------------------------------------------------------- surface

    function testFuzz_UndeclaredSelectorsRevertAndMoveNothing(bytes4 selector, bytes calldata args, address caller)
        public
    {
        for (uint256 i; i < 4 && _isDeclared(selector); ++i) {
            selector = bytes4(keccak256(abi.encodePacked(selector, i)));
        }
        if (_isDeclared(selector)) return;
        _fund(alice, 5e18);

        vm.prank(caller);
        (bool ok, bytes memory ret) = address(token).call(abi.encodePacked(selector, args));

        assertFalse(ok, "the token answered an undeclared selector");
        assertEq(ret.length, 0, "an undeclared selector returned data");
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(deployer), SUPPLY - 5e18);
        assertEq(token.balanceOf(alice), 5e18);
        assertEq(token.balanceOf(caller), caller == alice ? 5e18 : caller == deployer ? SUPPLY - 5e18 : 0);
    }

    function test_NoPermitOwnerPauseBurnOrLegacyAllowanceHelpers() public {
        _fund(alice, 5e18);
        bytes[] memory calls = new bytes[](14);
        calls[0] = abi.encodeWithSignature("DOMAIN_SEPARATOR()");
        calls[1] = abi.encodeWithSignature("nonces(address)", alice);
        calls[2] = abi.encodeWithSignature(
            "permit(address,address,uint256,uint256,uint8,bytes32,bytes32)",
            alice,
            spender,
            1e18,
            type(uint256).max,
            uint8(27),
            bytes32(0),
            bytes32(0)
        );
        calls[3] = abi.encodeWithSignature("owner()");
        calls[4] = abi.encodeWithSignature("paused()");
        calls[5] = abi.encodeWithSignature("renounceOwnership()");
        calls[6] = abi.encodeWithSignature("burn(uint256)", 1e18);
        calls[7] = abi.encodeWithSignature("burn(address,uint256)", alice, 1e18);
        calls[8] = abi.encodeWithSignature("burnFrom(address,uint256)", alice, 1e18);
        // OpenZeppelin v5 removed these; integrations that call them get a revert, not a no-op.
        calls[9] = abi.encodeWithSignature("increaseAllowance(address,uint256)", spender, 1e18);
        calls[10] = abi.encodeWithSignature("decreaseAllowance(address,uint256)", spender, 1e18);
        calls[11] = abi.encodeWithSignature("rescueTokens(address,address,uint256)", address(token), alice, 1e18);
        calls[12] = abi.encodeWithSignature("withdraw()");
        calls[13] = abi.encodeWithSignature("setFee(uint256)", 100);

        for (uint256 i; i < calls.length; ++i) {
            vm.prank(alice);
            (bool ok,) = address(token).call(calls[i]);
            assertFalse(ok, "an unexpected entry point answered");
            vm.prank(deployer);
            (ok,) = address(token).call(calls[i]);
            assertFalse(ok, "an unexpected entry point answered the deployer");
        }
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(alice), 5e18);
        assertEq(token.allowance(alice, spender), 0);
    }

    /// @dev The protected launch harness tries these from a stranger and from the factory, with
    /// (attacker, uint128 max) as arguments. The supply must not grow and the stranger gains nothing.
    function test_AdminSignaturesEncodedLikeTheProtectedHarnessCannotGrowSupply() public {
        bytes memory code = type(ReturnToken).creationCode;
        ReturnToken launched = ReturnToken(factory.create2(code, bytes32(uint256(1))));
        string[10] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "unpause()",
            "setMinter(address)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory data = abi.encodeWithSignature(signatures[i], ATTACKER, type(uint128).max);
            vm.prank(ATTACKER);
            (bool ok,) = address(launched).call(data);
            assertFalse(ok, signatures[i]);
            assertEq(launched.totalSupply(), SUPPLY, signatures[i]);
            assertEq(launched.balanceOf(ATTACKER), 0, signatures[i]);
            vm.prank(address(factory));
            (ok,) = address(launched).call(data);
            assertFalse(ok, signatures[i]);
            assertEq(launched.totalSupply(), SUPPLY, signatures[i]);
            assertEq(launched.balanceOf(address(factory)), SUPPLY, signatures[i]);
        }
    }

    /// @dev The protected launch harness tries these from the factory with (holder, true) as
    /// arguments, then tries a transferFrom without approval. The holder keeps every token and
    /// can still transfer afterwards.
    function test_FreezeSignaturesEncodedLikeTheProtectedHarnessLeaveTheHolderFree() public {
        bytes memory code = type(ReturnToken).creationCode;
        ReturnToken launched = ReturnToken(factory.create2(code, bytes32(uint256(2))));
        assertTrue(factory.move(launched, HOLDER, SUPPLY / 1_000));
        uint256 held = launched.balanceOf(HOLDER);
        assertEq(held, SUPPLY / 1_000);

        string[12] memory signatures = [
            "pause()",
            "blacklist(address)",
            "blocklist(address)",
            "freeze(address)",
            "freezeAccount(address)",
            "setBlacklist(address,bool)",
            "setBlocked(address,bool)",
            "lock(address)",
            "disableTransfers()",
            "setTransfersEnabled(bool)",
            "burnFrom(address,uint256)",
            "seize(address)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory data = abi.encodeWithSignature(signatures[i], HOLDER, true);
            vm.prank(address(factory));
            (bool ok,) = address(launched).call(data);
            assertFalse(ok, signatures[i]);
            assertEq(launched.balanceOf(HOLDER), held, signatures[i]);
        }

        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(factory), 0, 1)
        );
        vm.prank(address(factory));
        launched.transferFrom(HOLDER, address(factory), 1);
        assertEq(launched.balanceOf(HOLDER), held, "a privileged call moved the holder's balance");

        vm.prank(HOLDER);
        assertTrue(launched.transfer(OTHER, held / 2), "the holder can no longer transfer");
        assertEq(launched.balanceOf(OTHER), held / 2);
        assertEq(launched.balanceOf(HOLDER), held - held / 2);
        assertEq(launched.totalSupply(), SUPPLY);
    }

    // ----------------------------------------------------------------- recipients

    function testFuzz_AnyNonZeroRecipientReceivesExactlyWhatWasSent(address rawTo, uint256 rawAmount) public {
        address to = address(uint160(bound(uint256(uint160(rawTo)), 1, type(uint160).max)));
        uint256 amount = bound(rawAmount, 0, SUPPLY);
        uint256 before = token.balanceOf(to);

        vm.prank(deployer);
        assertTrue(token.transfer(to, amount));

        if (to == deployer) {
            assertEq(token.balanceOf(deployer), SUPPLY);
        } else {
            assertEq(token.balanceOf(to), before + amount);
            assertEq(token.balanceOf(deployer), SUPPLY - amount);
        }
        assertEq(token.totalSupply(), SUPPLY, "a transfer changed the supply");
    }

    function test_SendingToConventionalBurnAddressDoesNotBurn() public {
        vm.prank(deployer);
        assertTrue(token.transfer(address(0xdEaD), 1e18));
        assertEq(token.balanceOf(address(0xdEaD)), 1e18);
        assertEq(token.totalSupply(), SUPPLY, "0xdEaD is a holder, not a burn, for this token");
    }

    function test_TokensSentToTheTokenItselfAreHeldAndUnrecoverable() public {
        vm.prank(deployer);
        assertTrue(token.transfer(address(token), 7e18));
        assertEq(token.balanceOf(address(token)), 7e18);
        assertEq(token.totalSupply(), SUPPLY);

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, deployer, 0, 1));
        vm.prank(deployer);
        token.transferFrom(address(token), deployer, 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 7e18));
        vm.prank(alice);
        token.transferFrom(address(token), alice, 7e18);
        assertEq(token.balanceOf(address(token)), 7e18, "tokens left the token contract");
    }

    function test_RevertSelfTransferAboveBalanceStillChecksBalance() public {
        _fund(alice, 10e18);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 10e18, 10e18 + 1));
        vm.prank(alice);
        token.transfer(alice, 10e18 + 1);
        assertEq(token.balanceOf(alice), 10e18);
    }

    // ----------------------------------------------------------------- allowances

    function test_RevertApproveFromTheZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidApprover.selector, address(0)));
        vm.prank(address(0));
        token.approve(spender, 1);
        assertEq(token.allowance(address(0), spender), 0);
    }

    function test_SpendingAllowanceEmitsOnlyTheTransferEvent() public {
        _fund(alice, 10e18);
        vm.prank(alice);
        token.approve(spender, 10e18);

        vm.recordLogs();
        vm.prank(spender);
        assertTrue(token.transferFrom(alice, bob, 4e18));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(logs.length, 1, "transferFrom emitted more than the Transfer event");
        assertEq(logs[0].topics[0], keccak256("Transfer(address,address,uint256)"));
        assertEq(token.allowance(alice, spender), 6e18, "the remaining allowance is only readable, not emitted");
    }

    function testFuzz_ApproveOverwritesRegardlessOfPriorValue(uint256 first, uint256 second) public {
        vm.startPrank(alice);
        assertTrue(token.approve(spender, first));
        assertEq(token.allowance(alice, spender), first);
        assertTrue(token.approve(spender, second));
        assertEq(token.allowance(alice, spender), second, "approve did not overwrite");
        assertTrue(token.approve(spender, second));
        assertEq(token.allowance(alice, spender), second, "a repeated approve is not idempotent");
        vm.stopPrank();
        assertEq(token.balanceOf(alice), 0, "approving created tokens");
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_AllowancesAreIsolatedPerOwnerAndSpender(address rawOwner, address rawSpender, uint256 amount)
        public
    {
        address owner = address(uint160(bound(uint256(uint160(rawOwner)), 1, type(uint160).max)));
        address approved = address(uint160(bound(uint256(uint160(rawSpender)), 1, type(uint160).max)));
        address otherSpender = makeAddr("other spender");
        address otherOwner = makeAddr("other owner");

        vm.prank(owner);
        assertTrue(token.approve(approved, amount));

        assertEq(token.allowance(owner, approved), amount);
        assertEq(token.allowance(owner, otherSpender), 0, "allowance leaked to another spender");
        assertEq(token.allowance(otherOwner, approved), 0, "allowance leaked to another owner");
        assertEq(token.allowance(approved, owner), owner == approved ? amount : 0, "allowance is not directional");
        assertEq(token.allowance(owner, owner), owner == approved ? amount : 0);
    }

    function testFuzz_ExactAllowanceAndBalanceBoundaryIsSpendableOnce(uint256 rawAmount) public {
        uint256 amount = bound(rawAmount, 1, SUPPLY);
        _fund(alice, amount);
        vm.prank(alice);
        token.approve(spender, amount);

        vm.prank(spender);
        assertTrue(token.transferFrom(alice, bob, amount));
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), amount);
        assertEq(token.allowance(alice, spender), 0);

        // Both the allowance and the balance are exhausted; the allowance is checked first.
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(alice, bob, 1);
    }

    function testFuzz_UnlimitedAllowanceStopsAtTheBalanceNotTheAllowance(uint256 rawBalance) public {
        uint256 balance = bound(rawBalance, 0, SUPPLY);
        _fund(alice, balance);
        vm.prank(alice);
        token.approve(spender, type(uint256).max);

        vm.prank(spender);
        assertTrue(token.transferFrom(alice, bob, balance));
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), balance);
        assertEq(token.allowance(alice, spender), type(uint256).max, "an unlimited allowance was decremented");

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        vm.prank(spender);
        token.transferFrom(alice, bob, 1);
        assertEq(token.allowance(alice, spender), type(uint256).max);
    }

    function testFuzz_AllowanceAboveBalanceNeverCreatesTokens(uint256 rawBalance, uint256 rawExtra) public {
        uint256 balance = bound(rawBalance, 0, SUPPLY);
        uint256 extra = bound(rawExtra, 1, type(uint256).max - SUPPLY - 1);
        uint256 approved = balance + extra;
        _fund(alice, balance);
        vm.prank(alice);
        token.approve(spender, approved);

        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, balance, approved)
        );
        vm.prank(spender);
        token.transferFrom(alice, bob, approved);
        assertEq(token.allowance(alice, spender), approved, "a refused spend consumed allowance");
        assertEq(token.balanceOf(alice), balance);
        assertEq(token.balanceOf(bob), 0);

        vm.prank(spender);
        assertTrue(token.transferFrom(alice, bob, balance));
        assertEq(token.allowance(alice, spender), extra, "the allowance did not drop by exactly what was spent");
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), balance);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_NobodyWithoutAllowanceMovesAHoldersTokens(address stranger, uint256 rawAmount) public {
        uint256 amount = bound(rawAmount, 1, SUPPLY);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, stranger, 0, amount));
        vm.prank(stranger);
        token.transferFrom(deployer, stranger, amount);
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.balanceOf(stranger), stranger == deployer ? SUPPLY : 0);
    }

    function testFuzz_HolderCannotTransferFromThemselvesWithoutSelfApproval(uint256 rawAmount) public {
        uint256 amount = bound(rawAmount, 1, SUPPLY);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, deployer, 0, amount));
        vm.prank(deployer);
        token.transferFrom(deployer, alice, amount);

        vm.prank(deployer);
        token.approve(deployer, amount);
        vm.prank(deployer);
        assertTrue(token.transferFrom(deployer, alice, amount));
        assertEq(token.balanceOf(alice), amount);
        assertEq(token.allowance(deployer, deployer), 0);
    }

    // ----------------------------------------------------------------- helpers

    function _fund(address to, uint256 amount) private {
        vm.prank(deployer);
        assertTrue(token.transfer(to, amount));
    }

    function _isDeclared(bytes4 selector) private pure returns (bool) {
        return selector == IERC20Metadata.name.selector || selector == IERC20Metadata.symbol.selector
            || selector == IERC20Metadata.decimals.selector || selector == IERC20.totalSupply.selector
            || selector == IERC20.balanceOf.selector || selector == IERC20.transfer.selector
            || selector == IERC20.allowance.selector || selector == IERC20.approve.selector
            || selector == IERC20.transferFrom.selector || selector == bytes4(keccak256("INITIAL_SUPPLY()"));
    }
}
