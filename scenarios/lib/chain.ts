// Clients, accounts and time for the scenario scripts, in two modes:
//   local: a loopback anvil, accounts from anvil's public test mnemonic, time moved by cheatcodes.
//   live:  Base Sepolia, keys from the environment (never printed), time is the wall clock.
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";
import {
  BaseError,
  ContractFunctionRevertedError,
  createPublicClient,
  createTestClient,
  createWalletClient,
  defineChain,
  http,
  type Abi,
  type Address,
  type Chain,
  type Hex,
  type PublicClient,
  type TestClient,
  type TransactionReceipt,
  type WalletClient,
} from "viem";
import { mnemonicToAccount, privateKeyToAccount, type PrivateKeyAccount, type HDAccount } from "viem/accounts";
import type { AttestationSource } from "./attest.js";
import { evaluatorAbi, hookAbi } from "./abi.js";

export type Mode = "local" | "live";
export type Role = "deployer" | "client" | "provider" | "stranger" | "judge";

export interface Addresses {
  core: Address;
  evaluator: Address;
  hook: Address;
  verifier: Address;
  paymentToken: Address;
  proofVerifier?: Address;
}

export interface RunStep {
  step: string;
  tx?: Hex;
  gasUsed?: string;
  note?: string;
}

export interface Ctx {
  mode: Mode;
  chain: Chain;
  pub: PublicClient;
  test: TestClient | null;
  wallets: Record<Role, WalletClient>;
  accounts: Record<Role, PrivateKeyAccount | HDAccount>;
  addr: Addresses;
  attest: AttestationSource;
  /** Minutes a job's window runs: long enough for a live demo, shorter locally is irrelevant. */
  expiryMinutes: number;
  steps: RunStep[];
  scenario: string;
}

const ANVIL_MNEMONIC = "test test test test test test test test test test test junk";
const LOCAL_INDEX: Record<Role, number> = { deployer: 0, client: 1, provider: 2, stranger: 3, judge: 4 };

export function envOr(name: string, fallback: string): string {
  return process.env[name] && process.env[name] !== "" ? (process.env[name] as string) : fallback;
}

export function requireEnv(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`set ${name}`);
  return value;
}

export function parseMode(argv: string[]): Mode {
  if (argv.includes("--live")) return "live";
  if (argv.includes("--local") || process.env.LOCAL === "1") return "local";
  throw new Error("pass --local (anvil dry run) or --live (Base Sepolia)");
}

export function loadAddresses(chainId: number): Addresses {
  const path = envOr("DEPLOYMENTS", `deployments/${chainId}.json`);
  if (!existsSync(path)) throw new Error(`no ${path}: deploy first (see README)`);
  const d = JSON.parse(readFileSync(path, "utf8")) as Record<string, Address>;
  for (const k of ["core", "evaluator", "hook", "verifier", "paymentToken"]) {
    if (!d[k]) throw new Error(`${path} has no "${k}"`);
  }
  return {
    core: d.core!,
    evaluator: d.evaluator!,
    hook: d.hook!,
    verifier: d.verifier!,
    paymentToken: d.paymentToken!,
    proofVerifier: d.proofVerifier,
  };
}

export async function makeCtx(mode: Mode, scenario: string, attest: AttestationSource): Promise<Ctx> {
  const chainId = Number(envOr("CHAIN_ID", mode === "local" ? "31337" : "84532"));
  const rpc = mode === "local" ? envOr("RPC_URL", "http://127.0.0.1:18545") : requireEnv("RPC_URL");
  const chain = defineChain({
    id: chainId,
    name: mode === "local" ? "anvil" : "base-sepolia",
    nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
    rpcUrls: { default: { http: [rpc] } },
  });
  const transport = http(rpc);
  const pub = createPublicClient({ chain, transport });

  const accounts = {} as Ctx["accounts"];
  const wallets = {} as Ctx["wallets"];
  for (const role of Object.keys(LOCAL_INDEX) as Role[]) {
    const account =
      mode === "local"
        ? mnemonicToAccount(ANVIL_MNEMONIC, { addressIndex: LOCAL_INDEX[role] })
        : privateKeyToAccount(requireEnv(`${role.toUpperCase()}_KEY`) as Hex);
    accounts[role] = account;
    wallets[role] = createWalletClient({ account, chain, transport });
  }
  if (mode === "live") {
    const seen = new Set<string>();
    for (const role of ["client", "provider", "stranger", "judge"] as Role[]) {
      const a = accounts[role].address.toLowerCase();
      if (seen.has(a)) throw new Error(`${role} reuses another role's key: the scenarios need distinct wallets`);
      seen.add(a);
    }
  }

  return {
    mode,
    chain,
    pub,
    test: mode === "local" ? createTestClient({ chain, transport, mode: "anvil" }) : null,
    wallets,
    accounts,
    addr: loadAddresses(chainId),
    attest,
    expiryMinutes: Number(envOr("EXPIRY_MINUTES", mode === "local" ? "120" : "30")),
    steps: [],
    scenario,
  };
}

// ------------------------------------------------------------------ time

/** The chain's clock: the timestamp of the latest block. All contract timing is judged on it. */
export async function chainNow(ctx: Ctx): Promise<bigint> {
  const block = await ctx.pub.getBlock();
  return block.timestamp;
}

/**
 * Bring the chain clock to `target` (unix seconds). Locally that is a cheatcode; live it is
 * waiting, with a progress line, because Base Sepolia time is wall time.
 */
export async function waitUntil(ctx: Ctx, target: bigint, why: string): Promise<void> {
  if (ctx.test) {
    const now = await chainNow(ctx);
    if (target > now) {
      await ctx.test.setNextBlockTimestamp({ timestamp: target });
      await ctx.test.mine({ blocks: 1 });
    }
    return;
  }
  for (;;) {
    const now = await chainNow(ctx);
    if (now >= target) return;
    const left = Number(target - now);
    console.log(`  waiting ${Math.ceil(left / 60)} min (${why})`);
    await new Promise((r) => setTimeout(r, Math.min(left, 60) * 1000));
  }
}

// ------------------------------------------------------------------ transactions

export async function send(
  ctx: Ctx,
  role: Role,
  step: string,
  req: { address: Address; abi: Abi; functionName: string; args?: readonly unknown[] },
): Promise<TransactionReceipt> {
  const { request } = await ctx.pub.simulateContract({ ...req, account: ctx.accounts[role] } as never);
  const hash = await ctx.wallets[role].writeContract(request as never);
  const receipt = await ctx.pub.waitForTransactionReceipt({ hash });
  if (receipt.status !== "success") throw new Error(`${step}: transaction reverted (${hash})`);
  record(ctx, { step, tx: hash, gasUsed: receipt.gasUsed.toString() });
  console.log(`  ${step}  [${role}]  ${hash}  gas ${receipt.gasUsed}`);
  return receipt;
}

export function record(ctx: Ctx, step: RunStep): void {
  ctx.steps.push(step);
}

/**
 * Simulate a call that must revert and return the custom error's name, so a refusal is shown as
 * "UnexpectedValue" and not as a hex blob. Throws if the call would succeed.
 */
export async function revertName(
  ctx: Ctx,
  role: Role,
  req: { address: Address; abi: Abi; functionName: string; args?: readonly unknown[] },
): Promise<string> {
  // A hook's or the evaluator's custom error can surface through the core, so decode with theirs too.
  const errors = [...evaluatorAbi, ...hookAbi].filter((x) => x.type === "error");
  const abi = [...req.abi, ...errors] as Abi;
  try {
    await ctx.pub.simulateContract({ ...req, abi, account: ctx.accounts[role] } as never);
  } catch (e) {
    if (e instanceof BaseError) {
      const reverted = e.walk((x) => x instanceof ContractFunctionRevertedError);
      if (reverted instanceof ContractFunctionRevertedError) return reverted.data?.errorName ?? reverted.reason ?? "revert";
    }
    throw e;
  }
  throw new Error(`${req.functionName} was expected to revert but would succeed`);
}

// ------------------------------------------------------------------ run log

export function writeRunLog(ctx: Ctx, result: Record<string, unknown>): string {
  const dir = ctx.mode === "live" ? "runs" : "runs/local";
  const path = `${dir}/${ctx.scenario}.json`;
  mkdirSync(dirname(path), { recursive: true });
  const log = { scenario: ctx.scenario, mode: ctx.mode, chainId: ctx.chain.id, addresses: ctx.addr, result, steps: ctx.steps };
  writeFileSync(path, JSON.stringify(log, (_k, v) => (typeof v === "bigint" ? v.toString() : v), 2));
  return path;
}

export function must(cond: unknown, message: string): asserts cond {
  if (!cond) throw new Error(`CHECK FAILED: ${message}`);
  console.log(`  ok  ${message}`);
}
