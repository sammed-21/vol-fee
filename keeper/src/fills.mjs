// Quote = fill audit. For every swap on the pool, compare the fee the pool charged with
// feeFor() evaluated at that same block. Exits 1 on any mismatch.
//
//   FROM_BLOCK=0 node src/fills.mjs                        Uniswap v4 hook
//   KEEPER_TARGET=algebra FROM_BLOCK=0 node src/fills.mjs  Algebra plugin
import { createPublicClient, http } from "viem";
import { createTarget } from "./target.mjs";

const RPC_URL = process.env.RPC_URL ?? "http://127.0.0.1:8545";
const publicClient = createPublicClient({ transport: http(RPC_URL) });
const chainId = await publicClient.getChainId();
const target = createTarget({ publicClient, chainId });

// State at the end of block N still reports the fee live *in* N (a write in N is pending until N+1).
const rows = await target.fills(BigInt(process.env.FROM_BLOCK ?? 0));
let bad = 0;
for (const r of rows) {
  const ok = r.quoted === r.charged;
  if (!ok) bad++;
  console.log(`block ${r.blockNumber}  tick ${r.tick}  feeFor ${r.quoted}  charged ${r.charged}  ${ok ? "ok" : "MISMATCH"}`);
}
console.log(`${target.kind}: ${rows.length} swaps, ${bad} mismatches`);
process.exit(bad ? 1 : 0);
