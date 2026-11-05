// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IVerifier} from "@molpha/evm-verifier/interfaces/IVerifier.sol";

import {IProofVerifier, IAttestationVerifier} from "../interfaces/IProofVerifier.sol";

/// @title MolphaProofVerifier
/// @notice Presents a Molpha attestation as an ERC-8274 `IProofVerifier`, so a settlement contract
///         or evaluator written against that interface can use Molpha as its proof system.
///
/// @dev MAPPING
///        inputHash  = the Molpha `sourceId` (what was asked)
///        outputHash = the signed 32-byte `value` (the answer)
///        metadata   = abi.encode(uint256 minSignatures, uint256 notBefore, uint256 notAfter)
///        proof      = abi.encode(IVerifier.Attestation)   (exactly 256 bytes)
///      `notBefore`/`notAfter` bound the attestation's second as `[notBefore, notAfter)`; a
///      `notAfter` of zero means no upper bound. `minSignatures` is the caller's own threshold
///      (the source id does not commit one) and is never below `MIN_SIGNATURES_FLOOR`.
///
///      Returns false, and never reverts, for anything malformed or unverifiable, and for a zero
///      `inputHash` or `outputHash` (zero is what a node signs for a value it could not read).
///
///      THE CALLER OWNS THE POLICY  `inputHash`, `outputHash` and `metadata` must come from the
///      caller's own terms, never from whoever supplies the proof. `notBefore = notAfter = 0`
///      accepts an attestation of any age, and this adapter keeps no replay state: a stateful
///      caller needs its own guard.
///
///      WHAT IT DOES NOT BIND  A Molpha attestation carries no task id, agent id or caller, so
///      this adapter proves a fact about a source, not that a particular agent produced it. An
///      ERC-8274 `IAgentVerifier` wrapper would have to take those from its caller unchecked,
///      which is why none is shipped.
///
///      TRUST MODEL  Threshold signatures from the Molpha node committee, verified on-chain by
///      the Molpha `Verifier` (on testnet Molpha runs every node). Whoever controls what the
///      source returns controls the answer. Unaudited.
contract MolphaProofVerifier is IProofVerifier, IAttestationVerifier {
    string public constant PROOF_SYSTEM = "molpha-threshold-schnorr-secp256k1/v1";
    uint8 public constant MIN_SIGNATURES_FLOOR = 3;
    /// @notice How far past `block.timestamp` an attestation's second may be (clock drift).
    uint256 public constant MAX_FUTURE_SKEW = 15;

    IVerifier public immutable VERIFIER;

    error ZeroVerifier();

    constructor(IVerifier verifier) {
        if (address(verifier) == address(0)) revert ZeroVerifier();
        VERIFIER = verifier;
    }

    /// @inheritdoc IProofVerifier
    function verify(bytes32 inputHash, bytes32 outputHash, bytes calldata metadata, bytes calldata proof)
        external
        view
        override
        returns (bool)
    {
        (bool okMeta, uint8 minSignatures, uint64 notBefore, uint64 notAfter) = _decodeMetadata(metadata);
        if (!okMeta) return false;

        (bool okProof, IVerifier.Attestation memory att) = _decodeAttestation(proof);
        if (!okProof) return false;

        // Zero is what a node signs for a value it could not read: never an answer.
        if (inputHash == bytes32(0) || outputHash == bytes32(0)) return false;
        if (att.payload.sourceId != inputHash || att.payload.value != outputHash) return false;

        uint256 attestedAt = att.payload.timestamp / 1000;
        if (attestedAt < notBefore || (notAfter != 0 && attestedAt >= notAfter)) return false;

        return _verifies(att, minSignatures);
    }

    /// @notice The legacy two-argument form. `attestationHash` is the Molpha message digest
    ///         (`keccak256` over the 141-byte message), which commits the source, value,
    ///         threshold, registry version, time and signers. Only the floor is enforced here.
    /// @dev UNSAFE ON ITS OWN. The digest includes the signers bitmap and the timestamp, so a
    ///      caller cannot derive it from its terms alone; a caller that takes it from the prover
    ///      learns only that some source signed something, at any time. Use it only after
    ///      decoding `proof` and checking its source, value, threshold and time yourself, or use
    ///      the four-argument form.
    /// @inheritdoc IAttestationVerifier
    function verify(bytes32 attestationHash, bytes calldata proof) external view override returns (bool) {
        (bool ok, IVerifier.Attestation memory att) = _decodeAttestation(proof);
        if (!ok) return false;
        if (_digest(att) != attestationHash) return false;
        return _verifies(att, MIN_SIGNATURES_FLOOR);
    }

    /// @inheritdoc IProofVerifier
    function proofSystem() external pure override returns (string memory) {
        return PROOF_SYSTEM;
    }

    /// @notice Scoped to this deployment: the proof system, the verifier it trusts, and the
    ///         constants that shape what it accepts.
    /// @inheritdoc IProofVerifier
    function proofProfile() external view override returns (bytes32) {
        return
            keccak256(
                abi.encode(keccak256(bytes(PROOF_SYSTEM)), address(VERIFIER), MIN_SIGNATURES_FLOOR, MAX_FUTURE_SKEW)
            );
    }

    // ------------------------------------------------------------------ internals

    function _verifies(IVerifier.Attestation memory att, uint8 minSignatures) private view returns (bool) {
        if (minSignatures < MIN_SIGNATURES_FLOOR || att.payload.signaturesRequired < minSignatures) return false;
        // forge-lint: disable-next-line(block-timestamp)
        if (att.payload.timestamp / 1000 > block.timestamp + MAX_FUTURE_SKEW) return false;
        // `maxAge` is zero on purpose: the caller's window replaces the age check.
        try VERIFIER.verify(att, 0) returns (bool ok, uint8) {
            return ok;
        } catch {
            return false;
        }
    }

    function _decodeMetadata(bytes calldata metadata)
        private
        pure
        returns (bool ok, uint8 minSignatures, uint64 notBefore, uint64 notAfter)
    {
        if (metadata.length != 96) return (false, 0, 0, 0);
        (uint256 minSig, uint256 before, uint256 after_) = abi.decode(metadata, (uint256, uint256, uint256));
        if (minSig > type(uint8).max || before > type(uint64).max || after_ > type(uint64).max) {
            return (false, 0, 0, 0);
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        return (true, uint8(minSig), uint64(before), uint64(after_));
    }

    /// @dev Reads the eight words as plain integers first so an out-of-range word returns false
    ///      instead of making the ABI decoder revert.
    function _decodeAttestation(bytes calldata proof) private pure returns (bool ok, IVerifier.Attestation memory att) {
        if (proof.length != 256) return (false, att);
        (
            bytes32 value,
            bytes32 sourceId,
            uint256 registryVersion,
            uint256 signaturesRequired,
            uint256 timestamp,
            bytes32 s,
            uint256 commitment,
            uint256 bitmap
        ) = abi.decode(proof, (bytes32, bytes32, uint256, uint256, uint256, bytes32, uint256, uint256));
        if (
            registryVersion > type(uint32).max || signaturesRequired > type(uint8).max || timestamp > type(uint64).max
                || commitment > type(uint160).max
        ) return (false, att);

        // forge-lint: disable-start(unsafe-typecast)
        att.payload = IVerifier.AttestationPayload({
            value: value,
            sourceId: sourceId,
            registryVersion: uint32(registryVersion),
            signaturesRequired: uint8(signaturesRequired),
            timestamp: uint64(timestamp)
        });
        att.signature =
            IVerifier.SchnorrSignature({signature: s, commitment: address(uint160(commitment)), signersBitmap: bitmap});
        // forge-lint: disable-end(unsafe-typecast)
        return (true, att);
    }

    function _digest(IVerifier.Attestation memory att) private pure returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                keccak256("MOLPHA_MESSAGE_V1"),
                att.payload.value,
                att.payload.sourceId,
                att.payload.registryVersion,
                att.payload.signaturesRequired,
                att.payload.timestamp,
                att.signature.signersBitmap
            )
        );
    }
}
