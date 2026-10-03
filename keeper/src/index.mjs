// Keeper: sample the pool tick on an interval, compute the fee off-chain, write it with setFee.
// The hook/plugin applies a write from the next block: every swap in block N pays feeFor() as read at block N.
// KEEPER_TARGET=v4 (default) drives the Uniswap v4 VolFeeHook; KEEPER_TARGET=algebra the Algebra KeeperFeePlugin.
import { createPublicClient, createWalletClient, http } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { createTarget } from "./target.mjs";
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
const account = privateKeyToAccount(KEEPER_PK);
const chain = { id: chainId, name: `chain-${chainId}`, nativeCurrency: { name: "ETH", symbol: "ETH", decimals: 18 }, rpcUrls: { default: { http: [RPC_URL] } } };
const walletClient = createWalletClient({ account, chain, transport: http(RPC_URL) });
const target = createTarget({ publicClient, walletClient, chainId, env });

const log = (...a) => console.log(new Date().toISOString(), ...a);

async function main() {
  await target.preflight?.();
  const { keeper } = await target.readConfig();
  if (keeper.toLowerCase() !== account.address.toLowerCase()) {
    throw new Error(`signer ${account.address} is not the keeper ${keeper}`);
  }
  log(`keeper ${account.address} | chain ${chainId} | ${target.describe}`);
  log(`every ${INTERVAL_MS}ms, window ${WINDOW}, model`, MODEL);

  const ticks = [];
  for (;;) {
    try {
      ticks.push(await target.readTick());
      if (ticks.length > WINDOW) ticks.shift();

      if (ticks.length >= MIN_SAMPLES) {
        // Bounds can change on-chain; clamp so setFee never reverts on FeeOutOfBounds.
        const { minFee, maxFee } = await target.readConfig();
        const fee = Math.min(maxFee, Math.max(minFee, feeFromTicks(ticks, MODEL)));
        const scheduled = await target.scheduledFee();

        if (Math.abs(fee - scheduled) >= MIN_CHANGE) {
          const receipt = await publicClient.waitForTransactionReceipt({ hash: await target.setFee(fee) });
          log(`tick ${ticks.at(-1)} | setFee ${scheduled} -> ${fee} pips | live from block ${receipt.blockNumber + 1n} | ${receipt.status}`);
        } else {
          log(`tick ${ticks.at(-1)} | fee ${scheduled} pips (target ${fee}, no write)`);
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
