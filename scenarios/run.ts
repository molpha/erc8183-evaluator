// Run one scenario (or all): `tsx scenarios/run.ts s1 --local`   or   `tsx scenarios/run.ts s1 --live`
import { chainNow, envOr, makeCtx, parseMode, requireEnv, type Ctx, type Mode } from "./lib/chain.js";
import { gatewaySource, localSignerSource, offlineSource, type AttestationSource } from "./lib/attest.js";
import type { Address } from "viem";

const SCENARIOS: Record<string, () => Promise<{ run(ctx: Ctx): Promise<void> }>> = {
  s1: () => import("./s1-third-party-finalizes.js"),
  s2: () => import("./s2-evaluator-offline.js"),
  s3: () => import("./s3-signed-reject.js"),
  s4: () => import("./s4-bad-evidence.js"),
  s5: () => import("./s5-condition-hook.js"),
  s6: () => import("./s6-dns-txt.js"),
};

async function main(): Promise<void> {
  const argv = process.argv.slice(2);
  const mode: Mode = parseMode(argv);
  const names = argv.filter((a) => !a.startsWith("--"));
  const chosen = names.includes("all") || names.length === 0 ? Object.keys(SCENARIOS) : names;
  for (const n of chosen) if (!SCENARIOS[n]) throw new Error(`unknown scenario ${n}; use ${Object.keys(SCENARIOS).join(", ")} or all`);

  for (const name of chosen) {
    const ctx = await makeCtx(mode, name, offlineSource);
    ctx.attest =
      mode === "live"
        ? gatewaySource({ endpoint: envOr("MOLPHA_GATEWAY", "https://gateway.molpha.io/"), keypairPath: requireEnv("MOLPHA_KEYPAIR") })
        : (localSignerSource(ctx.pub, requireEnv("LOCAL_SIGNER") as Address, () => chainNow(ctx)) as AttestationSource);
    console.log(`\n=== ${name} (${mode}, chain ${ctx.chain.id}) ===`);
    await (await SCENARIOS[name]!()).run(ctx);
  }
  console.log("\nall requested scenarios passed");
}

main().catch((e) => {
  console.error(e instanceof Error ? e.message : e);
  process.exit(1);
});
