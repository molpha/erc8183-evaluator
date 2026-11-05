// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console2} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC8183} from "@erc8183/ERC8183.sol";

import {DeployBase} from "./lib/DeployBase.sol";

/// @title DeployCore
/// @notice Deploys the reference ERC-8183 core (`erc-8183/base-contracts` 142e669) behind an ERC-1967
///         proxy, as the reference intends, for a TESTNET demo. Nothing here is a production setup:
///         the admin is one key.
/// @dev Env:
///      - `PRIVATE_KEY` (required): broadcaster. Becomes admin and treasury unless overridden.
///      - `ADMIN`, `TREASURY` (optional): override the broadcaster.
///      - `PAYMENT_TOKEN` (optional): token to allowlist. Defaults to Base Sepolia USDC.
///      - `EVALUATOR_FEE_BP` (optional): evaluator fee in basis points. Default 50 (0.5%).
///      - `ALLOW_ANY_CHAIN=1` (optional): lift the testnet guard.
///      Writes `deployments/<chainid>.json` (keys `core`, `coreImplementation`, `paymentToken`).
contract DeployCore is DeployBase {
    address internal constant BASE_SEPOLIA_USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;

    function run() external returns (ERC8183 core) {
        _requireTestnet();

        uint256 key = vm.envUint("PRIVATE_KEY");
        address broadcaster = vm.addr(key);
        address admin = vm.envOr("ADMIN", broadcaster);
        address treasury = vm.envOr("TREASURY", broadcaster);
        address token = vm.envOr("PAYMENT_TOKEN", BASE_SEPOLIA_USDC);
        uint256 evaluatorFeeBp = vm.envOr("EVALUATOR_FEE_BP", uint256(50));

        require(token.code.length > 0, "payment token has no code on this chain");

        vm.startBroadcast(key);
        ERC8183 implementation = new ERC8183();
        ERC1967Proxy proxy =
            new ERC1967Proxy(address(implementation), abi.encodeCall(ERC8183.initialize, (treasury, admin)));
        core = ERC8183(address(proxy));
        // The allowlist and the evaluator fee are admin-only: they succeed only when the broadcaster
        // is the admin. Otherwise the admin sets them (see the printed notice).
        if (admin == broadcaster) {
            core.setPaymentTokenAllowed(token, true);
            core.setEvaluatorFee(evaluatorFeeBp);
        }
        vm.stopBroadcast();

        console2.log("ERC8183 implementation:", address(implementation));
        console2.log("ERC8183 core (proxy):  ", address(core));
        console2.log("admin:", admin);
        console2.log("treasury:", treasury);
        if (admin != broadcaster) {
            console2.log(
                "NOTICE: admin is not the broadcaster. Admin must call setPaymentTokenAllowed + setEvaluatorFee."
            );
        }

        string memory path = _path();
        string memory k = "core";
        vm.serializeAddress(k, "coreImplementation", address(implementation));
        vm.serializeAddress(k, "paymentToken", token);
        string memory out = vm.serializeAddress(k, "core", address(core));
        _merge(path, out);
    }
}
