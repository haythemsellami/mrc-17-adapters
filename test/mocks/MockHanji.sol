// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { MockERC20 } from "./MockERC20.sol";

contract MockHanjiWrappedNative is MockERC20 {
    constructor() MockERC20("Wrapped Monad", "WMON", 18) { }

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

contract MockHanjiFastQuoter {
    address public expectedMarket;

    uint72[] private _bidPrices;
    uint128[] private _bidShares;
    uint72[] private _askPrices;
    uint128[] private _askShares;

    constructor(address expectedMarket_) {
        expectedMarket = expectedMarket_;
    }

    function setExpectedMarket(address expectedMarket_) external {
        expectedMarket = expectedMarket_;
    }

    function setOrderbook(
        uint72[] calldata bidPrices_,
        uint128[] calldata bidShares_,
        uint72[] calldata askPrices_,
        uint128[] calldata askShares_
    ) external {
        require(bidPrices_.length == bidShares_.length, "BID_LENGTH");
        require(askPrices_.length == askShares_.length, "ASK_LENGTH");

        _bidPrices = bidPrices_;
        _bidShares = bidShares_;
        _askPrices = askPrices_;
        _askShares = askShares_;
    }

    function assembleOrderbooksFromOrders(address market, uint24 maxPriceLevels)
        external
        view
        returns (
            uint72[] memory bidPrices,
            uint128[] memory bidShares,
            uint72[] memory askPrices,
            uint128[] memory askShares
        )
    {
        require(market == expectedMarket, "MARKET");

        uint256 bidLength = _bidPrices.length < maxPriceLevels ? _bidPrices.length : maxPriceLevels;
        uint256 askLength = _askPrices.length < maxPriceLevels ? _askPrices.length : maxPriceLevels;
        bidPrices = new uint72[](bidLength);
        bidShares = new uint128[](bidLength);
        askPrices = new uint72[](askLength);
        askShares = new uint128[](askLength);

        for (uint256 i; i < bidLength; ++i) {
            bidPrices[i] = _bidPrices[i];
            bidShares[i] = _bidShares[i];
        }
        for (uint256 i; i < askLength; ++i) {
            askPrices[i] = _askPrices[i];
            askShares[i] = _askShares[i];
        }
    }
}

contract MockHanjiMarket {
    using SafeERC20 for IERC20;

    struct Execution {
        uint128 shares;
        uint128 value;
        uint128 fee;
        uint256 inputSpent;
        uint256 outputTransferred;
    }

    uint256 public scalingFactorTokenX;
    uint256 public scalingFactorTokenY;
    address public tokenX;
    address public tokenY;
    bool public supportsNativeEth;
    bool public isTokenXWeth;
    uint64 public adminCommissionRate;
    uint64 public totalAggressiveCommissionRate;
    uint64 public totalPassiveCommissionRate;
    uint64 public passiveOrderPayoutRate;
    bool public shouldInvokeOnTrade;

    Execution public sellExecution;
    Execution public buyExecution;
    bool public deliverBuyOutputAsNative;

    bool public lastIsAsk;
    uint128 public lastQuantity;
    uint72 public lastPrice;
    uint128 public lastMaxCommission;
    bool public lastMarketOnly;
    bool public lastPostOnly;
    bool public lastTransferExecutedTokens;
    uint256 public lastExpires;
    uint128 public lastTargetTokenYValue;

    constructor(address tokenX_, address tokenY_, uint256 scalingFactorTokenX_, uint256 scalingFactorTokenY_) {
        tokenX = tokenX_;
        tokenY = tokenY_;
        scalingFactorTokenX = scalingFactorTokenX_;
        scalingFactorTokenY = scalingFactorTokenY_;
        supportsNativeEth = true;
        isTokenXWeth = true;
        totalAggressiveCommissionRate = 1e14;
    }

    receive() external payable { }

    function setTokens(address tokenX_, address tokenY_) external {
        tokenX = tokenX_;
        tokenY = tokenY_;
    }

    function setScalingFactors(uint256 scalingFactorTokenX_, uint256 scalingFactorTokenY_) external {
        scalingFactorTokenX = scalingFactorTokenX_;
        scalingFactorTokenY = scalingFactorTokenY_;
    }

    function setNativeConfiguration(bool supportsNativeEth_, bool isTokenXWeth_) external {
        supportsNativeEth = supportsNativeEth_;
        isTokenXWeth = isTokenXWeth_;
    }

    function setFeeConfiguration(
        uint64 adminCommissionRate_,
        uint64 totalAggressiveCommissionRate_,
        uint64 totalPassiveCommissionRate_,
        uint64 passiveOrderPayoutRate_
    ) external {
        adminCommissionRate = adminCommissionRate_;
        totalAggressiveCommissionRate = totalAggressiveCommissionRate_;
        totalPassiveCommissionRate = totalPassiveCommissionRate_;
        passiveOrderPayoutRate = passiveOrderPayoutRate_;
    }

    function setSellExecution(uint128 shares, uint128 value, uint128 fee, uint256 inputSpent, uint256 outputTransferred)
        external
    {
        sellExecution = Execution({
            shares: shares, value: value, fee: fee, inputSpent: inputSpent, outputTransferred: outputTransferred
        });
    }

    function setBuyExecution(
        uint128 shares,
        uint128 value,
        uint128 fee,
        uint256 inputSpent,
        uint256 outputTransferred,
        bool asNative
    ) external {
        buyExecution = Execution({
            shares: shares, value: value, fee: fee, inputSpent: inputSpent, outputTransferred: outputTransferred
        });
        deliverBuyOutputAsNative = asNative;
    }

    function getConfig()
        external
        view
        returns (
            uint256 scalingFactorTokenX_,
            uint256 scalingFactorTokenY_,
            address tokenX_,
            address tokenY_,
            bool supportsNativeEth_,
            bool isTokenXWeth_,
            address askTrie,
            address bidTrie,
            uint64 adminCommissionRate_,
            uint64 totalAggressiveCommissionRate_,
            uint64 totalPassiveCommissionRate_,
            uint64 passiveOrderPayoutRate_,
            bool shouldInvokeOnTrade_
        )
    {
        return (
            scalingFactorTokenX,
            scalingFactorTokenY,
            tokenX,
            tokenY,
            supportsNativeEth,
            isTokenXWeth,
            address(0),
            address(0),
            adminCommissionRate,
            totalAggressiveCommissionRate,
            totalPassiveCommissionRate,
            passiveOrderPayoutRate,
            shouldInvokeOnTrade
        );
    }

    function placeOrder(
        bool isAsk,
        uint128 quantity,
        uint72 price,
        uint128 maxCommission,
        bool marketOnly,
        bool postOnly,
        bool transferExecutedTokens,
        uint256 expires
    ) external payable returns (uint64 orderId, uint128 executedShares, uint128 executedValue, uint128 aggressiveFee) {
        lastIsAsk = isAsk;
        lastQuantity = quantity;
        lastPrice = price;
        lastMaxCommission = maxCommission;
        lastMarketOnly = marketOnly;
        lastPostOnly = postOnly;
        lastTransferExecutedTokens = transferExecutedTokens;
        lastExpires = expires;

        Execution memory execution = sellExecution;
        if (execution.inputSpent != 0) {
            IERC20(tokenX).safeTransferFrom(msg.sender, address(this), execution.inputSpent);
        }
        if (execution.outputTransferred != 0) {
            IERC20(tokenY).safeTransfer(msg.sender, execution.outputTransferred);
        }

        return (0, execution.shares, execution.value, execution.fee);
    }

    function placeMarketOrderWithTargetValue(
        bool isAsk,
        uint128 targetTokenYValue,
        uint72 price,
        uint128 maxCommission,
        bool transferExecutedTokens,
        uint256 expires
    ) external payable returns (uint128 executedShares, uint128 executedValue, uint128 aggressiveFee) {
        lastIsAsk = isAsk;
        lastTargetTokenYValue = targetTokenYValue;
        lastPrice = price;
        lastMaxCommission = maxCommission;
        lastTransferExecutedTokens = transferExecutedTokens;
        lastExpires = expires;

        Execution memory execution = buyExecution;
        if (execution.inputSpent != 0) {
            IERC20(tokenY).safeTransferFrom(msg.sender, address(this), execution.inputSpent);
        }
        if (execution.outputTransferred != 0) {
            if (deliverBuyOutputAsNative) {
                (bool success,) = msg.sender.call{ value: execution.outputTransferred }("");
                require(success, "NATIVE_TRANSFER");
            } else {
                IERC20(tokenX).safeTransfer(msg.sender, execution.outputTransferred);
            }
        }

        return (execution.shares, execution.value, execution.fee);
    }
}
