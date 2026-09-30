// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import { IPropAMMRouter } from "../interfaces/IPropAMMRouter.sol";

/// @title MRC-17 adapter base
/// @notice Enforces exact-input token flow and recipient output accounting for MRC-17 venue adapters.
abstract contract MRC17Adapter is IPropAMMRouter, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /// @dev Fixed-market assets used only by the venue implementation.
    address internal immutable _token0;

    address internal immutable _token1;

    error DeadlineExpired();
    error InvalidAmountIn();
    error InvalidRecipient();
    error InvalidTokenPair();
    error InputTransferMismatch(uint256 expected, uint256 received);
    error OutputBalanceMismatch();
    error SlippageExceeded();

    /// @notice Initializes an adapter for one fixed ERC-20 pair.
    /// @param token0_ The first token in the adapter's canonical pair ordering.
    /// @param token1_ The second token in the adapter's canonical pair ordering.
    constructor(address token0_, address token1_) {
        if (
            token0_ == address(0) || token1_ == address(0) || token0_ == token1_ || token0_.code.length == 0
                || token1_.code.length == 0
        ) {
            revert InvalidTokenPair();
        }

        _token0 = token0_;
        _token1 = token1_;
    }

    /// @inheritdoc IPropAMMRouter
    function swap(
        address tokenIn,
        address tokenOut,
        address to,
        uint256 amountIn,
        uint256 amountOutMin,
        uint256 deadline,
        bytes calldata swapData
    ) external override nonReentrant returns (uint256 amountOut) {
        if (to == address(0)) revert InvalidRecipient();
        if (amountIn == 0) revert InvalidAmountIn();
        if (block.timestamp > deadline) revert DeadlineExpired();

        bool zeroForOne = _direction(tokenIn, tokenOut);
        IERC20 inputToken = IERC20(tokenIn);
        IERC20 outputToken = IERC20(tokenOut);
        uint256 recipientBalanceBefore = outputToken.balanceOf(to);
        uint256 inputBalanceBefore = inputToken.balanceOf(address(this));

        inputToken.safeTransferFrom(msg.sender, address(this), amountIn);
        uint256 inputBalanceAfter = inputToken.balanceOf(address(this));
        uint256 received = inputBalanceAfter >= inputBalanceBefore ? inputBalanceAfter - inputBalanceBefore : 0;
        if (received != amountIn) revert InputTransferMismatch(amountIn, received);

        uint256 expectedAmountOut = _executeSwap(zeroForOne, amountIn, amountOutMin, to, deadline, swapData);
        if (expectedAmountOut < amountOutMin) revert SlippageExceeded();

        uint256 recipientBalanceAfter = outputToken.balanceOf(to);
        amountOut = recipientBalanceAfter - recipientBalanceBefore;
        if (amountOut != expectedAmountOut) revert OutputBalanceMismatch();

        emit PropAMMSwap(msg.sender, to, tokenIn, tokenOut, amountIn, amountOut);
    }

    /// @dev Validates the requested assets and translates them to the venue's internal ordering.
    function _direction(address tokenIn, address tokenOut) internal view returns (bool) {
        if (tokenIn == _token0 && tokenOut == _token1) return true;
        if (tokenIn == _token1 && tokenOut == _token0) return false;
        revert InvalidTokenPair();
    }

    /// @dev Executes the venue-specific swap after the base has received the exact input amount.
    /// @param zeroForOne True to swap _token0 for _token1; false to swap _token1 for _token0.
    /// @param amountIn The exact input amount held by this adapter.
    /// @param amountOutMin The minimum output amount required by the caller.
    /// @param to The address that must receive the output tokens.
    /// @param deadline The latest timestamp at which execution may succeed.
    /// @param swapData Opaque venue-specific execution data returned by the quote.
    /// @return amountOut The output amount the venue delivered to `to`.
    function _executeSwap(
        bool zeroForOne,
        uint256 amountIn,
        uint256 amountOutMin,
        address to,
        uint256 deadline,
        bytes calldata swapData
    ) internal virtual returns (uint256 amountOut);

    /// @dev Transfers output held by the adapter.
    /// @param outputToken The ERC-20 output token.
    /// @param to The output recipient.
    /// @param amount The output amount to deliver.
    function _deliver(IERC20 outputToken, address to, uint256 amount) internal {
        outputToken.safeTransfer(to, amount);
    }
}
