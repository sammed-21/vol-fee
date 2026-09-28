# VolFeeHook

Uniswap v4 hook: **keeper writes the fee, the swap only reads it.**

```
ticks over a window → variance → fee = clamp(base + k·var, min, max)   (off-chain, script/volMath.mjs)
                                   ↓
                         keeper calls setFee(poolId, fee)
                                   ↓
            beforeSwap returns the stored fee | OVERRIDE_FEE_FLAG
```

- A fee written in block N goes live in block N+1. Every swap in a block pays the fee that was live
  when the block started, so `feeFor(poolId)` = the fee charged (quote = fill).
- No oracle and no `hookData`. `beforeSwap` does one storage read.
- The owner sets `[minFee, maxFee]`. The keeper can't write outside them, and if the bounds are
  tightened, live fees are clamped when read.
- Pools must be initialized with fee `0x800000` (dynamic). Hook flags: `AFTER_INITIALIZE | BEFORE_SWAP`.

## Run

```sh
forge test -vv                 # 12 tests incl. fuzzed quote == fill (checked against PoolManager's Swap event)
node script/volMath.mjs        # fee model on calm → stress tick series
POOL_MANAGER=0x... KEEPER=0x... forge script script/DeployVolFeeHook.s.sol --rpc-url $RPC_URL --broadcast
```

Fees are in pips: 1e6 = 100%, 100 = 1 bp.
