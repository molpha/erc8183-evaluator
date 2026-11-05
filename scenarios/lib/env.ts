import { envOr } from "./chain.js";

export interface PrRef {
  owner: string;
  repo: string;
  pr: number;
}

/** `owner/repo#12`. Live runs must name a real PR; the local default is a placeholder. */
export function prRef(name: "GITHUB_PR" | "GITHUB_OPEN_PR", live: boolean): PrRef {
  const fallback = name === "GITHUB_PR" ? "molpha/demo#1" : "molpha/demo#2";
  const raw = live ? process.env[name] : envOr(name, fallback);
  const m = raw?.match(/^([A-Za-z0-9._-]+)\/([A-Za-z0-9._-]+)#(\d+)$/);
  if (!m) throw new Error(`set ${name} to owner/repo#number${name === "GITHUB_OPEN_PR" ? " (a PR that stays open)" : ""}`);
  return { owner: m[1]!, repo: m[2]!, pr: Number(m[3]) };
}

export function dnsRef(live: boolean): { host: string; token: string } {
  const host = live ? process.env.DNS_HOST : envOr("DNS_HOST", "demo.molpha.example");
  if (!host) throw new Error("set DNS_HOST to a domain you control (the TXT record is added there)");
  return { host, token: envOr("DNS_TOKEN", "molpha-job=8183") };
}
