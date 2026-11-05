// S5: the condition hook. A quality judge (an EOA standing in for an AI model) cannot complete the job
// until a Molpha attestation shows the fact.
import { encodeAbiParameters } from "viem";
import { must, revertName, writeRunLog, type Ctx } from "./lib/chain.js";
import { prRef } from "./lib/env.js";
import { coreAbi, hookAbi } from "./lib/abi.js";
import {
  BUDGET, FEE_BP, balance, createJob, ensureClientFunds, expectStatus, fund, githubMerged, hookTermsParam, status, submitAfterChecking, waitForFact,
} from "./lib/flow.js";
import { send } from "./lib/chain.js";
import { TRUE_WORD, githubPrMerged } from "./lib/sources.js";
import { termsFor } from "./lib/terms.js";

export async function run(ctx: Ctx): Promise<void> {
  console.log("S5: the condition hook gates a quality judge");
  await ensureClientFunds(ctx);
  const { owner, repo, pr } = prRef("GITHUB_PR", ctx.mode === "live");
  const config = githubPrMerged(owner, repo, pr);
  const terms = termsFor(config, TRUE_WORD);

  const judge = ctx.accounts.judge.address;
  const { jobId, expiredAt } = await createJob(ctx, { evaluator: judge, hook: ctx.addr.hook, description: `quality + merged: ${owner}/${repo}#${pr}` });
  await fund(ctx, jobId, hookTermsParam(terms));
  await submitAfterChecking(ctx, { jobId, expiredAt, terms }, "hook");

  const complete = (optParams: `0x${string}`) =>
    ({ address: ctx.addr.core, abi: coreAbi, functionName: "complete", args: [jobId, `0x${"11".repeat(32)}`, optParams] }) as const;

  const without = await revertName(ctx, "judge", complete("0x"));
  must(without === "BadAttestation" || without === "NoTerms", `the judge cannot complete without an attestation: ${without}`);

  await waitForFact(ctx, `${owner}/${repo}#${pr} is merged`, `${owner}/${repo}#${pr} must be merged`, () => githubMerged(owner, repo, pr));
  const att = await ctx.attest.get({ config, quorum: 3, localValue: TRUE_WORD });
  const optParams = encodeAbiParameters(
    [{ type: "tuple", components: [
      { type: "tuple", name: "payload", components: [{ type: "bytes32", name: "value" }, { type: "bytes32", name: "sourceId" }, { type: "uint32", name: "registryVersion" }, { type: "uint8", name: "signaturesRequired" }, { type: "uint64", name: "timestamp" }] },
      { type: "tuple", name: "signature", components: [{ type: "bytes32", name: "signature" }, { type: "address", name: "commitment" }, { type: "uint256", name: "signersBitmap" }] },
    ] }],
    [att],
  );
  must((optParams.length - 2) / 2 === 256, "the attestation travels as 256 bytes in optParams");

  const providerBefore = await balance(ctx, ctx.accounts.provider.address);
  await send(ctx, "judge", "the judge completes with the attestation", complete(optParams));
  expectStatus(await status(ctx, jobId), "Completed");
  const fee = (BUDGET * FEE_BP) / 10_000n;
  must((await balance(ctx, ctx.accounts.provider.address)) - providerBefore === BUDGET - fee, "the provider was paid");
  must((await balance(ctx, judge)) >= fee, "the judge, not the hook, earned the evaluator fee");

  const frozen = await ctx.pub.readContract({ address: ctx.addr.hook, abi: hookAbi, functionName: "termsOf", args: [jobId] });
  console.log(`  run log: ${writeRunLog(ctx, { jobId, expiredAt, frozenSourceId: frozen.sourceId })}`);
}
