// The steps every scenario repeats: open a job, fund it, submit work, read state.
import { encodeAbiParameters, keccak256, parseEventLogs, stringToBytes, zeroAddress, type Address, type Hex } from "viem";
import { coreAbi, erc20Abi, evaluatorAbi, JobStatus } from "./abi.js";
import { chainNow, envOr, must, send, type Ctx } from "./chain.js";
import type { EvmAttestation } from "./attest.js";
import { checkHookTerms, checkTerms, type Terms } from "./terms.js";

export const BUDGET = BigInt(Math.round(Number(envOr("BUDGET_USDC", "1")) * 1e6));
export const FEE_BP = 50n;

export interface Job {
  jobId: bigint;
  expiredAt: bigint;
  terms: Terms;
}

/** Local runs mint mock USDC to the client; live runs expect the client wallet funded from a faucet. */
export async function ensureClientFunds(ctx: Ctx): Promise<void> {
  const token = ctx.addr.paymentToken;
  const balance = await ctx.pub.readContract({ address: token, abi: erc20Abi, functionName: "balanceOf", args: [ctx.accounts.client.address] });
  if (balance >= BUDGET * 6n) return;
  if (ctx.mode === "local") {
    await send(ctx, "deployer", "mint mock USDC to the client", { address: token, abi: erc20Abi, functionName: "mint", args: [ctx.accounts.client.address, BUDGET * 20n] });
    return;
  }
  throw new Error(`the client wallet ${ctx.accounts.client.address} needs about ${Number(BUDGET * 6n) / 1e6} USDC (Base Sepolia faucet)`);
}

export async function createJob(ctx: Ctx, opts: { evaluator: Address; hook?: Address; description: string }): Promise<{ jobId: bigint; expiredAt: bigint }> {
  const expiredAt = (await chainNow(ctx)) + BigInt(ctx.expiryMinutes) * 60n;
  const receipt = await send(ctx, "client", "client creates the job", {
    address: ctx.addr.core,
    abi: coreAbi,
    functionName: "createJob",
    args: [ctx.accounts.provider.address, opts.evaluator, Number(expiredAt), opts.description, opts.hook ?? zeroAddress, 0n],
  });
  const [created] = parseEventLogs({ abi: coreAbi, eventName: "JobCreated", logs: receipt.logs });
  if (!created) throw new Error("no JobCreated event");
  return { jobId: created.args.jobId, expiredAt };
}

export async function registerTerms(ctx: Ctx, jobId: bigint, terms: Terms): Promise<void> {
  await send(ctx, "client", "client freezes the terms on the evaluator", {
    address: ctx.addr.evaluator,
    abi: evaluatorAbi,
    functionName: "registerTerms",
    args: [ctx.addr.core, jobId, terms.sourceConfig, terms.passValue, terms.failValue ?? (`0x${"00".repeat(32)}` as Hex), terms.failValue !== null, terms.minSignatures],
  });
}

/** Provider sets the budget, client approves and funds. `optParams` carries hook terms, if any. */
export async function fund(ctx: Ctx, jobId: bigint, optParams: Hex = "0x"): Promise<void> {
  await send(ctx, "provider", "provider sets the budget", {
    address: ctx.addr.core, abi: coreAbi, functionName: "setBudget", args: [jobId, ctx.addr.paymentToken, BUDGET, "0x"],
  });
  await send(ctx, "client", "client approves the core", {
    address: ctx.addr.paymentToken, abi: erc20Abi, functionName: "approve", args: [ctx.addr.core, BUDGET],
  });
  await send(ctx, "client", "client funds the job", {
    address: ctx.addr.core, abi: coreAbi, functionName: "fund", args: [jobId, ctx.addr.paymentToken, BUDGET, optParams],
  });
}

export function hookTermsParam(terms: Terms): Hex {
  return encodeAbiParameters([{ type: "string" }, { type: "bytes32" }, { type: "uint8" }], [terms.sourceConfig, terms.passValue, terms.minSignatures]);
}

/** The provider reads the frozen terms back and compares them with what was agreed, then submits. */
export async function submitAfterChecking(ctx: Ctx, job: Job, via: "evaluator" | "hook"): Promise<void> {
  if (via === "evaluator") {
    await checkTerms(ctx.pub, ctx.addr.evaluator, ctx.addr.core, job.jobId, job.terms);
  } else {
    await checkHookTerms(ctx.pub, ctx.addr.hook, job.jobId, job.terms);
  }
  console.log("  provider checked the frozen terms against the agreement");
  await send(ctx, "provider", "provider submits the work", {
    address: ctx.addr.core, abi: coreAbi, functionName: "submit", args: [job.jobId, keccak256(stringToBytes(`work for job ${job.jobId}`)), "0x"],
  });
}

export async function jobOf(ctx: Ctx, jobId: bigint) {
  return ctx.pub.readContract({ address: ctx.addr.core, abi: coreAbi, functionName: "getJob", args: [jobId] });
}

export async function status(ctx: Ctx, jobId: bigint): Promise<number> {
  return (await jobOf(ctx, jobId)).status;
}

export async function balance(ctx: Ctx, who: Address): Promise<bigint> {
  return ctx.pub.readContract({ address: ctx.addr.paymentToken, abi: erc20Abi, functionName: "balanceOf", args: [who] });
}

export function evaluateRequest(ctx: Ctx, jobId: bigint, att: EvmAttestation) {
  return { address: ctx.addr.evaluator, abi: evaluatorAbi, functionName: "evaluate", args: [ctx.addr.core, jobId, att] } as const;
}

export async function evaluateAs(ctx: Ctx, who: "stranger" | "judge" | "client" | "provider", jobId: bigint, att: EvmAttestation, label: string) {
  return send(ctx, who, label, evaluateRequest(ctx, jobId, att));
}

export function expectStatus(actual: number, want: keyof typeof JobStatus): void {
  must(actual === JobStatus[want], `job status is ${want}`);
}

export function isThirdParty(ctx: Ctx, who: "stranger"): void {
  const a = ctx.accounts[who].address.toLowerCase();
  const others = [ctx.accounts.client, ctx.accounts.provider, ctx.accounts.judge, ctx.accounts.deployer].map((x) => x.address.toLowerCase());
  must(!others.includes(a), "the finalizer is not the client, the provider or the evaluator's owner");
}

// ------------------------------------------------------------------ is the fact true yet? (live)

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/** Poll until `check` is true. Local runs skip it: the simulated oracle simply signs. */
export async function waitForFact(ctx: Ctx, what: string, hint: string, check: () => Promise<boolean>, timeoutMin = 30): Promise<void> {
  if (ctx.mode === "local") return;
  console.log(`  ${hint}`);
  const deadline = Date.now() + timeoutMin * 60_000;
  while (Date.now() < deadline) {
    if (await check()) {
      console.log(`  fact observed: ${what}`);
      return;
    }
    await sleep(60_000);
  }
  throw new Error(`timed out waiting for: ${what}`);
}

export async function githubMerged(owner: string, repo: string, pr: number): Promise<boolean> {
  const res = await fetch(`https://api.github.com/repos/${owner}/${repo}/pulls/${pr}`, { headers: { Accept: "application/vnd.github+json" } });
  if (!res.ok) throw new Error(`GitHub answered ${res.status}`);
  return ((await res.json()) as { merged?: boolean }).merged === true;
}

export async function dnsHasTxt(host: string, token: string): Promise<boolean> {
  const res = await fetch(`https://cloudflare-dns.com/dns-query?name=${host}&type=TXT`, { headers: { Accept: "application/dns-json" } });
  if (!res.ok) throw new Error(`Cloudflare answered ${res.status}`);
  const body = (await res.json()) as { Answer?: { data?: string }[] };
  return (body.Answer ?? []).some((a) => a.data === `"${token}"`);
}
