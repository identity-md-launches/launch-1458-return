// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ReturnToken} from "../src/ReturnToken.sol";

/// @notice Drives the token with an open, growing set of holders and keeps ghost copies of every
/// balance and allowance it touches. Successful calls update the ghosts; calls that must fail are
/// made with the exact expected error and then checked to have changed nothing. Every recipient is
/// tracked, so the ghost ledger accounts for the whole supply at all times.
contract ReturnTokenGhostHandler is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 * 1e18;
    uint256 internal constant MAX_HOLDERS = 24;
    uint256 internal constant MAX_PAIRS = 48;

    ReturnToken public immutable token;

    address[] public holders;
    mapping(address => bool) public isHolder;
    mapping(address => uint256) public ghostBalance;

    address[] public pairOwners;
    address[] public pairSpenders;
    mapping(address => mapping(address => bool)) public pairTracked;
    mapping(address => mapping(address => uint256)) public ghostAllowance;

    uint256 public ghostVolume;
    uint256 public successfulTransfers;
    uint256 public successfulDelegatedTransfers;
    uint256 public rejectedTransfers;
    uint256 public rejectedDelegatedTransfers;
    uint256 public rejectedForeignCalls;

    constructor(ReturnToken token_, address deployer) {
        token = token_;
        _track(deployer);
        ghostBalance[deployer] = SUPPLY;
        // A conventional burn sink is just another holder for a token with no burn: it must keep
        // what it is sent and the supply must not move.
        _track(address(0xdEaD));
    }

    function holderCount() external view returns (uint256) {
        return holders.length;
    }

    function pairCount() external view returns (uint256) {
        return pairOwners.length;
    }

    // ----------------------------------------------------------------- successful paths

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        address from = _pick(fromSeed);
        address to = _pick(toSeed);
        uint256 amount = bound(amountSeed, 0, token.balanceOf(from));

        vm.prank(from);
        assertTrue(token.transfer(to, amount), "transfer returned false");

        ghostBalance[from] -= amount;
        ghostBalance[to] += amount;
        ghostVolume += amount;
        successfulTransfers++;
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) external {
        (address owner, address spender) = _pickPair(ownerSeed, spenderSeed);

        vm.prank(owner);
        assertTrue(token.approve(spender, amount), "approve returned false");

        ghostAllowance[owner][spender] = amount;
    }

    function transferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amountSeed) external {
        (address owner, address spender) = _pickPair(ownerSeed, spenderSeed);
        address to = _pick(toSeed);
        uint256 available = token.balanceOf(owner);
        uint256 allowed = token.allowance(owner, spender);
        uint256 amount = bound(amountSeed, 0, available < allowed ? available : allowed);

        vm.prank(spender);
        assertTrue(token.transferFrom(owner, to, amount), "transferFrom returned false");

        ghostBalance[owner] -= amount;
        ghostBalance[to] += amount;
        if (allowed != type(uint256).max) ghostAllowance[owner][spender] = allowed - amount;
        ghostVolume += amount;
        successfulDelegatedTransfers++;
    }

    // ----------------------------------------------------------------- failure paths

    /// @dev One wei or more above the balance is refused with the exact error and nothing moves.
    function transferAboveBalance(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        address from = _pick(fromSeed);
        address to = _pick(toSeed);
        uint256 balance = token.balanceOf(from);
        uint256 amount = bound(amountSeed, balance + 1, type(uint256).max);

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, balance, amount));
        vm.prank(from);
        token.transfer(to, amount);

        assertEq(token.balanceOf(from), balance, "a refused transfer changed the sender");
        rejectedTransfers++;
    }

    /// @dev The zero address is refused as a recipient for every amount, including zero.
    function transferToZeroAddress(uint256 fromSeed, uint256 amountSeed) external {
        address from = _pick(fromSeed);
        uint256 amount = bound(amountSeed, 0, token.balanceOf(from));

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(from);
        token.transfer(address(0), amount);

        rejectedTransfers++;
    }

    /// @dev Spending one wei beyond a finite allowance is refused and the allowance is untouched.
    function transferFromAboveAllowance(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amountSeed)
        external
    {
        (address owner, address spender) = _pickPair(ownerSeed, spenderSeed);
        address to = _pick(toSeed);
        uint256 allowed = token.allowance(owner, spender);
        if (allowed == type(uint256).max) {
            // An unlimited allowance has no "above"; the handler refuses to assert a non-fact.
            return;
        }
        uint256 amount = bound(amountSeed, allowed + 1, type(uint256).max);

        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowed, amount)
        );
        vm.prank(spender);
        token.transferFrom(owner, to, amount);

        assertEq(token.allowance(owner, spender), allowed, "a refused transferFrom changed the allowance");
        rejectedDelegatedTransfers++;
    }

    /// @dev Within the allowance but above the balance: refused with the balance error, and the
    /// allowance is restored, so a failed spend never consumes approval.
    function transferFromAboveBalance(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amountSeed)
        external
    {
        (address owner, address spender) = _pickPair(ownerSeed, spenderSeed);
        address to = _pick(toSeed);
        uint256 balance = token.balanceOf(owner);
        uint256 allowed = token.allowance(owner, spender);
        if (allowed <= balance) {
            return;
        }
        uint256 amount = bound(amountSeed, balance + 1, allowed);

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, balance, amount));
        vm.prank(spender);
        token.transferFrom(owner, to, amount);

        assertEq(token.allowance(owner, spender), allowed, "a refused transferFrom consumed allowance");
        assertEq(token.balanceOf(owner), balance, "a refused transferFrom changed the owner");
        rejectedDelegatedTransfers++;
    }

    /// @dev Nobody spends a holder's tokens without an explicit allowance: a spender that was never
    /// approved, or whose approval was revoked, is refused for one wei.
    function revokeThenSpend(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed) external {
        (address owner, address spender) = _pickPair(ownerSeed, spenderSeed);
        address to = _pick(toSeed);

        vm.prank(owner);
        assertTrue(token.approve(spender, 0), "revocation returned false");
        ghostAllowance[owner][spender] = 0;

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(owner, to, 1);

        rejectedDelegatedTransfers++;
    }

    /// @dev Any selector outside the ERC-20 surface is refused: there is no fallback, no admin
    /// entry point, no mint, no burn. The caller is a tracked holder so a success would show up
    /// as a ghost mismatch even if it slipped past the status check.
    function callForeignSelector(bytes4 selector, bytes calldata args, uint256 callerSeed) external {
        if (_isTokenSelector(selector)) {
            selector = bytes4(keccak256(abi.encodePacked(selector)));
            if (_isTokenSelector(selector)) return;
        }
        address caller = _pick(callerSeed);

        vm.prank(caller);
        (bool ok,) = address(token).call(abi.encodePacked(selector, args));

        assertFalse(ok, "the token answered a selector it does not declare");
        rejectedForeignCalls++;
    }

    /// @dev The token takes no native currency, with or without calldata.
    function sendNativeCurrency(uint256 callerSeed, uint256 valueSeed, bytes calldata data) external {
        address caller = _pick(callerSeed);
        uint256 value = bound(valueSeed, 1, 1_000 ether);
        vm.deal(caller, value);

        vm.prank(caller);
        (bool ok,) = address(token).call{value: value}(data);

        assertFalse(ok, "the token accepted native currency");
        assertEq(address(token).balance, 0, "the token holds native currency");
        rejectedForeignCalls++;
    }

    // ----------------------------------------------------------------- helpers

    function _pick(uint256 seed) internal returns (address) {
        if (holders.length < MAX_HOLDERS && seed % 5 == 0) {
            address fresh = address(uint160(uint256(keccak256(abi.encode("return holder", seed)))));
            if (fresh == address(0) || fresh == address(token) || isHolder[fresh]) {
                return holders[seed % holders.length];
            }
            _track(fresh);
            return fresh;
        }
        return holders[seed % holders.length];
    }

    function _pickPair(uint256 ownerSeed, uint256 spenderSeed) internal returns (address owner, address spender) {
        if (pairOwners.length >= MAX_PAIRS) {
            uint256 index = ownerSeed % pairOwners.length;
            return (pairOwners[index], pairSpenders[index]);
        }
        owner = _pick(ownerSeed);
        spender = _pick(spenderSeed);
        if (!pairTracked[owner][spender]) {
            pairTracked[owner][spender] = true;
            pairOwners.push(owner);
            pairSpenders.push(spender);
        }
    }

    function _track(address account) internal {
        if (!isHolder[account]) {
            isHolder[account] = true;
            holders.push(account);
        }
    }

    function _isTokenSelector(bytes4 selector) internal pure returns (bool) {
        return selector == IERC20Metadata.name.selector || selector == IERC20Metadata.symbol.selector
            || selector == IERC20Metadata.decimals.selector || selector == IERC20.totalSupply.selector
            || selector == IERC20.balanceOf.selector || selector == IERC20.transfer.selector
            || selector == IERC20.allowance.selector || selector == IERC20.approve.selector
            || selector == IERC20.transferFrom.selector || selector == bytes4(keccak256("INITIAL_SUPPLY()"));
    }
}

contract ReturnTokenGhostInvariantTest is Test {
    uint256 private constant SUPPLY = 1_000_000_000 * 1e18;

    ReturnToken private token;
    ReturnTokenGhostHandler private handler;
    address private deployer;
    bytes32 private runtimeHashAtDeployment;

    function setUp() public {
        deployer = makeAddr("launch deployer");
        vm.prank(deployer);
        token = new ReturnToken();
        runtimeHashAtDeployment = address(token).codehash;
        handler = new ReturnTokenGhostHandler(token, deployer);

        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = handler.transfer.selector;
        selectors[1] = handler.approve.selector;
        selectors[2] = handler.transferFrom.selector;
        selectors[3] = handler.transferAboveBalance.selector;
        selectors[4] = handler.transferToZeroAddress.selector;
        selectors[5] = handler.transferFromAboveAllowance.selector;
        selectors[6] = handler.transferFromAboveBalance.selector;
        selectors[7] = handler.revokeThenSpend.selector;
        selectors[8] = handler.callForeignSelector.selector;
        selectors[9] = handler.sendNativeCurrency.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_EveryTrackedBalanceMatchesItsGhost() public view {
        uint256 count = handler.holderCount();
        for (uint256 i; i < count; ++i) {
            address holder = handler.holders(i);
            assertEq(token.balanceOf(holder), handler.ghostBalance(holder), "balance drifted from the ghost ledger");
        }
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_TrackedBalancesSumToTheFixedSupply() public view {
        uint256 count = handler.holderCount();
        uint256 accounted;
        for (uint256 i; i < count; ++i) {
            uint256 balance = token.balanceOf(handler.holders(i));
            assertLe(balance, SUPPLY, "a holder has more than the supply");
            accounted += balance;
        }
        assertEq(accounted, SUPPLY, "tracked holders do not account for the whole supply");
        assertEq(token.totalSupply(), SUPPLY, "the supply changed");
        assertEq(token.balanceOf(address(0)), 0, "the zero address holds tokens");
        assertEq(token.balanceOf(address(token)), 0, "the token holds its own tokens without being sent any");
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_EveryTrackedAllowanceMatchesItsGhost() public view {
        uint256 count = handler.pairCount();
        for (uint256 i; i < count; ++i) {
            address owner = handler.pairOwners(i);
            address spender = handler.pairSpenders(i);
            assertEq(
                token.allowance(owner, spender),
                handler.ghostAllowance(owner, spender),
                "allowance drifted from the ghost ledger"
            );
        }
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_MetadataCodeAndTreasuryAreFrozen() public view {
        assertEq(token.name(), "Return");
        assertEq(token.symbol(), "RETURN");
        assertEq(token.decimals(), 18);
        assertEq(token.INITIAL_SUPPLY(), SUPPLY);
        assertEq(address(token).codehash, runtimeHashAtDeployment, "the runtime code changed");
        assertEq(address(token).balance, 0, "the token holds native currency");
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_VolumeNeverExceedsWhatTheDeployerCouldHaveReleased() public view {
        // Every token in circulation outside the deployer left the deployer through a transfer the
        // handler recorded, so the deployer's balance plus everything else always equals the supply
        // and nothing outside the deployer can exceed the volume moved.
        uint256 outside = SUPPLY - token.balanceOf(deployer);
        assertLe(outside, handler.ghostVolume(), "more tokens are in circulation than were ever transferred");
    }
}
