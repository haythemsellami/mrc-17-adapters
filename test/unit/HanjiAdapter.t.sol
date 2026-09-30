// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";

import { HanjiAdapter } from "../../src/adapters/HanjiAdapter.sol";
import { MRC17Adapter } from "../../src/base/MRC17Adapter.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockHanjiFastQuoter, MockHanjiMarket, MockHanjiWrappedNative } from "../mocks/MockHanji.sol";

contract HanjiAdapterUnitTest is Test {
    uint24 internal constant MAX_PRICE_LEVELS = 60;
    uint256 internal constant SCALING_X = 1 ether;
    uint256 internal constant SCALING_Y = 1;

    uint256 internal constant SELL_SHARES = 4;
    uint256 internal constant SELL_VALUE = 7_800_000;
    uint256 internal constant SELL_FEE = 780;
    uint256 internal constant SELL_OUTPUT = SELL_VALUE - SELL_FEE;

    uint256 internal constant BUY_SHARES = 4;
    uint256 internal constant BUY_VALUE = 8_600_000;
    uint256 internal constant BUY_FEE = 860;
    uint256 internal constant BUY_INPUT = BUY_VALUE + BUY_FEE;
    uint256 internal constant BUY_OUTPUT = BUY_SHARES * SCALING_X;

    MockHanjiWrappedNative internal wrappedNative;
    MockERC20 internal usdc;
    MockHanjiMarket internal market;
    MockHanjiFastQuoter internal helper;
    HanjiAdapter internal adapter;

    address internal user = makeAddr("user");
    address internal recipient = makeAddr("recipient");

    function setUp() public {
        wrappedNative = new MockHanjiWrappedNative();
        usdc = new MockERC20("USD Coin", "USDC", 6);
        market = new MockHanjiMarket(address(wrappedNative), address(usdc), SCALING_X, SCALING_Y);
        helper = new MockHanjiFastQuoter(address(market));
        adapter = new HanjiAdapter(address(market), address(helper), MAX_PRICE_LEVELS);

        _setMultilevelBook();
        wrappedNative.mint(address(market), 1_000_000 ether);
        usdc.mint(address(market), 1_000_000_000_000);
        vm.deal(address(market), 1_000_000 ether);

        wrappedNative.mint(user, 1_000_000 ether);
        usdc.mint(user, 1_000_000_000_000);
        vm.startPrank(user);
        wrappedNative.approve(address(adapter), type(uint256).max);
        usdc.approve(address(adapter), type(uint256).max);
        vm.stopPrank();
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
        assertEq(adapter.market(), address(market));
        assertEq(adapter.helper(), address(helper));
        assertEq(adapter.maxPriceLevels(), MAX_PRICE_LEVELS);
        assertEq(adapter.scalingFactorTokenX(), SCALING_X);
        assertEq(adapter.scalingFactorTokenY(), SCALING_Y);
        assertEq(adapter.wrappedNative(), address(wrappedNative));
        assertTrue(adapter.supportsNativeEth());
        assertTrue(adapter.isTokenXWrappedNative());
    }

    function test_quotesMultilevelBidWithCeilingFee() public view {
        (uint256 amountOut, bytes memory swapData) =
            adapter.getAmountOut(address(wrappedNative), address(usdc), SELL_SHARES * SCALING_X, bytes(""));

        assertEq(amountOut, SELL_OUTPUT);
        assertEq(swapData.length, 0);
    }

    function test_quotesMultilevelAskAtExactInputBoundary() public view {
        (uint256 amountOut, bytes memory swapData) =
            adapter.getAmountOut(address(usdc), address(wrappedNative), BUY_INPUT, bytes(""));

        assertEq(amountOut, BUY_OUTPUT);
        assertEq(swapData.length, 0);
    }

    function test_quoteCompletesUnderStaticcall() public view {
        (bool success, bytes memory result) = address(adapter)
            .staticcall(
                abi.encodeCall(adapter.getAmountOut, (address(usdc), address(wrappedNative), BUY_INPUT, bytes("")))
            );

        assertTrue(success);
        (uint256 amountOut, bytes memory swapData) = abi.decode(result, (uint256, bytes));
        assertEq(amountOut, BUY_OUTPUT);
        assertEq(swapData.length, 0);
    }

    function test_quoteRoundsFeeUp() public {
        uint72[] memory bidPrices = new uint72[](1);
        bidPrices[0] = 10_001;
        uint128[] memory bidShares = new uint128[](1);
        bidShares[0] = 1;
        helper.setOrderbook(bidPrices, bidShares, new uint72[](0), new uint128[](0));

        (uint256 amountOut,) = adapter.getAmountOut(address(wrappedNative), address(usdc), SCALING_X, bytes(""));

        assertEq(amountOut, 9999);
    }

    function test_buyQuoteRejectsInputAboveExactBoundary() public {
        vm.expectRevert(HanjiAdapter.InvalidQuote.selector);
        adapter.getAmountOut(address(usdc), address(wrappedNative), BUY_INPUT + 1, bytes(""));
    }

    function test_buyQuoteRejectsInputBelowFirstExactBoundary() public {
        vm.expectRevert(HanjiAdapter.InvalidQuote.selector);
        adapter.getAmountOut(address(usdc), address(wrappedNative), 2_100_210 - 1, bytes(""));
    }

    function test_sellQuoteRejectsFractionalShare() public {
        vm.expectRevert(HanjiAdapter.InvalidShareAmount.selector);
        adapter.getAmountOut(address(wrappedNative), address(usdc), SCALING_X + 1, bytes(""));
    }

    function test_sellQuoteRejectsInsufficientVisibleDepth() public {
        vm.expectRevert(HanjiAdapter.InsufficientHelperDepth.selector);
        adapter.getAmountOut(address(wrappedNative), address(usdc), 6 * SCALING_X, bytes(""));
    }

    function test_quoteRejectsUnexpectedData() public {
        vm.expectRevert(HanjiAdapter.UnexpectedData.selector);
        adapter.getAmountOut(address(wrappedNative), address(usdc), SCALING_X, hex"01");
    }

    function test_zeroInputQuotesAreRejectedByAmountConversion() public {
        vm.expectRevert(HanjiAdapter.QuoteAmountOverflow.selector);
        adapter.getAmountOut(address(wrappedNative), address(usdc), 0, bytes(""));

        vm.expectRevert(HanjiAdapter.QuoteAmountOverflow.selector);
        adapter.getAmountOut(address(usdc), address(wrappedNative), 0, bytes(""));
    }

    function test_sellExecutesErc20SettlementAndClearsAllowance() public {
        _configureExactSell();

        vm.prank(user);
        uint256 amountOut = adapter.swap(
            address(wrappedNative),
            address(usdc),
            recipient,
            SELL_SHARES * SCALING_X,
            SELL_OUTPUT,
            block.timestamp,
            bytes("")
        );

        assertEq(amountOut, SELL_OUTPUT);
        assertEq(usdc.balanceOf(recipient), SELL_OUTPUT);
        assertEq(wrappedNative.balanceOf(address(adapter)), 0);
        assertEq(usdc.balanceOf(address(adapter)), 0);
        assertEq(wrappedNative.allowance(address(adapter), address(market)), 0);
        assertEq(market.lastQuantity(), SELL_SHARES);
        assertEq(market.lastPrice(), 1);
        assertEq(market.lastMaxCommission(), type(uint128).max);
        assertEq(market.lastExpires(), block.timestamp);
        assertTrue(market.lastIsAsk());
        assertTrue(market.lastMarketOnly());
        assertFalse(market.lastPostOnly());
        assertTrue(market.lastTransferExecutedTokens());
    }

    function test_buyWrapsAuthorizedNativeOutputAndClearsAllowance() public {
        _configureExactNativeBuy();

        vm.prank(user);
        uint256 amountOut = adapter.swap(
            address(usdc), address(wrappedNative), recipient, BUY_INPUT, BUY_OUTPUT, block.timestamp, bytes("")
        );

        assertEq(amountOut, BUY_OUTPUT);
        assertEq(wrappedNative.balanceOf(recipient), BUY_OUTPUT);
        assertEq(wrappedNative.balanceOf(address(adapter)), 0);
        assertEq(usdc.balanceOf(address(adapter)), 0);
        assertEq(address(adapter).balance, 0);
        assertEq(usdc.allowance(address(adapter), address(market)), 0);
        assertEq(market.lastTargetTokenYValue(), BUY_INPUT);
        assertEq(market.lastPrice(), 999_999_000_000_000_000_000);
        assertEq(market.lastMaxCommission(), type(uint128).max);
        assertEq(market.lastExpires(), block.timestamp);
        assertFalse(market.lastIsAsk());
        assertTrue(market.lastTransferExecutedTokens());
    }

    function test_buyExecutesErc20OnlyMarket() public {
        MockERC20 tokenX = new MockERC20("Token X", "X", 18);
        MockERC20 tokenY = new MockERC20("Token Y", "Y", 6);
        MockHanjiMarket erc20Market = new MockHanjiMarket(address(tokenX), address(tokenY), SCALING_X, SCALING_Y);
        erc20Market.setNativeConfiguration(false, false);
        MockHanjiFastQuoter erc20Helper = new MockHanjiFastQuoter(address(erc20Market));
        HanjiAdapter erc20Adapter = new HanjiAdapter(address(erc20Market), address(erc20Helper), MAX_PRICE_LEVELS);

        uint72[] memory askPrices = new uint72[](1);
        askPrices[0] = 2_000_000;
        uint128[] memory askShares = new uint128[](1);
        askShares[0] = 10;
        erc20Helper.setOrderbook(new uint72[](0), new uint128[](0), askPrices, askShares);

        uint256 input = 4_000_400;
        uint256 output = 2 ether;
        erc20Market.setBuyExecution(2, 4_000_000, 400, input, output, false);
        tokenX.mint(address(erc20Market), output);
        tokenY.mint(user, input);
        vm.prank(user);
        tokenY.approve(address(erc20Adapter), input);

        vm.prank(user);
        uint256 amountOut =
            erc20Adapter.swap(address(tokenY), address(tokenX), recipient, input, output, block.timestamp, bytes(""));

        assertEq(amountOut, output);
        assertEq(tokenX.balanceOf(recipient), output);
        assertEq(tokenX.balanceOf(address(erc20Adapter)), 0);
        assertEq(tokenY.balanceOf(address(erc20Adapter)), 0);
        assertEq(tokenY.allowance(address(erc20Adapter), address(erc20Market)), 0);
        assertEq(erc20Adapter.wrappedNative(), address(0));
        assertFalse(erc20Adapter.supportsNativeEth());
        assertFalse(erc20Adapter.isTokenXWrappedNative());
    }

    function test_buyRejectsResidualInput() public {
        market.setBuyExecution(
            uint128(BUY_SHARES), uint128(BUY_VALUE), uint128(BUY_FEE), BUY_INPUT - 1, BUY_OUTPUT, true
        );

        vm.prank(user);
        vm.expectRevert(HanjiAdapter.IncompleteInputConsumption.selector);
        adapter.swap(address(usdc), address(wrappedNative), recipient, BUY_INPUT, 0, block.timestamp, bytes(""));
    }

    function test_buyRejectsOutputBelowQuotedMinimum() public {
        market.setBuyExecution(
            uint128(BUY_SHARES - 1), uint128(BUY_VALUE), uint128(BUY_FEE), BUY_INPUT, BUY_OUTPUT - SCALING_X, true
        );

        vm.prank(user);
        vm.expectRevert(MRC17Adapter.SlippageExceeded.selector);
        adapter.swap(
            address(usdc), address(wrappedNative), recipient, BUY_INPUT, BUY_OUTPUT, block.timestamp, bytes("")
        );
    }

    function test_swapRejectsUnexpectedData() public {
        vm.prank(user);
        vm.expectRevert(HanjiAdapter.UnexpectedData.selector);
        adapter.swap(address(wrappedNative), address(usdc), recipient, SCALING_X, 0, block.timestamp, hex"01");
    }

    function test_swapPreservesDonatedTokenAndNativeBalances() public {
        uint256 donatedInput = 7_000_000;
        uint256 donatedOutput = 5 ether;
        uint256 donatedNative = 3 ether;
        usdc.mint(address(adapter), donatedInput);
        wrappedNative.mint(address(adapter), donatedOutput);
        vm.deal(address(adapter), donatedNative);
        _configureExactNativeBuy();

        vm.prank(user);
        uint256 amountOut = adapter.swap(
            address(usdc), address(wrappedNative), recipient, BUY_INPUT, BUY_OUTPUT, block.timestamp, bytes("")
        );

        assertEq(amountOut, BUY_OUTPUT);
        assertEq(usdc.balanceOf(address(adapter)), donatedInput);
        assertEq(wrappedNative.balanceOf(address(adapter)), donatedOutput);
        assertEq(address(adapter).balance, donatedNative);
        assertEq(wrappedNative.balanceOf(recipient), BUY_OUTPUT);
    }

    function test_swapRejectsExpiredDeadline() public {
        vm.warp(100);

        vm.prank(user);
        vm.expectRevert(MRC17Adapter.DeadlineExpired.selector);
        adapter.swap(address(wrappedNative), address(usdc), recipient, SCALING_X, 0, 99, bytes(""));
    }

    function test_swapRejectsZeroRecipient() public {
        vm.prank(user);
        vm.expectRevert(MRC17Adapter.InvalidRecipient.selector);
        adapter.swap(address(wrappedNative), address(usdc), address(0), SCALING_X, 0, block.timestamp, bytes(""));
    }

    function test_rejectsUnauthorizedNativeTransfer() public {
        (bool success, bytes memory returnData) = address(adapter).call{ value: 1 }("");

        assertFalse(success);
        assertGe(returnData.length, 4);
        assertEq(bytes4(returnData), HanjiAdapter.UnexpectedNativeTransfer.selector);
    }

    function test_constructorRejectsNonContractMarket() public {
        vm.expectRevert(HanjiAdapter.InvalidConfiguration.selector);
        new HanjiAdapter(makeAddr("market"), address(helper), MAX_PRICE_LEVELS);
    }

    function test_constructorRejectsNonContractHelper() public {
        vm.expectRevert(HanjiAdapter.InvalidConfiguration.selector);
        new HanjiAdapter(address(market), makeAddr("helper"), MAX_PRICE_LEVELS);
    }

    function test_constructorRejectsZeroMaximumPriceLevels() public {
        vm.expectRevert(HanjiAdapter.InvalidConfiguration.selector);
        new HanjiAdapter(address(market), address(helper), 0);
    }

    function test_constructorRejectsZeroScalingFactor() public {
        market.setScalingFactors(0, SCALING_Y);

        vm.expectRevert(HanjiAdapter.InvalidConfiguration.selector);
        new HanjiAdapter(address(market), address(helper), MAX_PRICE_LEVELS);
    }

    function test_quoteRejectsChangedCapturedConfiguration() public {
        market.setScalingFactors(SCALING_X, 2);

        vm.expectRevert(HanjiAdapter.InvalidConfiguration.selector);
        adapter.getAmountOut(address(wrappedNative), address(usdc), SCALING_X, bytes(""));
    }

    function test_quoteUsesCurrentCommissionConfiguration() public {
        market.setFeeConfiguration(0, 2e14, 0, 1e14);

        (uint256 amountOut,) =
            adapter.getAmountOut(address(wrappedNative), address(usdc), SELL_SHARES * SCALING_X, bytes(""));

        assertEq(amountOut, SELL_VALUE - 2340);
    }

    function _setMultilevelBook() internal {
        uint72[] memory bidPrices = new uint72[](2);
        bidPrices[0] = 2_000_000;
        bidPrices[1] = 1_900_000;
        uint128[] memory bidShares = new uint128[](2);
        bidShares[0] = 2;
        bidShares[1] = 3;

        uint72[] memory askPrices = new uint72[](2);
        askPrices[0] = 2_100_000;
        askPrices[1] = 2_200_000;
        uint128[] memory askShares = new uint128[](2);
        askShares[0] = 2;
        askShares[1] = 3;

        helper.setOrderbook(bidPrices, bidShares, askPrices, askShares);
    }

    function _configureExactSell() internal {
        market.setSellExecution(
            uint128(SELL_SHARES), uint128(SELL_VALUE), uint128(SELL_FEE), SELL_SHARES * SCALING_X, SELL_OUTPUT
        );
    }

    function _configureExactNativeBuy() internal {
        market.setBuyExecution(uint128(BUY_SHARES), uint128(BUY_VALUE), uint128(BUY_FEE), BUY_INPUT, BUY_OUTPUT, true);
    }
}
