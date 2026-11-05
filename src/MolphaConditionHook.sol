// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {IERC8183Hook} from "@erc8183/IERC8183Hook.sol";
import {IERC8183HookMetadata} from "@hooks/interfaces/IERC8183HookMetadata.sol";

/// @dev The Molpha verifier, as far as this hook uses it. `verify` has selector 0x67e2907b and
///      never reverts on a bad attestation: it returns a code.
interface IMolphaVerifier {
    struct AttestationPayload {
        bytes32 value;
        bytes32 sourceId;
        uint32 registryVersion;
        uint8 signaturesRequired;
        uint64 timestamp; // unix milliseconds
    }

    struct SchnorrSignature {
        bytes32 signature;
        address commitment;
        uint256 signersBitmap;
    }

    struct Attestation {
        AttestationPayload payload;
        SchnorrSignature signature;
    }

    function verify(Attestation calldata attestation, uint64 maxAge) external view returns (bool success, uint8 code);

    function getTotalNodes() external view returns (uint256 totalNodes);
}

/// @dev The one read this hook needs from the ERC-8183 core.
interface IERC8183JobReader {
    struct Job {
        address client;
        uint8 status;
        address provider;
        uint48 expiredAt;
        address evaluator;
        uint48 submittedAt;
        uint256 budget;
        address hook;
        address paymentToken;
        uint256 providerAgentId;
        string description;
        uint256 settledAmount;
        address payoutReceiver;
    }

    function getJob(uint256 jobId) external view returns (Job memory);
}

/// @title MolphaConditionHook
/// @notice Blocks `complete` on an ERC-8183 job until a threshold-signed Molpha attestation shows
///         an agreed fact. For jobs whose evaluator judges quality (an AI model, a human, a
///         committee): that evaluator cannot approve the work while the fact is unattested.
///
/// @dev USE CASE  Work with an objective precondition and a subjective grade, for example "the PR
///      is merged AND the code is good". The fact is Molpha's to prove; the grade stays with the
///      evaluator.
///
///      FLOW  1. The client creates the job with this hook and any evaluator.
///      2. The client calls `fund` with `optParams = abi.encode(sourceConfig, passValue,
///      minSignatures)`. The hook freezes those terms for the job (`TermsFrozen`) before any
///      money moves. `sourceConfig` is the Molpha source's canonical JSON, so its `keccak256`
///      is the `sourceId`.
///      3. The provider reads `termsOf(jobId)` and only then works and submits (`submit` reverts
///      while terms are missing, which also covers zero-budget jobs submitted from Open).
///      4. The evaluator calls `complete` with `optParams = abi.encode(attestation)` for a
///      Molpha attestation whose value is the pass word and whose second lies in
///      `[submittedAt, expiredAt)`. Anything else reverts and the job stays Submitted.
///
///      `reject` is not gated, so a client is never held hostage by the fact, and
///      `submitClaim` always reverts: a milestone claim approved by the evaluator would
///      otherwise pay out without ever reaching `complete`. `claimRefund` is not hookable.
///
///      BEHIND A ROUTER  The gate holds only if every selector in `requiredSelectors` reaches this
///      hook, `submitClaim` included. A router that forwards `complete` but not `submitClaim`
///      reopens the claim path: the evaluator can approve a full-budget claim with no attestation.
///      This hook cannot detect that. `MultiHookRouter` at `3abab14` cannot route `submitClaim` or
///      the core's `fund`, and checks completeness only in `batchConfigureHooks`, so `addHook` can
///      wire this hook for `complete` alone and fail open on claims. Attach it directly to the job.
///
///      ONE ATTESTATION, MANY JOBS  Nothing here consumes an attestation: two jobs with the same
///      terms and overlapping windows are both satisfied by one. Make the source name the job.
///
///      TRUST MODEL  Whoever can make the signed word true satisfies the gate: never use a fact
///      the paid party controls. Molpha attestations are signed by a threshold of its node
///      committee (on testnet Molpha runs every node). This hook holds no funds and has no admin,
///      but the verifier's owner (whose `addNode` takes effect at once) and the core's admin (who can
///      also detach this hook from a job with `batchDetachHook`) can each decide an outcome.
///      Nothing here is audited. Timestamps are the gateway's clock in milliseconds; the deadline is
///      soft by up to about a minute (see `MolphaEvaluator`).
///
///      WIRED DIRECTLY, NOT THROUGH `BaseERC8183Hook`: its `beforeAction` is not virtual and it
///      dispatches on `fund(uint256,uint256,bytes)`, while the core's `fund` is
///      `fund(uint256,address,uint256,bytes)`, so a subclass never sees `fund`.
contract MolphaConditionHook is ERC165, IERC8183Hook, IERC8183HookMetadata {
    // Selectors of the core's hookable functions (`erc-8183/base-contracts` 142e669).
    bytes4 private constant SEL_FUND = bytes4(keccak256("fund(uint256,address,uint256,bytes)"));
    bytes4 private constant SEL_SUBMIT = bytes4(keccak256("submit(uint256,bytes32,bytes)"));
    bytes4 private constant SEL_COMPLETE = bytes4(keccak256("complete(uint256,bytes32,bytes)"));
    bytes4 private constant SEL_SUBMIT_CLAIM = bytes4(keccak256("submitClaim(uint256,uint256,bytes32,bytes)"));

    uint8 public constant MIN_SIGNATURES_FLOOR = 3;
    uint256 public constant MAX_FUTURE_SKEW = 15;
    uint256 public constant MAX_CONFIG_BYTES = 2048;
    /// @dev A static `Attestation` ABI-encodes to eight words.
    uint256 private constant ATTESTATION_BYTES = 256;

    /// @notice The ERC-8183 core. It calls this hook directly, or through the hook a job is registered with.
    IERC8183JobReader public immutable CORE;
    /// @notice The Molpha verifier whose attestations satisfy the gate.
    IMolphaVerifier public immutable VERIFIER;

    struct Terms {
        bytes32 sourceId;
        bytes32 passValue;
        uint8 minSignatures;
        bool set;
    }

    mapping(uint256 jobId => Terms) private _terms;

    event TermsFrozen(
        uint256 indexed jobId, bytes32 indexed sourceId, string sourceConfig, bytes32 passValue, uint8 minSignatures
    );

    error OnlyCore();
    error ZeroAddress();
    error NoTerms();
    error TermsAlreadySet();
    error BadAttestation(uint256 length);
    error ClaimsNotAllowed();
    error EmptyConfig();
    error ConfigTooLong(uint256 length);
    error TemplatePlaceholder();
    error ZeroPassValue();
    error ThresholdBelowFloor(uint8 minimum, uint8 floor);
    error NoSpareSigner(uint8 minimum, uint256 committee);
    error VerifyFailed(uint8 code);
    error WrongSource(bytes32 expected, bytes32 actual);
    error ThresholdBelowTerms(uint8 minimum, uint8 actual);
    error UnexpectedValue(bytes32 value);
    error FutureAttestation(uint256 attestedAt, uint256 latestAllowed);
    error OutsideWindow(uint256 attestedAt, uint256 submittedAt, uint256 expiredAt);

    constructor(IERC8183JobReader core, IMolphaVerifier verifier) {
        if (address(core) == address(0) || address(verifier) == address(0)) revert ZeroAddress();
        CORE = core;
        VERIFIER = verifier;
    }

    // ------------------------------------------------------------------ IERC8183Hook

    function beforeAction(uint256 jobId, bytes4 selector, bytes calldata data) external override {
        _requireCaller(jobId);

        if (selector == SEL_FUND) {
            (, bytes memory optParams) = abi.decode(data, (address, bytes));
            _freezeTerms(jobId, optParams);
        } else if (selector == SEL_SUBMIT) {
            if (!_terms[jobId].set) revert NoTerms();
        } else if (selector == SEL_COMPLETE) {
            (,, bytes memory optParams) = abi.decode(data, (address, bytes32, bytes));
            _requireFact(jobId, optParams);
        } else if (selector == SEL_SUBMIT_CLAIM) {
            revert ClaimsNotAllowed();
        }
    }

    function afterAction(uint256 jobId, bytes4, bytes calldata) external view override {
        _requireCaller(jobId);
    }

    // ------------------------------------------------------------------ views

    /// @notice The terms frozen for a job (all zero when none).
    function termsOf(uint256 jobId) external view returns (Terms memory) {
        return _terms[jobId];
    }

    /// @inheritdoc IERC8183HookMetadata
    /// @dev `submitClaim` is listed although the hook only ever refuses it: a router that wired this
    ///      hook for `complete` but not for `submitClaim` would let a provider claim the whole budget
    ///      and an evaluator approve it without any attestation. Listing it makes a router that
    ///      checks completeness wire it or refuse the configuration.
    function requiredSelectors() external pure override returns (bytes4[] memory selectors) {
        selectors = new bytes4[](4);
        selectors[0] = SEL_FUND;
        selectors[1] = SEL_SUBMIT;
        selectors[2] = SEL_COMPLETE;
        selectors[3] = SEL_SUBMIT_CLAIM;
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC165, IERC165) returns (bool) {
        return interfaceId == type(IERC8183Hook).interfaceId || interfaceId == type(IERC8183HookMetadata).interfaceId
            || super.supportsInterface(interfaceId);
    }

    // ------------------------------------------------------------------ internals

    /// @dev The core, or the hook the job is registered with: a router fanning out to this hook
    ///      calls it with itself as `msg.sender`. State is keyed by `jobId`, so a caller that is a
    ///      job's own (core-whitelisted) hook can only affect that job.
    function _requireCaller(uint256 jobId) private view {
        if (msg.sender == address(CORE)) return;
        if (msg.sender != CORE.getJob(jobId).hook) revert OnlyCore();
    }

    function _freezeTerms(uint256 jobId, bytes memory optParams) private {
        if (optParams.length == 0) revert NoTerms();
        if (_terms[jobId].set) revert TermsAlreadySet();

        (string memory sourceConfig, bytes32 passValue, uint8 minSignatures) =
            abi.decode(optParams, (string, bytes32, uint8));
        bytes memory config = bytes(sourceConfig);

        if (config.length == 0) revert EmptyConfig();
        if (config.length > MAX_CONFIG_BYTES) revert ConfigTooLong(config.length);
        // `sourceId` commits to a template placeholder, not to what a requester fills in. Any `{{`
        // is refused, not only the exact `{{secret.` spelling.
        if (_contains(config, "{{")) revert TemplatePlaceholder();
        // Zero is what a node signs for a value it could not read.
        if (passValue == bytes32(0)) revert ZeroPassValue();
        if (minSignatures < MIN_SIGNATURES_FLOOR) revert ThresholdBelowFloor(minSignatures, MIN_SIGNATURES_FLOOR);
        // A threshold of the whole committee needs every node to sign, so one node offline would
        // block `complete` for good. Require a spare signer.
        uint256 committee = VERIFIER.getTotalNodes();
        if (minSignatures >= committee) revert NoSpareSigner(minSignatures, committee);

        bytes32 sourceId = keccak256(config);
        _terms[jobId] = Terms({sourceId: sourceId, passValue: passValue, minSignatures: minSignatures, set: true});
        emit TermsFrozen(jobId, sourceId, sourceConfig, passValue, minSignatures);
    }

    function _requireFact(uint256 jobId, bytes memory optParams) private view {
        Terms memory t = _terms[jobId];
        if (!t.set) revert NoTerms();
        if (optParams.length != ATTESTATION_BYTES) revert BadAttestation(optParams.length);

        IMolphaVerifier.Attestation memory att = abi.decode(optParams, (IMolphaVerifier.Attestation));
        if (att.payload.sourceId != t.sourceId) revert WrongSource(t.sourceId, att.payload.sourceId);
        if (att.payload.signaturesRequired < t.minSignatures) {
            revert ThresholdBelowTerms(t.minSignatures, att.payload.signaturesRequired);
        }

        // `maxAge` is zero on purpose: the job window below replaces the age check.
        (bool ok, uint8 code) = VERIFIER.verify(att, 0);
        if (!ok) revert VerifyFailed(code);

        if (att.payload.value != t.passValue) revert UnexpectedValue(att.payload.value);

        uint256 attestedAt = att.payload.timestamp / 1000;
        // forge-lint: disable-next-line(block-timestamp)
        uint256 latestAllowed = block.timestamp + MAX_FUTURE_SKEW;
        if (attestedAt > latestAllowed) revert FutureAttestation(attestedAt, latestAllowed);

        IERC8183JobReader.Job memory job = CORE.getJob(jobId);
        if (attestedAt < job.submittedAt || attestedAt >= job.expiredAt) {
            revert OutsideWindow(attestedAt, job.submittedAt, job.expiredAt);
        }
    }

    function _contains(bytes memory haystack, bytes memory needle) private pure returns (bool) {
        uint256 n = needle.length;
        if (haystack.length < n) return false;
        unchecked {
            for (uint256 i = 0; i <= haystack.length - n; ++i) {
                uint256 j;
                while (j < n && haystack[i + j] == needle[j]) ++j;
                if (j == n) return true;
            }
        }
        return false;
    }
}
