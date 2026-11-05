// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";

/// @dev Shared by the deploy scripts: the testnet guard and the merged `deployments/<chainid>.json`.
abstract contract DeployBase is Script {
    function _path() internal view returns (string memory) {
        return string.concat("./deployments/", vm.toString(block.chainid), ".json");
    }

    /// @dev Adds `fresh`'s keys to the file at `path`, keeping what is already there.
    function _merge(string memory path, string memory fresh) internal {
        string memory existing = vm.exists(path) ? vm.readFile(path) : "{}";
        string[] memory keys = vm.parseJsonKeys(fresh, "$");
        string memory k = "merged";
        string memory out = existing;
        for (uint256 i = 0; i < keys.length; ++i) {
            out = vm.serializeAddress(k, keys[i], vm.parseJsonAddress(fresh, string.concat(".", keys[i])));
        }
        // Keys already in the file that this run did not touch.
        string[] memory old = vm.parseJsonKeys(existing, "$");
        for (uint256 i = 0; i < old.length; ++i) {
            bool fromThisRun;
            for (uint256 j = 0; j < keys.length; ++j) {
                if (keccak256(bytes(keys[j])) == keccak256(bytes(old[i]))) fromThisRun = true;
            }
            if (!fromThisRun) {
                out = vm.serializeAddress(k, old[i], vm.parseJsonAddress(existing, string.concat(".", old[i])));
            }
        }
        vm.writeJson(out, path);
    }

    function _requireTestnet() internal view {
        if (vm.envOr("ALLOW_ANY_CHAIN", false)) return;
        require(block.chainid == 84532 || block.chainid == 31337, "testnet only: set ALLOW_ANY_CHAIN=1 to override");
    }
}
