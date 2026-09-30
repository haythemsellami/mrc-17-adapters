// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { MRC17Adapter } from "../base/MRC17Adapter.sol";

/// @notice Minimal LFJ POE pool interface required for swap execution.
interface IPoePool {
    /// @notice Returns the pool's immutable token ordering.
    /// @return tokenX The pool's first token.
    /// @return tokenY The pool's second token.
    function getTokens() external view returns (address tokenX, address tokenY);

    /// @notice Executes a swap and settles its positive input delta through the caller's callback.
    /// @param recipient The address that receives the output token.
    /// @param swapXToY True to swap token X for token Y; false for the reverse direction.
    /// @param amountIn The requested exact input amount.
    /// @param data Opaque data forwarded to the caller's callback.
    /// @return deltaX The pool's signed token-X delta.
    /// @return deltaY The pool's signed token-Y delta.
    function swap(address recipient, bool swapXToY, uint256 amountIn, bytes calldata data)
        external
        returns (int256 deltaX, int256 deltaY);
}

/// @title LFJ POE MRC-17 adapter
/// @notice Adapts one fixed LFJ POE pool to exact-input MRC-17 quoting and execution.
contract PoeAdapter is MRC17Adapter {
    using SafeERC20 for IERC20;

    bytes4 private constant _GET_QUOTE_SELECTOR = bytes4(keccak256("getQuote(bool,uint256)"));

    /// @notice The LFJ POE pool served by this adapter.
    address public immutable pool;

    uint256 private _callbackAmount;
    bool private _callbackDirection;
    bool private _callbackCompleted;

    error CallbackNotCompleted();
    error InvalidCallback();
    error InvalidPool();
    error InvalidQuote();
    error UnexpectedData();

    /// @notice Initializes an adapter for one LFJ POE pool.
    /// @param pool_ The pool whose token ordering, quote, swap, and callback semantics are adapted.
    constructor(address pool_) MRC17Adapter(_readToken(pool_, true), _readToken(pool_, false)) {
        if (pool_.code.length == 0) revert InvalidPool();
        pool = pool_;
    }

    /// @notice Returns the full-fill output quoted by the POE pool.
    /// @dev The pool quote is executed through `STATICCALL`; partial input quotes are rejected.
    /// @param tokenIn The requested input token.
    /// @param tokenOut The requested output token.
    /// @param amountIn The exact input amount to quote.
    /// @param quoteData Venue-specific quote data, which must be empty for POE.
    /// @return amountOut The pool's quoted output amount.
    /// @return swapData Empty execution data because the POE swap needs no quote-derived plan.
    function getAmountOut(address tokenIn, address tokenOut, uint256 amountIn, bytes calldata quoteData)
        external
        view
        override
        returns (uint256 amountOut, bytes memory swapData)
    {
        bool zeroForOne = _direction(tokenIn, tokenOut);
        if (quoteData.length != 0) revert UnexpectedData();

        (bool success, bytes memory result) =
            pool.staticcall(abi.encodeWithSelector(_GET_QUOTE_SELECTOR, zeroForOne, amountIn));
        if (!success) _bubbleRevert(result);
        if (result.length < 64) revert InvalidQuote();

        uint256 actualAmountIn;
        assembly ("memory-safe") {
            amountOut := mload(add(result, 0x20))
            actualAmountIn := mload(add(result, 0x40))
        }
        if (amountOut == 0 || actualAmountIn != amountIn) revert InvalidQuote();
        swapData = bytes("");
    }

    /// @notice Pays the pool's authenticated positive input delta during an active swap.
    /// @param deltaX The pool's signed token-X delta.
    /// @param deltaY The pool's signed token-Y delta.
    /// @param data The ABI-encoded input-token address supplied by this adapter.
    /// @return selector The callback selector expected by the pool.
    function swapCallback(int256 deltaX, int256 deltaY, bytes calldata data) external returns (bytes4 selector) {
        if (msg.sender != pool || _callbackAmount == 0 || _callbackCompleted || data.length != 32) {
            revert InvalidCallback();
        }

        IERC20 expectedToken = IERC20(_callbackDirection ? _token0 : _token1);
        if (abi.decode(data, (address)) != address(expectedToken)) revert InvalidCallback();

        int256 inputDelta = _callbackDirection ? deltaX : deltaY;
        int256 outputDelta = _callbackDirection ? deltaY : deltaX;
        if (inputDelta <= 0 || uint256(inputDelta) != _callbackAmount || outputDelta >= 0) {
            revert InvalidCallback();
        }

        _callbackCompleted = true;
        _callbackAmount = 0;
        expectedToken.safeTransfer(pool, uint256(inputDelta));
        selector = this.swapCallback.selector;
    }

    /// @inheritdoc MRC17Adapter
    function _executeSwap(bool zeroForOne, uint256 amountIn, uint256, address to, uint256, bytes calldata swapData)
        internal
        override
        returns (uint256 amountOut)
    {
        if (swapData.length != 0) revert UnexpectedData();

        _callbackAmount = amountIn;
        _callbackDirection = zeroForOne;
        _callbackCompleted = false;

        (int256 deltaX, int256 deltaY) =
            IPoePool(pool).swap(to, zeroForOne, amountIn, abi.encode(zeroForOne ? _token0 : _token1));
        if (!_callbackCompleted || _callbackAmount != 0) revert CallbackNotCompleted();

        int256 inputDelta = zeroForOne ? deltaX : deltaY;
        int256 outputDelta = zeroForOne ? deltaY : deltaX;
        if (inputDelta <= 0 || uint256(inputDelta) != amountIn || outputDelta >= 0) revert InvalidCallback();

        unchecked {
            amountOut = uint256(-(outputDelta + 1)) + 1;
        }
        if (amountOut == 0) revert InvalidQuote();
    }

    /// @dev Reads one token from the pool while validating that the pool is a deployed contract.
    /// @param pool_ The LFJ POE pool.
    /// @param first True to return token X; false to return token Y.
    /// @return token The selected pool token.
    function _readToken(address pool_, bool first) private view returns (address token) {
        if (pool_.code.length == 0) revert InvalidPool();
        (address tokenX, address tokenY) = IPoePool(pool_).getTokens();
        token = first ? tokenX : tokenY;
    }

    /// @dev Reverts with the exact returndata produced by a failed pool quote.
    /// @param reason The revert data returned by the pool.
    function _bubbleRevert(bytes memory reason) private pure {
        assembly ("memory-safe") {
            revert(add(reason, 0x20), mload(reason))
        }
    }
}
