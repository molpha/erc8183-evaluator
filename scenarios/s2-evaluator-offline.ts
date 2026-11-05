// S2: the attestation is taken inside the window; Molpha is then unreachable and the deadline passes.
// Anyone finalizes from the saved file during the grace hour.
import { loadAttestation, offlineSource, saveAttestation } from "./lib/attest.js";
import { chainNow, must, waitUntil, writeRunLog, type Ctx } from "./lib/chain.js";
import { prRef } from "./lib/env.js";
import {
  createJob, ensureClientFunds, evaluateAs, expectStatus, fund, githubMerged, registerTerms, status, submitAfterChecking, waitForFact,
} from "./lib/flow.js";
import { TRUE_WORD, githubPrMerged } from "./lib/sources.js";
import { termsFor } from "./lib/terms.js";

export async function run(ctx: Ctx): Promise<void> {
  console.log("S2: the evaluator service is offline; a third party finalizes from a saved attestation");
  await ensureClientFunds(ctx);
  const { owner, repo, pr } = prRef("GITHUB_PR", ctx.mode === "live");
  const config = githubPrMerged(owner, repo, pr);
  const terms = termsFor(config, TRUE_WORD);

  const { jobId, expiredAt } = await createJob(ctx, { evaluator: ctx.addr.evaluator, description: `merge ${owner}/${repo}#${pr} (offline)` });
  await registerTerms(ctx, jobId, terms);
  await fund(ctx, jobId);
  await submitAfterChecking(ctx, { jobId, expiredAt, terms }, "evaluator");

  await waitForFact(ctx, `${owner}/${repo}#${pr} is merged`, `${owner}/${repo}#${pr} must be merged`, () => githubMerged(owner, repo, pr));
  const taken = await ctx.attest.get({ config, quorum: 3, localValue: TRUE_WORD });
  const file = `${ctx.mode === "live" ? "runs" : "runs/local"}/s2.attestation.json`;
  saveAttestation(file, taken);
  must(taken.payload.timestamp / 1000n < expiredAt, "the attestation was taken inside the job window");

  // From here on nothing may call Molpha.
  ctx.attest = offlineSource;
  await waitUntil(ctx, expiredAt + 60n, "the job deadline passes");
  must((await chainNow(ctx)) >= expiredAt, "the deadline has passed");
  must((await chainNow(ctx)) < expiredAt + 3600n, "claimRefund is still closed: the evaluation grace hour is running");
  expectStatus(await status(ctx, jobId), "Submitted");

  const saved = loadAttestation(file);
  await evaluateAs(ctx, "stranger", jobId, saved, "a third party finalizes from the saved file");
  expectStatus(await status(ctx, jobId), "Completed");
  console.log(`  run log: ${writeRunLog(ctx, { jobId, expiredAt, attestationFile: file, finalizedAfterDeadline: true })}`);
}
