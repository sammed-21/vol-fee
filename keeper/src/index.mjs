// Keeper: sample the pool tick on an interval, compute the fee off-chain, write it with setFee.
// The hook applies a write from the next block: every swap in block N pays feeFor() as read at block N.
import { createPublicClient, createWalletClient, http, encodeAbiParameters, keccak256 } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { volFeeHookAbi, poolManagerAbi } from "@vol-fee-hook/contracts";
import { resolveTarget } from "./target.mjs";
import { feeFromTicks, DEFAULTS } from "./volMath.mjs";

const env = process.env;
const RPC_URL = env.RPC_URL ?? "http://127.0.0.1:8545";
const KEEPER_PK = env.KEEPER_PK ?? "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"; // anvil #1
const INTERVAL_MS = Number(env.INTERVAL_MS ?? 12_000);
const WINDOW = Number(env.WINDOW ?? 60); // samples kept
const MIN_SAMPLES = Number(env.MIN_SAMPLES ?? 10); // samples before the first write
const MIN_CHANGE = Number(env.MIN_CHANGE_PIPS ?? 100); // skip writes smaller than 1 bp
const MODEL = {
  base: Number(env.FEE_BASE ?? DEFAULTS.base),
  k: Number(env.FEE_K ?? DEFAULTS.k),
  min: Number(env.FEE_MIN ?? DEFAULTS.min),
  max: Number(env.FEE_MAX ?? DEFAULTS.max),
};

const publicClient = createPublicClient({ transport: http(RPC_URL) });
const chainId = await publicClient.getChainId();
const { hook: HOOK, poolId: POOL_ID, poolManager: POOL_MANAGER } = resolveTarget(chainId, env);

const account = privateKeyToAccount(KEEPER_PK);
const chain = { id: chainId, name: `chain-${chainId}`, nativeCurrency: { name: "ETH", symbol: "ETH", decimals: 18 }, rpcUrls: { default: { http: [RPC_URL] } } };
const walletClient = createWalletClient({ account, chain, transport: http(RPC_URL) });

const hook = { address: HOOK, abi: volFeeHookAbi };

// PoolManager stores pools at mapping slot 6; slot0 packs sqrtPriceX96 (160 bits) | tick (int24) | ...
const POOLS_SLOT = 6n;
const slot0Slot = keccak256(encodeAbiParameters([{ type: "bytes32" }, { type: "uint256" }], [POOL_ID, POOLS_SLOT]));

async function readTick() {
  const word = BigInt(
    await publicClient.readContract({ address: POOL_MANAGER, abi: poolManagerAbi, functionName: "extsload", args: [slot0Slot] }),
  );
  const raw = Number((word >> 160n) & 0xffffffn);
  return raw >= 0x800000 ? raw - 0x1000000 : raw;
}

async function onChainBounds() {
  const [keeper, minFee, maxFee] = await Promise.all(
    ["keeper", "minFee", "maxFee"].map((functionName) => publicClient.readContract({ ...hook, functionName })),
  );
  return { keeper, minFee: Number(minFee), maxFee: Number(maxFee) };
}

const log = (...a) => console.log(new Date().toISOString(), ...a);

async function main() {
  const { keeper } = await onChainBounds();
  if (keeper.toLowerCase() !== account.address.toLowerCase()) {
    throw new Error(`signer ${account.address} is not the hook keeper ${keeper}`);
  }
  log(`keeper ${account.address} | chain ${chainId} | hook ${HOOK}`);
  log(`pool ${POOL_ID} | every ${INTERVAL_MS}ms, window ${WINDOW}, model`, MODEL);

  const ticks = [];
  for (;;) {
    try {
      ticks.push(await readTick());
      if (ticks.length > WINDOW) ticks.shift();

      if (ticks.length >= MIN_SAMPLES) {
        // Bounds can change on-chain; clamp so setFee never reverts on FeeOutOfBounds.
        const { minFee, maxFee } = await onChainBounds();
        const target = Math.min(maxFee, Math.max(minFee, feeFromTicks(ticks, MODEL)));
        const state = await publicClient.readContract({ ...hook, functionName: "feeState", args: [POOL_ID] });
        const scheduled = Number(state.nextFee);

        if (Math.abs(target - scheduled) >= MIN_CHANGE) {
          const txHash = await walletClient.writeContract({ ...hook, functionName: "setFee", args: [POOL_ID, target] });
          const receipt = await publicClient.waitForTransactionReceipt({ hash: txHash });
          log(`tick ${ticks.at(-1)} | setFee ${scheduled} -> ${target} pips | live from block ${receipt.blockNumber + 1n} | ${receipt.status}`);
        } else {
          log(`tick ${ticks.at(-1)} | fee ${scheduled} pips (target ${target}, no write)`);
        }
      } else {
        log(`tick ${ticks.at(-1)} | warming up ${ticks.length}/${MIN_SAMPLES}`);
      }
    } catch (err) {
      log("error:", err.shortMessage ?? err.message);
    }
    await new Promise((r) => setTimeout(r, INTERVAL_MS));
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
