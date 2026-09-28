// Quote = fill audit. For every Swap on the pool, compare the fee the PoolManager charged
// with the hook's feeFor() evaluated at that same block. Exits 1 on any mismatch.
//
//   FROM_BLOCK=0 node src/fills.mjs
import { createPublicClient, http, parseAbiItem } from "viem";
import { volFeeHookAbi, getDeployment } from "@vol-fee-hook/contracts";

const RPC_URL = process.env.RPC_URL ?? "http://127.0.0.1:8545";
const client = createPublicClient({ transport: http(RPC_URL) });
const chainId = await client.getChainId();
const d = process.env.HOOK ? {} : getDeployment(chainId);
const HOOK = process.env.HOOK ?? d.hook;
const POOL_ID = process.env.POOL_ID ?? d.poolId;
const POOL_MANAGER = process.env.POOL_MANAGER ?? d.poolManager;

const swapEvent = parseAbiItem(
  "event Swap(bytes32 indexed id, address indexed sender, int128 amount0, int128 amount1, uint160 sqrtPriceX96, uint128 liquidity, int24 tick, uint24 fee)",
);
const logs = await client.getLogs({
  address: POOL_MANAGER,
  event: swapEvent,
  args: { id: POOL_ID },
  fromBlock: BigInt(process.env.FROM_BLOCK ?? 0),
});

let bad = 0;
for (const log of logs) {
  // State at the end of block N still reports the fee live *in* N (a write in N is pending until N+1).
  const quoted = await client.readContract({
    address: HOOK,
    abi: volFeeHookAbi,
    functionName: "feeFor",
    args: [POOL_ID],
    blockNumber: log.blockNumber,
  });
  const ok = Number(quoted) === log.args.fee;
  if (!ok) bad++;
  console.log(`block ${log.blockNumber}  tick ${log.args.tick}  feeFor ${quoted}  charged ${log.args.fee}  ${ok ? "ok" : "MISMATCH"}`);
}
console.log(`${logs.length} swaps, ${bad} mismatches`);
process.exit(bad ? 1 : 0);
