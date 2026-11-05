# Molpha ERC-8183 evaluator

An [ERC-8183](https://eips.ethereum.org/EIPS/eip-8183) evaluator that settles a job when a
threshold-signed Molpha attestation shows the agreed fact. Anyone holding the attestation can
submit it.

> **Testnet, unaudited.** On testnet Molpha runs every node, so the committee is not independent
> yet; independent operators come with mainnet. Slashing is not in effect. Verification is
> permissionless on every chain, signing is threshold-distributed, and coordination is a service.
> The verifier's owner (Molpha) controls the committee, and the ERC-8183 core's admin can upgrade,
> pause and drain the core: either can decide an outcome (see [Trust model](#trust-model)). Do not
> secure real value with this.

For objective, API-observable facts (a pull request is merged, a DNS record exists, a deployment
hash matches). Molpha does not judge quality: pair it with an AI or human evaluator through the
condition hook when the work also needs grading. If the paid party controls the attested API, the
attestation proves nothing.

## What is here

| Path | What it is |
| --- | --- |
| `src/MolphaEvaluator.sol` | The evaluator. Terms are frozen on chain before any work (`registerTerms`); anyone settles with `evaluate`. |
| `src/MolphaConditionHook.sol` | A hook that stops another evaluator completing a job until the fact is attested. Single file, written to the `hook-contracts` PR rules. |
| `src/adapters/MolphaProofVerifier.sol` | The same check as an ERC-8274 `IProofVerifier` (draft). The caller supplies the policy and keeps its own replay guard. Also the legacy two-argument form, which is unsafe unless the caller checks the decoded proof itself. |
| `scenarios/` | Six scenario scripts, a preflight, and offline checks. Run locally on anvil or live on Base Sepolia. |
| `scripts/` | `dryrun-local.sh` (deployment mechanics), `e2e-local.sh` (all six scenarios), `extract-public-nodes.py`. |
| `DEPLOY.md` | The Base Sepolia runbook. |

How a job settles, the rules for what an attestation can do, and the limits are documented in
`guides/erc8183-evaluator.mdx` of the docs repository ("Use Molpha as an ERC-8183 evaluator").

## Pinned dependencies (git submodules)

| Dependency | Pin |
| --- | --- |
| `molpha/evm-verifier` | `2b23e51`, whose build predicts the deployed verifier `0xA6e49A3A1caf3E110cC04765B934C8FF118C2568` |
| `erc-8183/base-contracts` | `142e669` (Jun 30 2026) |
| `erc-8183/hook-contracts` | `3abab14` |
| OpenZeppelin contracts / upgradeable | `v5.6.1` |
| `solady` | `acd959a`, the verifier's pin |
| `forge-std` | `b013eff` (v1.17.0+) |

```bash
git submodule update --init       # not --recursive: the nested libraries are remapped to the ones above
pnpm install --frozen-lockfile
```

## Check it

```bash
forge build --deny warnings
forge test                                   # contracts, against the real core and the real Verifier
FOUNDRY_PROFILE=gas forge test              # gas, each call as its own transaction -> snapshots/gas.json
pnpm exec tsc --noEmit && pnpm test          # scenario code and the source-id vectors
scripts/e2e-local.sh                         # all six scenarios on a loopback anvil
```

`e2e-local.sh` verifies every attestation with the real `Verifier` and genuine Schnorr signatures
(through `MolphaTestSigner`), but the oracle is simulated: the scenarios choose which word it
signs. It does **not** exercise the gateway or the nodes. The live run does (`DEPLOY.md`).

`scripts/dryrun-local.sh` rehearses the Base Sepolia deployment: the verifier at its canonical
address, the five recorded `addNode` calls replayed to registry v5, and the core, evaluator, hook
and adapter deployed with this repository's scripts.

## Design decisions

- **Zero is never a verdict.** A node signs zero for a value it cannot read, so `registerTerms`
  refuses a zero pass or fail word. Booleans and text become words with the node's opt-in
  `valueTransform: "keccak256"`, which an older node refuses instead of signing zero.
- **No templates in a source.** `sourceId` commits to a `{{secret.X}}` placeholder, not to what
  fills it, so whoever requests the round would choose what is fetched. Terms containing `{{` in any
  spelling are refused.
- **A threshold that leaves a spare signer.** `minSignatures` must be at least 3 and below the
  verifier's current node count. The verifier draws its signing group as the threshold plus a
  redundancy buffer, capped at the committee, so a threshold of the whole committee needs every node
  and one node offline would block every pass. The committee can shrink after registration; a
  provider should want more headroom than one node.
- **No client hook on an evaluator job.** A hook can block `complete` but not `claimRefund`, so a
  client-chosen hook could guarantee itself a refund.
- **The job window replaces the age check.** `evaluate` calls the verifier with `maxAge = 0`; the
  pass word must be taken in `[submittedAt, expiredAt)`, and the job's single status change is the
  replay guard. That guard is per job: two jobs with the same source and pass word, whose windows
  overlap, settle on one attestation. Make the source name the job's deliverable.
- **A fail waits 30 minutes after the deadline**, so a pass taken in the last second keeps priority,
  yet a fail still lands before the core's one-hour `claimRefund` wait. Register a fail word only
  for a fact that goes from false to true and never back (a merged PR stays merged): then a fail
  read after the deadline means the fact was never true in the window. Because the deadline is soft
  by about a minute, a fact that turns true right at it can yield both a pass and a fail: the pass
  alone can settle for the first 30 minutes, then whichever is submitted first wins.
- **One evaluator per verifier.** Its owner can only withdraw fees; it has no power over outcomes.
- **The hook implements `IERC8183Hook` directly.** `BaseERC8183Hook.beforeAction` is not `virtual`
  and routes the stale selector `fund(uint256,uint256,bytes)`; the core's is
  `fund(uint256,address,uint256,bytes)`, so a subclass never sees `fund`. `MultiHookRouter` has the
  same stale selectors.
- **Attach the hook directly, not through a router.** Its `requiredSelectors` include `submitClaim`,
  which it only refuses: a router that forwards `complete` but not `submitClaim` would let the
  evaluator pay the whole budget through a milestone claim with no attestation, and the hook cannot
  detect that. A router that enforces `requiredSelectors` has to wire all four or refuse.
  `MultiHookRouter` at `3abab14` cannot route `submitClaim` or the core's `fund`, and enforces
  completeness only in `batchConfigureHooks`: wired with `addHook` for `complete` alone, it fails
  open on claims.

## Trust model

- **The fact's owner.** Whoever can make the signed word true decides the job. If the provider
  controls the attested API (merges into the repository, owns the domain), the attestation proves
  nothing.
- **The node committee.** A threshold of Molpha nodes signs each attestation. On testnet Molpha
  runs every node.
- **The verifier's owner.** `addNode` takes effect immediately, so the owner can seat enough keys to
  sign any word. On Base Sepolia this is the Molpha protocol admin.
- **The core's admin.** The reference core is upgradeable and can be paused; while paused, the
  admin can `emergencyWithdraw` escrow. The admin can also detach the condition hook from a job
  (`batchDetachHook`), which removes its gate.
- **Timestamps.** An attestation's time is the gateway's clock; nodes accept a few seconds of drift
  and a node catching up may fetch up to a minute later. Treat the deadline as soft by about a
  minute and leave margin.

## Before a provider works

The contracts refuse terms that are malformed or impossible on their face, not terms that are
merely unsatisfiable. Unsatisfiable terms end in a full refund to the client after the work is done,
so the provider checks before starting:

1. The job is Funded and its terms are frozen (`termsOf(...).set`; terms cannot change once set),
   and `minSignatures` leaves enough of the committee spare for nodes to be offline.
2. The logged config text (`TermsRegistered` or `TermsFrozen`) is the agreed one, byte for byte, and
   its `keccak256` is the `sourceId`. `scenarios/lib/terms.ts` (`checkTerms`, `checkHookTerms`) does
   this.
3. The source is fetchable by the nodes and produces the pass word when the fact holds, ideally by
   dry-running a round (`scenarios/preflight.ts --rounds` shows how).
4. Who controls the fact. If the client does (the PR is merged into the client's repository), the
   client can withhold it, which makes the fact an acceptance decision: price that in. The source
   should also be specific to this job (see the replay note above).

## Not built

- An ERC-8274 `IAgentVerifier` wrapper: a Molpha attestation binds no task id or agent id, so a
  wrapper would have to take them from its caller unchecked.
- An ERC-8412 contract attester: deferred until that draft (ethereum/ERCs#2002) settles. The
  evaluator already publishes its criteria in plaintext before any work.
- Mainnet. The audit gates it.

## License

MIT for this repository's code, except `src/interfaces/IProofVerifier.sol`, which mirrors the
ERC-8274 draft interface and keeps its CC0-1.0 license. The pinned dependencies keep their own
licenses (the Molpha verifier is Apache-2.0).
