// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC8183Hook} from "@erc8183/IERC8183Hook.sol";

/// @dev A router in the shape of `MultiHookRouter`: it is the job's registered hook and forwards
///      every callback to a sub-hook, so the sub-hook sees the router, not the core, as its caller.
contract MockRouterHook is IERC8183Hook {
    IERC8183Hook public immutable SUB;

    constructor(IERC8183Hook sub) {
        SUB = sub;
    }

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == type(IERC8183Hook).interfaceId || id == type(IERC165).interfaceId;
    }

    function beforeAction(uint256 jobId, bytes4 selector, bytes calldata data) external {
        SUB.beforeAction(jobId, selector, data);
    }

    function afterAction(uint256 jobId, bytes4 selector, bytes calldata data) external {
        SUB.afterAction(jobId, selector, data);
    }
}
