import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { keccak256, stringToBytes } from "viem";
import { FALSE_WORD, TRUE_WORD, DNS_PRESENT_WORD, canonicalJson, contentHash, dnsTxt, githubPrMerged, sourceIdOf } from "./sources.js";

// The Solidity tests hard-code the PR config and its words; these tests tie the three together.
const baseTest = readFileSync(new URL("../../test/Base.t.sol", import.meta.url), "utf8");
const solidityConstant = (name: string): string => {
  const m = baseTest.match(new RegExp(`${name}\\s*=\\s*(?:'([^']*)'|(0x[0-9a-fA-F]{64}))`));
  if (!m) throw new Error(`${name} not found in test/Base.t.sol`);
  return (m[1] ?? m[2])!;
};

describe("the GitHub PR source", () => {
  const cfg = githubPrMerged("molpha", "demo", 1);

  it("builds exactly the config text the Solidity tests use", () => {
    expect(canonicalJson(cfg)).toBe(solidityConstant("PR_CONFIG"));
  });

  it("derives the source id as keccak256 of that text, as the contract does", () => {
    expect(sourceIdOf(cfg)).toBe(keccak256(stringToBytes(canonicalJson(cfg))));
  });

  it("uses the same pass and fail words as the Solidity tests", () => {
    expect(TRUE_WORD).toBe(solidityConstant("PASS"));
    expect(FALSE_WORD).toBe(solidityConstant("FAIL"));
  });

  it("never lets a placeholder or odd character into a job's source", () => {
    expect(() => githubPrMerged("mol pha", "demo", 1)).toThrow();
    expect(() => githubPrMerged("molpha", "de/mo", 1)).toThrow();
    expect(() => githubPrMerged("molpha", "demo", 0)).toThrow();
    expect(canonicalJson(cfg)).not.toContain("{{"); // the contracts refuse any template
  });
});

describe("the DNS TXT source", () => {
  const cfg = dnsTxt("demo.molpha.example", "molpha-job=8183");

  it("filters on the quoted TXT data and signs the record type", () => {
    expect(cfg.responseParser).toBe(`$.Answer[?(@.data=='"molpha-job=8183"')].type`);
    expect(cfg.valueTransform).toBe("");
    expect(cfg.headers).toEqual({ Accept: "application/dns-json" });
    expect(DNS_PRESENT_WORD).toBe("0x0000000000000000000000000000000000000000000000000000000000000010");
  });

  it("refuses a token that could break out of the filter", () => {
    expect(() => dnsTxt("demo.molpha.example", "a'b")).toThrow();
    expect(() => dnsTxt("demo.molpha.example", 'a"b')).toThrow();
    expect(() => dnsTxt("bad host", "x")).toThrow();
  });
});

describe("source ids are stable and distinct", () => {
  it("differs per PR and per source kind, and is deterministic", () => {
    const a = sourceIdOf(githubPrMerged("molpha", "demo", 1));
    expect(sourceIdOf(githubPrMerged("molpha", "demo", 1))).toBe(a);
    expect(sourceIdOf(githubPrMerged("molpha", "demo", 2))).not.toBe(a);
    expect(sourceIdOf(dnsTxt("demo.molpha.example", "t"))).not.toBe(a);
    expect(sourceIdOf(contentHash("https://example.test/app.js"))).not.toBe(a);
  });

  it("pins the vectors the Go node test and the Solidity test also assert", () => {
    // These constants are repeated in molpha-node-client's TestERC8183DemoSourceIDs and in
    // test/SourceIdVectors.t.sol: all three must change together.
    expect(sourceIdOf(githubPrMerged("molpha", "demo", 1))).toBe(VECTORS.pr);
    expect(sourceIdOf(dnsTxt("demo.molpha.example", "molpha-job=8183"))).toBe(VECTORS.dns);
    expect(sourceIdOf(contentHash("https://example.test/app.js"))).toBe(VECTORS.content);
  });
});

const VECTORS = {
  pr: "0x904559abd0f84c121073fb7c9ffd385321cb0ce5ad99d62a6470a91284201cef",
  dns: "0xfafd023490f1066a12f6e586590926e2450e84610fc698829117bce4d9241ede",
  content: "0xc45612f5642f2ac0b84d6833f7f4f42e4846da28a0b9584178254c78dae266f9",
};
