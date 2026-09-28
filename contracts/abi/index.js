export { volFeeHookAbi, poolManagerAbi, deployments } from "./generated.js";
import { deployments } from "./generated.js";

/// Addresses written by the deploy scripts (contracts/deployments/<chainId>.json).
export function getDeployment(chainId) {
  const d = deployments[Number(chainId)];
  if (!d) throw new Error(`no deployment for chain ${chainId} (run a deploy script, then pnpm build)`);
  return d;
}
