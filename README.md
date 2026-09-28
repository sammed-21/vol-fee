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
contracts/   Foundry: hook, tests, deploy scripts. Also the JS package the keeper imports:
             abi/ (generated ABIs + deployments) and deployments/<chainId>.json
keeper/      keeper loop, fee model (volMath.mjs), quote=fill audit (fills.mjs)
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
pnpm test            # 12 forge tests incl. fuzzed quote == fill
```

## Local run

```sh
pnpm chain                     # 1. Anvil (PoolManager is >24KB without via_ir; local only)
pnpm deploy:local              # 2. manager, tokens, hook, pool, liquidity → deployments/31337.json
pnpm keeper                    # 3. signs as anvil #1 (the hook's keeper)

ZERO_FOR_ONE=false AMOUNT=50000000000000000000000 pnpm swap:local   # move the price, repeat
pnpm fills                     # every swap: fee charged vs feeFor at that block
```

Keeper env: `RPC_URL`, `KEEPER_PK`, `INTERVAL_MS`, `WINDOW`, `MIN_SAMPLES`, `MIN_CHANGE_PIPS`,
`FEE_BASE`, `FEE_K`, `FEE_MIN`, `FEE_MAX`, and `HOOK`/`POOL_ID`/`POOL_MANAGER` to override the deployment file.

## Deploy (real chain)

```sh
cd contracts
POOL_MANAGER=0x... KEEPER=0x... forge script script/DeployVolFeeHook.s.sol --rpc-url $RPC_URL --broadcast
```

Then initialize the pool with fee `0x800000`, and add `poolId` and `startBlock` to `deployments/<chainId>.json`.
