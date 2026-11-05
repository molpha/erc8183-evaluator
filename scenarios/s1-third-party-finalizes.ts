// S1: a third party finalizes a GitHub "PR merged" job. This is build-gate scenario 1.
import { saveAttestation } from "./lib/attest.js";
import { must, writeRunLog, type Ctx } from "./lib/chain.js";
import { prRef } from "./lib/env.js";
import {
  BUDGET, FEE_BP, balance, createJob, ensureClientFunds, evaluateAs, expectStatus, fund, githubMerged, isThirdParty,
  registerTerms, status, submitAfterChecking, waitForFact,
} from "./lib/flow.js";
import { TRUE_WORD, githubPrMerged } from "./lib/sources.js";
import { termsFor } from "./lib/terms.js";

export async function run(ctx: Ctx): Promise<void> {
  console.log("S1: a third party finalizes a PR-merged job");
  await ensureClientFunds(ctx);
  const { owner, repo, pr } = prRef("GITHUB_PR", ctx.mode === "live");
  const config = githubPrMerged(owner, repo, pr);
  const terms = termsFor(config, TRUE_WORD);

  const { jobId, expiredAt } = await createJob(ctx, { evaluator: ctx.addr.evaluator, description: `merge ${owner}/${repo}#${pr}` });
  await registerTerms(ctx, jobId, terms);
  await fund(ctx, jobId);
  await submitAfterChecking(ctx, { jobId, expiredAt, terms }, "evaluator");

  await waitForFact(ctx, `${owner}/${repo}#${pr} is merged`, `merge ${owner}/${repo}#${pr} now (the job expires in ${ctx.expiryMinutes} min)`, () => githubMerged(owner, repo, pr));
  const attestation = await ctx.attest.get({ config, quorum: 3, localValue: TRUE_WORD });
  const file = `${ctx.mode === "live" ? "runs" : "runs/local"}/s1.attestation.json`;
  saveAttestation(file, attestation);
  must(attestation.payload.value === TRUE_WORD, 'the signed value is keccak256("true")');
  must(attestation.payload.signaturesRequired >= 3, `the attestation carries a threshold of ${attestation.payload.signaturesRequired} signatures`);

  isThirdParty(ctx, "stranger");
  const providerBefore = await balance(ctx, ctx.accounts.provider.address);
  const evaluatorBefore = await balance(ctx, ctx.addr.evaluator);
  await evaluateAs(ctx, "stranger", jobId, attestation, "a third party calls evaluate");

  expectStatus(await status(ctx, jobId), "Completed");
  const fee = (BUDGET * FEE_BP) / 10_000n;
  must((await balance(ctx, ctx.accounts.provider.address)) - providerBefore === BUDGET - fee, "the provider was paid the budget less the evaluator fee");
  must((await balance(ctx, ctx.addr.evaluator)) - evaluatorBefore === fee, "the evaluator contract accrued the evaluator fee");

  console.log(`  run log: ${writeRunLog(ctx, { jobId, expiredAt, attestationFile: file, sourceId: terms.sourceId })}`);
}
