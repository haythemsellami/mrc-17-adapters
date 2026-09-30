// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";

import { CloberAdapter } from "../../src/adapters/CloberAdapter.sol";
import { MRC17Adapter } from "../../src/base/MRC17Adapter.sol";
import { MockCloberBookManager, MockCloberBookViewer, MockWrappedNative } from "../mocks/MockClober.sol";
import { MockCloberController } from "../mocks/MockCloberController.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";

contract CloberAdapterUnitTest is Test {
    uint192 internal constant WNATIVE_FOR_USDC = 1;
    uint192 internal constant USDC_FOR_WNATIVE = 2;

    MockWrappedNative internal wrappedNative;
    MockERC20 internal usdc;
    MockCloberBookManager internal manager;
    MockCloberBookViewer internal viewer;
    MockCloberController internal controller;
    CloberAdapter internal adapter;

    address internal recipient = makeAddr("recipient");

    function setUp() public {
        wrappedNative = new MockWrappedNative();
        usdc = new MockERC20("USD Coin", "USDC", 6);
        manager = new MockCloberBookManager();
        viewer = new MockCloberBookViewer(address(manager));
        controller = new MockCloberController(address(manager));

        manager.setBook(WNATIVE_FOR_USDC, address(0), address(usdc), 1);
        manager.setBook(USDC_FOR_WNATIVE, address(usdc), address(0), 1);
        viewer.setRate(WNATIVE_FOR_USDC, 2, 1);
        viewer.setRate(USDC_FOR_WNATIVE, 1, 2);
        controller.setRate(WNATIVE_FOR_USDC, 2, 1);
        controller.setRate(USDC_FOR_WNATIVE, 1, 2);

        adapter = _deployAdapter(
            manager,
            viewer,
            controller,
            wrappedNative,
            address(wrappedNative),
            address(usdc),
            WNATIVE_FOR_USDC,
            USDC_FOR_WNATIVE
        );

        vm.deal(address(this), 100 ether);
        vm.deal(address(controller), 100 ether);
        usdc.mint(address(controller), 1_000_000 ether);
    }

    function test_rejectsUnsupportedAssetsInQuotesAndSwaps() public {
        vm.expectRevert(MRC17Adapter.InvalidTokenPair.selector);
        adapter.getAmountOut(address(wrappedNative), address(wrappedNative), 1, bytes(""));
        vm.expectRevert(MRC17Adapter.InvalidTokenPair.selector);
        adapter.getAmountOut(address(0xBEEF), address(usdc), 1, bytes(""));
        vm.expectRevert(MRC17Adapter.InvalidTokenPair.selector);
        adapter.swap(address(wrappedNative), address(0xBEEF), recipient, 1, 0, block.timestamp, bytes(""));
    }

    function test_doesNotExposeTokenOrderingGetters() public view {
        (bool first,) = address(adapter).staticcall(abi.encodeWithSignature("token0()"));
        (bool second,) = address(adapter).staticcall(abi.encodeWithSignature("token1()"));
        assertFalse(first);
        assertFalse(second);
    }

    function test_exposesValidatedConfiguration() public view {
        assertEq(adapter.bookManager(), address(manager));
        assertEq(adapter.bookViewer(), address(viewer));
        assertEq(adapter.controller(), address(controller));
        assertEq(adapter.wrappedNative(), address(wrappedNative));
        assertEq(adapter.currency0(), address(0));
        assertEq(adapter.currency1(), address(usdc));
        assertEq(adapter.bookId0For1(), WNATIVE_FOR_USDC);
        assertEq(adapter.bookId1For0(), USDC_FOR_WNATIVE);
    }

    function test_quotesBothDirections() public view {
        (uint256 zeroForOneAmountOut, bytes memory zeroForOneData) =
            adapter.getAmountOut(address(wrappedNative), address(usdc), 3 ether, bytes(""));
        (uint256 oneForZeroAmountOut, bytes memory oneForZeroData) =
            adapter.getAmountOut(address(usdc), address(wrappedNative), 4 ether, bytes(""));

        assertEq(zeroForOneAmountOut, 6 ether);
        assertEq(oneForZeroAmountOut, 2 ether);
        assertEq(zeroForOneData.length, 0);
        assertEq(oneForZeroData.length, 0);
    }

    function test_quoteCompletesUnderStaticcall() public view {
        (bool success, bytes memory result) = address(adapter)
            .staticcall(
                abi.encodeCall(CloberAdapter.getAmountOut, (address(wrappedNative), address(usdc), 3 ether, bytes("")))
            );

        assertTrue(success);
        (uint256 amountOut, bytes memory swapData) = abi.decode(result, (uint256, bytes));
        assertEq(amountOut, 6 ether);
        assertEq(swapData.length, 0);
    }

    function test_zeroInputQuoteIsRejectedByResultValidation() public {
        vm.expectRevert(CloberAdapter.InvalidQuote.selector);
        adapter.getAmountOut(address(wrappedNative), address(usdc), 0, bytes(""));
    }

    function test_rejectsZeroOutputQuote() public {
        viewer.setRate(WNATIVE_FOR_USDC, 0, 1);

        vm.expectRevert(CloberAdapter.InvalidQuote.selector);
        adapter.getAmountOut(address(wrappedNative), address(usdc), 1 ether, bytes(""));
    }

    function test_rejectsPartialExactInputQuote() public {
        viewer.setPartialFill(true);

        vm.expectRevert(CloberAdapter.IncompleteFill.selector);
        adapter.getAmountOut(address(wrappedNative), address(usdc), 1 ether, bytes(""));
    }

    function test_rejectsUnexpectedQuoteData() public {
        vm.expectRevert(CloberAdapter.UnexpectedData.selector);
        adapter.getAmountOut(address(wrappedNative), address(usdc), 1 ether, hex"01");
    }

    function test_unwrapsInputAndForwardsErc20Output() public {
        uint256 amountIn = 3 ether;
        wrappedNative.deposit{ value: amountIn }();
        wrappedNative.approve(address(adapter), amountIn);

        (uint256 quote, bytes memory swapData) =
            adapter.getAmountOut(address(wrappedNative), address(usdc), amountIn, bytes(""));
        uint256 amountOut =
            adapter.swap(address(wrappedNative), address(usdc), recipient, amountIn, quote, block.timestamp, swapData);

        assertEq(amountOut, quote);
        assertEq(usdc.balanceOf(recipient), quote);
        assertEq(wrappedNative.balanceOf(address(adapter)), 0);
        assertEq(usdc.balanceOf(address(adapter)), 0);
        assertEq(address(adapter).balance, 0);
    }

    function test_wrapsNativeOutputAndForwardsWrappedToken() public {
        uint256 amountIn = 4 ether;
        usdc.mint(address(this), amountIn);
        usdc.approve(address(adapter), amountIn);

        (uint256 quote, bytes memory swapData) =
            adapter.getAmountOut(address(usdc), address(wrappedNative), amountIn, bytes(""));
        uint256 amountOut =
            adapter.swap(address(usdc), address(wrappedNative), recipient, amountIn, quote, block.timestamp, swapData);

        assertEq(amountOut, quote);
        assertEq(wrappedNative.balanceOf(recipient), quote);
        assertEq(usdc.balanceOf(address(adapter)), 0);
        assertEq(wrappedNative.balanceOf(address(adapter)), 0);
        assertEq(address(adapter).balance, 0);
        assertEq(usdc.allowance(address(adapter), address(controller)), 0);
    }

    function test_supportsAdapterAsRecipient() public {
        uint256 amountIn = 4 ether;
        usdc.mint(address(this), amountIn);
        usdc.approve(address(adapter), amountIn);

        uint256 amountOut = adapter.swap(
            address(usdc), address(wrappedNative), address(adapter), amountIn, 2 ether, block.timestamp, bytes("")
        );

        assertEq(amountOut, 2 ether);
        assertEq(wrappedNative.balanceOf(address(adapter)), amountOut);
    }

    function test_preservesDonatedOutputBalance() public {
        uint256 donation = 5 ether;
        uint256 amountIn = 3 ether;
        usdc.mint(address(adapter), donation);
        wrappedNative.deposit{ value: amountIn }();
        wrappedNative.approve(address(adapter), amountIn);

        uint256 amountOut = adapter.swap(
            address(wrappedNative), address(usdc), recipient, amountIn, 6 ether, block.timestamp, bytes("")
        );

        assertEq(amountOut, 6 ether);
        assertEq(usdc.balanceOf(address(adapter)), donation);
        assertEq(usdc.balanceOf(recipient), amountOut);
    }

    function test_executesErc20ToErc20Book() public {
        uint192 tokenAForTokenB = 3;
        uint192 tokenBForTokenA = 4;
        MockERC20 tokenA = new MockERC20("Token A", "A", 18);
        MockERC20 tokenB = new MockERC20("Token B", "B", 18);
        MockCloberBookManager erc20Manager = new MockCloberBookManager();
        MockCloberBookViewer erc20Viewer = new MockCloberBookViewer(address(erc20Manager));
        MockCloberController erc20Controller = new MockCloberController(address(erc20Manager));
        erc20Manager.setBook(tokenAForTokenB, address(tokenA), address(tokenB), 1);
        erc20Manager.setBook(tokenBForTokenA, address(tokenB), address(tokenA), 1);
        erc20Viewer.setRate(tokenAForTokenB, 3, 2);
        erc20Viewer.setRate(tokenBForTokenA, 2, 3);
        erc20Controller.setRate(tokenAForTokenB, 3, 2);
        erc20Controller.setRate(tokenBForTokenA, 2, 3);
        CloberAdapter erc20Adapter = _deployAdapter(
            erc20Manager,
            erc20Viewer,
            erc20Controller,
            wrappedNative,
            address(tokenA),
            address(tokenB),
            tokenAForTokenB,
            tokenBForTokenA
        );
        tokenB.mint(address(erc20Controller), 100 ether);
        tokenA.mint(address(this), 2 ether);
        tokenA.approve(address(erc20Adapter), 2 ether);

        uint256 amountOut = erc20Adapter.swap(
            address(tokenA), address(tokenB), recipient, 2 ether, 3 ether, block.timestamp, bytes("")
        );

        assertEq(amountOut, 3 ether);
        assertEq(tokenA.balanceOf(address(erc20Controller)), 2 ether);
        assertEq(tokenB.balanceOf(recipient), 3 ether);
        assertEq(tokenA.allowance(address(erc20Adapter), address(erc20Controller)), 0);
    }

    function test_rejectsPartialErc20Execution() public {
        uint256 amountIn = 4 ether;
        controller.setSpendBps(5000);
        usdc.mint(address(this), amountIn);
        usdc.approve(address(adapter), amountIn);

        vm.expectRevert(CloberAdapter.IncompleteFill.selector);
        adapter.swap(address(usdc), address(wrappedNative), recipient, amountIn, 0, block.timestamp, bytes(""));

        assertEq(usdc.balanceOf(address(this)), amountIn);
        assertEq(wrappedNative.balanceOf(recipient), 0);
        assertEq(usdc.balanceOf(address(adapter)), 0);
        assertEq(usdc.allowance(address(adapter), address(controller)), 0);
    }

    function test_rejectsPartialNativeExecution() public {
        uint256 amountIn = 4 ether;
        controller.setSpendBps(5000);
        wrappedNative.deposit{ value: amountIn }();
        wrappedNative.approve(address(adapter), amountIn);

        vm.expectRevert(CloberAdapter.IncompleteFill.selector);
        adapter.swap(address(wrappedNative), address(usdc), recipient, amountIn, 0, block.timestamp, bytes(""));

        assertEq(wrappedNative.balanceOf(address(this)), amountIn);
        assertEq(usdc.balanceOf(recipient), 0);
        assertEq(wrappedNative.balanceOf(address(adapter)), 0);
        assertEq(address(adapter).balance, 0);
    }

    function test_rejectsExecutionBelowMinimum() public {
        uint256 amountIn = 3 ether;
        wrappedNative.deposit{ value: amountIn }();
        wrappedNative.approve(address(adapter), amountIn);

        vm.expectRevert();
        adapter.swap(
            address(wrappedNative), address(usdc), recipient, amountIn, 6 ether + 1, block.timestamp, bytes("")
        );
    }

    function test_rejectsUnexpectedSwapData() public {
        uint256 amountIn = 3 ether;
        wrappedNative.deposit{ value: amountIn }();
        wrappedNative.approve(address(adapter), amountIn);

        vm.expectRevert(CloberAdapter.UnexpectedData.selector);
        adapter.swap(address(wrappedNative), address(usdc), recipient, amountIn, 0, block.timestamp, hex"01");
    }

    function test_rejectsExpiredSwap() public {
        vm.warp(10);

        vm.expectRevert(MRC17Adapter.DeadlineExpired.selector);
        adapter.swap(address(wrappedNative), address(usdc), recipient, 1 ether, 0, 9, bytes(""));
    }

    function test_rejectsZeroRecipient() public {
        vm.expectRevert(MRC17Adapter.InvalidRecipient.selector);
        adapter.swap(address(wrappedNative), address(usdc), address(0), 1 ether, 0, block.timestamp, bytes(""));
    }

    function test_rejectsUnauthorizedNativeTransfer() public {
        (bool success, bytes memory returnData) = address(adapter).call{ value: 1 }("");

        assertFalse(success);
        assertGe(returnData.length, 4);
        assertEq(bytes4(returnData), CloberAdapter.UnexpectedNativeTransfer.selector);
    }

    function test_constructorRejectsNonContractDependency() public {
        vm.expectRevert(CloberAdapter.InvalidConfiguration.selector);
        new CloberAdapter(
            address(0),
            address(viewer),
            address(controller),
            address(wrappedNative),
            address(wrappedNative),
            address(usdc),
            WNATIVE_FOR_USDC,
            USDC_FOR_WNATIVE
        );
    }

    function test_constructorRejectsMismatchedManager() public {
        MockCloberBookManager otherManager = new MockCloberBookManager();

        vm.expectRevert(CloberAdapter.InvalidConfiguration.selector);
        new CloberAdapter(
            address(otherManager),
            address(viewer),
            address(controller),
            address(wrappedNative),
            address(wrappedNative),
            address(usdc),
            WNATIVE_FOR_USDC,
            USDC_FOR_WNATIVE
        );
    }

    function test_constructorRejectsDuplicateBookIds() public {
        vm.expectRevert(CloberAdapter.InvalidConfiguration.selector);
        new CloberAdapter(
            address(manager),
            address(viewer),
            address(controller),
            address(wrappedNative),
            address(wrappedNative),
            address(usdc),
            WNATIVE_FOR_USDC,
            WNATIVE_FOR_USDC
        );
    }

    function test_constructorRejectsNonMirroredBooks() public {
        uint192 firstBook = 3;
        uint192 secondBook = 4;
        MockERC20 otherToken = new MockERC20("Other", "OTHER", 18);
        MockCloberBookManager invalidManager = new MockCloberBookManager();
        MockCloberBookViewer invalidViewer = new MockCloberBookViewer(address(invalidManager));
        MockCloberController invalidController = new MockCloberController(address(invalidManager));
        invalidManager.setBook(firstBook, address(0), address(usdc), 1);
        invalidManager.setBook(secondBook, address(otherToken), address(0), 1);

        vm.expectRevert(CloberAdapter.InvalidBook.selector);
        new CloberAdapter(
            address(invalidManager),
            address(invalidViewer),
            address(invalidController),
            address(wrappedNative),
            address(wrappedNative),
            address(usdc),
            firstBook,
            secondBook
        );
    }

    function _deployAdapter(
        MockCloberBookManager manager_,
        MockCloberBookViewer viewer_,
        MockCloberController controller_,
        MockWrappedNative wrappedNative_,
        address token0_,
        address token1_,
        uint192 bookId0For1_,
        uint192 bookId1For0_
    ) internal returns (CloberAdapter deployedAdapter) {
        deployedAdapter = new CloberAdapter(
            address(manager_),
            address(viewer_),
            address(controller_),
            address(wrappedNative_),
            token0_,
            token1_,
            bookId0For1_,
            bookId1For0_
        );
    }
}
