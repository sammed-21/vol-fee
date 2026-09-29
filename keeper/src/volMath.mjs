// Off-chain fee model the keeper runs. Nothing here touches the swap path.
//
//   ticks over a window -> variance of tick deltas -> fee = clamp(base + k * var, min, max)
//
// Fees are in pips (1e6 = 100%, 100 = 1 bp), matching VolFeeHook.setFee.
// One tick ~= 1 bp of price, so tick deltas are roughly bp returns per sample.

export const DEFAULTS = { base: 500, k: 50, min: 500, max: 10_000 };

export function variance(ticks) {
  console.log({ ticks });
  const d = ticks.slice(1).map((t, i) => t - ticks[i]);
  if (d.length < 2) return 0;
  const mean = d.reduce((a, b) => a + b, 0) / d.length;
  return d.reduce((a, x) => a + (x - mean) ** 2, 0) / (d.length - 1);
}

export function feeFromTicks(ticks, { base, k, min, max } = DEFAULTS) {
  const raw = base + k * variance(ticks);
  return Math.round(Math.min(max, Math.max(min, raw)));
}

// --- demo ------------------------------------------------------------------

function randomWalk(n, stepStd, seed) {
  let s = seed >>> 0;
  const rand = () => (s = (s * 1664525 + 1013904223) >>> 0) / 2 ** 32;
  const gauss = () => Math.sqrt(-2 * Math.log(rand() || 1e-12)) * Math.cos(2 * Math.PI * rand());
  const out = [-197_000]; // ~ETH/USDC-ish tick
  for (let i = 1; i < n; i++) out.push(out[i - 1] + Math.round(gauss() * stepStd));
  return out;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const bp = (pips) => (pips / 100).toFixed(1).padStart(6) + " bp";
  const scenarios = [
    ["calm    (±3 ticks/sample)", randomWalk(60, 3, 1)],
    ["normal  (±6 ticks/sample)", randomWalk(60, 6, 2)],
    ["choppy  (±12 ticks/sample)", randomWalk(60, 12, 3)],
    ["stress  (±30 ticks/sample)", randomWalk(60, 30, 4)],
  ];
  console.log(`model: fee = clamp(${DEFAULTS.base} + ${DEFAULTS.k}·var, ${DEFAULTS.min}, ${DEFAULTS.max}) pips\n`);
  for (const [name, ticks] of scenarios) {
    const v = variance(ticks);
    const fee = feeFromTicks(ticks);
    console.log(`${name}  var=${v.toFixed(1).padStart(7)}  fee=${String(fee).padStart(5)} pips =${bp(fee)}`);
  }
}
