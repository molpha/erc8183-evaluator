// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC8183Hook} from "@erc8183/IERC8183Hook.sol";
import {IERC8183HookMetadata} from "@hooks/interfaces/IERC8183HookMetadata.sol";

/// @dev A router in the shape of `MultiHookRouter`, but with the core's real selectors: it forwards
///      a callback to its sub-hook only for the selectors wired for that job. With `checksMetadata`
///      it refuses, at `fund`, a wiring that leaves out any of the sub-hook's `requiredSelectors`
///      (the rule `MultiHookRouter` states); without it, it forwards whatever it was wired for.
///      Test only: `wire` has no access control.
contract MockSelectiveRouterHook is IERC8183Hook {
    bytes4 private constant SEL_FUND = bytes4(keccak256("fund(uint256,address,uint256,bytes)"));

    IERC8183Hook public immutable SUB;
    bool public immutable CHECKS_METADATA;

    mapping(uint256 jobId => mapping(bytes4 selector => bool)) public wired;

    error IncompleteWiring(bytes4 missing);

    constructor(IERC8183Hook sub, bool checksMetadata) {
        SUB = sub;
        CHECKS_METADATA = checksMetadata;
    }

    function wire(uint256 jobId, bytes4[] calldata selectors) external {
        for (uint256 i; i < selectors.length; ++i) {
            wired[jobId][selectors[i]] = true;
        }
    }

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == type(IERC8183Hook).interfaceId || id == type(IERC165).interfaceId;
    }

    function beforeAction(uint256 jobId, bytes4 selector, bytes calldata data) external {
        if (!wired[jobId][selector]) return;
        if (CHECKS_METADATA && selector == SEL_FUND) {
            bytes4[] memory required = IERC8183HookMetadata(address(SUB)).requiredSelectors();
            for (uint256 i; i < required.length; ++i) {
                if (!wired[jobId][required[i]]) revert IncompleteWiring(required[i]);
            }
        }
        SUB.beforeAction(jobId, selector, data);
    }

    function afterAction(uint256 jobId, bytes4 selector, bytes calldata data) external {
        if (!wired[jobId][selector]) return;
        SUB.afterAction(jobId, selector, data);
    }
}
