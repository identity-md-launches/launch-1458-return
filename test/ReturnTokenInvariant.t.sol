// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ReturnToken} from "../src/ReturnToken.sol";

/// @dev Every transfer recipient is in this closed actor set so its sum accounts for the entire supply.
contract ReturnTokenHandler is Test {
    ReturnToken public immutable token;
    address[4] public actors;

    constructor(ReturnToken token_, address[4] memory actors_) {
        token = token_;
        actors = actors_;
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 amount = bound(amountSeed, 0, token.balanceOf(from));
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) external {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        vm.prank(owner);
        assertTrue(token.approve(spender, amount));
        assertEq(token.allowance(owner, spender), amount);
    }

    function transferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amountSeed) external {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 available = token.balanceOf(owner);
        uint256 allowed = token.allowance(owner, spender);
        uint256 amount = bound(amountSeed, 0, available < allowed ? available : allowed);
        vm.prank(spender);
        assertTrue(token.transferFrom(owner, to, amount));
        assertEq(token.allowance(owner, spender), allowed == type(uint256).max ? allowed : allowed - amount);
    }
}

contract ReturnTokenInvariantTest is Test {
    uint256 private constant SUPPLY = 1_000_000_000 * 1e18;

    ReturnToken private token;
    ReturnTokenHandler private handler;

    function setUp() public {
        address[4] memory actors = [makeAddr("actor 0"), makeAddr("actor 1"), makeAddr("actor 2"), makeAddr("actor 3")];
        vm.prank(actors[0]);
        token = new ReturnToken();
        handler = new ReturnTokenHandler(token, actors);

        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = handler.transfer.selector;
        selectors[1] = handler.approve.selector;
        selectors[2] = handler.transferFrom.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariant_SupplyAndAccountedBalancesRemainConstant() public view {
        uint256 accounted;
        for (uint256 i; i < 4; ++i) {
            uint256 balance = token.balanceOf(handler.actors(i));
            assertLe(balance, SUPPLY);
            accounted += balance;
        }
        assertEq(accounted, SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.name(), "Return");
        assertEq(token.symbol(), "RETURN");
        assertEq(token.decimals(), 18);
    }
}
