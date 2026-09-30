// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Callback surface used by the mock LFJ POE pool.
interface IMockPoeSwapCallback {
    function swapCallback(int256 deltaX, int256 deltaY, bytes calldata data) external returns (bytes4 selector);
}

/// @notice Configurable LFJ POE pool mock for adapter quote and callback-settlement tests.
contract MockPoePool {
    using SafeERC20 for IERC20;

    enum ExecutionMode {
        Normal,
        SkipCallback,
        WrongInputDelta,
        WrongOutputDelta,
        WrongCallbackData
    }

    address public immutable tokenX;
    address public immutable tokenY;
    uint256 public immutable numerator;
    uint256 public immutable denominator;

    bool public partialQuote;
    ExecutionMode public executionMode;

    constructor(address tokenX_, address tokenY_, uint256 numerator_, uint256 denominator_) {
        tokenX = tokenX_;
        tokenY = tokenY_;
        numerator = numerator_;
        denominator = denominator_;
    }

    function setPartialQuote(bool partialQuote_) external {
        partialQuote = partialQuote_;
    }

    function setExecutionMode(ExecutionMode executionMode_) external {
        executionMode = executionMode_;
    }

    function getTokens() external view returns (address, address) {
        return (tokenX, tokenY);
    }

    function getQuote(bool, uint256 amountIn)
        external
        view
        returns (uint256 amountOut, uint256 actualAmountIn, uint256 feeIn, uint256 feeOut)
    {
        amountOut = amountIn * numerator / denominator;
        actualAmountIn = partialQuote ? amountIn - 1 : amountIn;
        feeIn = 0;
        feeOut = 0;
    }

    function swap(address recipient, bool swapXToY, uint256 amountIn, bytes calldata data)
        external
        returns (int256 deltaX, int256 deltaY)
    {
        uint256 amountOut = amountIn * numerator / denominator;
        IERC20 outputToken = IERC20(swapXToY ? tokenY : tokenX);
        outputToken.safeTransfer(recipient, amountOut);

        deltaX = swapXToY ? int256(amountIn) : -int256(amountOut);
        deltaY = swapXToY ? -int256(amountOut) : int256(amountIn);

        ExecutionMode mode = executionMode;
        if (mode == ExecutionMode.SkipCallback) return (deltaX, deltaY);
        if (mode == ExecutionMode.WrongInputDelta) {
            if (swapXToY) {
                deltaX += 1;
            } else {
                deltaY += 1;
            }
        } else if (mode == ExecutionMode.WrongOutputDelta) {
            if (swapXToY) {
                deltaY = 1;
            } else {
                deltaX = 1;
            }
        }

        bytes memory callbackData = data;
        if (mode == ExecutionMode.WrongCallbackData) {
            callbackData = abi.encode(address(outputToken));
        }

        bytes4 response = IMockPoeSwapCallback(msg.sender).swapCallback(deltaX, deltaY, callbackData);
        require(response == IMockPoeSwapCallback.swapCallback.selector, "CALLBACK");
    }
}
