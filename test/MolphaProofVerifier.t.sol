// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IVerifier} from "@molpha/evm-verifier/interfaces/IVerifier.sol";
import {VerifierLib} from "@molpha/evm-verifier/libs/VerifierLib.sol";

import {EvaluatorBase} from "./Base.t.sol";
import {MolphaProofVerifier} from "../src/adapters/MolphaProofVerifier.sol";
import {IProofVerifier, IAttestationVerifier} from "../src/interfaces/IProofVerifier.sol";

contract MolphaProofVerifierTest is EvaluatorBase {
    MolphaProofVerifier internal adapter;

    function setUp() public override {
        super.setUp();
        adapter = new MolphaProofVerifier(verifier);
    }

    function _meta(uint256 minSigs, uint256 notBefore, uint256 notAfter) internal pure returns (bytes memory) {
        return abi.encode(minSigs, notBefore, notAfter);
    }

    function _now() internal view returns (uint256) {
        return vm.getBlockTimestamp();
    }

    function _verify(bytes32 input, bytes32 output, bytes memory meta, bytes memory proof)
        internal
        view
        returns (bool)
    {
        return adapter.verify(input, output, meta, proof);
    }

    // ------------------------------------------------------------------ the mapping

    function test_acceptsAValidProofThatMatchesInputOutputAndPolicy() public view {
        bytes memory proof = abi.encode(_att(PASS, _now()));
        assertTrue(_verify(_sourceId(), PASS, _meta(SIGS, 0, 0), proof));
        assertTrue(_verify(_sourceId(), PASS, _meta(SIGS, _now() - 1, _now() + 1), proof), "inside [before, after)");
    }

    function test_rejectsAWrongInputOrOutput() public view {
        bytes memory proof = abi.encode(_att(PASS, _now()));
        assertFalse(_verify(keccak256("other source"), PASS, _meta(SIGS, 0, 0), proof));
        assertFalse(_verify(_sourceId(), FAIL, _meta(SIGS, 0, 0), proof));
    }

    function test_rejectsAThresholdBelowThePolicyOrBelowTheFloor() public view {
        bytes memory proof = abi.encode(_att(PASS, _now())); // signed with 3
        assertFalse(_verify(_sourceId(), PASS, _meta(5, 0, 0), proof), "policy asks for more than was signed");
        assertFalse(_verify(_sourceId(), PASS, _meta(2, 0, 0), proof), "a policy below the floor is refused");
        assertFalse(_verify(_sourceId(), PASS, _meta(0, 0, 0), proof));
    }

    function test_windowIsHalfOpen() public view {
        uint256 t = _now();
        bytes memory proof = abi.encode(_att(PASS, t));
        assertFalse(_verify(_sourceId(), PASS, _meta(SIGS, t + 1, 0), proof), "before notBefore");
        assertTrue(_verify(_sourceId(), PASS, _meta(SIGS, t, 0), proof), "at notBefore");
        assertTrue(_verify(_sourceId(), PASS, _meta(SIGS, 0, t + 1), proof), "one before notAfter");
        assertFalse(_verify(_sourceId(), PASS, _meta(SIGS, 0, t), proof), "at notAfter");
    }

    function test_zeroIsNeverAnAnswer() public view {
        // A genuine attestation of the zero word, which a node signs for a value it could not read.
        IVerifier.Attestation memory unreadable = _att(bytes32(0), _now());
        (bool genuine,) = verifier.verify(unreadable, 0);
        assertTrue(genuine, "the signature itself is valid");
        assertFalse(_verify(_sourceId(), bytes32(0), _meta(SIGS, 0, 0), abi.encode(unreadable)), "zero output");
        assertFalse(_verify(bytes32(0), PASS, _meta(SIGS, 0, 0), abi.encode(_att(PASS, _now()))), "zero input");
    }

    function test_clockSkewAllowance() public view {
        assertTrue(_verify(_sourceId(), PASS, _meta(SIGS, 0, 0), abi.encode(_att(PASS, _now() + 15))));
        assertFalse(_verify(_sourceId(), PASS, _meta(SIGS, 0, 0), abi.encode(_att(PASS, _now() + 16))));
    }

    function test_rejectsATamperedOrForgedAttestation() public view {
        IVerifier.Attestation memory att = _att(PASS, _now());
        att.signature.signature = bytes32(uint256(att.signature.signature) + 1);
        assertFalse(_verify(_sourceId(), PASS, _meta(SIGS, 0, 0), abi.encode(att)));

        IVerifier.Attestation memory forged = _att(FAIL, _now());
        forged.payload.value = PASS;
        assertFalse(_verify(_sourceId(), PASS, _meta(SIGS, 0, 0), abi.encode(forged)));
    }

    // ------------------------------------------------------------------ malformed input

    function test_malformedInputReturnsFalseAndNeverReverts() public view {
        bytes memory good = abi.encode(_att(PASS, _now()));
        bytes memory meta = _meta(SIGS, 0, 0);

        assertFalse(_verify(_sourceId(), PASS, meta, ""));
        assertFalse(_verify(_sourceId(), PASS, meta, new bytes(255)));
        assertFalse(_verify(_sourceId(), PASS, meta, bytes.concat(good, hex"00")));
        assertFalse(_verify(_sourceId(), PASS, "", good));
        assertFalse(_verify(_sourceId(), PASS, new bytes(95), good));
        assertFalse(_verify(_sourceId(), PASS, new bytes(97), good));

        // A word that does not fit its field would make a typed ABI decode revert.
        bytes memory dirtySigs = good;
        _setWord(dirtySigs, 3, 256);
        assertFalse(_verify(_sourceId(), PASS, meta, dirtySigs));
        bytes memory dirtyVersion = good;
        _setWord(dirtyVersion, 2, uint256(type(uint32).max) + 1);
        assertFalse(_verify(_sourceId(), PASS, meta, dirtyVersion));
        bytes memory dirtyTime = good;
        _setWord(dirtyTime, 4, uint256(type(uint64).max) + 1);
        assertFalse(_verify(_sourceId(), PASS, meta, dirtyTime));
        bytes memory dirtyAddr = good;
        _setWord(dirtyAddr, 6, uint256(type(uint160).max) + 1);
        assertFalse(_verify(_sourceId(), PASS, meta, dirtyAddr));

        assertFalse(_verify(_sourceId(), PASS, _meta(256, 0, 0), good));
        assertFalse(_verify(_sourceId(), PASS, _meta(SIGS, uint256(type(uint64).max) + 1, 0), good));
        assertFalse(_verify(_sourceId(), PASS, _meta(SIGS, 0, uint256(type(uint64).max) + 1), good));
    }

    function testFuzz_neverReverts(bytes32 input, bytes32 output, bytes calldata meta, bytes calldata proof)
        public
        view
    {
        adapter.verify(input, output, meta, proof);
        adapter.verify(input, proof);
    }

    function testFuzz_neverReverts_wordsOfTheRightShape(uint256[8] memory words, uint256[3] memory metaWords)
        public
        view
    {
        adapter.verify(bytes32(words[1]), bytes32(words[0]), abi.encode(metaWords), abi.encode(words));
    }

    // ------------------------------------------------------------------ legacy form and metadata

    /// @dev The digests come from the verifier's own `VerifierLib.constructMessage`, so the
    ///      adapter's hand-written encoding is pinned to the library it must match.
    function test_legacyFormChecksTheDigestAndTheFloor() public {
        DigestHarness lib = new DigestHarness();
        IVerifier.Attestation memory att = _att(PASS, _now());
        bytes32 digest = lib.digest(att);
        assertTrue(adapter.verify(digest, abi.encode(att)));
        assertFalse(adapter.verify(bytes32(uint256(digest) + 1), abi.encode(att)), "wrong digest");

        IVerifier.Attestation memory thin = signer.attest(_sourceId(), PASS, 2, uint64(_now()) * 1000);
        assertFalse(adapter.verify(lib.digest(thin), abi.encode(thin)), "below the floor");
    }

    function test_metadataAndProfile() public view {
        assertEq(adapter.proofSystem(), "molpha-threshold-schnorr-secp256k1/v1");
        assertEq(
            adapter.proofProfile(),
            keccak256(abi.encode(keccak256(bytes(adapter.PROOF_SYSTEM())), address(verifier), uint8(3), uint256(15)))
        );
    }

    function test_isCallableAsAStaticCall() public view {
        bytes memory proof = abi.encode(_att(PASS, _now()));
        (bool ok, bytes memory ret) = address(adapter)
            .staticcall(
                abi.encodeWithSelector(IProofVerifier.verify.selector, _sourceId(), PASS, _meta(SIGS, 0, 0), proof)
            );
        assertTrue(ok, "a view function, so a settlement contract may staticcall it");
        assertTrue(abi.decode(ret, (bool)));
    }

    function test_constructorRefusesAZeroVerifier() public {
        vm.expectRevert(MolphaProofVerifier.ZeroVerifier.selector);
        new MolphaProofVerifier(IVerifier(address(0)));
    }

    // ------------------------------------------------------------------ helpers

    function _setWord(bytes memory b, uint256 index, uint256 value) internal pure {
        assembly {
            mstore(add(add(b, 0x20), mul(index, 0x20)), value)
        }
    }
}

/// @dev `VerifierLib.constructMessage` takes calldata, so it is reached through an external call.
contract DigestHarness {
    function digest(IVerifier.Attestation calldata a) external pure returns (bytes32) {
        return VerifierLib.constructMessage(a.payload, a.signature.signersBitmap);
    }
}
