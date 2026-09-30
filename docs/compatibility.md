# Monad propAMM compatibility

This document describes the MRC-17 wrappers for the supported Monad propAMMs. Their fork fixtures use Monad mainnet
block `90,990,000`; Hanji exact-execution controls additionally use block `88,161,153`.
Both quote and swap calls identify direction with explicit `tokenIn` and `tokenOut` addresses. Each wrapper validates
its configured pair without exposing token-ordering getters.

## Status

| Venue | Quote path | Exact-input execution | Adapter status |
| --- | --- | --- | --- |
| LFJ POE | Static-compatible pool quote | Callback settlement | Supported |
| Clober V2 | Static-compatible BookViewer | Supported when the complete requested base amount is executable | Supported |
| Metric legacy | State-changing legacy router quote | Router pulls exact input | Supported through rollback-isolated non-view quoting |
| Hanji | Static-compatible helper ladder | Proxy execution with exact-input verification | Operational exception requiring complete-swap simulation and winner pruning |
| ThogAMM | Static-compatible maker quote | Maker pulls exact input and credits the recipient | Supported with per-implementation revalidation |

A conforming adapter must satisfy MRC-17's exact-input funding, executable-quote, and recipient-settlement
requirements. Hanji is the explicitly documented exception: it is usable with a simulation-gated builder flow but is
not claimed to satisfy strict same-state quote fidelity.

## LFJ POE

`PoeAdapter` reads the pool's fixed token order, rejects quotes that do not consume the complete requested input, and
authenticates POE's settlement callback before paying the pool. POE sends output directly to the MRC-17 recipient, and
the shared base verifies the recipient's balance increase.

| Contract | Monad address |
| --- | --- |
| Factory | `0x78120F2C0EBF0cc8B7E7749e62D36e6523dD711D` |
| WMON/USDC pool | `0x02A8A16613a421EabaD6861fF6d8159f6D5EDB8f` |

## Clober V2

`CloberAdapter` validates its BookManager, BookViewer, Controller, and mirrored directional books at construction.
Quotes revert unless the viewer reports that the full exact input is executable. For native-MON books, the adapter
normalizes the MRC-17 endpoint to WMON and wraps or unwraps only during venue settlement.

| Contract | Monad address |
| --- | --- |
| BookManager | `0x6657d192273731C3cAc646cc82D5F28D0CBE8CCC` |
| BookViewer | `0xe424c211e2Ed8a5B6d1C57FA493C41715568D238` |
| Controller | `0x19b68a2b909D96c05B623050C276FBD457De8e83` |

| Adapter pair | token0-for-token1 book | token1-for-token0 book |
| --- | ---: | ---: |
| WMON/USDC | `5954885684956363054050231031211743946744177791604395877538` | `3875727077379471850923186002296331935053867847116966170720` |
| WBTC/USDC | `5310657737502833383554997860081619839164052597766524570606` | `3854396250455310695147789948131437079035726850548834252223` |
| WETH/USDC | `680091963353999958661303284433884846705699901928885914311` | `6215929461771924482215683498685754109371513948112281158916` |

## Metric legacy

`MetricAdapter` calls the legacy router's state-changing `quoteSwap` path. This is compatible with the current MRC-17
because quotes use ordinary `CALL` inside a child frame that always rolls back. The adapter reads the pool's price
provider for its bid and ask inputs, validates signed quote deltas, and requires both quoted and reported executed
input to equal the requested exact input.

| Contract | Monad address |
| --- | --- |
| Router | `0xaF9ADa6b6eC7993CE146f6c0bF98f7211CDfD3e5` |
| WMON/USDC pool | `0xFA32f9ec28787d1F9C5BA5c39e54e59984FEF3f0` |
| WBTC/USDC pool | `0x2D82AC42334b394A9a8d8f097d61DC1c6B065Fd8` |
| WETH/USDC pool | `0x354D92279cA0190fF275095fE6A2a6989BAa66Fb` |

Metric quotes fail under EVM `STATICCALL`. Integrations must use a rollback-isolated ordinary-call implementation.

## Hanji

`HanjiAdapter` walks the configured FastQuoterHelper ladder and executes against one fixed active market proxy.
Token-X inputs must be whole Hanji shares with sufficient visible depth. Token-Y inputs must equal an exact
helper-derived share boundary. Execution requires the proxy to consume the complete input and normalizes native MON
output to WMON where needed.

The helper ladder is not an enforced execution preview. A quote can win and then revert because the proxy consumes
less input or delivers less output. This is fund-safe because the complete transaction rolls back, but it is a
liveness and gas-cost risk. A builder must:

1. Quote the intended candidate set through the current router interface.
2. Simulate the exact complete swap with the intended calldata, caller, balances, allowances, gas limit, and state.
3. If a selected Hanji execution reverts, remove that winning adapter and repeat selection and complete-swap simulation.
4. Submit only a candidate set whose complete swap simulation succeeds.

A successful simulation is not a future-block guarantee, so the router and adapter retain atomic settlement checks.
The repository's pinned fork controls currently cover WMON/USDC.

| Deployment input | Monad address/value |
| --- | --- |
| WMON/USDC market | `0x1aeD222dda944a87703c918745b11bE13f8eEf10` |
| FastQuoterHelper | `0x237dB58fea34A35A8543b44C217d221606cE7788` |
| Recommended maximum price levels | `60` |

## ThogAMM

`ThogAdapter` binds one immutable token pair to ThogAMM's inventory-funded maker proxy. The constructor requires the
proxy to expose exactly one ERC-7815 pool ID and a unique, nonzero token registry containing both configured tokens.
It intentionally does not store the pool ID because the venue can rotate that identifier while retaining the same
proxy and token registry.

Quotes call `makerQuoteExactInput(tokenIn, tokenOut, amountIn)`, reject zero output, and require a nonzero posted block
no greater than the current block. Quote and swap data must both be empty. Execution grants the proxy an allowance of
exactly `amountIn`, calls
`makerSwapExactInput(tokenIn, tokenOut, amountIn, amountOutMin, recipient, block.number)`, clears and verifies the
allowance, and proves the venue consumed exactly the newly received input without touching a preexisting adapter
balance. ThogAMM sends output directly to the MRC-17 recipient, so the shared base also checks the actual recipient
balance delta against the venue's reported output. MRC-17's user deadline remains timestamp-based and is enforced by
the base before the venue receives its block-number deadline.

| Deployment input | Monad address |
| --- | --- |
| ThogAMM proxy | `0x80c74517BCC2D67fFE02D3ED886796272F647210` |
| WMON | `0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A` |
| USDC | `0x754704Bc059F8C67012fEd69BC8A327a5aafb603` |

The pinned fork evidence at block `90,990,000` is tied to implementation
`0x127a5B18e3e96fc104F5eAF280dfe502dd3fD40A`, whose runtime code hash is
`0x432d64d0d143d454afe9586a9708f431f4131523e9b5dc34ca1c7cc683715393`. It verifies static discovery, quotes, and
exact swaps in both WMON/USDC directions. The adapter intentionally integrates the upgradeable proxy rather than
pinning its ERC-1967 implementation. A proxy upgrade can therefore change execution semantics without changing the
venue or adapter address, and each implementation requires fresh compatibility evidence.
