// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC8183Hook} from "@erc8183/IERC8183Hook.sol";

/// @dev The smallest hook the core accepts: ERC-165 for `IERC8183Hook`, callbacks that do nothing.
contract MockHook is IERC8183Hook {
    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == type(IERC8183Hook).interfaceId || id == type(IERC165).interfaceId;
    }

    function beforeAction(uint256, bytes4, bytes calldata) external {}

    function afterAction(uint256, bytes4, bytes calldata) external {}
}
