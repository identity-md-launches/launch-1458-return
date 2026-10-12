// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ReturnToken} from "../src/ReturnToken.sol";

/// @dev Test-only deployment and distribution harness; not an application to deploy.
contract TokenFactoryHarness {
    function deploy(bytes32 salt) external returns (ReturnToken) {
        return new ReturnToken{salt: salt}();
    }

    function move(ReturnToken token, address to, uint256 amount) external returns (bool) {
        return token.transfer(to, amount);
    }
}

contract ReturnTokenLaunchTest is Test {
    uint256 private constant SUPPLY = 1_000_000_000 * 1e18;

    TokenFactoryHarness private factory;
    ReturnToken private token;
    address private requester;
    address private distributor;
    address private pool;
    address private claimant;
    address private trader;

    function setUp() public {
        requester = makeAddr("requester");
        distributor = makeAddr("distributor");
        pool = makeAddr("pool token holder");
        claimant = makeAddr("claimant");
        trader = makeAddr("trader");
        factory = new TokenFactoryHarness();
        vm.prank(requester, requester);
        token = factory.deploy(keccak256("Return launch"));
    }

    function test_Create2MintsToFactoryAndNotTransactionOrigin() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(factory)), SUPPLY);
        assertEq(token.balanceOf(requester), 0);
        assertEq(token.balanceOf(address(this)), 0);
    }

    /// @dev Exercises token-side distribution and pool transfers, not Uniswap price or liquidity math.
    function test_DistributionClaimsAndPoolTransfersArriveWhole() public {
        uint256 swarm = SUPPLY / 10;
        uint256 poolShare = SUPPLY * 8 / 10;
        uint256 remainder = SUPPLY - swarm - poolShare;
        assertTrue(factory.move(token, distributor, swarm));
        assertTrue(factory.move(token, pool, poolShare));
        assertTrue(factory.move(token, requester, remainder));
        assertEq(token.balanceOf(address(factory)), 0);
        assertEq(token.balanceOf(distributor), swarm);
        assertEq(token.balanceOf(pool), poolShare);
        assertEq(token.balanceOf(requester), remainder);

        vm.prank(distributor);
        assertTrue(token.transfer(claimant, swarm));
        assertEq(token.balanceOf(claimant), swarm);
        assertEq(token.balanceOf(distributor), 0);

        uint256 bought = 100e18;
        vm.prank(pool);
        assertTrue(token.transfer(trader, bought));
        assertEq(token.balanceOf(trader), bought);
        assertEq(token.balanceOf(pool), poolShare - bought);
        vm.prank(trader);
        assertTrue(token.transfer(pool, bought));
        assertEq(token.balanceOf(trader), 0);
        assertEq(token.balanceOf(pool), poolShare);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_NoMintBurnOrAdministrativeEntryPointsForFactoryOrStranger() public {
        assertTrue(factory.move(token, claimant, 100e18));
        bytes[] memory calls = new bytes[](25);
        calls[0] = abi.encodeWithSignature("mint(address,uint256)", trader, 1e18);
        calls[1] = abi.encodeWithSignature("mint(uint256)", 1e18);
        calls[2] = abi.encodeWithSignature("mint()");
        calls[3] = abi.encodeWithSignature("issue(uint256)", 1e18);
        calls[4] = abi.encodeWithSignature("setOwner(address)", trader);
        calls[5] = abi.encodeWithSignature("transferOwnership(address)", trader);
        calls[6] = abi.encodeWithSignature("upgradeTo(address)", trader);
        calls[7] = abi.encodeWithSignature("initialize(address)", trader);
        calls[8] = abi.encodeWithSignature("unpause()");
        calls[9] = abi.encodeWithSignature("setMinter(address)", trader);
        calls[10] = abi.encodeWithSignature("pause()");
        calls[11] = abi.encodeWithSignature("blacklist(address)", claimant);
        calls[12] = abi.encodeWithSignature("blocklist(address)", claimant);
        calls[13] = abi.encodeWithSignature("freeze(address)", claimant);
        calls[14] = abi.encodeWithSignature("freezeAccount(address)", claimant);
        calls[15] = abi.encodeWithSignature("setBlacklist(address,bool)", claimant, true);
        calls[16] = abi.encodeWithSignature("setBlocked(address,bool)", claimant, true);
        calls[17] = abi.encodeWithSignature("lock(address)", claimant);
        calls[18] = abi.encodeWithSignature("disableTransfers()");
        calls[19] = abi.encodeWithSignature("setTransfersEnabled(bool)", false);
        calls[20] = abi.encodeWithSignature("burnFrom(address,uint256)", claimant, 100e18);
        calls[21] = abi.encodeWithSignature("seize(address)", claimant);
        calls[22] = abi.encodeWithSignature("burn(uint256)", 1);
        calls[23] = abi.encodeWithSignature("_mint(address,uint256)", trader, 1e18);
        calls[24] = abi.encodeWithSignature("_update(address,address,uint256)", address(0), trader, 1e18);

        for (uint256 i; i < calls.length; ++i) {
            vm.prank(address(factory));
            (bool factorySucceeded,) = address(token).call(calls[i]);
            assertFalse(factorySucceeded, "factory reached an unexpected entry point");
            vm.prank(trader);
            (bool strangerSucceeded,) = address(token).call(calls[i]);
            assertFalse(strangerSucceeded, "stranger reached an unexpected entry point");
            assertEq(token.totalSupply(), SUPPLY);
            assertEq(token.balanceOf(claimant), 100e18);
            assertEq(token.balanceOf(trader), 0);
        }

        vm.prank(claimant);
        assertTrue(token.transfer(trader, 100e18));
        assertEq(token.balanceOf(claimant), 0);
        assertEq(token.balanceOf(trader), 100e18);
    }

    function test_RuntimeHasNoForbiddenOpcodesAndFitsDeploymentLimit() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576);
        for (uint256 i; i < runtime.length; ++i) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4, "DELEGATECALL");
            assertTrue(op != 0xf2, "CALLCODE");
            assertTrue(op != 0xff, "SELFDESTRUCT");
        }
    }
}
