// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { MRC17Adapter } from "../base/MRC17Adapter.sol";

/// @notice Minimal ThogAMM maker interface required for discovery, quoting, and execution.
interface IThogAMM {
    /// @notice Returns every ERC-7815 pool identifier currently exposed by the venue.
    function getPoolIds() external view returns (bytes32[] memory poolIds);

    /// @notice Returns the tokens currently registered in one pool.
    function getTokens(bytes32 poolId) external view returns (address[] memory tokens);

    /// @notice Quotes an inventory-backed exact-input maker swap.
    /// @return amountOut The executable output amount.
    /// @return lastPostedBlock The block at which the maker prices used by the quote were posted.
    function makerQuoteExactInput(address tokenIn, address tokenOut, uint256 amountIn)
        external
        view
        returns (uint256 amountOut, uint256 lastPostedBlock);

    /// @notice Executes an exact-input maker swap and sends output directly to the recipient.
    /// @param deadlineBlock The latest block at which execution may succeed.
    /// @return amountOut The output amount reported by the venue.
    function makerSwapExactInput(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        address recipient,
        uint256 deadlineBlock
    ) external returns (uint256 amountOut);
}

/// @title ThogAMM MRC-17 adapter
/// @notice Adapts one fixed token pair from ThogAMM's rotating multi-token pool to exact-input MRC-17 routing.
contract ThogAdapter is MRC17Adapter {
    using SafeERC20 for IERC20;

    /// @notice The ThogAMM proxy used for discovery, quoting, and execution.
    address public immutable venue;

    error IncompleteInputConsumption();
    error InvalidPoolConfiguration();
    error InvalidQuote();
    error InvalidSwapResult();
    error InvalidVenue();
    error ResidualAllowance();
    error UnexpectedData();

    /// @notice Initializes an adapter for one pair in ThogAMM's single ERC-7815 pool.
    /// @dev Pool IDs are intentionally validated but not stored because the venue rotates its sole pool ID.
    /// @param venue_ The ThogAMM proxy.
    /// @param token0_ The first token in the adapter's canonical pair ordering.
    /// @param token1_ The second token in the adapter's canonical pair ordering.
    constructor(address venue_, address token0_, address token1_) MRC17Adapter(token0_, token1_) {
        if (venue_.code.length == 0) revert InvalidVenue();

        bytes32[] memory poolIds = _readPoolIds(venue_);
        if (poolIds.length != 1) revert InvalidPoolConfiguration();

        address[] memory tokens = _readTokens(venue_, poolIds[0]);

        bool containsToken0;
        bool containsToken1;
        for (uint256 i; i < tokens.length; ++i) {
            if (tokens[i] == address(0)) revert InvalidPoolConfiguration();
            for (uint256 j; j < i; ++j) {
                if (tokens[j] == tokens[i]) revert InvalidPoolConfiguration();
            }
            containsToken0 = containsToken0 || tokens[i] == token0_;
            containsToken1 = containsToken1 || tokens[i] == token1_;
        }
        if (!containsToken0 || !containsToken1) revert InvalidPoolConfiguration();

        venue = venue_;
    }

    /// @notice Returns ThogAMM's executable full-fill quote for the fixed adapter pair.
    /// @param tokenIn The requested input token.
    /// @param tokenOut The requested output token.
    /// @param amountIn The exact input amount to quote.
    /// @param quoteData Venue-specific quote data, which must be empty for ThogAMM.
    /// @return amountOut The venue's quoted output amount.
    /// @return swapData Empty execution data because execution uses the current maker state.
    function getAmountOut(address tokenIn, address tokenOut, uint256 amountIn, bytes calldata quoteData)
        external
        view
        override
        returns (uint256 amountOut, bytes memory swapData)
    {
        _direction(tokenIn, tokenOut);
        if (quoteData.length != 0) revert UnexpectedData();

        uint256 lastPostedBlock;
        (amountOut, lastPostedBlock) = IThogAMM(venue).makerQuoteExactInput(tokenIn, tokenOut, amountIn);
        if (amountOut == 0 || lastPostedBlock == 0 || lastPostedBlock > block.number) revert InvalidQuote();

        swapData = bytes("");
    }

    /// @inheritdoc MRC17Adapter
    function _executeSwap(
        bool zeroForOne,
        uint256 amountIn,
        uint256 amountOutMin,
        address to,
        uint256,
        bytes calldata swapData
    ) internal override returns (uint256 amountOut) {
        if (swapData.length != 0) revert UnexpectedData();

        IERC20 inputToken = IERC20(zeroForOne ? _token0 : _token1);
        address outputToken = zeroForOne ? _token1 : _token0;
        uint256 inputBalanceBefore = inputToken.balanceOf(address(this));

        inputToken.forceApprove(venue, amountIn);
        amountOut = IThogAMM(venue)
            .makerSwapExactInput(address(inputToken), outputToken, amountIn, amountOutMin, to, block.number);
        inputToken.forceApprove(venue, 0);
        if (inputToken.allowance(address(this), venue) != 0) revert ResidualAllowance();

        uint256 inputBalanceAfter = inputToken.balanceOf(address(this));
        if (inputBalanceAfter > inputBalanceBefore || inputBalanceBefore - inputBalanceAfter != amountIn) {
            revert IncompleteInputConsumption();
        }
        if (amountOut == 0) revert InvalidSwapResult();
    }

    /// @dev Reads the venue's dynamic pool-ID array with strict ABI-shape validation.
    function _readPoolIds(address venue_) private view returns (bytes32[] memory poolIds) {
        (bool success, bytes memory returnData) = venue_.staticcall(abi.encodeCall(IThogAMM.getPoolIds, ()));
        if (!success || !_isValidWordArray(returnData, false)) revert InvalidVenue();
        return abi.decode(returnData, (bytes32[]));
    }

    /// @dev Reads one dynamic token array with strict ABI-shape and canonical-address validation.
    function _readTokens(address venue_, bytes32 poolId) private view returns (address[] memory tokens) {
        (bool success, bytes memory returnData) = venue_.staticcall(abi.encodeCall(IThogAMM.getTokens, (poolId)));
        if (!success || !_isValidWordArray(returnData, true)) revert InvalidPoolConfiguration();
        return abi.decode(returnData, (address[]));
    }

    /// @dev Validates the canonical ABI encoding of one returned dynamic array of 32-byte words.
    function _isValidWordArray(bytes memory returnData, bool addressElements) private pure returns (bool valid) {
        if (returnData.length < 64) return false;

        uint256 offset;
        uint256 arrayLength;
        assembly ("memory-safe") {
            offset := mload(add(returnData, 0x20))
            arrayLength := mload(add(returnData, 0x40))
        }
        if (offset != 32 || arrayLength > (returnData.length - 64) / 32) return false;
        if (returnData.length != 64 + arrayLength * 32) return false;

        if (addressElements) {
            for (uint256 i; i < arrayLength; ++i) {
                uint256 word;
                assembly ("memory-safe") {
                    word := mload(add(add(returnData, 0x60), mul(i, 0x20)))
                }
                if (word >> 160 != 0) return false;
            }
        }
        return true;
    }
}
