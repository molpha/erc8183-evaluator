// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title MolphaJobTerms
/// @notice The agreed fact of one ERC-8183 job, and the checks every set of terms must pass.
/// @dev A Molpha source is not registered anywhere: its `sourceId` is `keccak256` of its canonical
///      config JSON. Terms therefore carry the config text itself, so the criteria are public
///      before any work starts and anyone can recompute the id.
library MolphaJobTerms {
    /// @dev Upper bound on the stored config text. Real configs are a few hundred bytes.
    uint256 internal constant MAX_CONFIG_BYTES = 2048;

    /// @dev Opening of a template placeholder (`{{secret.X}}` today). `sourceId` commits to the
    ///      placeholder, not to what fills it, so a config containing one lets whoever asks for the
    ///      round choose what is fetched. Any `{{` is refused, not only the exact `{{secret.`
    ///      spelling, so a variant the node also accepts (spacing, case, a future template kind)
    ///      cannot slip through. A canonical config has no other use for `{{`.
    bytes internal constant TEMPLATE_MARKER = "{{";

    struct Terms {
        bytes32 sourceId;
        bytes32 passValue;
        bytes32 failValue;
        uint8 minSignatures;
        bool hasFail;
        bool set;
    }

    error EmptyConfig();
    error ConfigTooLong(uint256 length);
    error TemplatePlaceholder();
    error ZeroPassValue();
    error ZeroFailValue();
    error PassEqualsFail();
    error ThresholdBelowFloor(uint8 minimum, uint8 floor);

    /// @notice Check a set of terms and return the `sourceId` they define.
    /// @dev Zero is refused as a verdict because it is what a node signs for a value it could not
    ///      read. A pass or fail word of zero would be satisfiable by a broken source.
    function validate(
        bytes memory sourceConfig,
        bytes32 passValue,
        bytes32 failValue,
        bool hasFail,
        uint8 minSignatures,
        uint8 floor
    ) internal pure returns (bytes32 sourceId) {
        if (sourceConfig.length == 0) revert EmptyConfig();
        if (sourceConfig.length > MAX_CONFIG_BYTES) revert ConfigTooLong(sourceConfig.length);
        if (contains(sourceConfig, TEMPLATE_MARKER)) revert TemplatePlaceholder();
        if (passValue == bytes32(0)) revert ZeroPassValue();
        if (hasFail) {
            if (failValue == bytes32(0)) revert ZeroFailValue();
            if (failValue == passValue) revert PassEqualsFail();
        }
        if (minSignatures < floor) revert ThresholdBelowFloor(minSignatures, floor);
        sourceId = keccak256(sourceConfig);
    }

    /// @notice Whether `needle` occurs in `haystack`.
    function contains(bytes memory haystack, bytes memory needle) internal pure returns (bool) {
        uint256 n = needle.length;
        if (n == 0 || haystack.length < n) return false;
        unchecked {
            for (uint256 i = 0; i <= haystack.length - n; ++i) {
                uint256 j = 0;
                while (j < n && haystack[i + j] == needle[j]) ++j;
                if (j == n) return true;
            }
        }
        return false;
    }
}
