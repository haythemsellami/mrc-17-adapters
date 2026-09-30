// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { CloberAdapter } from "../../src/adapters/CloberAdapter.sol";
import { MetricAdapter } from "../../src/adapters/MetricAdapter.sol";
import { AdapterMarketAssertions } from "../utils/AdapterMarketAssertions.sol";
import { PoeAdapter } from "../../src/adapters/PoeAdapter.sol";

interface IERC20E2E {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IWrappedNativeE2E {
    function deposit() external payable;
}

interface IPoeFactoryE2E {
    function getPool(address tokenX, address tokenY) external view returns (address);
}

contract MonadAdaptersE2ETest is Test {
    uint256 internal constant MONAD_FORK_BLOCK = 90_990_000;

    address internal constant WMON = 0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A;
    address internal constant USDC = 0x754704Bc059F8C67012fEd69BC8A327a5aafb603;

    address internal constant POE_FACTORY = 0x78120F2C0EBF0cc8B7E7749e62D36e6523dD711D;

    address internal constant CLOBER_BOOK_MANAGER = 0x6657d192273731C3cAc646cc82D5F28D0CBE8CCC;
    address internal constant CLOBER_BOOK_VIEWER = 0xe424c211e2Ed8a5B6d1C57FA493C41715568D238;
    address internal constant CLOBER_CONTROLLER = 0x19b68a2b909D96c05B623050C276FBD457De8e83;
    uint192 internal constant CLOBER_WMON_FOR_USDC_BOOK =
        5_954_885_684_956_363_054_050_231_031_211_743_946_744_177_791_604_395_877_538;
    uint192 internal constant CLOBER_USDC_FOR_WMON_BOOK =
        3_875_727_077_379_471_850_923_186_002_296_331_935_053_867_847_116_966_170_720;

    address internal constant METRIC_ROUTER = 0xaF9ADa6b6eC7993CE146f6c0bF98f7211CDfD3e5;
    address internal constant METRIC_WMON_USDC_POOL = 0xFA32f9ec28787d1F9C5BA5c39e54e59984FEF3f0;

    bool internal forkEnabled;

    function setUp() public {
        string memory rpcUrl = vm.envOr("MONAD_ARCHIVE_RPC_URL", vm.envOr("MONAD_RPC_URL", string("")));
        if (bytes(rpcUrl).length == 0) {
            vm.skip(true, "Set MONAD_RPC_URL to run fork tests");
            return;
        }
        vm.createSelectFork(rpcUrl, MONAD_FORK_BLOCK);
        forkEnabled = true;
    }

    function test_poeQuoteAndSwapAgainstLivePool() public {
        if (!forkEnabled) return;

        address pool = IPoeFactoryE2E(POE_FACTORY).getPool(WMON, USDC);
        assertTrue(pool.code.length != 0);
        PoeAdapter adapter = new PoeAdapter(pool);
        AdapterMarketAssertions.assertMarket(adapter, WMON, USDC, PoeAdapter.UnexpectedData.selector);

        uint256 amountIn = 4 ether;
        _fundWrappedNative(amountIn);
        IERC20E2E(WMON).approve(address(adapter), amountIn);

        (bool success, bytes memory result) =
            address(adapter).staticcall(abi.encodeCall(adapter.getAmountOut, (WMON, USDC, amountIn, bytes(""))));
        assertTrue(success);
        (uint256 quote, bytes memory swapData) = abi.decode(result, (uint256, bytes));
        address recipient = makeAddr("poe-recipient");
        uint256 amountOut = adapter.swap(WMON, USDC, recipient, amountIn, quote, block.timestamp, swapData);

        assertEq(amountOut, quote);
        assertEq(IERC20E2E(USDC).balanceOf(recipient), quote);
    }

    function test_cloberQuoteAndSwapWrapsLiveNativeOutput() public {
        if (!forkEnabled) return;

        CloberAdapter adapter = new CloberAdapter(
            CLOBER_BOOK_MANAGER,
            CLOBER_BOOK_VIEWER,
            CLOBER_CONTROLLER,
            WMON,
            WMON,
            USDC,
            CLOBER_WMON_FOR_USDC_BOOK,
            CLOBER_USDC_FOR_WMON_BOOK
        );
        uint256 amountIn = 100e6;
        deal(USDC, address(this), amountIn);
        IERC20E2E(USDC).approve(address(adapter), amountIn);

        (bool success, bytes memory result) =
            address(adapter).staticcall(abi.encodeCall(adapter.getAmountOut, (USDC, WMON, amountIn, bytes(""))));
        assertTrue(success);
        (uint256 quote, bytes memory swapData) = abi.decode(result, (uint256, bytes));
        address recipient = makeAddr("clober-recipient");
        uint256 amountOut = adapter.swap(USDC, WMON, recipient, amountIn, quote, block.timestamp, swapData);

        assertEq(amountOut, quote);
        assertEq(IERC20E2E(WMON).balanceOf(recipient), quote);
        assertEq(address(adapter).balance, 0);
    }

    function test_metricQuotesThroughRollbackIsolatedOrdinaryCallAndSwaps() public {
        if (!forkEnabled) return;

        MetricAdapter adapter = new MetricAdapter(METRIC_ROUTER, METRIC_WMON_USDC_POOL);
        AdapterMarketAssertions.assertMarket(adapter, WMON, USDC, MetricAdapter.UnexpectedQuoteData.selector);

        uint256 amountIn = 1 ether;
        bytes memory quoteCall = abi.encodeCall(adapter.getAmountOut, (WMON, USDC, amountIn, bytes("")));
        (bool staticCallSuccess,) = address(adapter).staticcall{ gas: 300_000 }(quoteCall);
        assertFalse(staticCallSuccess);

        uint256 snapshotId = vm.snapshotState();
        (uint256 quote, bytes memory swapData) = adapter.getAmountOut(WMON, USDC, amountIn, bytes(""));
        assertTrue(vm.revertToStateAndDelete(snapshotId));
        assertGt(quote, 0);

        _fundWrappedNative(amountIn);
        IERC20E2E(WMON).approve(address(adapter), amountIn);
        address recipient = makeAddr("metric-recipient");
        uint256 amountOut = adapter.swap(WMON, USDC, recipient, amountIn, quote, block.timestamp, swapData);

        assertGe(amountOut, quote);
        assertEq(IERC20E2E(USDC).balanceOf(recipient), amountOut);
    }

    function _fundWrappedNative(uint256 amount) private {
        vm.deal(address(this), address(this).balance + amount);
        IWrappedNativeE2E(WMON).deposit{ value: amount }();
    }
}
