// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ReturnToken} from "../src/ReturnToken.sol";

contract ReturnTokenTest is Test {
    uint256 private constant SUPPLY = 1_000_000_000_000_000_000_000_000_000;

    ReturnToken private token;
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
        vm.prank(deployer);
        token = new ReturnToken();
    }

    function test_MetadataAndEntireSupplyBelongToDeployer() public view {
        assertEq(token.name(), "Return");
        assertEq(token.symbol(), "RETURN");
        assertEq(token.decimals(), 18);
        assertEq(token.INITIAL_SUPPLY(), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.allowance(deployer, spender), 0);
    }

    function test_ConstructorEmitsExactlyOneMint() public {
        vm.recordLogs();
        vm.prank(alice);
        ReturnToken fresh = new ReturnToken();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(logs.length, 1);
        assertEq(logs[0].emitter, address(fresh));
        assertEq(logs[0].topics.length, 3);
        assertEq(logs[0].topics[0], keccak256("Transfer(address,address,uint256)"));
        assertEq(logs[0].topics[1], bytes32(0));
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(alice))));
        assertEq(abi.decode(logs[0].data, (uint256)), SUPPLY);
        assertEq(fresh.balanceOf(alice), SUPPLY);
        assertEq(fresh.balanceOf(deployer), 0);
    }

    function test_TransferDeliversExactAmountAndEmitsEvent() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(deployer, alice, 123e18);
        vm.prank(deployer);
        assertTrue(token.transfer(alice, 123e18));

        assertEq(token.balanceOf(alice), 123e18);
        assertEq(token.balanceOf(deployer), SUPPLY - 123e18);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_EntireSupplyCanMoveAndReturn() public {
        vm.prank(deployer);
        assertTrue(token.transfer(alice, SUPPLY));
        assertEq(token.balanceOf(deployer), 0);
        assertEq(token.balanceOf(alice), SUPPLY);

        vm.prank(alice);
        assertTrue(token.transfer(deployer, SUPPLY));
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_ZeroTransferFromEmptyAccountEmitsEvent() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(alice, bob, 0);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 0));
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_SelfTransferPreservesBalance() public {
        vm.prank(deployer);
        assertTrue(token.transfer(deployer, SUPPLY));
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_RevertTransferAboveBalanceIsAtomic() public {
        _fundAlice(10e18);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 10e18, 10e18 + 1));
        vm.prank(alice);
        token.transfer(bob, 10e18 + 1);
        assertEq(token.balanceOf(alice), 10e18);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_RevertTransferMaximumAmount() public {
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, deployer, SUPPLY, type(uint256).max)
        );
        vm.prank(deployer);
        token.transfer(alice, type(uint256).max);
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
    }

    function test_RevertTransferToZeroIncludingZeroAmount() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(deployer);
        token.transfer(address(0), 1);

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(deployer);
        token.transfer(address(0), 0);
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_ApproveEmitsEventAndOverwritesAllowance() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Approval(alice, spender, 40e18);
        vm.prank(alice);
        assertTrue(token.approve(spender, 40e18));
        assertEq(token.allowance(alice, spender), 40e18);

        vm.prank(alice);
        assertTrue(token.approve(spender, 7e18));
        assertEq(token.allowance(alice, spender), 7e18);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_RevertApproveZeroSpender() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        vm.prank(alice);
        token.approve(address(0), 1);
        assertEq(token.allowance(alice, address(0)), 0);
    }

    function test_TransferFromConsumesAllowanceAndEmitsTransfer() public {
        _fundAlice(100e18);
        _approveAlice(60e18);
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(alice, bob, 40e18);
        vm.prank(spender);
        assertTrue(token.transferFrom(alice, bob, 40e18));

        assertEq(token.balanceOf(alice), 60e18);
        assertEq(token.balanceOf(bob), 40e18);
        assertEq(token.allowance(alice, spender), 20e18);
        assertEq(token.totalSupply(), SUPPLY);

        vm.prank(spender);
        assertTrue(token.transferFrom(alice, bob, 20e18));
        assertEq(token.allowance(alice, spender), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(alice, bob, 1);
        assertEq(token.balanceOf(alice), 40e18);
        assertEq(token.balanceOf(bob), 60e18);
    }

    function test_TransferFromToSelfConsumesAllowanceWithoutChangingBalance() public {
        _fundAlice(10e18);
        _approveAlice(10e18);
        vm.prank(spender);
        assertTrue(token.transferFrom(alice, alice, 10e18));
        assertEq(token.balanceOf(alice), 10e18);
        assertEq(token.allowance(alice, spender), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_ZeroTransferFromNeedsNoAllowance() public {
        vm.prank(spender);
        assertTrue(token.transferFrom(alice, bob, 0));
        assertEq(token.allowance(alice, spender), 0);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_UnlimitedAllowanceIsNotDecremented() public {
        _fundAlice(100e18);
        _approveAlice(type(uint256).max);
        vm.startPrank(spender);
        assertTrue(token.transferFrom(alice, bob, 60e18));
        assertTrue(token.transferFrom(alice, bob, 40e18));
        vm.stopPrank();
        assertEq(token.allowance(alice, spender), type(uint256).max);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 100e18);
    }

    function test_RevocationPreventsSpending() public {
        _fundAlice(100e18);
        _approveAlice(type(uint256).max);
        vm.expectEmit(true, true, false, true, address(token));
        emit Approval(alice, spender, 0);
        _approveAlice(0);

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(alice, bob, 1);
        assertEq(token.allowance(alice, spender), 0);
        assertEq(token.balanceOf(alice), 100e18);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_RevertUnapprovedSpenderCannotUseAnotherSpendersAllowance() public {
        _fundAlice(100e18);
        _approveAlice(100e18);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1));
        vm.prank(bob);
        token.transferFrom(alice, bob, 1);
        assertEq(token.allowance(alice, spender), 100e18);
        assertEq(token.balanceOf(alice), 100e18);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_RevertInsufficientAllowanceIsAtomic() public {
        _fundAlice(100e18);
        _approveAlice(10e18);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 10e18, 10e18 + 1)
        );
        vm.prank(spender);
        token.transferFrom(alice, bob, 10e18 + 1);
        assertEq(token.allowance(alice, spender), 10e18);
        assertEq(token.balanceOf(alice), 100e18);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_RevertInsufficientBalanceRestoresSpentAllowance() public {
        _fundAlice(10e18);
        _approveAlice(20e18);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 10e18, 20e18));
        vm.prank(spender);
        token.transferFrom(alice, bob, 20e18);
        assertEq(token.allowance(alice, spender), 20e18);
        assertEq(token.balanceOf(alice), 10e18);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_RevertTransferFromToZeroRestoresAllowance() public {
        _fundAlice(10e18);
        _approveAlice(10e18);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(spender);
        token.transferFrom(alice, address(0), 10e18);
        assertEq(token.allowance(alice, spender), 10e18);
        assertEq(token.balanceOf(alice), 10e18);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_RevertTransferFromZeroEvenForZeroAmount() public {
        // Allowance validation rejects the zero owner before the transfer checks run.
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidApprover.selector, address(0)));
        vm.prank(spender);
        token.transferFrom(address(0), bob, 0);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_DeployerCannotSpendHoldersTokensWithoutApproval() public {
        _fundAlice(10e18);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, deployer, 0, 1));
        vm.prank(deployer);
        token.transferFrom(alice, deployer, 1);
        assertEq(token.balanceOf(alice), 10e18);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 10e18));
        assertEq(token.balanceOf(bob), 10e18);
    }

    function test_RevertNativeCurrencyAndUnknownSelector() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool received,) = address(token).call{value: 1 wei}("");
        assertFalse(received);
        assertEq(address(token).balance, 0);
        (bool unknown,) = address(token).call(hex"ffffffff");
        assertFalse(unknown);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_TransfersConserveSupply(uint256 rawAmount, uint256 rawForwarded) public {
        uint256 amount = bound(rawAmount, 0, SUPPLY);
        uint256 forwarded = bound(rawForwarded, 0, amount);
        _fundAlice(amount);
        vm.prank(alice);
        assertTrue(token.transfer(bob, forwarded));
        assertEq(token.balanceOf(deployer), SUPPLY - amount);
        assertEq(token.balanceOf(alice), amount - forwarded);
        assertEq(token.balanceOf(bob), forwarded);
        assertEq(token.balanceOf(deployer) + token.balanceOf(alice) + token.balanceOf(bob), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_DelegatedTransferAccounting(uint256 rawBalance, uint256 rawApproval, uint256 rawSpend) public {
        uint256 balance = bound(rawBalance, 0, SUPPLY);
        uint256 approval = bound(rawApproval, 0, SUPPLY);
        uint256 spend = bound(rawSpend, 0, balance < approval ? balance : approval);
        _fundAlice(balance);
        _approveAlice(approval);
        vm.prank(spender);
        assertTrue(token.transferFrom(alice, bob, spend));
        assertEq(token.balanceOf(alice), balance - spend);
        assertEq(token.balanceOf(bob), spend);
        assertEq(token.allowance(alice, spender), approval - spend);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_RevertTransferAboveBalance(uint256 rawBalance, uint256 rawExcess) public {
        uint256 balance = bound(rawBalance, 0, SUPPLY);
        uint256 excess = bound(rawExcess, 1, type(uint256).max - balance);
        uint256 amount = balance + excess;
        _fundAlice(balance);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, balance, amount));
        vm.prank(alice);
        token.transfer(bob, amount);
        assertEq(token.balanceOf(alice), balance);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_RevertDelegatedTransferAboveAllowance(uint256 rawAllowance) public {
        uint256 allowance = bound(rawAllowance, 0, SUPPLY - 1);
        _fundAlice(SUPPLY);
        _approveAlice(allowance);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowance, allowance + 1)
        );
        vm.prank(spender);
        token.transferFrom(alice, bob, allowance + 1);
        assertEq(token.allowance(alice, spender), allowance);
        assertEq(token.balanceOf(alice), SUPPLY);
        assertEq(token.balanceOf(bob), 0);
    }

    function _fundAlice(uint256 amount) private {
        vm.prank(deployer);
        assertTrue(token.transfer(alice, amount));
    }

    function _approveAlice(uint256 amount) private {
        vm.prank(alice);
        assertTrue(token.approve(spender, amount));
    }
}
