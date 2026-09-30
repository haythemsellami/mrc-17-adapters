// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title Proprietary AMM Routing Interface
/// @dev A contract may serve one or more markets.
///      `tokenIn` and `tokenOut` specify the requested assets and direction.
interface IPropAMMRouter {
    /// @notice Emitted after a successful swap.
    /// @param sender The caller that funded the swap.
    /// @param to The recipient credited with the output token.
    /// @param tokenIn The input token transferred from `sender`.
    /// @param tokenOut The output token credited to `to`.
    /// @param amountIn The exact input amount pulled from `sender`.
    /// @param amountOut The actual output amount credited to `to`.
    event PropAMMSwap(
        address indexed sender,
        address to,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut
    );

    /// @notice Quotes an exact input swap.
    /// @param tokenIn The ERC-20 input token.
    /// @param tokenOut The ERC-20 output token.
    /// @param amountIn The exact input amount in base units of `tokenIn`.
    /// @param quoteData Opaque venue specific quote input, may be empty.
    /// @return amountOut The expected output amount in base units of `tokenOut`.
    /// @return swapData Opaque venue specific data to supply to `swap`, may be empty.
    /// @dev This function is intentionally non-view. Routers that integrate
    ///      with `IPropAMMRouter` must execute it in a call frame whose state
    ///      changes are reverted.
    function getAmountOut(address tokenIn, address tokenOut, uint256 amountIn, bytes calldata quoteData)
        external
        returns (uint256 amountOut, bytes memory swapData);

    /// @notice Executes an exact input swap.
    /// @dev Before calling, `msg.sender` must grant this contract an ERC-20
    ///      allowance of at least `amountIn` for `tokenIn`. The contract
    ///      pulls exactly `amountIn` of `tokenIn` during this call and credits
    ///      the actual output in `tokenOut` to `to` before returning.
    /// @param tokenIn The ERC-20 input token.
    /// @param tokenOut The ERC-20 output token.
    /// @param to The recipient of the output token.
    /// @param amountIn The exact amount of `tokenIn` pulled from `msg.sender`.
    /// @param amountOutMin The minimum amount of `tokenOut` credited to `to`.
    /// @param deadline The timestamp after which the swap must revert.
    /// @param swapData Opaque venue specific execution data, may be empty.
    /// @return amountOut The actual amount of `tokenOut` credited to `to`.
    function swap(
        address tokenIn,
        address tokenOut,
        address to,
        uint256 amountIn,
        uint256 amountOutMin,
        uint256 deadline,
        bytes calldata swapData
    ) external returns (uint256 amountOut);
}
