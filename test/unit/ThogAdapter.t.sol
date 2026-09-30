// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";

import { MRC17Adapter } from "../../src/base/MRC17Adapter.sol";
import { ThogAdapter } from "../../src/adapters/ThogAdapter.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import {
    MockMalformedThog,
    MockMalformedThogTokens,
    MockNonCanonicalThogTokens,
    MockThog
} from "../mocks/MockThog.sol";

contract MockResidualAllowanceERC20 is MockERC20 {
    mapping(address owner => mapping(address spender => bool sticky)) private _stickyAllowance;

    constructor() MockERC20("Sticky", "STICKY", 18) { }

    function approve(address spender, uint256 value) public override returns (bool) {
        bool approved = super.approve(spender, value);
        _stickyAllowance[msg.sender][spender] = value == 0;
        return approved;
    }

    function allowance(address owner, address spender) public view override returns (uint256) {
        if (_stickyAllowance[owner][spender]) return 1;
        return super.allowance(owner, spender);
    }
}

contract ThogAdapterUnitTest is Test {
    bytes32 private constant _POOL_ID = keccak256("thog-pool");
    uint256 private constant _AMOUNT_IN = 10 ether;
    uint256 private constant _AMOUNT_OUT = 19 ether;
    uint256 private constant _BLOCK_NUMBER = 1000;
    uint256 private constant _TIMESTAMP = 5000;

    address private user;
    address private recipient;
    MockERC20 private token0;
    MockERC20 private token1;
    MockERC20 private otherToken;
    MockThog private venue;
    ThogAdapter private adapter;

    function setUp() public {
        vm.roll(_BLOCK_NUMBER);
        vm.warp(_TIMESTAMP);

        user = makeAddr("user");
        recipient = makeAddr("recipient");
        token0 = new MockERC20("Token 0", "T0", 18);
        token1 = new MockERC20("Token 1", "T1", 18);
        otherToken = new MockERC20("Other", "OTHER", 18);

        address[] memory tokens = new address[](3);
        tokens[0] = address(otherToken);
        tokens[1] = address(token1);
        tokens[2] = address(token0);
        venue = new MockThog(_POOL_ID, tokens);
        adapter = new ThogAdapter(address(venue), address(token0), address(token1));

        venue.configureQuote(address(token0), address(token1), _AMOUNT_IN, _AMOUNT_OUT, _BLOCK_NUMBER - 1);
        venue.configureQuote(address(token1), address(token0), _AMOUNT_IN, _AMOUNT_OUT, _BLOCK_NUMBER);
        venue.configureSwap(_AMOUNT_OUT, _AMOUNT_IN, _AMOUNT_OUT);

        token0.mint(user, 1000 ether);
        token1.mint(user, 1000 ether);
        token0.mint(address(venue), 1000 ether);
        token1.mint(address(venue), 1000 ether);

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

    function test_constructorStoresValidatedConfiguration() public view {
        assertEq(adapter.venue(), address(venue));
    }

    function test_constructorAcceptsTokensInAnyPositionWithinSuperset() public {
        ThogAdapter deployed = new ThogAdapter(address(venue), address(token1), address(otherToken));
        venue.configureQuote(address(token1), address(otherToken), _AMOUNT_IN, _AMOUNT_OUT, 1);
        (uint256 amountOut,) = deployed.getAmountOut(address(token1), address(otherToken), _AMOUNT_IN, bytes(""));
        assertEq(amountOut, _AMOUNT_OUT);
    }

    function test_constructorRejectsNonContractVenue() public {
        vm.expectRevert(ThogAdapter.InvalidVenue.selector);
        new ThogAdapter(makeAddr("venue"), address(token0), address(token1));
    }

    function test_constructorRejectsMalformedPoolDiscovery() public {
        MockMalformedThog malformed = new MockMalformedThog();

        vm.expectRevert(ThogAdapter.InvalidVenue.selector);
        new ThogAdapter(address(malformed), address(token0), address(token1));
    }

    function test_constructorRejectsRevertingPoolDiscovery() public {
        venue.setFailureModes(true, false, false, false);

        vm.expectRevert(ThogAdapter.InvalidVenue.selector);
        new ThogAdapter(address(venue), address(token0), address(token1));
    }

    function test_constructorRejectsNoPoolIds() public {
        venue.setPoolIds(new bytes32[](0));

        vm.expectRevert(ThogAdapter.InvalidPoolConfiguration.selector);
        new ThogAdapter(address(venue), address(token0), address(token1));
    }

    function test_constructorRejectsMultiplePoolIds() public {
        bytes32[] memory poolIds = new bytes32[](2);
        poolIds[0] = _POOL_ID;
        poolIds[1] = keccak256("second-pool");
        venue.setPoolIds(poolIds);

        vm.expectRevert(ThogAdapter.InvalidPoolConfiguration.selector);
        new ThogAdapter(address(venue), address(token0), address(token1));
    }

    function test_constructorRejectsRevertingTokenDiscovery() public {
        venue.setFailureModes(false, true, false, false);

        vm.expectRevert(ThogAdapter.InvalidPoolConfiguration.selector);
        new ThogAdapter(address(venue), address(token0), address(token1));
    }

    function test_constructorRejectsMalformedTokenDiscovery() public {
        MockMalformedThogTokens malformed = new MockMalformedThogTokens(_POOL_ID);

        vm.expectRevert(ThogAdapter.InvalidPoolConfiguration.selector);
        new ThogAdapter(address(malformed), address(token0), address(token1));
    }

    function test_constructorRejectsNoncanonicalTokenAddressEncoding() public {
        MockNonCanonicalThogTokens malformed = new MockNonCanonicalThogTokens(_POOL_ID);

        vm.expectRevert(ThogAdapter.InvalidPoolConfiguration.selector);
        new ThogAdapter(address(malformed), address(token0), address(token1));
    }

    function test_constructorRejectsMissingToken0() public {
        address[] memory tokens = new address[](2);
        tokens[0] = address(otherToken);
        tokens[1] = address(token1);
        venue.setTokens(_POOL_ID, tokens);

        vm.expectRevert(ThogAdapter.InvalidPoolConfiguration.selector);
        new ThogAdapter(address(venue), address(token0), address(token1));
    }

    function test_constructorRejectsMissingToken1() public {
        address[] memory tokens = new address[](2);
        tokens[0] = address(token0);
        tokens[1] = address(otherToken);
        venue.setTokens(_POOL_ID, tokens);

        vm.expectRevert(ThogAdapter.InvalidPoolConfiguration.selector);
        new ThogAdapter(address(venue), address(token0), address(token1));
    }

    function test_constructorRejectsZeroTokenInVenueRegistry() public {
        address[] memory tokens = new address[](3);
        tokens[0] = address(token0);
        tokens[1] = address(0);
        tokens[2] = address(token1);
        venue.setTokens(_POOL_ID, tokens);

        vm.expectRevert(ThogAdapter.InvalidPoolConfiguration.selector);
        new ThogAdapter(address(venue), address(token0), address(token1));
    }

    function test_constructorRejectsDuplicateTokenInVenueRegistry() public {
        address[] memory tokens = new address[](3);
        tokens[0] = address(token0);
        tokens[1] = address(token1);
        tokens[2] = address(token0);
        venue.setTokens(_POOL_ID, tokens);

        vm.expectRevert(ThogAdapter.InvalidPoolConfiguration.selector);
        new ThogAdapter(address(venue), address(token0), address(token1));
    }

    function test_constructorRejectsInvalidBasePair() public {
        vm.expectRevert(MRC17Adapter.InvalidTokenPair.selector);
        new ThogAdapter(address(venue), address(token0), address(token0));
    }

    function test_adapterDoesNotPinRotatingPoolId() public {
        bytes32 rotatedPoolId = keccak256("rotated-pool");
        bytes32[] memory poolIds = new bytes32[](1);
        poolIds[0] = rotatedPoolId;
        venue.setPoolIds(poolIds);
        address[] memory tokens = new address[](2);
        tokens[0] = address(token0);
        tokens[1] = address(token1);
        venue.setTokens(rotatedPoolId, tokens);

        (uint256 amountOut,) = adapter.getAmountOut(address(token0), address(token1), _AMOUNT_IN, bytes(""));

        assertEq(amountOut, _AMOUNT_OUT);
    }

    function test_getAmountOutQuotesBothDirectionsAndReturnsEmptySwapData() public view {
        (uint256 zeroForOneOut, bytes memory zeroForOneData) =
            adapter.getAmountOut(address(token0), address(token1), _AMOUNT_IN, bytes(""));
        (uint256 oneForZeroOut, bytes memory oneForZeroData) =
            adapter.getAmountOut(address(token1), address(token0), _AMOUNT_IN, bytes(""));

        assertEq(zeroForOneOut, _AMOUNT_OUT);
        assertEq(oneForZeroOut, _AMOUNT_OUT);
        assertEq(zeroForOneData, bytes(""));
        assertEq(oneForZeroData, bytes(""));
    }

    function test_getAmountOutCompletesUnderStaticcall() public view {
        (bool success, bytes memory result) = address(adapter)
            .staticcall(abi.encodeCall(adapter.getAmountOut, (address(token0), address(token1), _AMOUNT_IN, bytes(""))));

        assertTrue(success);
        (uint256 amountOut, bytes memory swapData) = abi.decode(result, (uint256, bytes));
        assertEq(amountOut, _AMOUNT_OUT);
        assertEq(swapData, bytes(""));
    }

    function test_getAmountOutRejectsUnexpectedData() public {
        vm.expectRevert(ThogAdapter.UnexpectedData.selector);
        adapter.getAmountOut(address(token0), address(token1), _AMOUNT_IN, hex"01");
    }

    function test_getAmountOutRejectsZeroOutput() public {
        venue.configureQuote(address(token0), address(token1), _AMOUNT_IN, 0, _BLOCK_NUMBER);

        vm.expectRevert(ThogAdapter.InvalidQuote.selector);
        adapter.getAmountOut(address(token0), address(token1), _AMOUNT_IN, bytes(""));
    }

    function test_getAmountOutRejectsZeroPostedBlock() public {
        venue.configureQuote(address(token0), address(token1), _AMOUNT_IN, _AMOUNT_OUT, 0);

        vm.expectRevert(ThogAdapter.InvalidQuote.selector);
        adapter.getAmountOut(address(token0), address(token1), _AMOUNT_IN, bytes(""));
    }

    function test_getAmountOutRejectsFuturePostedBlock() public {
        venue.configureQuote(address(token0), address(token1), _AMOUNT_IN, _AMOUNT_OUT, _BLOCK_NUMBER + 1);

        vm.expectRevert(ThogAdapter.InvalidQuote.selector);
        adapter.getAmountOut(address(token0), address(token1), _AMOUNT_IN, bytes(""));
    }

    function test_getAmountOutAcceptsCurrentPostedBlock() public view {
        (uint256 amountOut,) = adapter.getAmountOut(address(token1), address(token0), _AMOUNT_IN, bytes(""));

        assertEq(amountOut, _AMOUNT_OUT);
    }

    function test_getAmountOutBubblesVenueRevert() public {
        venue.setFailureModes(false, false, true, false);

        vm.expectRevert(MockThog.QuoteFailed.selector);
        adapter.getAmountOut(address(token0), address(token1), _AMOUNT_IN, bytes(""));
    }

    function test_swapExecutesZeroForOneWithExactApprovalAndBlockDeadline() public {
        uint256 amountOutMin = _AMOUNT_OUT - 1;
        uint256 userInputBefore = token0.balanceOf(user);

        vm.prank(user);
        uint256 amountOut = adapter.swap(
            address(token0), address(token1), recipient, _AMOUNT_IN, amountOutMin, _TIMESTAMP + 1, bytes("")
        );

        assertEq(amountOut, _AMOUNT_OUT);
        assertEq(userInputBefore - token0.balanceOf(user), _AMOUNT_IN);
        assertEq(token1.balanceOf(recipient), _AMOUNT_OUT);
        assertEq(token0.balanceOf(address(adapter)), 0);
        assertEq(token0.allowance(address(adapter), address(venue)), 0);
        assertEq(venue.observedAllowance(), _AMOUNT_IN);
        assertEq(venue.lastTokenIn(), address(token0));
        assertEq(venue.lastTokenOut(), address(token1));
        assertEq(venue.lastAmountIn(), _AMOUNT_IN);
        assertEq(venue.lastAmountOutMin(), amountOutMin);
        assertEq(venue.lastRecipient(), recipient);
        assertEq(venue.lastDeadlineBlock(), _BLOCK_NUMBER);
    }

    function test_swapExecutesOneForZero() public {
        vm.prank(user);
        uint256 amountOut =
            adapter.swap(address(token1), address(token0), recipient, _AMOUNT_IN, _AMOUNT_OUT, _TIMESTAMP, bytes(""));

        assertEq(amountOut, _AMOUNT_OUT);
        assertEq(token0.balanceOf(recipient), _AMOUNT_OUT);
        assertEq(token1.balanceOf(address(adapter)), 0);
        assertEq(token1.allowance(address(adapter), address(venue)), 0);
        assertEq(venue.lastTokenIn(), address(token1));
        assertEq(venue.lastTokenOut(), address(token0));
    }

    function test_swapPreservesPreexistingAdapterInputBalance() public {
        uint256 donatedInput = 7 ether;
        token0.mint(address(adapter), donatedInput);

        vm.prank(user);
        adapter.swap(address(token0), address(token1), recipient, _AMOUNT_IN, 0, _TIMESTAMP, bytes(""));

        assertEq(token0.balanceOf(address(adapter)), donatedInput);
        assertEq(token0.allowance(address(adapter), address(venue)), 0);
    }

    function test_swapPreservesPreexistingAdapterOutputBalance() public {
        uint256 donatedOutput = 7 ether;
        token1.mint(address(adapter), donatedOutput);

        vm.prank(user);
        adapter.swap(address(token0), address(token1), recipient, _AMOUNT_IN, 0, _TIMESTAMP, bytes(""));

        assertEq(token1.balanceOf(address(adapter)), donatedOutput);
        assertEq(token1.balanceOf(recipient), _AMOUNT_OUT);
    }

    function test_swapRejectsPartialInputConsumptionEvenWithPreexistingBalance() public {
        token0.mint(address(adapter), 7 ether);
        venue.configureSwap(_AMOUNT_OUT, _AMOUNT_IN - 1, _AMOUNT_OUT);

        vm.expectRevert(ThogAdapter.IncompleteInputConsumption.selector);
        vm.prank(user);
        adapter.swap(address(token0), address(token1), recipient, _AMOUNT_IN, 0, _TIMESTAMP, bytes(""));

        assertEq(token0.balanceOf(address(adapter)), 7 ether);
        assertEq(token0.allowance(address(adapter), address(venue)), 0);
    }

    function test_swapCannotConsumeMoreThanExactInputAllowance() public {
        token0.mint(address(adapter), 7 ether);
        venue.configureSwap(_AMOUNT_OUT, _AMOUNT_IN + 1, _AMOUNT_OUT);

        vm.expectRevert();
        vm.prank(user);
        adapter.swap(address(token0), address(token1), recipient, _AMOUNT_IN, 0, _TIMESTAMP, bytes(""));

        assertEq(token0.balanceOf(address(adapter)), 7 ether);
        assertEq(token0.allowance(address(adapter), address(venue)), 0);
    }

    function test_swapRejectsResidualVenueAllowance() public {
        MockResidualAllowanceERC20 stickyToken = new MockResidualAllowanceERC20();
        address[] memory tokens = new address[](2);
        tokens[0] = address(stickyToken);
        tokens[1] = address(token1);
        MockThog stickyVenue = new MockThog(_POOL_ID, tokens);
        ThogAdapter stickyAdapter = new ThogAdapter(address(stickyVenue), address(stickyToken), address(token1));
        stickyVenue.configureSwap(_AMOUNT_OUT, _AMOUNT_IN, _AMOUNT_OUT);
        stickyToken.mint(user, _AMOUNT_IN);
        token1.mint(address(stickyVenue), _AMOUNT_OUT);
        vm.prank(user);
        stickyToken.approve(address(stickyAdapter), _AMOUNT_IN);

        vm.expectRevert(ThogAdapter.ResidualAllowance.selector);
        vm.prank(user);
        stickyAdapter.swap(address(stickyToken), address(token1), recipient, _AMOUNT_IN, 0, _TIMESTAMP, bytes(""));
    }

    function test_swapRejectsZeroReportedOutput() public {
        venue.configureSwap(0, _AMOUNT_IN, 0);

        vm.expectRevert(ThogAdapter.InvalidSwapResult.selector);
        vm.prank(user);
        adapter.swap(address(token0), address(token1), recipient, _AMOUNT_IN, 0, _TIMESTAMP, bytes(""));
    }

    function test_swapRejectsDishonestReportedOutput() public {
        venue.configureSwap(_AMOUNT_OUT, _AMOUNT_IN, _AMOUNT_OUT - 1);

        vm.expectRevert(MRC17Adapter.OutputBalanceMismatch.selector);
        vm.prank(user);
        adapter.swap(address(token0), address(token1), recipient, _AMOUNT_IN, 0, _TIMESTAMP, bytes(""));
    }

    function test_swapRejectsOutputBelowMinimum() public {
        vm.expectRevert(MRC17Adapter.SlippageExceeded.selector);
        vm.prank(user);
        adapter.swap(address(token0), address(token1), recipient, _AMOUNT_IN, _AMOUNT_OUT + 1, _TIMESTAMP, bytes(""));
    }

    function test_swapRejectsUnexpectedDataWithoutMovingFunds() public {
        uint256 userBalanceBefore = token0.balanceOf(user);

        vm.expectRevert(ThogAdapter.UnexpectedData.selector);
        vm.prank(user);
        adapter.swap(address(token0), address(token1), recipient, _AMOUNT_IN, 0, _TIMESTAMP, hex"01");

        assertEq(token0.balanceOf(user), userBalanceBefore);
    }

    function test_swapRejectsExpiredTimestampBeforeCallingVenue() public {
        vm.expectRevert(MRC17Adapter.DeadlineExpired.selector);
        vm.prank(user);
        adapter.swap(address(token0), address(token1), recipient, _AMOUNT_IN, 0, _TIMESTAMP - 1, bytes(""));

        assertEq(venue.lastRecipient(), address(0));
    }

    function test_swapBubblesVenueRevert() public {
        venue.setFailureModes(false, false, false, true);

        vm.expectRevert(MockThog.SwapFailed.selector);
        vm.prank(user);
        adapter.swap(address(token0), address(token1), recipient, _AMOUNT_IN, 0, _TIMESTAMP, bytes(""));

        assertEq(token0.allowance(address(adapter), address(venue)), 0);
    }
}
