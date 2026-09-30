// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { MRC17Adapter } from "../base/MRC17Adapter.sol";
import { IPropAMMRouter } from "../interfaces/IPropAMMRouter.sol";

/// @notice Wrapped-native-token interface used by Clober native-currency books.
interface ICloberWrappedNative {
    /// @notice Wraps the native currency sent with the call.
    function deposit() external payable;

    /// @notice Burns wrapped tokens and sends the corresponding native currency to the caller.
    /// @param amount The wrapped-native-token amount to unwrap.
    function withdraw(uint256 amount) external;
}

/// @notice Read interface for Clober V2 book configuration.
interface ICloberBookManager {
    /// @notice Immutable configuration of a Clober order book.
    /// @param base The base currency, or the zero address for native MON.
    /// @param unitSize The book's base-token unit size.
    /// @param quote The quote currency, or the zero address for native MON.
    /// @param makerPolicy The maker fee policy identifier.
    /// @param hooks The optional hooks contract.
    /// @param takerPolicy The taker fee policy identifier.
    struct BookKey {
        address base;
        uint64 unitSize;
        address quote;
        uint24 makerPolicy;
        address hooks;
        uint24 takerPolicy;
    }

    /// @notice Returns the configuration for a book identifier.
    /// @param id The Clober book identifier.
    /// @return key The book configuration.
    function getBookKey(uint192 id) external view returns (BookKey memory key);
}

/// @notice Quote interface for the Clober V2 book viewer.
interface ICloberBookViewer {
    /// @notice Parameters for simulating a market spend order.
    /// @param id The Clober book identifier.
    /// @param limitPrice The price limit, where zero selects no limit.
    /// @param baseAmount The exact base-currency amount offered.
    /// @param minQuoteAmount The minimum quote-currency amount required.
    /// @param hookData Opaque data forwarded to book hooks.
    struct SpendOrderParams {
        uint192 id;
        uint256 limitPrice;
        uint256 baseAmount;
        uint256 minQuoteAmount;
        bytes hookData;
    }

    /// @notice Returns the book manager associated with this viewer.
    /// @return The book manager address.
    function bookManager() external view returns (address);

    /// @notice Simulates a spend order against current book liquidity.
    /// @param params The order parameters to quote.
    /// @return takenQuoteAmount The expected quote-currency output.
    /// @return spentBaseAmount The base-currency amount the book can consume.
    function getExpectedOutput(SpendOrderParams calldata params)
        external
        view
        returns (uint256 takenQuoteAmount, uint256 spentBaseAmount);
}

/// @notice Execution interface for the Clober V2 controller.
interface ICloberController {
    /// @notice Parameters for one executable market spend order.
    /// @param id The Clober book identifier.
    /// @param limitPrice The price limit, where zero selects no limit.
    /// @param baseAmount The exact base-currency amount offered.
    /// @param minQuoteAmount The minimum quote-currency amount required.
    /// @param hookData Opaque data forwarded to book hooks.
    struct SpendOrderParams {
        uint192 id;
        uint256 limitPrice;
        uint256 baseAmount;
        uint256 minQuoteAmount;
        bytes hookData;
    }

    /// @notice EIP-2612 signature fields accepted by the controller.
    /// @param deadline The permit expiry.
    /// @param v The recovery identifier.
    /// @param r The first signature word.
    /// @param s The second signature word.
    struct PermitSignature {
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    /// @notice Optional ERC-20 permit data accepted by the controller.
    /// @param token The permitted token.
    /// @param permitAmount The permitted amount.
    /// @param signature The permit signature.
    struct ERC20PermitParams {
        address token;
        uint256 permitAmount;
        PermitSignature signature;
    }

    /// @notice Returns the book manager associated with this controller.
    /// @return The book manager address.
    function bookManager() external view returns (address);

    /// @notice Executes one or more spend orders and settles their currencies.
    /// @param orderParamsList The spend orders to execute.
    /// @param tokensToSettle The non-native currencies that must be settled.
    /// @param permitParamsList Optional ERC-20 permits.
    /// @param deadline The controller deadline.
    function spend(
        SpendOrderParams[] calldata orderParamsList,
        address[] calldata tokensToSettle,
        ERC20PermitParams[] calldata permitParamsList,
        uint64 deadline
    ) external payable;
}

/// @title Clober V2 MRC-17 adapter
/// @notice Routes exact-input swaps through a mirrored pair of Clober V2 order books.
/// @dev Native MON books are exposed as wrapped-native-token pairs to MRC-17 callers.
contract CloberAdapter is MRC17Adapter {
    using SafeERC20 for IERC20;

    /// @notice Clober book manager used to validate the configured books.
    address public immutable bookManager;

    /// @notice Clober viewer used to quote spend orders.
    address public immutable bookViewer;

    /// @notice Clober controller used to execute spend orders.
    address public immutable controller;

    /// @notice Wrapped-native-token contract used to normalize native MON books.
    address public immutable wrappedNative;

    /// @notice Clober currency corresponding to `_token0`, or zero for native MON.
    address public immutable currency0;

    /// @notice Clober currency corresponding to `_token1`, or zero for native MON.
    address public immutable currency1;

    /// @notice Book used when spending `_token0` for `_token1`.
    uint192 public immutable bookId0For1;

    /// @notice Book used when spending `_token1` for `_token0`.
    uint192 public immutable bookId1For0;

    /// @notice The venue cannot consume the complete exact input.
    error IncompleteFill();

    /// @notice The configured books do not form the requested mirrored token pair.
    error InvalidBook();

    /// @notice A dependency or book identifier is invalid or inconsistent.
    error InvalidConfiguration();

    /// @notice Venue execution did not produce a positive, internally settled output.
    error InvalidExecution();

    /// @notice Venue quoting produced a zero or otherwise invalid result.
    error InvalidQuote();

    /// @notice Native settlement reduced a balance that should have been preserved.
    error NativeBalanceMismatch();

    /// @notice Clober does not use opaque MRC-17 quote or swap data.
    error UnexpectedData();

    /// @notice An unauthorized account attempted to send native MON to the adapter.
    error UnexpectedNativeTransfer();

    /// @notice Configures one normalized token pair and its two directional Clober books.
    /// @param bookManager_ The Clober book manager.
    /// @param bookViewer_ The Clober quote viewer.
    /// @param controller_ The Clober execution controller.
    /// @param wrappedNative_ The wrapped native MON token.
    /// @param token0_ The adapter's canonical first ERC-20 token.
    /// @param token1_ The adapter's canonical second ERC-20 token.
    /// @param bookId0For1_ The book that spends `token0_` for `token1_`.
    /// @param bookId1For0_ The book that spends `token1_` for `token0_`.
    constructor(
        address bookManager_,
        address bookViewer_,
        address controller_,
        address wrappedNative_,
        address token0_,
        address token1_,
        uint192 bookId0For1_,
        uint192 bookId1For0_
    ) MRC17Adapter(token0_, token1_) {
        if (
            bookManager_.code.length == 0 || bookViewer_.code.length == 0 || controller_.code.length == 0
                || wrappedNative_.code.length == 0 || bookId0For1_ == 0 || bookId1For0_ == 0
                || bookId0For1_ == bookId1For0_
        ) {
            revert InvalidConfiguration();
        }
        if (
            ICloberBookViewer(bookViewer_).bookManager() != bookManager_
                || ICloberController(controller_).bookManager() != bookManager_
        ) {
            revert InvalidConfiguration();
        }

        ICloberBookManager.BookKey memory zeroForOne = ICloberBookManager(bookManager_).getBookKey(bookId0For1_);
        ICloberBookManager.BookKey memory oneForZero = ICloberBookManager(bookManager_).getBookKey(bookId1For0_);
        if (
            oneForZero.base != zeroForOne.quote || oneForZero.quote != zeroForOne.base
                || _normalize(zeroForOne.base, wrappedNative_) != token0_
                || _normalize(zeroForOne.quote, wrappedNative_) != token1_
                || _normalize(oneForZero.base, wrappedNative_) != token1_
                || _normalize(oneForZero.quote, wrappedNative_) != token0_
        ) {
            revert InvalidBook();
        }

        bookManager = bookManager_;
        bookViewer = bookViewer_;
        controller = controller_;
        wrappedNative = wrappedNative_;
        currency0 = zeroForOne.base;
        currency1 = zeroForOne.quote;
        bookId0For1 = bookId0For1_;
        bookId1For0 = bookId1For0_;
    }

    /// @notice Receives native MON released during authorized Clober settlement.
    /// @dev Only the configured manager, controller, or wrapped-native-token contract may send value.
    receive() external payable {
        if (msg.sender != bookManager && msg.sender != controller && msg.sender != wrappedNative) {
            revert UnexpectedNativeTransfer();
        }
    }

    /// @inheritdoc IPropAMMRouter
    function getAmountOut(address tokenIn, address tokenOut, uint256 amountIn, bytes calldata quoteData)
        external
        view
        override
        returns (uint256 amountOut, bytes memory swapData)
    {
        bool token0ForToken1 = _direction(tokenIn, tokenOut);
        if (quoteData.length != 0) revert UnexpectedData();

        ICloberBookViewer.SpendOrderParams memory params = ICloberBookViewer.SpendOrderParams({
            id: token0ForToken1 ? bookId0For1 : bookId1For0,
            limitPrice: 0,
            baseAmount: amountIn,
            minQuoteAmount: 0,
            hookData: bytes("")
        });
        uint256 spentBaseAmount;
        (amountOut, spentBaseAmount) = ICloberBookViewer(bookViewer).getExpectedOutput(params);
        if (amountOut == 0) revert InvalidQuote();
        if (spentBaseAmount != amountIn) revert IncompleteFill();
        swapData = bytes("");
    }

    /// @inheritdoc MRC17Adapter
    function _executeSwap(
        bool token0ForToken1,
        uint256 amountIn,
        uint256 amountOutMin,
        address to,
        uint256 deadline,
        bytes calldata swapData
    ) internal override returns (uint256 amountOut) {
        if (swapData.length != 0) revert UnexpectedData();

        IERC20 inputToken = IERC20(token0ForToken1 ? _token0 : _token1);
        IERC20 outputToken = IERC20(token0ForToken1 ? _token1 : _token0);
        address inputCurrency = token0ForToken1 ? currency0 : currency1;
        address outputCurrency = token0ForToken1 ? currency1 : currency0;
        uint192 bookId = token0ForToken1 ? bookId0For1 : bookId1For0;
        uint256 inputBalanceBefore = inputToken.balanceOf(address(this));
        uint256 outputBalanceBefore = outputToken.balanceOf(address(this));
        uint256 nativeBalanceBefore = address(this).balance;
        uint256 callValue;

        if (inputCurrency == address(0)) {
            ICloberWrappedNative(wrappedNative).withdraw(amountIn);
            callValue = amountIn;
        } else {
            inputToken.forceApprove(controller, amountIn);
        }

        ICloberController.SpendOrderParams[] memory params = new ICloberController.SpendOrderParams[](1);
        params[0] = ICloberController.SpendOrderParams({
            id: bookId, limitPrice: 0, baseAmount: amountIn, minQuoteAmount: amountOutMin, hookData: bytes("")
        });
        address[] memory tokensToSettle = _tokensToSettle(inputCurrency, outputCurrency);
        ICloberController.ERC20PermitParams[] memory permits = new ICloberController.ERC20PermitParams[](0);
        uint64 controllerDeadline = deadline > type(uint64).max ? type(uint64).max : uint64(deadline);

        ICloberController(controller).spend{ value: callValue }(params, tokensToSettle, permits, controllerDeadline);
        if (inputCurrency != address(0)) inputToken.forceApprove(controller, 0);

        _wrapNativeDelta(nativeBalanceBefore);
        uint256 inputBalanceAfter = inputToken.balanceOf(address(this));
        if (inputBalanceAfter > inputBalanceBefore || inputBalanceBefore - inputBalanceAfter != amountIn) {
            revert IncompleteFill();
        }
        uint256 outputBalanceAfter = outputToken.balanceOf(address(this));
        if (outputBalanceAfter < outputBalanceBefore) revert InvalidExecution();
        amountOut = outputBalanceAfter - outputBalanceBefore;
        if (amountOut == 0) revert InvalidExecution();
        _deliver(outputToken, to, amountOut);
    }

    /// @dev Builds the non-native currency list required by Clober settlement.
    /// @param inputCurrency The raw Clober input currency.
    /// @param outputCurrency The raw Clober output currency.
    /// @return tokens The non-native currencies to settle.
    function _tokensToSettle(address inputCurrency, address outputCurrency)
        private
        pure
        returns (address[] memory tokens)
    {
        uint256 count = (inputCurrency == address(0) ? 0 : 1) + (outputCurrency == address(0) ? 0 : 1);
        tokens = new address[](count);
        uint256 index;
        if (inputCurrency != address(0)) tokens[index++] = inputCurrency;
        if (outputCurrency != address(0)) tokens[index] = outputCurrency;
    }

    /// @dev Wraps native MON received from Clober without consuming any pre-existing native balance.
    /// @param nativeBalanceBefore The adapter's native balance before venue execution.
    function _wrapNativeDelta(uint256 nativeBalanceBefore) private {
        uint256 nativeBalanceAfter = address(this).balance;
        if (nativeBalanceAfter < nativeBalanceBefore) revert NativeBalanceMismatch();
        uint256 nativeDelta = nativeBalanceAfter - nativeBalanceBefore;
        if (nativeDelta != 0) ICloberWrappedNative(wrappedNative).deposit{ value: nativeDelta }();
    }

    /// @dev Maps Clober's native-currency sentinel to the wrapped-native-token address.
    /// @param currency The raw Clober currency address.
    /// @param wrappedNative_ The wrapped native token.
    /// @return normalized The ERC-20 representation exposed by this adapter.
    function _normalize(address currency, address wrappedNative_) private pure returns (address normalized) {
        normalized = currency == address(0) ? wrappedNative_ : currency;
    }
}
