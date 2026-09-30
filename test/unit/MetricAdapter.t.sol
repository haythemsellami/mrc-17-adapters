// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";

import { MetricAdapter } from "../../src/adapters/MetricAdapter.sol";
import { MRC17Adapter } from "../../src/base/MRC17Adapter.sol";
import { IPropAMMRouter } from "../../src/interfaces/IPropAMMRouter.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import {
    MockMalformedMetricPool,
    MockMetricPool,
    MockMetricPriceProvider,
    MockMetricRouter
} from "../mocks/MockMetric.sol";

contract MetricAdapterUnitTest is Test {
    uint128 private constant _BID_PRICE_X64 = 1000;
    uint128 private constant _ASK_PRICE_X64 = 2000;
    uint256 private constant _AMOUNT_IN = 10 ether;
    uint256 private constant _AMOUNT_OUT = 19 ether;
    uint256 private constant _DEADLINE = 1_000_000;

    address private user;
    address private recipient;
    MockERC20 private token0;
    MockERC20 private token1;
    MockMetricPriceProvider private priceProvider;
    MockMetricPool private pool;
    MockMetricRouter private router;
    MetricAdapter private adapter;

    function setUp() public {
        user = makeAddr("user");
        recipient = makeAddr("recipient");
        token0 = new MockERC20("Token 0", "T0", 18);
        token1 = new MockERC20("Token 1", "T1", 18);
        priceProvider = new MockMetricPriceProvider(_BID_PRICE_X64, _ASK_PRICE_X64);
        pool = new MockMetricPool(address(priceProvider), address(token0), address(token1));
        router = new MockMetricRouter();
        adapter = new MetricAdapter(address(router), address(pool));

        token0.mint(user, 1000 ether);
        token1.mint(user, 1000 ether);
        token0.mint(address(router), 1000 ether);
        token1.mint(address(router), 1000 ether);

        vm.startPrank(user);
        token0.approve(address(adapter), type(uint256).max);
        token1.approve(address(adapter), type(uint256).max);
        vm.stopPrank();
    }

    function test_rejectsUnsupportedAssetsInQuotesAndSwaps() public {
        vm.expectRevert(MRC17Adapter.InvalidTokenPair.selector);
        adapter.getAmountOut(address(token0), address(token0), 1, bytes(""));
        vm.expectRevert(MRC17Adapter.InvalidTokenPair.selector);
        adapter.getAmountOut(address(0xBEEF), address(token1), 1, bytes(""));
        vm.expectRevert(MRC17Adapter.InvalidTokenPair.selector);
        adapter.swap(address(token0), address(0xBEEF), recipient, 1, 0, block.timestamp, bytes(""));
    }

    function test_doesNotExposeTokenOrderingGetters() public view {
        (bool first,) = address(adapter).staticcall(abi.encodeWithSignature("token0()"));
        (bool second,) = address(adapter).staticcall(abi.encodeWithSignature("token1()"));
        assertFalse(first);
        assertFalse(second);
    }

    function test_constructorStoresValidatedPoolConfiguration() public view {
        assertEq(adapter.router(), address(router));
        assertEq(adapter.pool(), address(pool));
        assertEq(adapter.priceProvider(), address(priceProvider));
    }

    function test_constructorRejectsInvalidRouter() public {
        vm.expectRevert(MetricAdapter.InvalidRouter.selector);
        new MetricAdapter(makeAddr("invalid router"), address(pool));
    }

    function test_constructorRejectsInvalidPool() public {
        vm.expectRevert(MetricAdapter.InvalidPool.selector);
        new MetricAdapter(address(router), makeAddr("invalid pool"));
    }

    function test_constructorRejectsMalformedPoolConfiguration() public {
        MockMalformedMetricPool malformedPool = new MockMalformedMetricPool();

        vm.expectRevert(MetricAdapter.InvalidPool.selector);
        new MetricAdapter(address(router), address(malformedPool));
    }

    function test_constructorRejectsInvalidPriceProvider() public {
        MockMetricPool invalidPool = new MockMetricPool(makeAddr("invalid provider"), address(token0), address(token1));

        vm.expectRevert(MetricAdapter.InvalidPriceProvider.selector);
        new MetricAdapter(address(router), address(invalidPool));
    }

    function test_constructorRejectsInvalidTokenPair() public {
        MockMetricPool invalidPool = new MockMetricPool(address(priceProvider), address(token0), address(token0));

        vm.expectRevert(MRC17Adapter.InvalidTokenPair.selector);
        new MetricAdapter(address(router), address(invalidPool));
    }

    function test_getAmountOutQuotesZeroForOneWithLowerPriceLimit() public {
        router.configureQuote(int128(int256(_AMOUNT_IN)), -int128(int256(_AMOUNT_OUT)));

        (uint256 amountOut, bytes memory swapData) =
            adapter.getAmountOut(address(token0), address(token1), _AMOUNT_IN, bytes(""));

        assertEq(amountOut, _AMOUNT_OUT);
        assertEq(swapData, bytes(""));
        assertEq(router.quoteCalls(), 1);
        assertEq(router.lastPool(), address(pool));
        assertTrue(router.lastZeroForOne());
        assertEq(router.lastAmountSpecified(), int128(int256(_AMOUNT_IN)));
        assertEq(router.lastPriceLimitX64(), 1);
        assertEq(router.lastBidPriceX64(), _BID_PRICE_X64);
        assertEq(router.lastAskPriceX64(), _ASK_PRICE_X64);
    }

    function test_getAmountOutQuotesOneForZeroWithUpperPriceLimit() public {
        router.configureQuote(-int128(int256(_AMOUNT_OUT)), int128(int256(_AMOUNT_IN)));

        (uint256 amountOut, bytes memory swapData) =
            adapter.getAmountOut(address(token1), address(token0), _AMOUNT_IN, bytes(""));

        assertEq(amountOut, _AMOUNT_OUT);
        assertEq(swapData, bytes(""));
        assertFalse(router.lastZeroForOne());
        assertEq(router.lastAmountSpecified(), int128(int256(_AMOUNT_IN)));
        assertEq(router.lastPriceLimitX64(), type(uint128).max);
    }

    function test_getAmountOutUsesOrdinaryCallForStatefulMetricQuote() public {
        router.configureQuote(int128(int256(_AMOUNT_IN)), -int128(int256(_AMOUNT_OUT)));
        bytes memory callData =
            abi.encodeCall(IPropAMMRouter.getAmountOut, (address(token0), address(token1), _AMOUNT_IN, bytes("")));

        (bool staticSuccess,) = address(adapter).staticcall{ gas: 300_000 }(callData);
        assertFalse(staticSuccess);
        assertEq(router.quoteCalls(), 0);

        (uint256 amountOut,) = adapter.getAmountOut(address(token0), address(token1), _AMOUNT_IN, bytes(""));
        assertEq(amountOut, _AMOUNT_OUT);
        assertEq(router.quoteCalls(), 1);
    }

    function test_getAmountOutForwardsCurrentOraclePrices() public {
        uint128 updatedBid = 3000;
        uint128 updatedAsk = 4000;
        priceProvider.setPrices(updatedBid, updatedAsk);
        router.configureQuote(int128(int256(_AMOUNT_IN)), -int128(int256(_AMOUNT_OUT)));

        adapter.getAmountOut(address(token0), address(token1), _AMOUNT_IN, bytes(""));

        assertEq(router.lastBidPriceX64(), updatedBid);
        assertEq(router.lastAskPriceX64(), updatedAsk);
    }

    function test_getAmountOutRejectsUnexpectedQuoteData() public {
        vm.expectRevert(MetricAdapter.UnexpectedQuoteData.selector);
        adapter.getAmountOut(address(token0), address(token1), _AMOUNT_IN, hex"01");
    }

    function test_zeroInputQuoteIsRejectedByResultValidation() public {
        vm.expectRevert(MetricAdapter.InvalidQuote.selector);
        adapter.getAmountOut(address(token0), address(token1), 0, bytes(""));
    }

    function test_getAmountOutRejectsAmountAboveSignedInt128() public {
        uint256 amountIn = uint256(uint128(type(int128).max)) + 1;

        vm.expectRevert(MetricAdapter.QuoteAmountOverflow.selector);
        adapter.getAmountOut(address(token0), address(token1), amountIn, bytes(""));
    }

    function test_getAmountOutRejectsPartialInputQuote() public {
        router.configureQuote(int128(int256(_AMOUNT_IN - 1)), -int128(int256(_AMOUNT_OUT)));

        vm.expectRevert(MetricAdapter.InvalidQuote.selector);
        adapter.getAmountOut(address(token0), address(token1), _AMOUNT_IN, bytes(""));
    }

    function test_getAmountOutRejectsNonNegativeOutputDelta() public {
        router.configureQuote(int128(int256(_AMOUNT_IN)), 0);

        vm.expectRevert(MetricAdapter.InvalidQuote.selector);
        adapter.getAmountOut(address(token0), address(token1), _AMOUNT_IN, bytes(""));
    }

    function test_getAmountOutBubblesRouterRevert() public {
        router.setFailureModes(true, false);

        vm.expectRevert(MockMetricRouter.QuoteFailed.selector);
        adapter.getAmountOut(address(token0), address(token1), _AMOUNT_IN, bytes(""));
    }

    function test_swapExecutesZeroForOneAndForwardsAllParameters() public {
        uint256 amountOutMin = _AMOUNT_OUT - 1;
        router.configureSwap(_AMOUNT_OUT, _AMOUNT_IN, _AMOUNT_IN, _AMOUNT_OUT);
        uint256 userInputBefore = token0.balanceOf(user);
        uint256 recipientOutputBefore = token1.balanceOf(recipient);

        vm.prank(user);
        uint256 amountOut =
            adapter.swap(address(token0), address(token1), recipient, _AMOUNT_IN, amountOutMin, _DEADLINE, bytes(""));

        assertEq(amountOut, _AMOUNT_OUT);
        assertEq(userInputBefore - token0.balanceOf(user), _AMOUNT_IN);
        assertEq(token1.balanceOf(recipient) - recipientOutputBefore, _AMOUNT_OUT);
        assertEq(token0.balanceOf(address(adapter)), 0);
        assertEq(token1.balanceOf(address(adapter)), 0);
        assertEq(token0.allowance(address(adapter), address(router)), 0);
        assertEq(router.lastPool(), address(pool));
        assertEq(router.lastRecipient(), recipient);
        assertTrue(router.lastZeroForOne());
        assertEq(router.lastAmountIn(), uint128(_AMOUNT_IN));
        assertEq(router.lastPriceLimitX64(), 1);
        assertEq(router.lastAmountOutMin(), amountOutMin);
        assertEq(router.lastDeadline(), _DEADLINE);
    }

    function test_swapExecutesOneForZeroWithUpperPriceLimit() public {
        router.configureSwap(_AMOUNT_OUT, _AMOUNT_IN, _AMOUNT_IN, _AMOUNT_OUT);
        uint256 userInputBefore = token1.balanceOf(user);
        uint256 recipientOutputBefore = token0.balanceOf(recipient);

        vm.prank(user);
        uint256 amountOut =
            adapter.swap(address(token1), address(token0), recipient, _AMOUNT_IN, _AMOUNT_OUT, _DEADLINE, bytes(""));

        assertEq(amountOut, _AMOUNT_OUT);
        assertEq(userInputBefore - token1.balanceOf(user), _AMOUNT_IN);
        assertEq(token0.balanceOf(recipient) - recipientOutputBefore, _AMOUNT_OUT);
        assertFalse(router.lastZeroForOne());
        assertEq(router.lastPriceLimitX64(), type(uint128).max);
        assertEq(token1.allowance(address(adapter), address(router)), 0);
    }

    function test_swapRejectsUnexpectedSwapDataWithoutMovingFunds() public {
        uint256 userInputBefore = token0.balanceOf(user);

        vm.expectRevert(MetricAdapter.UnexpectedSwapData.selector);
        vm.prank(user);
        adapter.swap(address(token0), address(token1), recipient, _AMOUNT_IN, 0, _DEADLINE, hex"01");

        assertEq(token0.balanceOf(user), userInputBefore);
    }

    function test_swapRejectsAmountAboveSignedInt128() public {
        uint256 amountIn = uint256(uint128(type(int128).max)) + 1;
        token0.mint(user, amountIn);

        vm.expectRevert(MetricAdapter.SwapAmountOverflow.selector);
        vm.prank(user);
        adapter.swap(address(token0), address(token1), recipient, amountIn, 0, _DEADLINE, bytes(""));
    }

    function test_swapRejectsReportedPartialInputUse() public {
        router.configureSwap(_AMOUNT_OUT, _AMOUNT_IN - 1, _AMOUNT_IN, _AMOUNT_OUT);

        vm.expectRevert(MetricAdapter.InvalidSwapResult.selector);
        vm.prank(user);
        adapter.swap(address(token0), address(token1), recipient, _AMOUNT_IN, 0, _DEADLINE, bytes(""));
    }

    function test_swapRejectsZeroReportedOutput() public {
        router.configureSwap(0, _AMOUNT_IN, _AMOUNT_IN, 0);

        vm.expectRevert(MetricAdapter.InvalidSwapResult.selector);
        vm.prank(user);
        adapter.swap(address(token0), address(token1), recipient, _AMOUNT_IN, 0, _DEADLINE, bytes(""));
    }

    function test_swapRejectsDishonestReportedOutput() public {
        router.configureSwap(_AMOUNT_OUT, _AMOUNT_IN, _AMOUNT_IN, _AMOUNT_OUT - 1);

        vm.expectRevert(MRC17Adapter.OutputBalanceMismatch.selector);
        vm.prank(user);
        adapter.swap(address(token0), address(token1), recipient, _AMOUNT_IN, 0, _DEADLINE, bytes(""));
    }

    function test_swapTrustsReportedInputUseWhenRouterPullsLess() public {
        router.configureSwap(_AMOUNT_OUT, _AMOUNT_IN, _AMOUNT_IN - 1, _AMOUNT_OUT);

        vm.prank(user);
        uint256 amountOut =
            adapter.swap(address(token0), address(token1), recipient, _AMOUNT_IN, 0, _DEADLINE, bytes(""));

        assertEq(amountOut, _AMOUNT_OUT);
        assertEq(token1.balanceOf(recipient), _AMOUNT_OUT);
        assertEq(token0.balanceOf(address(adapter)), 1);
        assertEq(token0.allowance(address(adapter), address(router)), 0);
    }

    function test_swapEnforcesMinimumAgainstRecipientBalanceDelta() public {
        router.configureSwap(_AMOUNT_OUT, _AMOUNT_IN, _AMOUNT_IN, _AMOUNT_OUT);

        vm.expectRevert(MRC17Adapter.SlippageExceeded.selector);
        vm.prank(user);
        adapter.swap(address(token0), address(token1), recipient, _AMOUNT_IN, _AMOUNT_OUT + 1, _DEADLINE, bytes(""));
    }

    function test_swapBubblesRouterRevert() public {
        router.setFailureModes(false, true);

        vm.expectRevert(MockMetricRouter.SwapFailed.selector);
        vm.prank(user);
        adapter.swap(address(token0), address(token1), recipient, _AMOUNT_IN, 0, _DEADLINE, bytes(""));
    }
}
