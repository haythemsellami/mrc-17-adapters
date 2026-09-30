// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { MRC17Adapter } from "../base/MRC17Adapter.sol";
import { IPropAMMRouter } from "../interfaces/IPropAMMRouter.sol";

/// @notice Immutable configuration returned by a legacy Metric OMM pool.
struct MetricPoolImmutables {
    address factory;
    address priceProvider;
    address token0;
    address token1;
    uint104 a;
    uint104 b;
    uint104 c;
    bool reportSwapToPriceProvider;
    uint256 maxDriftE8;
    uint256 maxDriftDecayPerSecondE8;
    int16 lowestBin;
    int16 highestBin;
    uint256 token0ScaleMultiplier;
    uint256 token1ScaleMultiplier;
}

/// @notice Minimal interface for a legacy Metric OMM pool.
interface IMetricLegacyPool {
    /// @notice Returns the pool's immutable configuration.
    /// @return poolImmutables The immutable pool configuration.
    function getImmutables() external view returns (MetricPoolImmutables memory poolImmutables);
}

/// @notice Minimal interface for a legacy Metric price provider.
interface IMetricLegacyPriceProvider {
    /// @notice Returns the current oracle bid and ask prices in Q64.64 format.
    /// @return bidPriceX64 The current bid price.
    /// @return askPriceX64 The current ask price.
    function getBidAndAskPrice() external view returns (uint128 bidPriceX64, uint128 askPriceX64);
}

/// @notice Minimal interface for the legacy Metric OMM swap router.
interface IMetricLegacyRouter {
    /// @notice Simulates an exact-input swap and returns its signed token deltas.
    /// @param pool The Metric pool to quote.
    /// @param zeroForOne True to swap token0 for token1; false to swap token1 for token0.
    /// @param amountSpecified The positive exact input amount.
    /// @param priceLimitX64 The terminal Q64.64 price limit.
    /// @param bidPriceX64 The oracle bid price.
    /// @param askPriceX64 The oracle ask price.
    /// @return amount0Delta The pool's signed token0 delta.
    /// @return amount1Delta The pool's signed token1 delta.
    function quoteSwap(
        address pool,
        bool zeroForOne,
        int128 amountSpecified,
        uint128 priceLimitX64,
        uint128 bidPriceX64,
        uint128 askPriceX64
    ) external returns (int128 amount0Delta, int128 amount1Delta);

    /// @notice Executes an exact-input swap.
    /// @param pool The Metric pool to trade against.
    /// @param recipient The address that receives the output token.
    /// @param zeroForOne True to swap token0 for token1; false to swap token1 for token0.
    /// @param amountIn The exact input amount.
    /// @param priceLimitX64 The terminal Q64.64 price limit.
    /// @param amountOutMin The minimum acceptable output amount.
    /// @param deadline The latest timestamp at which execution may succeed.
    /// @return amountOut The output amount delivered by the router.
    /// @return amountInUsed The input amount consumed by the router.
    function swapExactInput(
        address pool,
        address recipient,
        bool zeroForOne,
        uint128 amountIn,
        uint128 priceLimitX64,
        uint256 amountOutMin,
        uint256 deadline
    ) external payable returns (uint256 amountOut, uint256 amountInUsed);
}

/// @title Metric legacy MRC-17 adapter
/// @notice Adapts one legacy Metric OMM pool to the MRC-17 exact-input interface.
contract MetricAdapter is MRC17Adapter {
    using SafeERC20 for IERC20;

    uint128 private constant _MIN_PRICE_LIMIT_X64 = 1;
    uint128 private constant _MAX_PRICE_LIMIT_X64 = type(uint128).max;
    uint256 private constant _MAX_QUOTE_AMOUNT = uint256(uint128(type(int128).max));

    /// @notice The legacy Metric OMM swap router.
    address public immutable router;

    /// @notice The Metric OMM pool adapted by this contract.
    address public immutable pool;

    /// @notice The pool's oracle price provider.
    address public immutable priceProvider;

    error InvalidPool();
    error InvalidPriceProvider();
    error InvalidQuote();
    error InvalidRouter();
    error InvalidSwapResult();
    error QuoteAmountOverflow();
    error SwapAmountOverflow();
    error UnexpectedQuoteData();
    error UnexpectedSwapData();

    /// @notice Initializes an adapter for one legacy Metric OMM pool.
    /// @param router_ The legacy Metric OMM swap router.
    /// @param pool_ The Metric OMM pool to adapt.
    constructor(address router_, address pool_)
        MRC17Adapter(_readPoolToken(pool_, true), _readPoolToken(pool_, false))
    {
        if (router_.code.length == 0) {
            revert InvalidRouter();
        }

        MetricPoolImmutables memory poolImmutables = _readPoolImmutables(pool_);
        if (poolImmutables.token0 != _token0 || poolImmutables.token1 != _token1) revert InvalidPool();
        if (poolImmutables.priceProvider.code.length == 0) revert InvalidPriceProvider();

        router = router_;
        pool = pool_;
        priceProvider = poolImmutables.priceProvider;
    }

    /// @inheritdoc IPropAMMRouter
    function getAmountOut(address tokenIn, address tokenOut, uint256 amountIn, bytes calldata quoteData)
        external
        override
        returns (uint256 amountOut, bytes memory swapData)
    {
        bool zeroForOne = _direction(tokenIn, tokenOut);
        if (quoteData.length != 0) revert UnexpectedQuoteData();
        if (amountIn > _MAX_QUOTE_AMOUNT) revert QuoteAmountOverflow();

        (uint128 bidPriceX64, uint128 askPriceX64) = IMetricLegacyPriceProvider(priceProvider).getBidAndAskPrice();
        (int128 amount0Delta, int128 amount1Delta) = IMetricLegacyRouter(router)
            .quoteSwap(pool, zeroForOne, int128(uint128(amountIn)), _priceLimit(zeroForOne), bidPriceX64, askPriceX64);

        int128 inputDelta = zeroForOne ? amount0Delta : amount1Delta;
        int128 outputDelta = zeroForOne ? amount1Delta : amount0Delta;
        if (inputDelta != int128(uint128(amountIn)) || outputDelta >= 0) revert InvalidQuote();

        amountOut = uint256(-int256(outputDelta));
        swapData = new bytes(0);
    }

    /// @inheritdoc MRC17Adapter
    function _executeSwap(
        bool zeroForOne,
        uint256 amountIn,
        uint256 amountOutMin,
        address to,
        uint256 deadline,
        bytes calldata swapData
    ) internal override returns (uint256 amountOut) {
        if (swapData.length != 0) revert UnexpectedSwapData();
        if (amountIn > _MAX_QUOTE_AMOUNT) revert SwapAmountOverflow();

        IERC20 inputToken = IERC20(zeroForOne ? _token0 : _token1);
        inputToken.forceApprove(router, amountIn);

        uint256 amountInUsed;
        (amountOut, amountInUsed) = IMetricLegacyRouter(router)
            .swapExactInput(pool, to, zeroForOne, uint128(amountIn), _priceLimit(zeroForOne), amountOutMin, deadline);

        inputToken.forceApprove(router, 0);
        if (amountInUsed != amountIn || amountOut == 0) revert InvalidSwapResult();
    }

    /// @dev Returns the directional legacy Metric price-limit sentinel.
    /// @param zeroForOne True to use the lower sentinel; false to use the upper sentinel.
    /// @return priceLimitX64 The Q64.64 price-limit sentinel.
    function _priceLimit(bool zeroForOne) private pure returns (uint128 priceLimitX64) {
        return zeroForOne ? _MIN_PRICE_LIMIT_X64 : _MAX_PRICE_LIMIT_X64;
    }

    /// @dev Reads one canonical token from a Metric pool during construction.
    /// @param pool_ The Metric pool to inspect.
    /// @param readToken0 True to read _token0; false to read _token1.
    /// @return token The requested token address.
    function _readPoolToken(address pool_, bool readToken0) private view returns (address token) {
        MetricPoolImmutables memory poolImmutables = _readPoolImmutables(pool_);
        return readToken0 ? poolImmutables.token0 : poolImmutables.token1;
    }

    /// @dev Reads and validates the complete immutable configuration returned by a Metric pool.
    /// @param pool_ The Metric pool to inspect.
    /// @return poolImmutables The decoded immutable pool configuration.
    function _readPoolImmutables(address pool_) private view returns (MetricPoolImmutables memory poolImmutables) {
        if (pool_.code.length == 0) revert InvalidPool();

        (bool success, bytes memory returnData) = pool_.staticcall(abi.encodeCall(IMetricLegacyPool.getImmutables, ()));
        if (!success || returnData.length != 14 * 32) revert InvalidPool();

        poolImmutables = abi.decode(returnData, (MetricPoolImmutables));
    }
}
