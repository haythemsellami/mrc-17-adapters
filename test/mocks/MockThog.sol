// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IThogAMM } from "../../src/adapters/ThogAdapter.sol";

/// @notice Configurable ThogAMM mock for discovery, quote, and exact-settlement adapter tests.
contract MockThog is IThogAMM {
    using SafeERC20 for IERC20;

    bytes32[] private _poolIds;
    mapping(bytes32 poolId => address[] tokens) private _tokens;

    struct Quote {
        uint256 expectedAmountIn;
        uint256 amountOut;
        uint256 lastPostedBlock;
    }

    mapping(address tokenIn => mapping(address tokenOut => Quote quote)) private _quotes;
    uint256 public swapAmountOut;
    uint256 public swapPullAmount;
    uint256 public swapTransferAmount;
    bool public revertPoolIds;
    bool public revertTokens;
    bool public revertQuote;
    bool public revertSwap;

    address public lastTokenIn;
    address public lastTokenOut;
    uint256 public lastAmountIn;
    uint256 public lastAmountOutMin;
    address public lastRecipient;
    uint256 public lastDeadlineBlock;
    uint256 public observedAllowance;

    error PoolIdsFailed();
    error QuoteFailed();
    error SwapFailed();
    error TokensFailed();
    error UnexpectedQuoteParameters();

    constructor(bytes32 poolId_, address[] memory tokens_) {
        _poolIds.push(poolId_);
        _tokens[poolId_] = tokens_;
    }

    function setPoolIds(bytes32[] calldata poolIds_) external {
        delete _poolIds;
        for (uint256 i; i < poolIds_.length; ++i) {
            _poolIds.push(poolIds_[i]);
        }
    }

    function setTokens(bytes32 poolId, address[] calldata tokens_) external {
        delete _tokens[poolId];
        for (uint256 i; i < tokens_.length; ++i) {
            _tokens[poolId].push(tokens_[i]);
        }
    }

    function configureQuote(
        address tokenIn,
        address tokenOut,
        uint256 expectedAmountIn,
        uint256 amountOut,
        uint256 lastPostedBlock
    ) external {
        _quotes[tokenIn][tokenOut] = Quote(expectedAmountIn, amountOut, lastPostedBlock);
    }

    function configureSwap(uint256 amountOut_, uint256 pullAmount_, uint256 transferAmount_) external {
        swapAmountOut = amountOut_;
        swapPullAmount = pullAmount_;
        swapTransferAmount = transferAmount_;
    }

    function setFailureModes(bool poolIds_, bool tokens_, bool quote_, bool swap_) external {
        revertPoolIds = poolIds_;
        revertTokens = tokens_;
        revertQuote = quote_;
        revertSwap = swap_;
    }

    function getPoolIds() external view returns (bytes32[] memory poolIds) {
        if (revertPoolIds) revert PoolIdsFailed();
        return _poolIds;
    }

    function getTokens(bytes32 poolId) external view returns (address[] memory tokens) {
        if (revertTokens) revert TokensFailed();
        return _tokens[poolId];
    }

    function makerQuoteExactInput(address tokenIn, address tokenOut, uint256 amountIn)
        external
        view
        returns (uint256 amountOut, uint256 lastPostedBlock)
    {
        if (revertQuote) revert QuoteFailed();
        Quote memory quote = _quotes[tokenIn][tokenOut];
        if (quote.expectedAmountIn != amountIn) revert UnexpectedQuoteParameters();
        return (quote.amountOut, quote.lastPostedBlock);
    }

    function makerSwapExactInput(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        address recipient,
        uint256 deadlineBlock
    ) external returns (uint256 amountOut) {
        if (revertSwap) revert SwapFailed();

        lastTokenIn = tokenIn;
        lastTokenOut = tokenOut;
        lastAmountIn = amountIn;
        lastAmountOutMin = amountOutMin;
        lastRecipient = recipient;
        lastDeadlineBlock = deadlineBlock;
        observedAllowance = IERC20(tokenIn).allowance(msg.sender, address(this));

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), swapPullAmount);
        IERC20(tokenOut).safeTransfer(recipient, swapTransferAmount);
        return swapAmountOut;
    }
}

/// @notice Contract with the ThogAMM discovery selectors but malformed dynamic-array return data.
contract MockMalformedThog {
    fallback() external {
        assembly ("memory-safe") {
            mstore(0, 1)
            return(0, 32)
        }
    }
}

/// @notice Contract with valid pool discovery but malformed token-array return data.
contract MockMalformedThogTokens {
    bytes32 private immutable _poolId;

    constructor(bytes32 poolId_) {
        _poolId = poolId_;
    }

    function getPoolIds() external view returns (bytes32[] memory poolIds) {
        poolIds = new bytes32[](1);
        poolIds[0] = _poolId;
    }

    fallback() external {
        assembly ("memory-safe") {
            mstore(0, 1)
            return(0, 32)
        }
    }
}

/// @notice Contract that returns a correctly shaped token array with a noncanonical address word.
contract MockNonCanonicalThogTokens {
    bytes32 private immutable _poolId;

    constructor(bytes32 poolId_) {
        _poolId = poolId_;
    }

    function getPoolIds() external view returns (bytes32[] memory poolIds) {
        poolIds = new bytes32[](1);
        poolIds[0] = _poolId;
    }

    fallback() external {
        assembly ("memory-safe") {
            mstore(0, 0x20)
            mstore(0x20, 1)
            mstore(0x40, shl(160, 1))
            return(0, 0x60)
        }
    }
}
