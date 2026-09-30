// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { AdapterMarketAssertions } from "../utils/AdapterMarketAssertions.sol";
import { Test } from "forge-std/Test.sol";
import { IThogAMM, ThogAdapter } from "../../src/adapters/ThogAdapter.sol";

interface IERC20ThogE2E {
    function approve(address spender, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
}

contract ThogAdapterE2ETest is Test {
    uint256 private constant MONAD_MAINNET_CHAIN_ID = 143;
    uint256 private constant PINNED_BLOCK = 90_990_000;
    address private constant THOG = 0x80c74517BCC2D67fFE02D3ED886796272F647210;
    address private constant WMON = 0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A;
    address private constant USDC = 0x754704Bc059F8C67012fEd69BC8A327a5aafb603;
    address private constant PINNED_IMPLEMENTATION = 0x127a5b18E3E96fc104F5Eaf280DFe502DD3fd40a;
    bytes32 private constant PINNED_IMPLEMENTATION_HASH =
        0x432d64d0d143d454afe9586a9708f431f4131523e9b5dc34ca1c7cc683715393;
    bytes32 private constant ERC1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    uint256 private constant WMON_AMOUNT_IN = 0.01 ether;
    uint256 private constant PINNED_WMON_AMOUNT_OUT = 207;
    uint256 private constant USDC_AMOUNT_IN = 1_000_000;
    uint256 private constant PINNED_USDC_AMOUNT_OUT = 46_657_176_072_636_145_929;
    uint256 private constant PINNED_LAST_POSTED_BLOCK = 90_989_987;

    string private currentRpcUrl;
    string private pinnedRpcUrl;
    ThogAdapter private adapter;
    address private user;
    address private recipient;
    bool private forkEnabled;

    function setUp() public {
        currentRpcUrl = vm.envOr("MONAD_RPC_URL", string(""));
        string memory archiveRpcUrl = vm.envOr("MONAD_ARCHIVE_RPC_URL", string(""));
        pinnedRpcUrl = bytes(archiveRpcUrl).length == 0 ? currentRpcUrl : archiveRpcUrl;
        if (bytes(pinnedRpcUrl).length == 0) {
            vm.skip(true, "Set MONAD_ARCHIVE_RPC_URL to run ThogAMM fork tests");
            return;
        }

        vm.createSelectFork(pinnedRpcUrl, PINNED_BLOCK);
        assertEq(block.chainid, MONAD_MAINNET_CHAIN_ID);
        assertEq(block.number, PINNED_BLOCK);

        adapter = new ThogAdapter(THOG, WMON, USDC);
        user = makeAddr("thog-user");
        recipient = makeAddr("thog-recipient");
        forkEnabled = true;
    }

    function test_discoversSinglePoolAndConfiguredTokensThroughStaticcall() public {
        if (!forkEnabled) return;

        (bool idsSuccess, bytes memory idsResult) = THOG.staticcall(abi.encodeCall(IThogAMM.getPoolIds, ()));
        assertTrue(idsSuccess);
        bytes32[] memory poolIds = abi.decode(idsResult, (bytes32[]));
        assertEq(poolIds.length, 1);

        (bool tokensSuccess, bytes memory tokensResult) =
            THOG.staticcall(abi.encodeCall(IThogAMM.getTokens, (poolIds[0])));
        assertTrue(tokensSuccess);
        address[] memory tokens = abi.decode(tokensResult, (address[]));
        assertTrue(_contains(tokens, WMON));
        assertTrue(_contains(tokens, USDC));

        assertEq(adapter.venue(), THOG);
        AdapterMarketAssertions.assertMarket(adapter, WMON, USDC, ThogAdapter.UnexpectedData.selector);

        address implementation = address(uint160(uint256(vm.load(THOG, ERC1967_IMPLEMENTATION_SLOT))));
        assertEq(implementation, PINNED_IMPLEMENTATION);
        assertEq(implementation.codehash, PINNED_IMPLEMENTATION_HASH);
    }

    function test_currentStateSupportsConstructorDiscovery() public {
        if (!forkEnabled) return;
        string memory rpcUrl = bytes(currentRpcUrl).length == 0 ? pinnedRpcUrl : currentRpcUrl;
        vm.createSelectFork(rpcUrl);

        ThogAdapter currentAdapter = new ThogAdapter(THOG, WMON, USDC);

        assertEq(currentAdapter.venue(), THOG);
        AdapterMarketAssertions.assertMarket(currentAdapter, WMON, USDC, ThogAdapter.UnexpectedData.selector);
    }

    function test_quotesAndExecutesWmonForUsdc() public {
        if (!forkEnabled) return;

        (uint256 directQuote, uint256 lastPostedBlock) = IThogAMM(THOG).makerQuoteExactInput(WMON, USDC, WMON_AMOUNT_IN);
        assertEq(directQuote, PINNED_WMON_AMOUNT_OUT);
        assertEq(lastPostedBlock, PINNED_LAST_POSTED_BLOCK);

        (uint256 adapterQuote, bytes memory swapData) = adapter.getAmountOut(WMON, USDC, WMON_AMOUNT_IN, bytes(""));
        assertEq(adapterQuote, directQuote);
        assertEq(swapData, bytes(""));

        deal(WMON, user, WMON_AMOUNT_IN, false);
        vm.prank(user);
        IERC20ThogE2E(WMON).approve(address(adapter), WMON_AMOUNT_IN);

        vm.prank(user);
        uint256 amountOut = adapter.swap(WMON, USDC, recipient, WMON_AMOUNT_IN, adapterQuote, block.timestamp, swapData);

        assertEq(amountOut, adapterQuote);
        assertEq(IERC20ThogE2E(WMON).balanceOf(user), 0);
        assertEq(IERC20ThogE2E(WMON).balanceOf(address(adapter)), 0);
        assertEq(IERC20ThogE2E(WMON).allowance(address(adapter), THOG), 0);
        assertEq(IERC20ThogE2E(USDC).balanceOf(recipient), adapterQuote);
    }

    function test_quotesAndExecutesUsdcForWmon() public {
        if (!forkEnabled) return;

        (uint256 directQuote, uint256 lastPostedBlock) = IThogAMM(THOG).makerQuoteExactInput(USDC, WMON, USDC_AMOUNT_IN);
        assertEq(directQuote, PINNED_USDC_AMOUNT_OUT);
        assertEq(lastPostedBlock, PINNED_LAST_POSTED_BLOCK);

        (uint256 adapterQuote, bytes memory swapData) = adapter.getAmountOut(USDC, WMON, USDC_AMOUNT_IN, bytes(""));
        assertEq(adapterQuote, directQuote);
        assertEq(swapData, bytes(""));

        deal(USDC, user, USDC_AMOUNT_IN, true);
        vm.prank(user);
        IERC20ThogE2E(USDC).approve(address(adapter), USDC_AMOUNT_IN);

        vm.prank(user);
        uint256 amountOut = adapter.swap(USDC, WMON, recipient, USDC_AMOUNT_IN, adapterQuote, block.timestamp, swapData);

        assertEq(amountOut, adapterQuote);
        assertEq(IERC20ThogE2E(USDC).balanceOf(user), 0);
        assertEq(IERC20ThogE2E(USDC).balanceOf(address(adapter)), 0);
        assertEq(IERC20ThogE2E(USDC).allowance(address(adapter), THOG), 0);
        assertEq(IERC20ThogE2E(WMON).balanceOf(recipient), adapterQuote);
    }

    function _contains(address[] memory tokens, address token) private pure returns (bool) {
        for (uint256 i; i < tokens.length; ++i) {
            if (tokens[i] == token) return true;
        }
        return false;
    }
}
