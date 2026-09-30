// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { ICloberBookManager, ICloberBookViewer, ICloberWrappedNative } from "../../src/adapters/CloberAdapter.sol";
import { MockERC20 } from "./MockERC20.sol";

contract MockWrappedNative is MockERC20, ICloberWrappedNative {
    constructor() MockERC20("Wrapped Native", "WNATIVE", 18) { }

    receive() external payable {
        deposit();
    }

    function deposit() public payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool success,) = msg.sender.call{ value: amount }("");
        require(success, "NATIVE_TRANSFER");
    }
}

contract MockCloberBookManager is ICloberBookManager {
    mapping(uint192 id => BookKey key) private _bookKeys;

    function setBook(uint192 id, address base, address quote, uint64 unitSize) external {
        _bookKeys[id] = BookKey({
            base: base, unitSize: unitSize, quote: quote, makerPolicy: 0, hooks: address(0), takerPolicy: 0
        });
    }

    function getBookKey(uint192 id) external view returns (BookKey memory key) {
        key = _bookKeys[id];
    }
}

contract MockCloberBookViewer is ICloberBookViewer {
    address public immutable override bookManager;

    mapping(uint192 id => uint256 rateNumerator) public numerator;
    mapping(uint192 id => uint256 rateDenominator) public denominator;
    bool public partialFill;

    constructor(address bookManager_) {
        bookManager = bookManager_;
    }

    function setRate(uint192 id, uint256 numerator_, uint256 denominator_) external {
        require(denominator_ != 0, "DENOMINATOR");
        numerator[id] = numerator_;
        denominator[id] = denominator_;
    }

    function setPartialFill(bool partialFill_) external {
        partialFill = partialFill_;
    }

    function getExpectedOutput(SpendOrderParams calldata params)
        external
        view
        returns (uint256 takenQuoteAmount, uint256 spentBaseAmount)
    {
        spentBaseAmount = partialFill ? params.baseAmount - 1 : params.baseAmount;
        takenQuoteAmount = spentBaseAmount * numerator[params.id] / denominator[params.id];
    }
}
