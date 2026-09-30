# MRC-17 adapters

Solidity adapters for integrating Monad proprietary AMMs through the MRC-17 exact-input interface.

The repository ships five venue adapters:

- `PoeAdapter`: LFJ POE oracle-pool markets.
- `CloberAdapter`: Clober V2 mirror-book markets, including native MON books normalized to WMON.
- `MetricAdapter`: legacy Metric OMM pools using rollback-isolated non-view quoting.
- `HanjiAdapter`: Hanji order-book markets using helper ladders and exact-execution checks.
- `ThogAdapter`: ThogAMM inventory-backed maker markets with rotating pool discovery.

## Installation

Install the package in a Foundry project and commit the resulting submodule revision:

```sh
forge install haythemsellami/mrc-17-adapters
```

Add `mrc-17-adapters/=lib/mrc-17-adapters/` to your `remappings.txt`, then import the shared interface or a venue:

```solidity
import { IPropAMMRouter } from "mrc-17-adapters/src/interfaces/IPropAMMRouter.sol";
import { PoeAdapter } from "mrc-17-adapters/src/adapters/PoeAdapter.sol";
```

The package owns the venue implementations, `src/base/MRC17Adapter.sol`, and adapter unit tests. Consumers such as
[Monoper](https://github.com/haythemsellami/monoper) import this package and retain their router integration tests.
Use Solidity 0.8.26 or later and a Cancun-compatible EVM; the shared base uses transient-storage reentrancy protection.
The tested dependency versions are pinned in `foundry.lock`.

## MRC-17 behavior

The interface supports one or more markets per contract. These adapters each represent one fixed ERC-20 pair:

- `tokenIn` and `tokenOut` explicitly select the assets and direction; unsupported pairs revert;
- the interface requires no token-ordering or pair-discovery getters;
- `getAmountOut` has a non-view interface and requires neither tokens nor an allowance;
- routers must call every quote through ordinary EVM `CALL` inside a child frame that always reverts;
- `swap` pulls exactly `amountIn` from the immediate caller using ERC-20 `transferFrom` semantics;
- the adapter independently enforces a non-zero recipient, deadline, and minimum output;
- the returned output equals the recipient's observable ERC-20 balance increase; and
- every successful swap emits `PropAMMSwap` with the immediate caller, recipient, input and output assets, input
  amount, and actual output.

The shared [interface](src/interfaces/IPropAMMRouter.sol) exposes:

```solidity
function getAmountOut(address tokenIn, address tokenOut, uint256 amountIn, bytes calldata quoteData)
    external returns (uint256 amountOut, bytes memory swapData);

function swap(address tokenIn, address tokenOut, address to, uint256 amountIn, uint256 amountOutMin,
    uint256 deadline, bytes calldata swapData) external returns (uint256 amountOut);
```

This ABI requires new adapter deployments and updated callers; renaming an existing deployment does not change its ABI.

Poe, Clober, Hanji, and ThogAMM currently use static-compatible quote paths, but integrations must not depend on that.
Metric's legacy quote path changes state and fails under `STATICCALL`; it works through the standard rollback-isolated
ordinary call flow. The ABI selector does not encode mutability, so view implementations remain compatible with the
non-view interface.

Before calling `swap`, the caller must approve the selected adapter for at least the exact input amount. Exact-amount
approvals are recommended.

## Venue deployments

### LFJ POE

The constructor accepts a POE pool address. Pools should be resolved from the factory before deployment.

| Contract | Monad address |
| --- | --- |
| Factory | `0x78120F2C0EBF0cc8B7E7749e62D36e6523dD711D` |
| WMON/USDC pool | `0x02A8A16613a421EabaD6861fF6d8159f6D5EDB8f` |

### Clober V2

| Contract | Monad address |
| --- | --- |
| BookManager | `0x6657d192273731C3cAc646cc82D5F28D0CBE8CCC` |
| BookViewer | `0xe424c211e2Ed8a5B6d1C57FA493C41715568D238` |
| Controller | `0x19b68a2b909D96c05B623050C276FBD457De8e83` |

Deploy one `CloberAdapter` per pair, supplying the directional mirror books in canonical token order:

| `token0` / `token1` | token0-for-token1 book | token1-for-token0 book |
| --- | ---: | ---: |
| WMON / USDC | `5954885684956363054050231031211743946744177791604395877538` | `3875727077379471850923186002296331935053867847116966170720` |
| WBTC / USDC | `5310657737502833383554997860081619839164052597766524570606` | `3854396250455310695147789948131437079035726850548834252223` |
| WETH / USDC | `680091963353999958661303284433884846705699901928885914311` | `6215929461771924482215683498685754109371513948112281158916` |

Clober represents MON as `address(0)` internally. The adapter exposes WMON at the MRC-17 boundary and rejects quotes
unless the viewer reports that the complete exact input is executable.

### Metric legacy

| Contract | Monad address |
| --- | --- |
| Router | `0xaF9ADa6b6eC7993CE146f6c0bF98f7211CDfD3e5` |
| WMON/USDC pool | `0xFA32f9ec28787d1F9C5BA5c39e54e59984FEF3f0` |
| WBTC/USDC pool | `0x2D82AC42334b394A9a8d8f097d61DC1c6B065Fd8` |
| WETH/USDC pool | `0x354D92279cA0190fF275095fE6A2a6989BAa66Fb` |

Metric quotes are not static-call compatible. Do not call `getAmountOut` directly from persistent onchain execution;
use a router that performs an ordinary call inside an unconditional rollback sandbox.

### Hanji

| Deployment input | Monad address/value |
| --- | --- |
| FastQuoterHelper | `0x237dB58fea34A35A8543b44C217d221606cE7788` |
| Recommended maximum price levels | `60` |

`HanjiAdapter` is an operational ABI-compatible exception: its helper ladder is not an enforced execution preview.
Every successful swap still satisfies exact-input settlement, but a winning quote can revert during execution when the
market materializes different liquidity. Builders must simulate the complete intended router swap and remove a Hanji
winner if that simulation fails before selecting again.

### ThogAMM

| Deployment input | Monad address |
| --- | --- |
| ThogAMM proxy | `0x80c74517BCC2D67fFE02D3ED886796272F647210` |
| Validated pair | WMON / USDC |

`ThogAdapter` validates ThogAMM's single rotating ERC-7815 pool and binds one immutable token pair. It accepts only
nonzero, nonfuture maker quotes, grants an exact temporary input allowance, verifies complete input consumption, and
clears the venue allowance after execution. The venue is an upgradeable proxy, so every implementation change needs
fresh compatibility and fork-test evidence.

## Token addresses

| Token | Monad address |
| --- | --- |
| WMON | `0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A` |
| USDC | `0x754704Bc059F8C67012fEd69BC8A327a5aafb603` |
| WBTC | `0x0555e30da8f98308edb960aa94c0db47230d2b9c` |
| cbBTC | `0xd18b7ec58cdf4876f6afebd3ed1730e4ce10414b` |
| WETH | `0xEE8c0E9f1BFFb4Eb878d8f15f368A02a35481242` |

## Tests

```sh
git submodule update --init --recursive
forge build
forge fmt --check
forge test --match-path 'test/unit/*'
forge test
FOUNDRY_HARDFORK=monad:MonadNine forge test --network monad --match-path 'test/e2e/*'
```

Foundry loads the gitignored `.env` automatically. Copy `.env.example` and configure `MONAD_RPC_URL` and an
archive-capable `MONAD_ARCHIVE_RPC_URL` before running fork tests. Missing RPC configuration is reported as a skip.
Fork tests use the pinned Monad Foundry `v1.7.1-monad-v1.0.0` toolchain.

The fork suite validates Poe, Clober, Metric, and ThogAMM at Monad block `90,990,000`. Hanji controls cover a known
exact execution boundary at block `88,161,153` and a known quote/execution divergence at block `90,990,000`.
ThogAMM's pinned exact swaps and Hanji's historical exact-boundary control require an archive-capable RPC.

The contracts have not been audited. Treat the repository as integration code under active development until an
independent security review and pinned deployment process are complete.
