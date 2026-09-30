// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";

import { MRC17Adapter } from "../../src/base/MRC17Adapter.sol";
import { ThogAdapter } from "../../src/adapters/ThogAdapter.sol";
import { IPropAMMRouter } from "../../src/interfaces/IPropAMMRouter.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockThog } from "../mocks/MockThog.sol";
import { AdapterMarketAssertions } from "../utils/AdapterMarketAssertions.sol";

contract AdapterMarketAssertionsHarness {
    function assertThogMarket(IPropAMMRouter adapter, address tokenA, address tokenB) external {
        AdapterMarketAssertions.assertMarket(adapter, tokenA, tokenB, ThogAdapter.UnexpectedData.selector);
    }
}

contract AdapterMarketAssertionsTest is Test {
    AdapterMarketAssertionsHarness private harness;
    MockThog private venue;
    address private tokenA;
    address private tokenB;
    address private tokenC;

    function setUp() public {
        harness = new AdapterMarketAssertionsHarness();
        tokenA = address(new MockERC20("Token A", "A", 18));
        tokenB = address(new MockERC20("Token B", "B", 18));
        tokenC = address(new MockERC20("Token C", "C", 18));
        address[] memory tokens = new address[](3);
        tokens[0] = tokenA;
        tokens[1] = tokenB;
        tokens[2] = tokenC;
        venue = new MockThog(keccak256("pool"), tokens);
    }

    function test_acceptsConfiguredMarketWithoutVenueLiquidity() public {
        ThogAdapter adapter = new ThogAdapter(address(venue), tokenA, tokenB);
        venue.configureQuote(tokenA, tokenB, 1, 0, 0);
        vm.expectRevert(ThogAdapter.InvalidQuote.selector);
        adapter.getAmountOut(tokenA, tokenB, 1, bytes(""));

        harness.assertThogMarket(adapter, tokenA, tokenB);
    }

    function test_rejectsWrongSecondAssetFromVenueSuperset() public {
        ThogAdapter adapter = new ThogAdapter(address(venue), tokenA, tokenC);
        // The previous same-token assertion passes even though this adapter serves A/C instead of A/B.
        vm.expectRevert(MRC17Adapter.InvalidTokenPair.selector);
        adapter.getAmountOut(tokenA, tokenA, 1, bytes(""));

        _expectWrongMarket(adapter, tokenA, tokenB);
        harness.assertThogMarket(adapter, tokenA, tokenB);
    }

    function test_rejectsWrongFirstAssetFromVenueSuperset() public {
        ThogAdapter adapter = new ThogAdapter(address(venue), tokenC, tokenB);

        _expectWrongMarket(adapter, tokenA, tokenB);
        harness.assertThogMarket(adapter, tokenA, tokenB);
    }

    function test_rejectsMarketWhenOnlyForwardDirectionIsAccepted() public {
        ThogAdapter adapter = new ThogAdapter(address(venue), tokenA, tokenB);
        vm.mockCallRevert(
            address(adapter),
            abi.encodeCall(IPropAMMRouter.getAmountOut, (tokenB, tokenA, 1, hex"01")),
            abi.encodeWithSelector(MRC17Adapter.InvalidTokenPair.selector)
        );

        _expectWrongMarket(adapter, tokenB, tokenA);
        harness.assertThogMarket(adapter, tokenA, tokenB);
    }

    function _expectWrongMarket(IPropAMMRouter adapter, address tokenIn, address tokenOut) private {
        vm.expectRevert(
            abi.encodeWithSelector(
                AdapterMarketAssertions.UnexpectedMarket.selector,
                address(adapter),
                tokenIn,
                tokenOut,
                abi.encodeWithSelector(MRC17Adapter.InvalidTokenPair.selector)
            )
        );
    }
}
