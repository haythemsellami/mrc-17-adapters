// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {
    IMetricLegacyPool,
    IMetricLegacyPriceProvider,
    IMetricLegacyRouter,
    MetricPoolImmutables
} from "../../src/adapters/MetricAdapter.sol";

contract MockMetricPool is IMetricLegacyPool {
    MetricPoolImmutables private _poolImmutables;

    constructor(address priceProvider_, address token0_, address token1_) {
        _poolImmutables.factory = address(this);
        _poolImmutables.priceProvider = priceProvider_;
        _poolImmutables.token0 = token0_;
        _poolImmutables.token1 = token1_;
    }

    function setPriceProvider(address priceProvider_) external {
        _poolImmutables.priceProvider = priceProvider_;
    }

    function setTokens(address token0_, address token1_) external {
        _poolImmutables.token0 = token0_;
        _poolImmutables.token1 = token1_;
    }

    function getImmutables() external view returns (MetricPoolImmutables memory poolImmutables) {
        return _poolImmutables;
    }
}

contract MockMetricPriceProvider is IMetricLegacyPriceProvider {
    uint128 public bidPriceX64;
    uint128 public askPriceX64;

    constructor(uint128 bidPriceX64_, uint128 askPriceX64_) {
        bidPriceX64 = bidPriceX64_;
        askPriceX64 = askPriceX64_;
    }

    function setPrices(uint128 bidPriceX64_, uint128 askPriceX64_) external {
        bidPriceX64 = bidPriceX64_;
        askPriceX64 = askPriceX64_;
    }

    function getBidAndAskPrice() external view returns (uint128, uint128) {
        return (bidPriceX64, askPriceX64);
    }
}

contract MockMetricRouter is IMetricLegacyRouter {
    using SafeERC20 for IERC20;

    error QuoteFailed();
    error SwapFailed();

    int128 public quoteAmount0Delta;
    int128 public quoteAmount1Delta;
    uint256 public swapAmountOut;
    uint256 public swapAmountInUsed;
    uint256 public swapPullAmount;
    uint256 public swapTransferAmount;
    bool public revertQuote;
    bool public revertSwap;

    uint256 public quoteCalls;
    address public lastPool;
    address public lastRecipient;
    bool public lastZeroForOne;
    int128 public lastAmountSpecified;
    uint128 public lastAmountIn;
    uint128 public lastPriceLimitX64;
    uint128 public lastBidPriceX64;
    uint128 public lastAskPriceX64;
    uint256 public lastAmountOutMin;
    uint256 public lastDeadline;

    function configureQuote(int128 amount0Delta_, int128 amount1Delta_) external {
        quoteAmount0Delta = amount0Delta_;
        quoteAmount1Delta = amount1Delta_;
    }

    function configureSwap(uint256 amountOut_, uint256 amountInUsed_, uint256 pullAmount_, uint256 transferAmount_)
        external
    {
        swapAmountOut = amountOut_;
        swapAmountInUsed = amountInUsed_;
        swapPullAmount = pullAmount_;
        swapTransferAmount = transferAmount_;
    }

    function setFailureModes(bool revertQuote_, bool revertSwap_) external {
        revertQuote = revertQuote_;
        revertSwap = revertSwap_;
    }

    function quoteSwap(
        address pool,
        bool zeroForOne,
        int128 amountSpecified,
        uint128 priceLimitX64,
        uint128 bidPriceX64,
        uint128 askPriceX64
    ) external returns (int128 amount0Delta, int128 amount1Delta) {
        if (revertQuote) revert QuoteFailed();

        ++quoteCalls;
        lastPool = pool;
        lastZeroForOne = zeroForOne;
        lastAmountSpecified = amountSpecified;
        lastPriceLimitX64 = priceLimitX64;
        lastBidPriceX64 = bidPriceX64;
        lastAskPriceX64 = askPriceX64;

        return (quoteAmount0Delta, quoteAmount1Delta);
    }

    function swapExactInput(
        address pool,
        address recipient,
        bool zeroForOne,
        uint128 amountIn,
        uint128 priceLimitX64,
        uint256 amountOutMin,
        uint256 deadline
    ) external payable returns (uint256 amountOut, uint256 amountInUsed) {
        if (revertSwap) revert SwapFailed();

        lastPool = pool;
        lastRecipient = recipient;
        lastZeroForOne = zeroForOne;
        lastAmountIn = amountIn;
        lastPriceLimitX64 = priceLimitX64;
        lastAmountOutMin = amountOutMin;
        lastDeadline = deadline;

        MetricPoolImmutables memory poolImmutables = IMetricLegacyPool(pool).getImmutables();
        IERC20 inputToken = IERC20(zeroForOne ? poolImmutables.token0 : poolImmutables.token1);
        IERC20 outputToken = IERC20(zeroForOne ? poolImmutables.token1 : poolImmutables.token0);

        inputToken.safeTransferFrom(msg.sender, address(this), swapPullAmount);
        outputToken.safeTransfer(recipient, swapTransferAmount);

        return (swapAmountOut, swapAmountInUsed);
    }
}

contract MockMalformedMetricPool {
    fallback() external {
        assembly ("memory-safe") {
            mstore(0, 1)
            return(0, 32)
        }
    }
}
