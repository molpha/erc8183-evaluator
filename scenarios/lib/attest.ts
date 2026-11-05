// Where a scenario gets its attestations: the Molpha gateway (live), or a local test signer that
// signs with the verifier's real Schnorr scheme (local dry run).
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname } from "node:path";
import { Keypair } from "@solana/web3.js";
import {
  MolphaGateway,
  buildEvmVerifierArgs,
  signerFromKeypair,
  type APIConfig,
  type Attestation,
} from "@molpha/sdk";
import type { Address, Hex, PublicClient } from "viem";
import { parseAbi } from "viem";
import { sourceIdOf } from "./sources.js";

/** `IVerifier.Attestation` in the shape viem encodes. */
export interface EvmAttestation {
  payload: { value: Hex; sourceId: Hex; registryVersion: number; signaturesRequired: number; timestamp: bigint };
  signature: { signature: Hex; commitment: Hex; signersBitmap: bigint };
}

export interface AttestRequest {
  config: APIConfig;
  quorum: number;
  /** Local mode only: the word the simulated oracle signs. Ignored live, where the nodes decide. */
  localValue?: Hex;
  /** Local mode only: the round's unix second. Defaults to the chain's clock. */
  localTimestampSeconds?: bigint;
}

export interface AttestationSource {
  get(req: AttestRequest): Promise<EvmAttestation>;
}

// ------------------------------------------------------------------ files

type Wire = { payload: Omit<EvmAttestation["payload"], "timestamp"> & { timestamp: string }; signature: Omit<EvmAttestation["signature"], "signersBitmap"> & { signersBitmap: string } };

export function saveAttestation(path: string, att: EvmAttestation): void {
  const wire: Wire = {
    payload: { ...att.payload, timestamp: att.payload.timestamp.toString() },
    signature: { ...att.signature, signersBitmap: att.signature.signersBitmap.toString() },
  };
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, JSON.stringify(wire, null, 2));
}

/** An attestation is plain public data: anyone holding this file can finalize the job. */
export function loadAttestation(path: string): EvmAttestation {
  const w = JSON.parse(readFileSync(path, "utf8")) as Wire;
  return {
    payload: { ...w.payload, timestamp: BigInt(w.payload.timestamp) },
    signature: { ...w.signature, signersBitmap: BigInt(w.signature.signersBitmap) },
  };
}

// ------------------------------------------------------------------ live: the Molpha gateway

/** Load a Solana keypair file (a JSON array of 64 bytes). The key is held in memory only. */
function loadKeypair(path: string): Keypair {
  return Keypair.fromSecretKey(Uint8Array.from(JSON.parse(readFileSync(path, "utf8")) as number[]));
}

export function gatewaySource(opts: { endpoint: string; keypairPath: string }): AttestationSource {
  const keypair = loadKeypair(opts.keypairPath);
  const owner = keypair.publicKey.toBase58();
  let gateway: MolphaGateway | undefined;

  const client = async (): Promise<MolphaGateway> => {
    if (gateway) return gateway;
    // The registry the round binds to: read from the gateway's own view of the chain. The gateway
    // refuses a round whose version is not the current one, so a stale value fails loudly.
    const probe = new MolphaGateway(opts.endpoint, undefined, undefined, { defaultSubscriptionOwner: owner });
    const info = await probe.getNodesInfo();
    if (!info.registry) throw new Error("the gateway could not read the registry; try again shortly");
    const registry = { registryVersion: info.registry.version, redundancyBuffer: info.registry.redundancyBuffer, nodeCount: info.registry.nodeCount };
    gateway = new MolphaGateway(opts.endpoint, async () => registry, signerFromKeypair(keypair), {
      defaultSubscriptionOwner: owner,
      defaultConsumerAuthority: owner,
    });
    return gateway;
  };

  return {
    async get({ config, quorum }) {
      const gw = await client();
      const att: Attestation = await gw.requestSignedData({ apiConfig: config, signaturesRequired: quorum });
      if (att.payload.sourceId.toLowerCase().replace(/^0x/, "") !== sourceIdOf(config).slice(2).toLowerCase()) {
        throw new Error("the gateway returned an attestation for a different source id than the config derives");
      }
      const { attestation } = buildEvmVerifierArgs(att, { maxAge: 0 });
      return attestation as EvmAttestation;
    },
  };
}

// ------------------------------------------------------------------ local: a test signer

const signerAbi = parseAbi([
  "function attest(bytes32 sourceId, bytes32 value, uint8 signaturesRequired, uint64 timestamp) view returns (((bytes32 value, bytes32 sourceId, uint32 registryVersion, uint8 signaturesRequired, uint64 timestamp) payload, (bytes32 signature, address commitment, uint256 signersBitmap) signature))",
]);

export function localSignerSource(pub: PublicClient, signer: Address, nowSeconds: () => Promise<bigint>): AttestationSource {
  return {
    async get({ config, quorum, localValue, localTimestampSeconds }) {
      if (!localValue) throw new Error("local mode needs the word the simulated oracle signs");
      const ts = localTimestampSeconds ?? (await nowSeconds());
      const att = await pub.readContract({
        address: signer,
        abi: signerAbi,
        functionName: "attest",
        args: [sourceIdOf(config), localValue, quorum, ts * 1000n],
      });
      return att as EvmAttestation;
    },
  };
}

/** A source that must never be asked: proves a step ran with Molpha offline. */
export const offlineSource: AttestationSource = {
  async get() {
    throw new Error("Molpha is offline in this step: the saved attestation must be enough");
  },
};
