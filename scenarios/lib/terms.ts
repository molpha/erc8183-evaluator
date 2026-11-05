import type { Address, Hex, PublicClient } from "viem";
import { evaluatorAbi, hookAbi } from "./abi.js";
import { canonicalJson, sourceIdOf } from "./sources.js";
import type { APIConfig } from "@molpha/sdk";

/** What a client and a provider agreed a job settles on. */
export interface Terms {
  sourceConfig: string;
  sourceId: Hex;
  passValue: Hex;
  failValue: Hex | null;
  minSignatures: number;
}

export const MIN_SIGNATURES_FLOOR = 3;

export function termsFor(config: APIConfig, passValue: Hex, opts: { failValue?: Hex; minSignatures?: number } = {}): Terms {
  return {
    sourceConfig: canonicalJson(config),
    sourceId: sourceIdOf(config),
    passValue,
    failValue: opts.failValue ?? null,
    minSignatures: opts.minSignatures ?? MIN_SIGNATURES_FLOOR,
  };
}

/**
 * The provider's check before doing any work: read the frozen terms off the evaluator and compare
 * them with what was agreed off-chain. It recomputes the source id from the config text itself, so
 * the source the contract will accept is exactly the one agreed, not merely one with the same id.
 *
 * Throws with every difference found.
 */
export async function checkTerms(
  client: PublicClient,
  evaluator: Address,
  core: Address,
  jobId: bigint,
  expected: Terms,
): Promise<void> {
  const onChain = await client.readContract({
    address: evaluator,
    abi: evaluatorAbi,
    functionName: "termsOf",
    args: [core, jobId],
  });
  const problems: string[] = [];
  if (!onChain.set) problems.push("no terms are registered for this job");
  else {
    if (onChain.sourceId.toLowerCase() !== expected.sourceId.toLowerCase())
      problems.push(`source id ${onChain.sourceId} is not the agreed ${expected.sourceId}`);
    if (onChain.passValue.toLowerCase() !== expected.passValue.toLowerCase())
      problems.push(`pass word ${onChain.passValue} is not the agreed ${expected.passValue}`);
    if (onChain.minSignatures < expected.minSignatures)
      problems.push(`threshold ${onChain.minSignatures} is below the agreed ${expected.minSignatures}`);
    const hasFail = expected.failValue !== null;
    if (onChain.hasFail !== hasFail) problems.push(`fail terms: on chain ${onChain.hasFail}, agreed ${hasFail}`);
    else if (hasFail && onChain.failValue.toLowerCase() !== expected.failValue!.toLowerCase())
      problems.push(`fail word ${onChain.failValue} is not the agreed ${expected.failValue}`);
  }

  // The config text itself is in the TermsRegistered event, not in storage.
  const logs = await client.getContractEvents({
    address: evaluator,
    abi: evaluatorAbi,
    eventName: "TermsRegistered",
    args: { core, jobId },
    fromBlock: 0n,
  });
  const logged = logs.at(-1)?.args.sourceConfig;
  if (logged === undefined) problems.push("no TermsRegistered event found to read the source config from");
  else if (logged !== expected.sourceConfig) problems.push("the logged source config text differs from the agreed one");

  if (problems.length > 0) throw new Error(`terms do not match what was agreed:\n - ${problems.join("\n - ")}`);
}

/**
 * The same check for a job gated by the condition hook, whose terms the client froze at `fund`:
 * source id, pass word, threshold, and the config text from the `TermsFrozen` event.
 *
 * Throws with every difference found.
 */
export async function checkHookTerms(client: PublicClient, hook: Address, jobId: bigint, expected: Terms): Promise<void> {
  const onChain = await client.readContract({ address: hook, abi: hookAbi, functionName: "termsOf", args: [jobId] });
  const problems: string[] = [];
  if (!onChain.set) problems.push("no terms are frozen for this job");
  else {
    if (onChain.sourceId.toLowerCase() !== expected.sourceId.toLowerCase())
      problems.push(`source id ${onChain.sourceId} is not the agreed ${expected.sourceId}`);
    if (onChain.passValue.toLowerCase() !== expected.passValue.toLowerCase())
      problems.push(`pass word ${onChain.passValue} is not the agreed ${expected.passValue}`);
    if (onChain.minSignatures < expected.minSignatures)
      problems.push(`threshold ${onChain.minSignatures} is below the agreed ${expected.minSignatures}`);
  }

  const logs = await client.getContractEvents({ address: hook, abi: hookAbi, eventName: "TermsFrozen", args: { jobId }, fromBlock: 0n });
  const logged = logs.at(-1)?.args.sourceConfig;
  if (logged === undefined) problems.push("no TermsFrozen event found to read the source config from");
  else if (logged !== expected.sourceConfig) problems.push("the logged source config text differs from the agreed one");

  if (problems.length > 0) throw new Error(`hook terms do not match what was agreed:\n - ${problems.join("\n - ")}`);
}
