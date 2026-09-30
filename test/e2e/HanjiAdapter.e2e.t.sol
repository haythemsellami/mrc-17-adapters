// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { AdapterMarketAssertions } from "../utils/AdapterMarketAssertions.sol";
import { Test } from "forge-std/Test.sol";
import { HanjiAdapter } from "../../src/adapters/HanjiAdapter.sol";

interface IERC20HanjiE2E {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract HanjiAdapterE2ETest is Test {
    uint256 internal constant DIVERGENT_BLOCK = 90_990_000;
    uint256 internal constant EXACT_BLOCK = 88_161_153;
    uint256 internal constant DIVERGENT_AMOUNT_IN = 99_982_143;
    uint256 internal constant DIVERGENT_QUOTE = 4715 ether;
    uint256 internal constant EXACT_AMOUNT_IN = 99_991_215;
    uint256 internal constant EXACT_AMOUNT_OUT = 4538 ether;
    uint24 internal constant MAX_PRICE_LEVELS = 60;

    address internal constant WMON = 0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A;
    address internal constant USDC = 0x754704Bc059F8C67012fEd69BC8A327a5aafb603;
    address internal constant HANJI_WMON_USDC = 0x1aeD222dda944a87703c918745b11bE13f8eEf10;
    address internal constant HANJI_FAST_QUOTER_HELPER = 0x237dB58fea34A35A8543b44C217d221606cE7788;

    string internal rpcUrl;
    string internal archiveRpcUrl;

    function setUp() public {
        rpcUrl = vm.envOr("MONAD_RPC_URL", string(""));
        archiveRpcUrl = vm.envOr("MONAD_ARCHIVE_RPC_URL", rpcUrl);
        if (bytes(rpcUrl).length == 0) rpcUrl = archiveRpcUrl;
    }

    function test_exactBoundaryQuoteExecutes() public {
        if (bytes(archiveRpcUrl).length == 0) {
            vm.skip(true, "Set MONAD_ARCHIVE_RPC_URL to run the historical Hanji control");
            return;
        }
        vm.createSelectFork(archiveRpcUrl, EXACT_BLOCK);

        HanjiAdapter adapter = _deployAdapter();
        (uint256 quote, bytes memory swapData) = adapter.getAmountOut(USDC, WMON, EXACT_AMOUNT_IN, bytes(""));
        assertEq(quote, EXACT_AMOUNT_OUT);

        deal(USDC, address(this), EXACT_AMOUNT_IN);
        IERC20HanjiE2E(USDC).approve(address(adapter), EXACT_AMOUNT_IN);
        address recipient = makeAddr("hanji-exact-recipient");
        uint256 amountOut =
            adapter.swap(USDC, WMON, recipient, EXACT_AMOUNT_IN, EXACT_AMOUNT_OUT, block.timestamp, swapData);

        assertEq(amountOut, EXACT_AMOUNT_OUT);
        assertEq(IERC20HanjiE2E(USDC).balanceOf(address(this)), 0);
        assertEq(IERC20HanjiE2E(WMON).balanceOf(recipient), EXACT_AMOUNT_OUT);
    }

    function test_divergentBoundaryRevertsAtomically() public {
        if (bytes(rpcUrl).length == 0) {
            vm.skip(true, "Set MONAD_RPC_URL to run fork tests");
            return;
        }
        vm.createSelectFork(rpcUrl, DIVERGENT_BLOCK);

        HanjiAdapter adapter = _deployAdapter();
        (uint256 quote, bytes memory swapData) = adapter.getAmountOut(USDC, WMON, DIVERGENT_AMOUNT_IN, bytes(""));
        assertEq(quote, DIVERGENT_QUOTE);

        deal(USDC, address(this), DIVERGENT_AMOUNT_IN);
        IERC20HanjiE2E(USDC).approve(address(adapter), DIVERGENT_AMOUNT_IN);
        address recipient = makeAddr("hanji-divergent-recipient");

        vm.expectRevert();
        adapter.swap(USDC, WMON, recipient, DIVERGENT_AMOUNT_IN, quote, block.timestamp, swapData);

        assertEq(IERC20HanjiE2E(USDC).balanceOf(address(this)), DIVERGENT_AMOUNT_IN);
        assertEq(IERC20HanjiE2E(WMON).balanceOf(recipient), 0);
    }

    function _deployAdapter() private returns (HanjiAdapter adapter) {
        adapter = new HanjiAdapter(HANJI_WMON_USDC, HANJI_FAST_QUOTER_HELPER, MAX_PRICE_LEVELS);
        AdapterMarketAssertions.assertMarket(adapter, WMON, USDC, HanjiAdapter.UnexpectedData.selector);
    }
}
