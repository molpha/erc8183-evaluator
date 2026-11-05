// The Molpha sources the demo jobs settle on. A source is not registered anywhere: its id is the
// keccak256 of its canonical config JSON, so building the config is all "registering" there is.
import { canonicalizeAPIConfig, deriveSourceIdString, type APIConfig } from "@molpha/sdk";
import { keccak256, pad, stringToBytes, toHex, type Hex } from "viem";

/** What a node signs for the text "true" / "false" under `valueTransform: "keccak256"`. */
export const TRUE_WORD: Hex = keccak256(stringToBytes("true"));
export const FALSE_WORD: Hex = keccak256(stringToBytes("false"));

/** DNS record type TXT, which Cloudflare reports as 16: what a matching `Answer` entry signs. */
export const DNS_PRESENT_WORD: Hex = pad(toHex(16), { size: 32 });

const SAFE_PART = /^[A-Za-z0-9._-]+$/;

function requirePart(label: string, value: string): string {
  if (!SAFE_PART.test(value)) throw new Error(`${label} must match ${SAFE_PART}: ${JSON.stringify(value)}`);
  return value;
}

/**
 * "Pull request `owner/repo#pr` is merged." The node hashes the text of `$.merged`, so the pass
 * word is keccak256("true") and an open PR signs keccak256("false"): neither is the zero word a
 * node signs for a value it cannot read.
 *
 * Unauthenticated: GitHub allows 60 requests/hour per node address, enough for a demo. Never use a
 * `{{secret.*}}` placeholder here: the source id commits to the placeholder, not to what fills it.
 */
export function githubPrMerged(owner: string, repo: string, pr: number): APIConfig {
  if (!Number.isInteger(pr) || pr <= 0) throw new Error(`pr must be a positive integer: ${pr}`);
  return {
    url: `https://api.github.com/repos/${requirePart("owner", owner)}/${requirePart("repo", repo)}/pulls/${pr}`,
    method: "GET",
    headers: { Accept: "application/vnd.github+json" },
    responseParser: "$.merged",
    valueTransform: "keccak256",
  };
}

/**
 * "`host` has the TXT record `token`." Cloudflare's DNS-over-HTTPS JSON wraps TXT data in literal
 * quotes, and the array filter yields the record type (16) only when an answer matches, so a missing
 * record fails the round instead of signing a verdict: a pass-only source.
 *
 * Add the record BEFORE the first query: resolvers cache a negative answer. Do not extract `TTL`:
 * it differs between resolvers and the nodes would never agree.
 */
export function dnsTxt(host: string, token: string): APIConfig {
  requirePart("host", host);
  requirePart("token", token.replace(/=/g, "-")); // '=' is allowed in a token, nothing else unusual
  return {
    url: `https://cloudflare-dns.com/dns-query?name=${host}&type=TXT`,
    method: "GET",
    headers: { Accept: "application/dns-json" },
    responseParser: `$.Answer[?(@.data=='"${token}"')].type`,
    valueTransform: "",
  };
}

/**
 * "The body at `url` hashes to X" for a deployment artifact. The node hashes the whole response
 * body, trimmed of surrounding whitespace, so the pass word is keccak256 of that exact text.
 */
export function contentHash(url: string): APIConfig {
  return { url, method: "GET", headers: {}, responseParser: "", valueTransform: "keccak256" };
}

/** The exact text a job's terms carry: its `keccak256` is the source id. */
export function canonicalJson(config: APIConfig): string {
  return JSON.stringify(canonicalizeAPIConfig(config));
}

export function sourceIdOf(config: APIConfig): Hex {
  return `0x${deriveSourceIdString(config)}`;
}
