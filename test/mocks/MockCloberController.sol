// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { ICloberBookManager, ICloberController } from "../../src/adapters/CloberAdapter.sol";

contract MockCloberController is ICloberController {
    using SafeERC20 for IERC20;

    address public immutable override bookManager;

    mapping(uint192 id => uint256 rateNumerator) public numerator;
    mapping(uint192 id => uint256 rateDenominator) public denominator;
    uint256 public spendBps = 10_000;

    constructor(address bookManager_) {
        bookManager = bookManager_;
    }

    receive() external payable { }

    function setRate(uint192 id, uint256 numerator_, uint256 denominator_) external {
        require(denominator_ != 0, "DENOMINATOR");
        numerator[id] = numerator_;
        denominator[id] = denominator_;
    }

    function setSpendBps(uint256 spendBps_) external {
        require(spendBps_ <= 10_000, "SPEND_BPS");
        spendBps = spendBps_;
    }

    function spend(
        SpendOrderParams[] calldata orderParamsList,
        address[] calldata,
        ERC20PermitParams[] calldata,
        uint64 deadline
    ) external payable {
        require(block.timestamp <= deadline, "DEADLINE");
        require(orderParamsList.length == 1, "ORDERS");

        SpendOrderParams calldata params = orderParamsList[0];
        ICloberBookManager.BookKey memory key = ICloberBookManager(bookManager).getBookKey(params.id);
        uint256 spentBaseAmount = params.baseAmount * spendBps / 10_000;
        uint256 amountOut = spentBaseAmount * numerator[params.id] / denominator[params.id];
        require(amountOut >= params.minQuoteAmount, "MIN_OUTPUT");

        if (key.base == address(0)) {
            require(msg.value == params.baseAmount, "VALUE");
            uint256 refund = params.baseAmount - spentBaseAmount;
            if (refund != 0) {
                (bool success,) = msg.sender.call{ value: refund }("");
                require(success, "NATIVE_REFUND");
            }
        } else {
            require(msg.value == 0, "VALUE");
            IERC20(key.base).safeTransferFrom(msg.sender, address(this), spentBaseAmount);
        }

        if (key.quote == address(0)) {
            (bool success,) = msg.sender.call{ value: amountOut }("");
            require(success, "NATIVE_TRANSFER");
        } else {
            IERC20(key.quote).safeTransfer(msg.sender, amountOut);
        }
    }
}
