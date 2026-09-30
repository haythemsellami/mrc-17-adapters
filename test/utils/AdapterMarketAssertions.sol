// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IPropAMMRouter } from "../../src/interfaces/IPropAMMRouter.sol";

/// @notice Checks the configured assets of the package's fixed-market adapters without discovery getters.
library AdapterMarketAssertions {
    error UnexpectedMarket(address adapter, address tokenIn, address tokenOut, bytes response);

    /// @dev These adapters validate assets before rejecting nonempty quote data. Requiring that exact data error
    ///      proves both asset directions were accepted without depending on liquidity or running a venue quote.
    ///      This probe is specific to these wrappers, not a general MRC-17 conformance check.
    function assertMarket(IPropAMMRouter adapter, address tokenA, address tokenB, bytes4 quoteDataError) internal {
        _assertDirection(adapter, tokenA, tokenB, quoteDataError);
        _assertDirection(adapter, tokenB, tokenA, quoteDataError);
    }

    function _assertDirection(IPropAMMRouter adapter, address tokenIn, address tokenOut, bytes4 quoteDataError)
        private
    {
        (bool success, bytes memory response) =
            address(adapter).call(abi.encodeCall(IPropAMMRouter.getAmountOut, (tokenIn, tokenOut, 1, hex"01")));
        if (success || keccak256(response) != keccak256(abi.encodeWithSelector(quoteDataError))) {
            revert UnexpectedMarket(address(adapter), tokenIn, tokenOut, response);
        }
    }
}
