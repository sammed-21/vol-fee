import { deployments } from "@vol-fee-hook/contracts";

/// Which hook/pool to act on. Each value comes from env if set, otherwise from
/// contracts/deployments/<chainId>.json, so exporting just HOOK doesn't hide the rest.
export function resolveTarget(chainId, env = process.env) {
  const d = deployments[Number(chainId)] ?? {};
  const target = {
    hook: env.HOOK ?? d.hook,
    poolId: env.POOL_ID ?? d.poolId,
    poolManager: env.POOL_MANAGER ?? d.poolManager,
  };
  const missing = Object.entries({ HOOK: target.hook, POOL_ID: target.poolId, POOL_MANAGER: target.poolManager })
    .filter(([, v]) => !v)
    .map(([k]) => k);
  if (missing.length) {
    throw new Error(
      `missing ${missing.join(", ")} for chain ${chainId}: set them in env, or deploy and run \`pnpm build\` ` +
        `so contracts/deployments/${chainId}.json is bundled`,
    );
  }
  return target;
}
