// Chain adapters. The keeper loop and the fee model are venue-agnostic; each target knows how to
// read the tick, read keeper/bounds, read the scheduled fee, write a fee, and list charged fees.
//
//   KEEPER_TARGET=v4       Uniswap v4 VolFeeHook       (default)
//   KEEPER_TARGET=algebra  Algebra Integral v1.2.2 KeeperFeePlugin
//
// Addresses come from env if set, otherwise from contracts/deployments/<chainId>[.algebra].json.
import { encodeAbiParameters, keccak256, parseAbiItem } from "viem";
import {
  volFeeHookAbi,
  poolManagerAbi,
  keeperFeePluginAbi,
  keeperFeePluginFactoryAbi,
  algebraPoolAbi,
  deployments,
  algebraDeployments,
} from "@vol-fee-hook/contracts";

export function createTarget({ publicClient, walletClient, chainId, env = process.env }) {
  const kind = env.KEEPER_TARGET ?? "v4";
  if (kind === "v4") return v4Target({ publicClient, walletClient, chainId, env });
  if (kind === "algebra") return algebraTarget({ publicClient, walletClient, chainId, env });
  throw new Error(`unknown KEEPER_TARGET "${kind}" (v4 | algebra)`);
}

function requireAll(chainId, file, values) {
  const missing = Object.entries(values)
    .filter(([, v]) => !v)
    .map(([k]) => k);
  if (missing.length) {
    throw new Error(
      `missing ${missing.join(", ")} for chain ${chainId}: set them in env, or deploy and run \`pnpm build\` ` +
        `so contracts/deployments/${file} is bundled`,
    );
  }
}

const signedInt24 = (raw) => (raw >= 0x800000 ? raw - 0x1000000 : raw);

// ---------------------------------------------------------------------------
// Uniswap v4: VolFeeHook (one hook, many pools keyed by poolId)
// ---------------------------------------------------------------------------

function v4Target({ publicClient, walletClient, chainId, env }) {
  const d = deployments[Number(chainId)] ?? {};
  const HOOK = env.HOOK ?? d.hook;
  const POOL_ID = env.POOL_ID ?? d.poolId;
  const POOL_MANAGER = env.POOL_MANAGER ?? d.poolManager;
  requireAll(chainId, `${chainId}.json`, { HOOK, POOL_ID, POOL_MANAGER });

  const hook = { address: HOOK, abi: volFeeHookAbi };
  // PoolManager stores pools at mapping slot 6; slot0 packs sqrtPriceX96 (160 bits) | tick (int24) | ...
  const slot0Slot = keccak256(encodeAbiParameters([{ type: "bytes32" }, { type: "uint256" }], [POOL_ID, 6n]));
  const swapEvent = parseAbiItem(
    "event Swap(bytes32 indexed id, address indexed sender, int128 amount0, int128 amount1, uint160 sqrtPriceX96, uint128 liquidity, int24 tick, uint24 fee)",
  );

  return {
    kind: "v4",
    describe: `v4 hook ${HOOK} | pool ${POOL_ID}`,

    async readTick() {
      const word = BigInt(
        await publicClient.readContract({ address: POOL_MANAGER, abi: poolManagerAbi, functionName: "extsload", args: [slot0Slot] }),
      );
      return signedInt24(Number((word >> 160n) & 0xffffffn));
    },

    async readConfig() {
      const [keeper, minFee, maxFee] = await Promise.all(
        ["keeper", "minFee", "maxFee"].map((functionName) => publicClient.readContract({ ...hook, functionName })),
      );
      return { keeper, minFee: Number(minFee), maxFee: Number(maxFee) };
    },

    async scheduledFee() {
      const state = await publicClient.readContract({ ...hook, functionName: "feeState", args: [POOL_ID] });
      return Number(state.nextFee);
    },

    setFee: (fee) => walletClient.writeContract({ ...hook, functionName: "setFee", args: [POOL_ID, fee] }),

    /// Every swap's charged fee next to feeFor() at that block.
    async fills(fromBlock) {
      const logs = await publicClient.getLogs({ address: POOL_MANAGER, event: swapEvent, args: { id: POOL_ID }, fromBlock });
      return Promise.all(
        logs.map(async (l) => ({
          blockNumber: l.blockNumber,
          tick: l.args.tick,
          charged: l.args.fee,
          quoted: Number(
            await publicClient.readContract({ ...hook, functionName: "feeFor", args: [POOL_ID], blockNumber: l.blockNumber }),
          ),
        })),
      );
    },
  };
}

// ---------------------------------------------------------------------------
// Algebra Integral v1.2.2: KeeperFeePlugin (one plugin per pool, config in the plugin factory)
// ---------------------------------------------------------------------------

function algebraTarget({ publicClient, walletClient, chainId, env }) {
  const d = algebraDeployments[Number(chainId)] ?? {};
  const POOL = env.ALGEBRA_POOL ?? d.pool;
  const PLUGIN = env.ALGEBRA_PLUGIN ?? d.plugin;
  requireAll(chainId, `${chainId}.algebra.json`, { ALGEBRA_POOL: POOL, ALGEBRA_PLUGIN: PLUGIN });

  const plugin = { address: PLUGIN, abi: keeperFeePluginAbi };
  const pool = { address: POOL, abi: algebraPoolAbi };
  let factoryAddress; // plugin.factory(), resolved once
  const factory = async () => {
    factoryAddress ??= await publicClient.readContract({ ...plugin, functionName: "factory" });
    return { address: factoryAddress, abi: keeperFeePluginFactoryAbi };
  };
  const swapFeeEvent = parseAbiItem("event SwapFee(address indexed sender, uint24 overrideFee, uint24 pluginFee)");
  const swapEvent = parseAbiItem(
    "event Swap(address indexed sender, address indexed recipient, int256 amount0, int256 amount1, uint160 price, uint128 liquidity, int24 tick)",
  );

  return {
    kind: "algebra",
    describe: `algebra pool ${POOL} | plugin ${PLUGIN}`,

    /// Refuse to run against a pool whose plugin isn't ours (e.g. Nami's own plugin).
    async preflight() {
      const attached = await publicClient.readContract({ ...pool, functionName: "plugin" });
      if (attached.toLowerCase() !== PLUGIN.toLowerCase()) {
        throw new Error(`pool ${POOL} uses plugin ${attached}, not KeeperFeePlugin ${PLUGIN}`);
      }
    },

    async readTick() {
      const [, tick] = await publicClient.readContract({ ...pool, functionName: "globalState" });
      return Number(tick);
    },

    async readConfig() {
      const f = await factory();
      const [keeper, [minFee, maxFee]] = await Promise.all([
        publicClient.readContract({ ...f, functionName: "keeper" }),
        publicClient.readContract({ ...f, functionName: "bounds" }),
      ]);
      return { keeper, minFee: Number(minFee), maxFee: Number(maxFee) };
    },

    async scheduledFee() {
      const state = await publicClient.readContract({ ...plugin, functionName: "feeState" });
      return Number(state.nextFee);
    },

    setFee: (fee) => walletClient.writeContract({ ...plugin, functionName: "setFee", args: [fee] }),

    /// Every swap's overrideFee (from the pool's SwapFee event) next to plugin.feeFor() at that block.
    async fills(fromBlock) {
      const [fees, swaps] = await Promise.all([
        publicClient.getLogs({ address: POOL, event: swapFeeEvent, fromBlock }),
        publicClient.getLogs({ address: POOL, event: swapEvent, fromBlock }),
      ]);
      // The pool emits SwapFee immediately before its Swap.
      const tickAt = new Map(swaps.map((s) => [`${s.transactionHash}:${s.logIndex}`, s.args.tick]));
      return Promise.all(
        fees.map(async (l) => ({
          blockNumber: l.blockNumber,
          tick: tickAt.get(`${l.transactionHash}:${l.logIndex + 1}`),
          charged: l.args.overrideFee + l.args.pluginFee,
          quoted: Number(await publicClient.readContract({ ...plugin, functionName: "feeFor", blockNumber: l.blockNumber })),
        })),
      );
    },
  };
}
