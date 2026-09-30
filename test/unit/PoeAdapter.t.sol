// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";

import { MRC17Adapter } from "../../src/base/MRC17Adapter.sol";
import { IPropAMMRouter } from "../../src/interfaces/IPropAMMRouter.sol";
import { PoeAdapter } from "../../src/adapters/PoeAdapter.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockPoePool } from "../mocks/MockPoePool.sol";

contract PoeAdapterUnitTest is Test {
    MockERC20 internal tokenX;
    MockERC20 internal tokenY;
    MockPoePool internal pool;
    PoeAdapter internal adapter;

    address internal user = makeAddr("user");
    address internal recipient = makeAddr("recipient");

    function setUp() public {
        tokenX = new MockERC20("Token X", "X", 18);
        tokenY = new MockERC20("Token Y", "Y", 18);
        pool = new MockPoePool(address(tokenX), address(tokenY), 2, 1);
        adapter = new PoeAdapter(address(pool));

        tokenX.mint(user, 1_000_000 ether);
        tokenY.mint(user, 1_000_000 ether);
        tokenX.mint(address(pool), 2_000_000 ether);
        tokenY.mint(address(pool), 2_000_000 ether);

        vm.startPrank(user);
        tokenX.approve(address(adapter), type(uint256).max);
        tokenY.approve(address(adapter), type(uint256).max);
        vm.stopPrank();
    }

    function test_rejectsUnsupportedAssetsInQuotesAndSwaps() public {
        vm.expectRevert(MRC17Adapter.InvalidTokenPair.selector);
        adapter.getAmountOut(address(tokenX), address(tokenX), 1, bytes(""));
        vm.expectRevert(MRC17Adapter.InvalidTokenPair.selector);
        adapter.getAmountOut(address(0xBEEF), address(tokenY), 1, bytes(""));
        vm.expectRevert(MRC17Adapter.InvalidTokenPair.selector);
        adapter.swap(address(tokenX), address(0xBEEF), recipient, 1, 0, block.timestamp, bytes(""));
    }

    function test_doesNotExposeTokenOrderingGetters() public view {
        (bool first,) = address(adapter).staticcall(abi.encodeWithSignature("token0()"));
        (bool second,) = address(adapter).staticcall(abi.encodeWithSignature("token1()"));
        assertFalse(first);
        assertFalse(second);
    }

    function test_quoteCompletesUnderStaticcall() public view {
        (bool success, bytes memory result) = address(adapter)
            .staticcall(abi.encodeCall(adapter.getAmountOut, (address(tokenX), address(tokenY), 3 ether, bytes(""))));

        assertTrue(success);
        (uint256 amountOut, bytes memory swapData) = abi.decode(result, (uint256, bytes));
        assertEq(amountOut, 6 ether);
        assertEq(swapData.length, 0);
    }

    function test_quoteRejectsPartialInputFill() public {
        pool.setPartialQuote(true);

        vm.expectRevert(PoeAdapter.InvalidQuote.selector);
        adapter.getAmountOut(address(tokenX), address(tokenY), 3 ether, bytes(""));
    }

    function test_zeroInputQuoteIsRejectedByResultValidation() public {
        vm.expectRevert(PoeAdapter.InvalidQuote.selector);
        adapter.getAmountOut(address(tokenX), address(tokenY), 0, bytes(""));
    }

    function test_quoteRejectsUnexpectedData() public {
        vm.expectRevert(PoeAdapter.UnexpectedData.selector);
        adapter.getAmountOut(address(tokenX), address(tokenY), 3 ether, hex"01");
    }

    function test_swapPullsExactInputAndCreditsRecipient() public {
        uint256 amountIn = 3 ether;
        (uint256 quote, bytes memory swapData) =
            adapter.getAmountOut(address(tokenX), address(tokenY), amountIn, bytes(""));

        vm.prank(user);
        uint256 amountOut =
            adapter.swap(address(tokenX), address(tokenY), recipient, amountIn, quote, block.timestamp, swapData);

        assertEq(amountOut, 6 ether);
        assertEq(tokenX.balanceOf(user), 1_000_000 ether - amountIn);
        assertEq(tokenY.balanceOf(recipient), amountOut);
        assertEq(tokenX.balanceOf(address(adapter)), 0);
        assertEq(tokenY.balanceOf(address(adapter)), 0);
    }

    function test_swapDoesNotConsumePreexistingAdapterBalance() public {
        tokenX.mint(address(adapter), 7 ether);

        vm.prank(user);
        adapter.swap(address(tokenX), address(tokenY), recipient, 2 ether, 0, block.timestamp, bytes(""));

        assertEq(tokenX.balanceOf(address(adapter)), 7 ether);
    }

    function test_swapSupportsReverseDirection() public {
        vm.prank(user);
        uint256 amountOut =
            adapter.swap(address(tokenY), address(tokenX), recipient, 4 ether, 8 ether, block.timestamp, bytes(""));

        assertEq(amountOut, 8 ether);
        assertEq(tokenX.balanceOf(recipient), amountOut);
    }

    function test_swapEmitsExplicitAssetsAndActualDelivery() public {
        vm.expectEmit(true, true, true, true, address(adapter));
        emit IPropAMMRouter.PropAMMSwap(user, recipient, address(tokenY), address(tokenX), 2 ether, 4 ether);
        vm.prank(user);
        adapter.swap(address(tokenY), address(tokenX), recipient, 2 ether, 0, block.timestamp, bytes(""));
    }

    function test_feeOnTransferCannotConsumePreexistingBalance() public {
        tokenX.mint(address(adapter), 7 ether);
        tokenX.setFeeBps(1000);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(MRC17Adapter.InputTransferMismatch.selector, 1 ether, 0.9 ether));
        adapter.swap(address(tokenX), address(tokenY), recipient, 1 ether, 0, block.timestamp, bytes(""));
        assertEq(tokenX.balanceOf(address(adapter)), 7 ether);
        assertEq(tokenY.balanceOf(recipient), 0);
    }

    function test_swapRejectsZeroInputAtSharedBoundary() public {
        vm.prank(user);
        vm.expectRevert(MRC17Adapter.InvalidAmountIn.selector);
        adapter.swap(address(tokenX), address(tokenY), recipient, 0, 0, block.timestamp, bytes(""));
    }

    function test_swapRejectsExpiredDeadline() public {
        vm.warp(100);

        vm.prank(user);
        vm.expectRevert(MRC17Adapter.DeadlineExpired.selector);
        adapter.swap(address(tokenX), address(tokenY), recipient, 1 ether, 0, 99, bytes(""));
    }

    function test_swapRejectsZeroRecipient() public {
        vm.prank(user);
        vm.expectRevert(MRC17Adapter.InvalidRecipient.selector);
        adapter.swap(address(tokenX), address(tokenY), address(0), 1 ether, 0, block.timestamp, bytes(""));
    }

    function test_swapRejectsOutputBelowMinimum() public {
        vm.prank(user);
        vm.expectRevert(MRC17Adapter.SlippageExceeded.selector);
        adapter.swap(address(tokenX), address(tokenY), recipient, 1 ether, 2 ether + 1, block.timestamp, bytes(""));
    }

    function test_swapRejectsUnexpectedData() public {
        vm.prank(user);
        vm.expectRevert(PoeAdapter.UnexpectedData.selector);
        adapter.swap(address(tokenX), address(tokenY), recipient, 1 ether, 0, block.timestamp, hex"01");
    }

    function test_swapCallbackRejectsUnauthenticatedCaller() public {
        vm.expectRevert(PoeAdapter.InvalidCallback.selector);
        adapter.swapCallback(int256(1 ether), -int256(2 ether), abi.encode(address(tokenX)));
    }

    function test_swapRejectsWrongCallbackInputDelta() public {
        pool.setExecutionMode(MockPoePool.ExecutionMode.WrongInputDelta);

        vm.prank(user);
        vm.expectRevert(PoeAdapter.InvalidCallback.selector);
        adapter.swap(address(tokenX), address(tokenY), recipient, 1 ether, 0, block.timestamp, bytes(""));
    }

    function test_swapRejectsWrongCallbackOutputDelta() public {
        pool.setExecutionMode(MockPoePool.ExecutionMode.WrongOutputDelta);

        vm.prank(user);
        vm.expectRevert(PoeAdapter.InvalidCallback.selector);
        adapter.swap(address(tokenX), address(tokenY), recipient, 1 ether, 0, block.timestamp, bytes(""));
    }

    function test_swapRejectsWrongCallbackToken() public {
        pool.setExecutionMode(MockPoePool.ExecutionMode.WrongCallbackData);

        vm.prank(user);
        vm.expectRevert(PoeAdapter.InvalidCallback.selector);
        adapter.swap(address(tokenX), address(tokenY), recipient, 1 ether, 0, block.timestamp, bytes(""));
    }

    function test_swapRequiresCallbackCompletion() public {
        pool.setExecutionMode(MockPoePool.ExecutionMode.SkipCallback);

        vm.prank(user);
        vm.expectRevert(PoeAdapter.CallbackNotCompleted.selector);
        adapter.swap(address(tokenX), address(tokenY), recipient, 1 ether, 0, block.timestamp, bytes(""));
    }
}
