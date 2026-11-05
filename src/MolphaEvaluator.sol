// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IVerifier} from "@molpha/evm-verifier/interfaces/IVerifier.sol";
import {MolphaLib} from "@molpha/evm-verifier/consumer/MolphaLib.sol";
import {VerifierLib} from "@molpha/evm-verifier/libs/VerifierLib.sol";

import {IERC8183Core} from "./interfaces/IERC8183Core.sol";
import {MolphaJobTerms} from "./lib/MolphaJobTerms.sol";

/// @title MolphaEvaluator
/// @notice An ERC-8183 evaluator that settles a job when a threshold-signed Molpha attestation
///         shows the fact the client and provider agreed on. Anyone holding the attestation can
///         submit it.
///
/// @dev USE CASE  A job whose outcome is an objective, API-observable fact: a pull request is
///      merged, a DNS record exists, a deployment hash matches. Pair a quality judge with
///      `MolphaConditionHook` when the work also needs judging.
///
///      FLOW  1. The client creates the job with this contract as `evaluator` and no hook.
///      2. While the job is Open, the client calls `registerTerms` with the Molpha source config
///      (plain text, so the criteria are public before any work), the signed word that means
///      "pass" and, optionally, the word that means "fail".
///      3. The provider reads the terms (`termsOf`, which must show `set`), then sets a budget;
///      the client funds; the provider works and submits.
///      4. Anyone calls `evaluate` with a Molpha attestation. A pass word taken inside the job
///      window completes the job. A fail word taken at or after the deadline rejects it, but
///      only once `FAIL_DELAY` has passed so a late pass still has priority.
///
///      TRUST MODEL  Whoever can make the signed word true decides the job. A fact the paid party
///      controls (a repository the provider can merge into, a domain the provider owns) proves
///      nothing. Molpha is threshold-signed by its node committee; on testnet Molpha runs every
///      node. This contract's owner can only withdraw accrued evaluator fees, but two parties
///      outside it can decide outcomes: the verifier's owner, whose `addNode` takes effect at once
///      and so can seat enough keys to sign any word, and the core's admin (upgrade, pause,
///      `emergencyWithdraw`). Nothing here is audited.
///
///      TERMS ARE THE PROVIDER'S TO CHECK  The contract refuses terms that are malformed or
///      impossible on their face (zero words, templates, a threshold below `MIN_SIGNATURES_FLOOR`
///      or leaving no spare signer in the committee), not terms that are merely unsatisfiable: a
///      config the nodes cannot fetch, or a pass word the source never produces. Before working,
///      the provider confirms `termsOf(...).set`, that the logged config is the agreed one, and
///      ideally dry-runs a round. Unsatisfiable terms end in a full refund to the client.
///
///      ONE ATTESTATION, MANY JOBS  The replay guard is each job's single status change. Two jobs
///      with the same source and pass word, whose windows overlap, both settle on one
///      attestation. Make the source name this job's deliverable (a PR number, a job nonce).
///
///      TIME  Attestation timestamps are the gateway's clock in milliseconds. Nodes accept up to
///      5 s of drift, and a node catching up from a peer may fetch up to 60 s after the stamped
///      time, so the deadline is soft by up to about a minute. Leave margin before `expiredAt`.
///      For a fact that turns true within that minute, both a pass stamped before the deadline
///      and a fail stamped at it can exist: only the pass can settle in the first `FAIL_DELAY`
///      after the deadline, and after that whichever is submitted first wins.
contract MolphaEvaluator is Ownable2Step {
    using MolphaLib for IVerifier;
    using SafeERC20 for IERC20;

    /// @notice The Molpha verifier whose attestations settle jobs. Never repointed: a different
    ///         verifier is a different evaluator deployment.
    IVerifier public immutable VERIFIER;

    /// @notice Lowest signature threshold terms may ask for. Matches the protocol's own floor;
    ///         `sourceId` does not commit the threshold, so each job states it.
    uint8 public constant MIN_SIGNATURES_FLOOR = 3;

    /// @notice How far past `block.timestamp` an attestation's second may be. Covers gateway/node
    ///         clock drift and a simulation against a block a couple of seconds old.
    uint256 public constant MAX_FUTURE_SKEW = 15;

    /// @notice How long after the deadline a fail attestation waits, so a pass has priority.
    uint256 public constant FAIL_DELAY = 30 minutes;

    /// @dev core => jobId => terms. Keyed by core so one deployment serves any core with the
    ///      ERC-8183 ABI; a hostile core can only affect its own entries.
    mapping(address core => mapping(uint256 jobId => MolphaJobTerms.Terms)) private _terms;

    event TermsRegistered(
        address indexed core,
        uint256 indexed jobId,
        bytes32 indexed sourceId,
        string sourceConfig,
        bytes32 passValue,
        bytes32 failValue,
        bool hasFail,
        uint8 minSignatures
    );

    event Evaluated(
        address indexed core,
        uint256 indexed jobId,
        bool passed,
        bytes32 indexed sourceId,
        bytes32 value,
        uint64 timestamp,
        uint256 signersBitmap
    );

    error ZeroVerifier();
    error NotClient();
    error NotEvaluator();
    error WrongStatus(IERC8183Core.JobStatus status);
    error HookNotAllowed();
    error TermsAlreadySet();
    error NoTerms();
    error FutureAttestation(uint256 attestedAt, uint256 latestAllowed);
    error OutsideWindow(uint256 attestedAt, uint256 submittedAt, uint256 expiredAt);
    error FailNotYet(uint256 attestedAt, uint256 expiredAt, uint256 failAllowedFrom);
    error UnexpectedValue(bytes32 value);
    error NoSpareSigner(uint8 minimum, uint256 committee);

    constructor(IVerifier verifier, address owner_) Ownable(owner_) {
        if (address(verifier) == address(0)) revert ZeroVerifier();
        VERIFIER = verifier;
    }

    /// @notice Freeze the fact a job settles on. Client only, while the job is Open, once.
    /// @param sourceConfig The canonical Molpha source config JSON, byte for byte: its `keccak256`
    ///        is the `sourceId` the attestation must carry.
    /// @param passValue The signed word that means the fact holds. Never zero.
    /// @param failValue The signed word that means it does not (ignored unless `hasFail`).
    /// @param hasFail Whether a fail attestation can reject the job. Only sound for a fact that can
    ///        go from false to true and never back (a PR, once merged, stays merged): then a fail
    ///        word read after the deadline means the fact was never true inside the window.
    /// @param minSignatures Signatures the attestation must carry: at least `MIN_SIGNATURES_FLOOR`
    ///        and below the verifier's current committee size, so at least one node may be
    ///        offline. The committee can shrink later; a provider should want more headroom.
    function registerTerms(
        IERC8183Core core,
        uint256 jobId,
        string calldata sourceConfig,
        bytes32 passValue,
        bytes32 failValue,
        bool hasFail,
        uint8 minSignatures
    ) external {
        IERC8183Core.Job memory job = core.getJob(jobId);
        if (msg.sender != job.client) revert NotClient();
        if (job.status != IERC8183Core.JobStatus.Open) revert WrongStatus(job.status);
        if (job.evaluator != address(this)) revert NotEvaluator();
        // A client-chosen hook could block `complete` (it is not on the `claimRefund` path), so a
        // job that settles on a Molpha fact has no hook.
        if (job.hook != address(0)) revert HookNotAllowed();

        MolphaJobTerms.Terms storage t = _terms[address(core)][jobId];
        if (t.set) revert TermsAlreadySet();

        bytes32 sourceId = MolphaJobTerms.validate(
            bytes(sourceConfig), passValue, failValue, hasFail, minSignatures, MIN_SIGNATURES_FLOOR
        );
        // The verifier's selection group is `minSignatures + buffer`, capped at the committee, so a
        // threshold of the whole committee needs every node: one node offline and no pass can ever
        // be signed, leaving the client the work and the refund. Require a spare signer.
        uint256 committee = VERIFIER.getTotalNodes();
        if (minSignatures >= committee) revert NoSpareSigner(minSignatures, committee);

        _terms[address(core)][jobId] = MolphaJobTerms.Terms({
            sourceId: sourceId,
            passValue: passValue,
            failValue: hasFail ? failValue : bytes32(0),
            minSignatures: minSignatures,
            hasFail: hasFail,
            set: true
        });

        emit TermsRegistered(address(core), jobId, sourceId, sourceConfig, passValue, failValue, hasFail, minSignatures);
    }

    /// @notice Settle a Submitted job from a Molpha attestation. Anyone may call.
    /// @dev Pass: the attested value is the pass word and its second lies in
    ///      `[submittedAt, expiredAt)`. Fail: the fail word, at or after `expiredAt`, once
    ///      `FAIL_DELAY` has passed. `maxAge` is zero on purpose: the job window replaces the age
    ///      check, and the single status transition of the job is the replay guard.
    function evaluate(IERC8183Core core, uint256 jobId, IVerifier.Attestation calldata att) external {
        MolphaJobTerms.Terms memory t = _terms[address(core)][jobId];
        if (!t.set) revert NoTerms();

        IERC8183Core.Job memory job = core.getJob(jobId);
        if (job.status != IERC8183Core.JobStatus.Submitted) revert WrongStatus(job.status);

        VERIFIER.requireValid(
            att, MolphaLib.Policy({sourceId: t.sourceId, minSignatures: t.minSignatures, maxAge: MolphaLib.NO_MAX_AGE})
        );

        uint256 attestedAt = att.payload.timestamp / 1000;
        // forge-lint: disable-next-line(block-timestamp)
        uint256 latestAllowed = block.timestamp + MAX_FUTURE_SKEW;
        if (attestedAt > latestAllowed) revert FutureAttestation(attestedAt, latestAllowed);

        bytes32 value = att.payload.value;
        bytes32 digest = VerifierLib.constructMessage(att.payload, att.signature.signersBitmap);

        if (value == t.passValue) {
            if (attestedAt < job.submittedAt || attestedAt >= job.expiredAt) {
                revert OutsideWindow(attestedAt, job.submittedAt, job.expiredAt);
            }
            emit Evaluated(
                address(core), jobId, true, t.sourceId, value, att.payload.timestamp, att.signature.signersBitmap
            );
            core.complete(jobId, digest, "");
        } else if (t.hasFail && value == t.failValue) {
            uint256 failAllowedFrom = uint256(job.expiredAt) + FAIL_DELAY;
            // forge-lint: disable-next-line(block-timestamp)
            if (attestedAt < job.expiredAt || block.timestamp < failAllowedFrom) {
                revert FailNotYet(attestedAt, job.expiredAt, failAllowedFrom);
            }
            emit Evaluated(
                address(core), jobId, false, t.sourceId, value, att.payload.timestamp, att.signature.signersBitmap
            );
            core.reject(jobId, digest, "");
        } else {
            revert UnexpectedValue(value);
        }
    }

    /// @notice The frozen terms of a job (all zero when none were registered).
    function termsOf(address core, uint256 jobId) external view returns (MolphaJobTerms.Terms memory) {
        return _terms[core][jobId];
    }

    /// @notice Withdraw evaluator fees the core paid to this contract. The only owner power.
    function withdrawFees(IERC20 token, address to, uint256 amount) external onlyOwner {
        token.safeTransfer(to, amount);
    }
}
