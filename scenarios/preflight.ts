// Read-only checks before the live scenarios. Exits non-zero if any check fails.
//
//   RPC_URL=... tsx scenarios/preflight.ts [--predeploy] [--no-gateway] [--rounds]
//
//   --predeploy   only the checks that do not need the verifier or the contracts deployed yet
//   --no-gateway  skip the Molpha gateway (for a local anvil)
//   --rounds      also request real rounds (spends 2 rounds of quota): needs MOLPHA_KEYPAIR,
//                 PREFLIGHT_MERGED_PR and PREFLIGHT_OPEN_PR (owner/repo#n), and proves the nodes
//                 sign keccak256("true") for a merged PR and keccak256("false") for an open one
import { existsSync, readFileSync } from "node:fs";
import { createPublicClient, defineChain, http, type Address } from "viem";
import { MOLPHA_PROGRAM_ID } from "@molpha/sdk";
import { coreAbi, erc20Abi, evaluatorAbi, verifierAbi } from "./lib/abi.js";
import { envOr, requireEnv } from "./lib/chain.js";
import { gatewaySource } from "./lib/attest.js";
import { FALSE_WORD, TRUE_WORD, githubPrMerged } from "./lib/sources.js";

const args = new Set(process.argv.slice(2));
const predeploy = args.has("--predeploy");
const noGateway = args.has("--no-gateway");
const rounds = args.has("--rounds");

const CREATE2_PROXY: Address = "0x4e59b44847b379578588920cA78FbF26c0B4956C";
const BASE_SEPOLIA_USDC: Address = "0x036CbD53842c5426634e7929541eC2318f3dCF7e";
const CANONICAL_VERIFIER: Address = "0xA6e49A3A1caf3E110cC04765B934C8FF118C2568";
const PROTOCOL_ADMIN: Address = "0x6c6bCc50dDAA6884125e1060DCd6363F8866380A";

let failed = 0;
const ok = (m: string) => console.log(`  ok    ${m}`);
const info = (m: string) => console.log(`  info  ${m}`);
const fail = (m: string) => { failed++; console.log(`  FAIL  ${m}`); };
const check = (cond: boolean, pass: string, bad: string) => (cond ? ok(pass) : fail(bad));

async function main(): Promise<void> {
  const rpc = requireEnv("RPC_URL");
  const chainId = Number(envOr("CHAIN_ID", "84532"));
  const chain = defineChain({ id: chainId, name: "target", nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 }, rpcUrls: { default: { http: [rpc] } } });
  const pub = createPublicClient({ chain, transport: http(rpc) });

  console.log("chain");
  check((await pub.getChainId()) === chainId, `the RPC is chain ${chainId}`, `the RPC is not chain ${chainId}`);
  const hasCode = async (a: Address) => ((await pub.getCode({ address: a })) ?? "0x") !== "0x";
  check(await hasCode(CREATE2_PROXY), "the CREATE2 deployer proxy exists (the verifier deploys at its canonical address)", "no CREATE2 deployer proxy: the verifier script cannot deploy deterministically here");

  const usdc = chainId === 84532 ? BASE_SEPOLIA_USDC : (JSON.parse(readFileSync(envOr("DEPLOYMENTS", `deployments/${chainId}.json`), "utf8")).paymentToken as Address);
  if (await hasCode(usdc)) {
    const [symbol, decimals] = await Promise.all([
      pub.readContract({ address: usdc, abi: erc20Abi, functionName: "symbol" }),
      pub.readContract({ address: usdc, abi: erc20Abi, functionName: "decimals" }),
    ]);
    check(decimals === 6, `payment token ${symbol} has 6 decimals`, `payment token ${symbol} has ${decimals} decimals, the demo budget assumes 6`);
  } else fail(`no payment token at ${usdc}`);

  let gatewayRegistry: { version: number; nodeCount: number; redundancyBuffer: number } | undefined;
  if (!noGateway) {
    console.log("gateway");
    const gateway = envOr("MOLPHA_GATEWAY", "https://gateway.molpha.io/").replace(/\/$/, "");
    try {
      const infoRes = await fetch(`${gateway}/v1/info`);
      check(infoRes.ok, `${gateway}/v1/info answers`, `${gateway}/v1/info answered ${infoRes.status}`);
      // Every gateway answer is wrapped as { status, data }.
      const body = ((await infoRes.json()) as { data?: { programId?: string } }).data ?? {};
      check(body.programId === MOLPHA_PROGRAM_ID, `the gateway settles on the SDK's program ${MOLPHA_PROGRAM_ID}`, `the gateway reports program ${body.programId}, the SDK pins ${MOLPHA_PROGRAM_ID}`);
      const nodes = ((await (await fetch(`${gateway}/v1/nodes`)).json()) as { data?: { registry?: { version: number; nodeCount: number; redundancyBuffer: number } } }).data;
      gatewayRegistry = nodes?.registry;
      if (gatewayRegistry) ok(`registry v${gatewayRegistry.version}: ${gatewayRegistry.nodeCount} nodes, redundancy buffer ${gatewayRegistry.redundancyBuffer}`);
      else fail("the gateway could not read the registry");
    } catch (e) {
      fail(`gateway unreachable: ${(e as Error).message}`);
    }
    const rate = await fetch("https://api.github.com/rate_limit").then((r) => r.json() as Promise<{ resources?: { core?: { remaining: number; limit: number } } }>).catch(() => null);
    if (rate?.resources?.core) info(`GitHub unauthenticated limit from this machine: ${rate.resources.core.remaining}/${rate.resources.core.limit} (nodes use their own addresses)`);
  }

  if (!predeploy) {
    console.log("verifier and contracts");
    const path = envOr("DEPLOYMENTS", `deployments/${chainId}.json`);
    const dep = existsSync(path) ? (JSON.parse(readFileSync(path, "utf8")) as Record<string, Address>) : {};
    const verifier = dep.verifier ?? CANONICAL_VERIFIER;
    if (!(await hasCode(verifier))) {
      fail(`no verifier at ${verifier} on chain ${chainId}`);
    } else {
      const [version, total, buffer, owner] = await Promise.all([
        pub.readContract({ address: verifier, abi: verifierAbi, functionName: "getRegistryVersion" }),
        pub.readContract({ address: verifier, abi: verifierAbi, functionName: "getTotalNodes" }),
        pub.readContract({ address: verifier, abi: verifierAbi, functionName: "redundancyBuffer" }),
        pub.readContract({ address: verifier, abi: verifierAbi, functionName: "owner" }),
      ]);
      ok(`verifier ${verifier}: registry v${version}, ${total} nodes, buffer ${buffer}`);
      if (chainId === 84532) check(verifier.toLowerCase() === CANONICAL_VERIFIER.toLowerCase(), "the verifier is at the canonical address", `the verifier is at ${verifier}, not the canonical ${CANONICAL_VERIFIER}`);
      if (chainId === 84532) check(owner.toLowerCase() === PROTOCOL_ADMIN.toLowerCase(), "the verifier is owned by the Molpha protocol admin", `the verifier owner is ${owner}`);
      if (gatewayRegistry) {
        check(Number(version) === gatewayRegistry.version, "the verifier's registry version equals the gateway's (rounds will verify)", `the verifier is at registry v${version} but the gateway signs at v${gatewayRegistry.version}: replay the registry changes before the demo and freeze them`);
        check(Number(total) === gatewayRegistry.nodeCount, "the node counts match", `node count ${total} on chain, ${gatewayRegistry.nodeCount} at the gateway`);
        check(Number(buffer) === gatewayRegistry.redundancyBuffer, "the redundancy buffers match", `redundancy buffer ${buffer} on chain, ${gatewayRegistry.redundancyBuffer} at the gateway`);
      }
    }

    if (dep.core && dep.evaluator && dep.hook) {
      const evaluatorVerifier = await pub.readContract({ address: dep.evaluator, abi: evaluatorAbi, functionName: "VERIFIER" });
      check(evaluatorVerifier.toLowerCase() === verifier.toLowerCase(), "the evaluator trusts this verifier", `the evaluator trusts ${evaluatorVerifier}`);
      const [hookOk, tokenOk, fee] = await Promise.all([
        pub.readContract({ address: dep.core, abi: coreAbi, functionName: "whitelistedHooks", args: [dep.hook] }),
        pub.readContract({ address: dep.core, abi: coreAbi, functionName: "allowedPaymentTokens", args: [usdc] }),
        pub.readContract({ address: dep.core, abi: coreAbi, functionName: "evaluatorFeeBP" }),
      ]);
      check(hookOk, "the condition hook is whitelisted on the core", "the condition hook is NOT whitelisted on the core: the admin must call setHookWhitelist");
      check(tokenOk, "the payment token is allowlisted on the core", "the payment token is NOT allowlisted on the core");
      info(`evaluator fee ${fee} bp`);
    } else info(`no core/evaluator/hook in ${path} yet`);
  }

  if (rounds) {
    console.log("rounds (spends quota)");
    const merged = parsePr(requireEnv("PREFLIGHT_MERGED_PR"));
    const open = parsePr(requireEnv("PREFLIGHT_OPEN_PR"));
    const source = gatewaySource({ endpoint: envOr("MOLPHA_GATEWAY", "https://gateway.molpha.io/"), keypairPath: requireEnv("MOLPHA_KEYPAIR") });
    const a = await source.get({ config: githubPrMerged(merged.owner, merged.repo, merged.pr), quorum: 3 });
    check(a.payload.value === TRUE_WORD, `a merged PR signs keccak256("true")`, `a merged PR signed ${a.payload.value}: the nodes do not run the keccak256 transform yet`);
    const b = await source.get({ config: githubPrMerged(open.owner, open.repo, open.pr), quorum: 3 });
    check(b.payload.value === FALSE_WORD, `an open PR signs keccak256("false")`, `an open PR signed ${b.payload.value}`);
  }

  console.log(failed === 0 ? "\npreflight passed" : `\npreflight FAILED (${failed})`);
  process.exit(failed === 0 ? 0 : 1);
}

function parsePr(raw: string) {
  const m = raw.match(/^([A-Za-z0-9._-]+)\/([A-Za-z0-9._-]+)#(\d+)$/);
  if (!m) throw new Error(`expected owner/repo#number, got ${raw}`);
  return { owner: m[1]!, repo: m[2]!, pr: Number(m[3]) };
}

main().catch((e) => { console.error(e instanceof Error ? e.message : e); process.exit(1); });
