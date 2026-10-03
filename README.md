# VolFeeHook

Uniswap v4 hook: **keeper writes the fee, the swap only reads it.**

```
ticks over a window → variance → fee = clamp(base + k·var, min, max)   (keeper/, off-chain)
                                   ↓
                         keeper calls setFee(poolId, fee)
                                   ↓
            beforeSwap returns the stored fee | OVERRIDE_FEE_FLAG
```

- A fee written in block N goes live in block N+1. Every swap in block N pays `feeFor(poolId)` as read
  at block N (quote = fill). A swap sent now lands in the next block, so quote with `feeState()`:
  `nextFee` if `nextFeeBlock <= target block`, else `fee`.
- No oracle and no `hookData`. `beforeSwap` does one storage read.
- The owner sets `[minFee, maxFee]`. The keeper can't write outside them, and if the bounds are
  tightened, live fees are clamped when read.
- Pools must be initialized with fee `0x800000` (dynamic). Hook flags: `AFTER_INITIALIZE | BEFORE_SWAP`.

Fees are in pips: 1e6 = 100%, 100 = 1 bp.

## Layout

```
contracts/           Foundry: Uniswap v4 hook, tests, deploy scripts. Also the JS package the keeper imports:
                     abi/ (generated ABIs + deployments) and deployments/<chainId>[.algebra].json
contracts/algebra/   Separate Foundry project (solc 0.8.20, paris): Algebra Integral v1.2.2 KeeperFeePlugin
keeper/              keeper loop, fee model (volMath.mjs), venue adapters (target.mjs), quote=fill audit (fills.mjs)
```

How the pieces connect:

1. Deploy scripts write addresses to `contracts/deployments/<chainId>.json`.
2. `contracts` build (`forge build` + `scripts/generate.mjs`) bundles the ABIs and every deployment into
   `contracts/abi/generated.js`, exported as `@vol-fee-hook/contracts`.
3. The keeper imports ABIs and addresses from `@vol-fee-hook/contracts`, so a contract ABI change reaches it in the same commit.

## Setup

```sh
git submodule update --init --recursive
pnpm install
pnpm build
pnpm test            # 12 v4 tests + 14 Algebra tests, each incl. fuzzed quote == fill
```

## Local run

```sh
pnpm chain                     # 1. Anvil (PoolManager is >24KB without via_ir; local only)
pnpm deploy:local              # 2. manager, tokens, hook, pool, liquidity → deployments/31337.json
pnpm keeper                    # 3. signs as anvil #1 (the hook's keeper)

ZERO_FOR_ONE=false AMOUNT=50000000000000000000000 pnpm swap:local   # move the price, repeat
pnpm fills                     # every swap: fee charged vs feeFor at that block
```

Keeper env: `KEEPER_TARGET` (`v4` default, or `algebra`), `RPC_URL`, `KEEPER_PK`, `INTERVAL_MS`, `WINDOW`, `MIN_SAMPLES`, `MIN_CHANGE_PIPS`,
`FEE_BASE`, `FEE_K`, `FEE_MIN`, `FEE_MAX`. To override the deployment file: `HOOK`/`POOL_ID`/`POOL_MANAGER` (v4)
or `ALGEBRA_POOL`/`ALGEBRA_PLUGIN` (algebra).

## Deploy (real chain)

```sh
cd contracts
POOL_MANAGER=0x... KEEPER=0x... forge script script/DeployVolFeeHook.s.sol --rpc-url $RPC_URL --broadcast
```

Then initialize the pool with fee `0x800000`, and add `poolId` and `startBlock` to `deployments/<chainId>.json`.

## Algebra Integral v1.2.2 (Nami)

Nami's DEX does not run Uniswap v4. Its pools are stock Algebra Integral v1.2.2 pools, and Nami attaches its own plugin
to each one: a volatility oracle, a dynamic fee that follows volatility, the farming hook, MEV protection, and AntiSniper
on launch pools ([docs/gauges](https://github.com/namifi/Nami-Protocol/blob/main/docs/gauges/README.md)). That plugin's
source is not public yet. Nami's repo publishes modules as they go live, and "Pools and gauges" is marked "At launch".

So `contracts/algebra/` is written against the public Algebra v1.2.2 code (`lib/Algebra`, pinned to tag
`v1.2.2-integral`), not against Nami's plugin:

- `KeeperFeePlugin`: one per pool. The keeper calls `setFee(fee)`, and `beforeSwap` returns the stored fee as Algebra's
  `feeOverride` (pool flags `BEFORE_SWAP | DYNAMIC_FEE`). Same rules as the v4 hook: live from the next block, clamped
  to bounds. It implements the GPL `IAlgebraPlugin` interface directly, with no BUSL base-plugin code.
- `KeeperFeePluginFactory`: owner, keeper and fee bounds shared by all plugins. `createPlugin(pool)` deploys a
  plugin; the pool administrator then calls `pool.setPlugin(plugin)` (plus `pool.setPluginConfig(plugin.defaultPluginConfig())`
  if the pool is already initialized).
- Tests run against the real `AlgebraFactory`, `AlgebraPoolDeployer` and `AlgebraPool`. The charged fee is read from
  the pool's `SwapFee` event, and one test checks that a higher fee lowers the swap output.

Facts from the Algebra v1.2.2 source that shape the design:

- `pool.setFee()` is administrator-only and reverts while a dynamic-fee plugin is active, so a keeper cannot set the fee
  on a Nami pool directly. The fee has to come from the pool's plugin.
- `beforeSwap` returns `(selector, feeOverride, pluginFee)`. The pool charges `overrideFee + pluginFee` (must stay
  below 1e6), and `overrideFee == 0` means "no override", so the minimum fee is at least 1.
- Algebra's own `AlgebraBasePluginV1` computes volatility inside `beforeSwap` and returns the result as the override on
  every swap. This repo keeps volatility off-chain instead.

```sh
pnpm deploy:local:algebra                      # real Algebra factory + pool + KeeperFeePlugin on Anvil
KEEPER_TARGET=algebra pnpm keeper              # same keeper loop, Algebra adapter
ZERO_FOR_ONE=false AMOUNT=50000000000000000000000 pnpm swap:local:algebra
KEEPER_TARGET=algebra pnpm fills               # overrideFee from SwapFee vs plugin.feeFor() at that block
```

### Integrating with a Nami pool

A pool has exactly one plugin, and Nami's carries farming and AntiSniper, so swapping in `KeeperFeePlugin` would
break emissions on that pool. The realistic paths:

1. **Nami adds a keeper-fee mode to its own plugin** (recommended). The fee part is about 40 lines (`setFee`, `feeFor`,
   `_liveFee`, returned from their `beforeSwap`). `KeeperFeePlugin` is the reference implementation and the test suite
   is the spec. The keeper's `algebra` adapter then points at their plugin's ABI.
2. **A pool with no farming or launch guard** (a test pool) uses `KeeperFeePlugin` as-is.
3. **Not recommended:** if Nami's plugin keeps Algebra's `changeFeeConfiguration`, a keeper could set `alpha1 = alpha2 = 0`
   and write `baseFee`. That needs the factory-wide `ALGEBRA_BASE_PLUGIN_MANAGER` role and applies immediately rather
   than from the next block, so a quote taken earlier in the same block can differ from the fill.

