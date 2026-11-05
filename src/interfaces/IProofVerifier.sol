// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

/// @title IProofVerifier
/// @notice The inner proof-verifier interface of the ERC-8274 draft (ethereum/ERCs#1771, at
///         50e1e12). The draft is unmerged and has changed before: this file mirrors it for
///         interface-compatibility tests and is the only thing to update if it moves.
interface IProofVerifier {
    function verify(bytes32 inputHash, bytes32 outputHash, bytes calldata metadata, bytes calldata proof)
        external
        returns (bool);

    function proofSystem() external view returns (string memory);

    function proofProfile() external view returns (bytes32);
}

/// @title IAttestationVerifier
/// @notice The informal verifier shape used early in the ERC-8183 Magicians thread (marked
///         deprecated there in favour of ERC-8274). It is not part of any standard; kept so
///         integrations written against it can call Molpha.
interface IAttestationVerifier {
    function verify(bytes32 attestationHash, bytes calldata proof) external returns (bool);
}
