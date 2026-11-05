// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console2} from "forge-std/Script.sol";
import {ERC8183} from "@erc8183/ERC8183.sol";
import {IVerifier} from "@molpha/evm-verifier/interfaces/IVerifier.sol";

import {DeployBase} from "./lib/DeployBase.sol";
import {MolphaEvaluator} from "../src/MolphaEvaluator.sol";
import {MolphaConditionHook, IMolphaVerifier, IERC8183JobReader} from "../src/MolphaConditionHook.sol";
import {MolphaProofVerifier} from "../src/adapters/MolphaProofVerifier.sol";

/// @title DeployMolpha
/// @notice Deploys `MolphaEvaluator`, `MolphaConditionHook` and `MolphaProofVerifier` against a Molpha
///         verifier and an ERC-8183 core, then whitelists the hook on the core when the broadcaster
///         is the core's admin.
/// @dev Env:
///      - `PRIVATE_KEY` (required)
///      - `VERIFIER` (optional): the Molpha verifier. Default `0xA6e49A3A…2568`, the canonical one.
///      - `CORE` (optional): the ERC-8183 core. Default: `core` in `deployments/<chainid>.json`.
///      - `OWNER` (optional): evaluator fee owner. Default the broadcaster.
///      Writes `evaluator`, `hook`, `proofVerifier`, `verifier` to `deployments/<chainid>.json`.
contract DeployMolpha is DeployBase {
    address internal constant CANONICAL_VERIFIER = 0xA6e49A3A1caf3E110cC04765B934C8FF118C2568;

    function run() external returns (MolphaEvaluator evaluator, MolphaConditionHook hook, MolphaProofVerifier adapter) {
        _requireTestnet();

        uint256 key = vm.envUint("PRIVATE_KEY");
        address broadcaster = vm.addr(key);
        address verifier = vm.envOr("VERIFIER", CANONICAL_VERIFIER);
        address owner = vm.envOr("OWNER", broadcaster);
        address core = vm.envOr("CORE", _coreFromFile());

        require(verifier.code.length > 0, "no verifier at VERIFIER on this chain");
        require(core.code.length > 0, "no ERC-8183 core at CORE on this chain");

        // Show what the evaluator will trust before anything is deployed.
        (bool ok, bytes memory ret) = verifier.staticcall(abi.encodeWithSignature("getRegistryVersion()"));
        require(ok && ret.length == 32, "verifier does not answer getRegistryVersion()");
        console2.log("verifier registry version:", abi.decode(ret, (uint256)));

        vm.startBroadcast(key);
        evaluator = new MolphaEvaluator(IVerifier(verifier), owner);
        hook = new MolphaConditionHook(IERC8183JobReader(core), IMolphaVerifier(verifier));
        adapter = new MolphaProofVerifier(IVerifier(verifier));
        bytes32 adminRole = ERC8183(core).ADMIN_ROLE();
        if (ERC8183(core).hasRole(adminRole, broadcaster)) {
            ERC8183(core).setHookWhitelist(address(hook), true);
        } else {
            console2.log("NOTICE: broadcaster is not the core admin. Admin must call setHookWhitelist(hook, true).");
        }
        vm.stopBroadcast();

        console2.log("MolphaEvaluator:      ", address(evaluator));
        console2.log("MolphaConditionHook:  ", address(hook));
        console2.log("MolphaProofVerifier:  ", address(adapter));

        string memory k = "molpha";
        vm.serializeAddress(k, "verifier", verifier);
        vm.serializeAddress(k, "hook", address(hook));
        vm.serializeAddress(k, "proofVerifier", address(adapter));
        string memory out = vm.serializeAddress(k, "evaluator", address(evaluator));
        _merge(_path(), out);
    }

    function _coreFromFile() internal view returns (address) {
        string memory path = _path();
        require(vm.exists(path), "set CORE, or run DeployCore first");
        return vm.parseJsonAddress(vm.readFile(path), ".core");
    }
}
