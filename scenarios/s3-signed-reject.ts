// S3: the PR is not merged by the deadline. A signed "not merged" taken after the deadline rejects the
// job and refunds the client, ahead of the 1 hour wait for claimRefund.
import { must, revertName, waitUntil, chainNow, writeRunLog, type Ctx } from "./lib/chain.js";
import { prRef } from "./lib/env.js";
import {
  BUDGET, balance, createJob, ensureClientFunds, evaluateAs, evaluateRequest, expectStatus, fund, registerTerms, status, submitAfterChecking,
} from "./lib/flow.js";
import { FALSE_WORD, TRUE_WORD, githubPrMerged } from "./lib/sources.js";
import { termsFor } from "./lib/terms.js";

export async function run(ctx: Ctx): Promise<void> {
  console.log("S3: not merged by the deadline: a signed reject refunds the client");
  await ensureClientFunds(ctx);
  const { owner, repo, pr } = prRef("GITHUB_OPEN_PR", ctx.mode === "live");
  const config = githubPrMerged(owner, repo, pr);
  const terms = termsFor(config, TRUE_WORD, { failValue: FALSE_WORD });

  const clientBefore = await balance(ctx, ctx.accounts.client.address);
  const { jobId, expiredAt } = await createJob(ctx, { evaluator: ctx.addr.evaluator, description: `merge ${owner}/${repo}#${pr} (stays open)` });
  await registerTerms(ctx, jobId, terms);
  await fund(ctx, jobId);
  await submitAfterChecking(ctx, { jobId, expiredAt, terms }, "evaluator");

  await waitUntil(ctx, expiredAt + 60n, "the deadline passes");
  const att = await ctx.attest.get({ config, quorum: 3, localValue: FALSE_WORD, localTimestampSeconds: expiredAt + 60n });
  must(att.payload.value === FALSE_WORD, 'the signed value is keccak256("false")');
  must(att.payload.timestamp / 1000n >= expiredAt, "the attestation was taken at or after the deadline");

  // A fail waits so that a pass taken in the last second keeps priority.
  must(
    (await revertName(ctx, "stranger", evaluateRequest(ctx, jobId, att))) === "FailNotYet",
    "a fail is refused until 30 minutes after the deadline (FailNotYet)",
  );

  await waitUntil(ctx, expiredAt + 30n * 60n, "the fail delay passes");
  must((await chainNow(ctx)) < expiredAt + 3600n, "claimRefund is still closed (the grace hour is running)");
  await evaluateAs(ctx, "stranger", jobId, att, "a third party submits the signed reject");

  expectStatus(await status(ctx, jobId), "Rejected");
  must((await balance(ctx, ctx.accounts.client.address)) === clientBefore, `the client was refunded the whole ${Number(BUDGET) / 1e6} USDC budget`);
  console.log(`  run log: ${writeRunLog(ctx, { jobId, expiredAt, rejectedBeforeClaimRefund: true })}`);
}
