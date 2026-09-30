// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { MRC17Adapter } from "../base/MRC17Adapter.sol";
import { IPropAMMRouter } from "../interfaces/IPropAMMRouter.sol";

/// @notice Current configuration returned by a Hanji central-limit-order-book market.
struct HanjiMarketConfig {
    uint256 scalingFactorTokenX;
    uint256 scalingFactorTokenY;
    address tokenX;
    address tokenY;
    bool supportsNativeEth;
    bool isTokenXWeth;
    address askTrie;
    address bidTrie;
    uint64 adminCommissionRate;
    uint64 totalAggressiveCommissionRate;
    uint64 totalPassiveCommissionRate;
    uint64 passiveOrderPayoutRate;
    bool shouldInvokeOnTrade;
}

/// @notice Minimal Hanji market interface required for configuration and execution.
interface IHanjiMarket {
    /// @notice Returns the market's current token, scaling, native-settlement, and commission configuration.
    /// @return config The current market configuration.
    function getConfig() external view returns (HanjiMarketConfig memory config);

    /// @notice Places a market-only order for an exact number of token-X shares.
    /// @param isAsk True to sell token X for token Y.
    /// @param quantity The number of token-X shares to execute.
    /// @param price The permissive terminal price bound.
    /// @param maxCommission The maximum commission accepted by the caller.
    /// @param marketOnly True to prevent an unfilled remainder from resting on the book.
    /// @param postOnly Whether execution against existing liquidity is forbidden.
    /// @param transferExecutedTokens Whether proceeds are transferred to the caller.
    /// @param expires The order expiry timestamp.
    /// @return orderId The Hanji order identifier.
    /// @return executedShares The executed token-X shares.
    /// @return executedValue The executed token-Y value before aggressive fees.
    /// @return aggressiveFee The aggressive fee charged in token-Y value units.
    function placeOrder(
        bool isAsk,
        uint128 quantity,
        uint72 price,
        uint128 maxCommission,
        bool marketOnly,
        bool postOnly,
        bool transferExecutedTokens,
        uint256 expires
    ) external payable returns (uint64 orderId, uint128 executedShares, uint128 executedValue, uint128 aggressiveFee);

    /// @notice Places a market-only order with an exact token-Y target value.
    /// @param isAsk False to buy token X with token Y.
    /// @param targetTokenYValue The token-Y target inclusive of aggressive fees.
    /// @param price The permissive terminal price bound.
    /// @param maxCommission The maximum commission accepted by the caller.
    /// @param transferExecutedTokens Whether proceeds are transferred to the caller.
    /// @param expires The order expiry timestamp.
    /// @return executedShares The executed token-X shares.
    /// @return executedValue The executed token-Y value before aggressive fees.
    /// @return aggressiveFee The aggressive fee charged in token-Y value units.
    function placeMarketOrderWithTargetValue(
        bool isAsk,
        uint128 targetTokenYValue,
        uint72 price,
        uint128 maxCommission,
        bool transferExecutedTokens,
        uint256 expires
    ) external payable returns (uint128 executedShares, uint128 executedValue, uint128 aggressiveFee);
}

/// @notice Minimal Hanji fast-quoter helper interface.
interface IHanjiFastQuoterHelper {
    /// @notice Assembles the currently visible virtual bid and ask ladders for one market.
    /// @param market The Hanji market to inspect.
    /// @param maxPriceLevels The maximum number of price levels returned per side.
    /// @return bidPrices The bid prices in token-Y value units per token-X share.
    /// @return bidShares The token-X shares visible at each bid price.
    /// @return askPrices The ask prices in token-Y value units per token-X share.
    /// @return askShares The token-X shares visible at each ask price.
    function assembleOrderbooksFromOrders(address market, uint24 maxPriceLevels)
        external
        view
        returns (
            uint72[] memory bidPrices,
            uint128[] memory bidShares,
            uint72[] memory askPrices,
            uint128[] memory askShares
        );
}

/// @notice Wrapped-native-token interface used to normalize Hanji native output.
interface IHanjiWrappedNative {
    /// @notice Wraps the native currency sent with the call.
    function deposit() external payable;
}

/// @title Hanji routing adapter
/// @notice Provides a simulation-gated Monoper integration for one Hanji order-book market.
/// @dev Quotes reject helper-visible partial fills and token-Y targets that leave predictable residual input. Because
///      the helper ladder is not always an executable preview, integrations must simulate the complete router call.
///      Every successful execution still satisfies MRC-17 exact-input settlement.
contract HanjiAdapter is MRC17Adapter {
    using SafeERC20 for IERC20;

    uint256 private constant _COMMISSION_SCALE = 1e18;
    uint72 private constant _MIN_PRICE = 1;
    uint72 private constant _MAX_PRICE = 999_999_000_000_000_000_000;

    /// @notice The Hanji market served by this adapter.
    address public immutable market;

    /// @notice The Hanji helper used to read the virtual order-book ladder.
    address public immutable helper;

    /// @notice The wrapped native token used to normalize native market output.
    address public immutable wrappedNative;

    /// @notice The maximum number of helper price levels considered on each side.
    uint24 public immutable maxPriceLevels;

    /// @notice The token-X base-unit amount represented by one Hanji share.
    uint256 public immutable scalingFactorTokenX;

    /// @notice The token-Y base-unit amount represented by one Hanji value unit.
    uint256 public immutable scalingFactorTokenY;

    /// @notice Whether the configured market supports native-currency settlement.
    bool public immutable supportsNativeEth;

    /// @notice Whether token X is the configured wrapped-native side.
    bool public immutable isTokenXWrappedNative;

    error IncompleteInputConsumption();
    error InsufficientHelperDepth();
    error InvalidConfiguration();
    error InvalidExecution();
    error InvalidQuote();
    error InvalidShareAmount();
    error NativeBalanceMismatch();
    error QuoteAmountOverflow();
    error UnexpectedData();
    error UnexpectedNativeTransfer();

    /// @notice Configures one Hanji market and captures its canonical token and scaling configuration.
    /// @param market_ The Hanji market proxy.
    /// @param helper_ The Hanji fast-quoter helper.
    /// @param maxPriceLevels_ The maximum helper price levels to inspect per side.
    constructor(address market_, address helper_, uint24 maxPriceLevels_)
        MRC17Adapter(_readMarketToken(market_, true), _readMarketToken(market_, false))
    {
        if (helper_.code.length == 0 || maxPriceLevels_ == 0 || market_.code.length == 0) {
            revert InvalidConfiguration();
        }

        HanjiMarketConfig memory config = _readMarketConfig(market_);
        address wrappedNative_ =
            config.supportsNativeEth ? (config.isTokenXWeth ? config.tokenX : config.tokenY) : address(0);
        _validateConfig(config, wrappedNative_);

        market = market_;
        helper = helper_;
        wrappedNative = wrappedNative_;
        maxPriceLevels = maxPriceLevels_;
        scalingFactorTokenX = config.scalingFactorTokenX;
        scalingFactorTokenY = config.scalingFactorTokenY;
        supportsNativeEth = config.supportsNativeEth;
        isTokenXWrappedNative = config.isTokenXWeth;
    }

    /// @notice Receives native output from the configured Hanji market.
    /// @dev Native transfers from every other caller are rejected.
    receive() external payable {
        if (!supportsNativeEth || msg.sender != market) revert UnexpectedNativeTransfer();
    }

    /// @inheritdoc IPropAMMRouter
    function getAmountOut(address tokenIn, address tokenOut, uint256 amountIn, bytes calldata quoteData)
        external
        view
        override
        returns (uint256 amountOut, bytes memory swapData)
    {
        bool zeroForOne = _direction(tokenIn, tokenOut);
        if (quoteData.length != 0) revert UnexpectedData();

        uint256 feeRate = _validateCurrentConfig();
        (uint72[] memory bidPrices, uint128[] memory bidShares, uint72[] memory askPrices, uint128[] memory askShares) =
            IHanjiFastQuoterHelper(helper).assembleOrderbooksFromOrders(market, maxPriceLevels);

        if (bidPrices.length != bidShares.length || askPrices.length != askShares.length) {
            revert InvalidQuote();
        }

        amountOut = zeroForOne
            ? _quoteTokenXForTokenY(amountIn, feeRate, bidPrices, bidShares)
            : _quoteTokenYForTokenX(amountIn, feeRate, askPrices, askShares);
        swapData = bytes("");
    }

    /// @inheritdoc MRC17Adapter
    function _executeSwap(
        bool zeroForOne,
        uint256 amountIn,
        uint256,
        address to,
        uint256 deadline,
        bytes calldata swapData
    ) internal override returns (uint256 amountOut) {
        if (swapData.length != 0) revert UnexpectedData();
        _validateCurrentConfig();

        IERC20 inputToken = IERC20(zeroForOne ? _token0 : _token1);
        IERC20 outputToken = IERC20(zeroForOne ? _token1 : _token0);
        uint256 inputBalanceBefore = inputToken.balanceOf(address(this));
        uint256 outputBalanceBefore = outputToken.balanceOf(address(this));
        uint256 nativeBalanceBefore = address(this).balance;

        inputToken.forceApprove(market, amountIn);
        if (zeroForOne) {
            IHanjiMarket(market)
                .placeOrder(true, _tokenXShares(amountIn), _MIN_PRICE, type(uint128).max, true, false, true, deadline);
        } else {
            IHanjiMarket(market)
                .placeMarketOrderWithTargetValue(
                    false, _tokenYTarget(amountIn), _MAX_PRICE, type(uint128).max, true, deadline
                );
        }
        inputToken.forceApprove(market, 0);

        _wrapNativeDelta(nativeBalanceBefore, address(outputToken));

        uint256 inputBalanceAfter = inputToken.balanceOf(address(this));
        if (inputBalanceAfter > inputBalanceBefore || inputBalanceBefore - inputBalanceAfter != amountIn) {
            revert IncompleteInputConsumption();
        }

        uint256 outputBalanceAfter = outputToken.balanceOf(address(this));
        if (outputBalanceAfter <= outputBalanceBefore) revert InvalidExecution();
        amountOut = outputBalanceAfter - outputBalanceBefore;
        _deliver(outputToken, to, amountOut);
    }

    /// @dev Quotes a whole-share token-X sale against all required visible bid depth.
    /// @param amountIn The exact token-X input amount.
    /// @param feeRate The current aggressive fee and passive payout rate.
    /// @param prices The helper-visible bid prices.
    /// @param shares The helper-visible shares at each bid price.
    /// @return amountOut The net token-Y base units expected from the helper ladder.
    function _quoteTokenXForTokenY(uint256 amountIn, uint256 feeRate, uint72[] memory prices, uint128[] memory shares)
        private
        view
        returns (uint256 amountOut)
    {
        uint256 requestedShares = _tokenXShares(amountIn);
        uint256 remainingShares = requestedShares;
        uint256 grossValue;

        for (uint256 i; i < prices.length && remainingShares != 0; ++i) {
            if (prices[i] == 0) revert InvalidQuote();
            uint256 availableShares = shares[i];
            uint256 takenShares = remainingShares < availableShares ? remainingShares : availableShares;
            grossValue += takenShares * uint256(prices[i]);
            remainingShares -= takenShares;
        }

        if (remainingShares != 0) revert InsufficientHelperDepth();
        uint256 fee = _fee(grossValue, feeRate);
        if (grossValue <= fee) revert InvalidQuote();
        amountOut = (grossValue - fee) * scalingFactorTokenY;
        if (amountOut == 0) revert InvalidQuote();
    }

    /// @dev Quotes a token-Y target only when the helper walk consumes the target exactly, including its ceiling fee.
    /// @param amountIn The exact token-Y input amount.
    /// @param feeRate The current aggressive fee and passive payout rate.
    /// @param prices The helper-visible ask prices.
    /// @param shares The helper-visible shares at each ask price.
    /// @return amountOut The token-X base units expected from the helper ladder.
    function _quoteTokenYForTokenX(uint256 amountIn, uint256 feeRate, uint72[] memory prices, uint128[] memory shares)
        private
        view
        returns (uint256 amountOut)
    {
        uint256 targetValue = _tokenYTarget(amountIn);
        uint256 grossBudget = Math.mulDiv(targetValue, _COMMISSION_SCALE, _COMMISSION_SCALE + feeRate);
        uint256 remainingBudget = grossBudget;
        uint256 executedShares;
        uint256 grossValue;

        for (uint256 i; i < prices.length && remainingBudget != 0; ++i) {
            uint256 price = prices[i];
            if (price == 0) revert InvalidQuote();
            uint256 affordableShares = remainingBudget / price;
            uint256 availableShares = shares[i];
            uint256 takenShares = affordableShares < availableShares ? affordableShares : availableShares;
            executedShares += takenShares;
            uint256 levelValue = takenShares * price;
            grossValue += levelValue;
            remainingBudget -= levelValue;
            if (takenShares < availableShares) break;
        }

        if (executedShares == 0 || executedShares > type(uint128).max) revert InvalidQuote();
        if (grossValue + _fee(grossValue, feeRate) != targetValue) revert InvalidQuote();

        amountOut = executedShares * scalingFactorTokenX;
        if (amountOut == 0) revert InvalidQuote();
    }

    /// @dev Returns the token-X share count represented by an exact ERC-20 amount.
    /// @param amount The token-X base-unit amount.
    /// @return shares The exact Hanji share count.
    function _tokenXShares(uint256 amount) private view returns (uint128 shares) {
        if (amount % scalingFactorTokenX != 0) revert InvalidShareAmount();
        uint256 shareCount = amount / scalingFactorTokenX;
        if (shareCount == 0 || shareCount > type(uint128).max) revert QuoteAmountOverflow();
        // forge-lint: disable-next-line(unsafe-typecast)
        shares = uint128(shareCount);
    }

    /// @dev Returns the token-Y target represented by an exact ERC-20 amount.
    /// @param amount The token-Y base-unit amount.
    /// @return target The exact Hanji target-value quantity.
    function _tokenYTarget(uint256 amount) private view returns (uint128 target) {
        if (amount % scalingFactorTokenY != 0) revert InvalidShareAmount();
        uint256 targetValue = amount / scalingFactorTokenY;
        if (targetValue == 0 || targetValue > type(uint128).max) revert QuoteAmountOverflow();
        // forge-lint: disable-next-line(unsafe-typecast)
        target = uint128(targetValue);
    }

    /// @dev Returns the ceiling-rounded aggressive fee for a gross token-Y value.
    /// @param grossValue The gross token-Y value before fees.
    /// @param feeRate The current commission rate scaled by 1e18.
    /// @return fee The ceiling-rounded fee in token-Y value units.
    function _fee(uint256 grossValue, uint256 feeRate) private pure returns (uint256 fee) {
        fee = Math.mulDiv(grossValue, feeRate, _COMMISSION_SCALE, Math.Rounding.Ceil);
    }

    /// @dev Verifies that mutable market configuration remains compatible with this adapter.
    /// @return feeRate The current aggressive fee plus the passive-order payout rate.
    function _validateCurrentConfig() private view returns (uint256 feeRate) {
        HanjiMarketConfig memory config = _readMarketConfig(market);
        _validateConfig(config, wrappedNative);
        if (
            config.tokenX != _token0 || config.tokenY != _token1 || config.scalingFactorTokenX != scalingFactorTokenX
                || config.scalingFactorTokenY != scalingFactorTokenY || config.supportsNativeEth != supportsNativeEth
                || config.isTokenXWeth != isTokenXWrappedNative
        ) {
            revert InvalidConfiguration();
        }

        feeRate = uint256(config.totalAggressiveCommissionRate) + uint256(config.passiveOrderPayoutRate);
        if (feeRate >= _COMMISSION_SCALE) revert InvalidConfiguration();
    }

    /// @dev Wraps only the native balance increase produced by the active market call.
    /// @param nativeBalanceBefore The adapter's native balance before market execution.
    /// @param outputToken The ERC-20 output token expected from the active swap direction.
    function _wrapNativeDelta(uint256 nativeBalanceBefore, address outputToken) private {
        uint256 nativeBalanceAfter = address(this).balance;
        if (nativeBalanceAfter < nativeBalanceBefore) revert NativeBalanceMismatch();
        uint256 nativeDelta = nativeBalanceAfter - nativeBalanceBefore;
        if (nativeDelta == 0) return;
        if (!supportsNativeEth || outputToken != wrappedNative) revert InvalidExecution();
        IHanjiWrappedNative(wrappedNative).deposit{ value: nativeDelta }();
    }

    /// @dev Reads one canonical market token during construction.
    /// @param market_ The Hanji market to inspect.
    /// @param readTokenX True to read token X; false to read token Y.
    /// @return token The requested market token.
    function _readMarketToken(address market_, bool readTokenX) private view returns (address token) {
        HanjiMarketConfig memory config = _readMarketConfig(market_);
        token = readTokenX ? config.tokenX : config.tokenY;
    }

    /// @dev Reads the complete current market configuration.
    /// @param market_ The Hanji market to inspect.
    /// @return config The decoded market configuration.
    function _readMarketConfig(address market_) private view returns (HanjiMarketConfig memory config) {
        if (market_.code.length == 0) revert InvalidConfiguration();

        (bool success, bytes memory returnData) = market_.staticcall(abi.encodeCall(IHanjiMarket.getConfig, ()));
        if (!success || returnData.length != 13 * 32) revert InvalidConfiguration();
        config = abi.decode(returnData, (HanjiMarketConfig));
    }

    /// @dev Validates invariant fields required by the adapter's quote and settlement model.
    /// @param config The Hanji market configuration to validate.
    /// @param wrappedNative_ The configured wrapped-native-token address.
    function _validateConfig(HanjiMarketConfig memory config, address wrappedNative_) private view {
        if (config.scalingFactorTokenX == 0 || config.scalingFactorTokenY == 0) {
            revert InvalidConfiguration();
        }
        if (
            config.supportsNativeEth
                && (wrappedNative_ == address(0)
                    || (config.isTokenXWeth ? config.tokenX : config.tokenY) != wrappedNative_
                    || wrappedNative_.code.length == 0)
        ) {
            revert InvalidConfiguration();
        }
    }
}
