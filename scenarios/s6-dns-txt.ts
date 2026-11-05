// S6: a non-GitHub fact end to end: a DNS TXT record. This is build-gate scenario 6.
import { saveAttestation } from "./lib/attest.js";
import { must, writeRunLog, type Ctx } from "./lib/chain.js";
import { dnsRef } from "./lib/env.js";
import {
  BUDGET, FEE_BP, balance, createJob, dnsHasTxt, ensureClientFunds, evaluateAs, expectStatus, fund, isThirdParty, registerTerms, status, submitAfterChecking, waitForFact,
} from "./lib/flow.js";
import { DNS_PRESENT_WORD, dnsTxt } from "./lib/sources.js";
import { termsFor } from "./lib/terms.js";

export async function run(ctx: Ctx): Promise<void> {
  console.log("S6: a DNS TXT fact, finalized by a third party");
  await ensureClientFunds(ctx);
  const { host, token } = dnsRef(ctx.mode === "live");
  const config = dnsTxt(host, token);
  const terms = termsFor(config, DNS_PRESENT_WORD);

  const { jobId, expiredAt } = await createJob(ctx, { evaluator: ctx.addr.evaluator, description: `TXT ${token} on ${host}` });
  await registerTerms(ctx, jobId, terms);
  await fund(ctx, jobId);
  await submitAfterChecking(ctx, { jobId, expiredAt, terms }, "evaluator");

  await waitForFact(ctx, `${host} has the TXT record "${token}"`, `add TXT "${token}" to ${host} now (a resolver caches a missing record, so add it before the nodes first look)`, () => dnsHasTxt(host, token));
  const attestation = await ctx.attest.get({ config, quorum: 3, localValue: DNS_PRESENT_WORD });
  const file = `${ctx.mode === "live" ? "runs" : "runs/local"}/s6.attestation.json`;
  saveAttestation(file, attestation);
  must(attestation.payload.value === DNS_PRESENT_WORD, "the signed value is 16 (TXT): present");

  isThirdParty(ctx, "stranger");
  const providerBefore = await balance(ctx, ctx.accounts.provider.address);
  await evaluateAs(ctx, "stranger", jobId, attestation, "a third party calls evaluate");
  expectStatus(await status(ctx, jobId), "Completed");
  const fee = (BUDGET * FEE_BP) / 10_000n;
  must((await balance(ctx, ctx.accounts.provider.address)) - providerBefore === BUDGET - fee, "the provider was paid the budget less the evaluator fee");
  console.log(`  run log: ${writeRunLog(ctx, { jobId, expiredAt, attestationFile: file, sourceId: terms.sourceId })}`);
}
