// S4: evidence that must not settle a job. Each case is simulated (eth_call) and must revert with a
// named error; the job stays Submitted, and finally a good attestation still settles it.
import { chainNow, must, revertName, waitUntil, writeRunLog, type Ctx } from "./lib/chain.js";
import { dnsRef, prRef } from "./lib/env.js";
import {
  createJob, ensureClientFunds, evaluateAs, evaluateRequest, expectStatus, fund, githubMerged, registerTerms, status, submitAfterChecking, waitForFact,
} from "./lib/flow.js";
import { FALSE_WORD, TRUE_WORD, dnsTxt, githubPrMerged, DNS_PRESENT_WORD } from "./lib/sources.js";
import { termsFor } from "./lib/terms.js";

export async function run(ctx: Ctx): Promise<void> {
  console.log("S4: bad evidence is refused");
  await ensureClientFunds(ctx);
  const merged = prRef("GITHUB_PR", ctx.mode === "live");
  const open = prRef("GITHUB_OPEN_PR", ctx.mode === "live");
  const config = githubPrMerged(merged.owner, merged.repo, merged.pr);
  // The terms ask for 4 signatures; the evidence below is mostly signed by 3.
  const terms = termsFor(config, TRUE_WORD, { minSignatures: 4 });

  // Evidence taken BEFORE the job exists: it can never satisfy the window.
  await waitForFact(ctx, `${merged.owner}/${merged.repo}#${merged.pr} is merged`, "the PR must already be merged for this scenario", () => githubMerged(merged.owner, merged.repo, merged.pr));
  const beforeSubmission = await ctx.attest.get({ config, quorum: 4, localValue: TRUE_WORD });
  if (ctx.test) await waitUntil(ctx, (await chainNow(ctx)) + 30n, "time passes before the job is submitted");

  const { jobId, expiredAt } = await createJob(ctx, { evaluator: ctx.addr.evaluator, description: "bad evidence" });
  await registerTerms(ctx, jobId, terms);
  await fund(ctx, jobId);
  await submitAfterChecking(ctx, { jobId, expiredAt, terms }, "evaluator");

  const good = await ctx.attest.get({ config, quorum: 4, localValue: TRUE_WORD });
  const refused = async (label: string, att: typeof good, want: string) => {
    const got = await revertName(ctx, "stranger", evaluateRequest(ctx, jobId, att));
    must(got === want, `${label}: refused with ${got}`);
  };

  await refused("an attestation from before the work was submitted", beforeSubmission, "OutsideWindow");

  const tampered = { payload: good.payload, signature: { ...good.signature, signature: `0x${(BigInt(good.signature.signature) + 1n).toString(16).padStart(64, "0")}` as typeof good.signature.signature } };
  await refused("a tampered signature", tampered, "VerifyFailed");

  const forged = { payload: { ...good.payload, value: FALSE_WORD }, signature: good.signature };
  await refused("a signed value relabelled to another word", forged, "VerifyFailed");

  const thin = await ctx.attest.get({ config, quorum: 3, localValue: TRUE_WORD });
  await refused("a genuine attestation with fewer signatures than the terms ask for", thin, "ThresholdBelowPolicy");

  const other = ctx.mode === "live" ? dnsTxt(dnsRef(true).host, dnsRef(true).token) : dnsTxt("demo.molpha.example", "molpha-job=8183");
  const wrongSource = await ctx.attest.get({ config: other, quorum: 4, localValue: DNS_PRESENT_WORD }).catch(() => null);
  if (wrongSource) await refused("an attestation for a different source", wrongSource, "WrongSource");
  else console.log("  (skipped: the other source cannot be attested right now)");

  if (ctx.mode === "live") {
    const openConfig = githubPrMerged(open.owner, open.repo, open.pr);
    const notMerged = await ctx.attest.get({ config: openConfig, quorum: 4 });
    console.log(`  an open PR's genuine attestation has the other source id: ${notMerged.payload.sourceId === good.payload.sourceId ? "same (unexpected)" : "different"}`);
  } else {
    const wrongValue = await ctx.attest.get({ config, quorum: 4, localValue: FALSE_WORD });
    await refused('a genuine "not merged" where the terms have no fail word', wrongValue, "UnexpectedValue");
    const future = await ctx.attest.get({ config, quorum: 4, localValue: TRUE_WORD, localTimestampSeconds: (await chainNow(ctx)) + 3600n });
    await refused("an attestation dated an hour in the future", future, "FutureAttestation");
  }

  expectStatus(await status(ctx, jobId), "Submitted");
  await evaluateAs(ctx, "stranger", jobId, good, "the good attestation still settles the job");
  expectStatus(await status(ctx, jobId), "Completed");
  console.log(`  run log: ${writeRunLog(ctx, { jobId, expiredAt })}`);
}
