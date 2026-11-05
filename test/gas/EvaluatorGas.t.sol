// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IVerifier} from "@molpha/evm-verifier/interfaces/IVerifier.sol";

import {EvaluatorBase} from "../Base.t.sol";
import {IERC8183Core} from "../../src/interfaces/IERC8183Core.sol";
import {MolphaProofVerifier} from "../../src/adapters/MolphaProofVerifier.sol";
import {MolphaConditionHook, IMolphaVerifier, IERC8183JobReader} from "../../src/MolphaConditionHook.sol";

/// @dev Run as `FOUNDRY_PROFILE=gas forge test -vv`. In isolate mode every call below is its own
///      transaction, so the snapshots include the 21,000 intrinsic gas and calldata. State is built
///      in `setUp`, so each measured call starts cold, as a first call on chain would.
///      The verifier here runs 8 nodes with 3 signers (the testnet committee shape is 5 nodes).
contract EvaluatorGasTest is EvaluatorBase {
    MolphaConditionHook internal hook;
    MolphaProofVerifier internal adapter;
    address internal judge = makeAddr("judge");

    uint256 internal regJob;
    uint256 internal evalJob;
    uint256 internal baselineJob;
    uint256 internal hookFundJob;
    uint256 internal hookCompleteJob;
    IVerifier.Attestation internal evalAtt;
    IVerifier.Attestation internal hookAtt;

    function setUp() public override {
        super.setUp();
        hook = new MolphaConditionHook(IERC8183JobReader(address(core)), IMolphaVerifier(address(verifier)));
        adapter = new MolphaProofVerifier(verifier);
        vm.prank(admin);
        core.setHookWhitelist(address(hook), true);

        regJob = _createJob();

        evalJob = _submittedJob(false);
        evalAtt = _att(PASS, vm.getBlockTimestamp());

        // The same job completed by an externally owned evaluator: the baseline for `complete`.
        vm.prank(client);
        baselineJob = core.createJob(provider, judge, uint48(vm.getBlockTimestamp() + WINDOW), "plain", address(0), 0);
        _fundPlain(baselineJob);

        // A hook job still waiting to be funded, and one already submitted.
        hookFundJob = _newHookJob();
        vm.prank(provider);
        core.setBudget(hookFundJob, address(usdc), BUDGET, "");
        hookCompleteJob = _newHookJob();
        _fundHook(hookCompleteJob);
        vm.warp(vm.getBlockTimestamp() + 10 minutes);
        vm.prank(provider);
        core.submit(hookCompleteJob, keccak256("work"), "");
        vm.prank(provider);
        core.submit(baselineJob, keccak256("work"), "");
        hookAtt = _att(PASS, vm.getBlockTimestamp());
    }

    function _newHookJob() internal returns (uint256 jobId) {
        vm.prank(client);
        jobId = core.createJob(provider, judge, uint48(vm.getBlockTimestamp() + WINDOW), "q", address(hook), 0);
    }

    function _fundPlain(uint256 jobId) internal {
        vm.prank(provider);
        core.setBudget(jobId, address(usdc), BUDGET, "");
        vm.startPrank(client);
        usdc.approve(address(core), BUDGET);
        core.fund(jobId, address(usdc), BUDGET, "");
        vm.stopPrank();
    }

    function _fundHook(uint256 jobId) internal {
        vm.prank(provider);
        core.setBudget(jobId, address(usdc), BUDGET, "");
        vm.startPrank(client);
        usdc.approve(address(core), BUDGET);
        core.fund(jobId, address(usdc), BUDGET, abi.encode(PR_CONFIG, PASS, SIGS));
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ measurements

    function test_gas_verifierVerify() public {
        verifier.verify(evalAtt, 0);
        vm.snapshotGasLastCall("gas", "Verifier.verify (reference)");
    }

    function test_gas_evaluate_pass() public {
        vm.prank(stranger);
        evaluator.evaluate(icore, evalJob, evalAtt);
        vm.snapshotGasLastCall("gas", "MolphaEvaluator.evaluate pass (complete, fee path)");
    }

    function test_gas_registerTerms() public {
        vm.prank(client);
        evaluator.registerTerms(icore, regJob, PR_CONFIG, PASS, FAIL, true, SIGS);
        vm.snapshotGasLastCall("gas", "MolphaEvaluator.registerTerms");
    }

    function test_gas_baselineCompleteByAnEoa() public {
        vm.prank(judge);
        core.complete(baselineJob, keccak256("ok"), "");
        vm.snapshotGasLastCall("gas", "ERC8183.complete by an EOA evaluator (baseline)");
    }

    function test_gas_hookFundWithTerms() public {
        vm.startPrank(client);
        usdc.approve(address(core), BUDGET);
        vm.stopPrank();
        vm.prank(client);
        core.fund(hookFundJob, address(usdc), BUDGET, abi.encode(PR_CONFIG, PASS, SIGS));
        vm.snapshotGasLastCall("gas", "ERC8183.fund through MolphaConditionHook (freezes terms)");
    }

    function test_gas_hookComplete() public {
        vm.prank(judge);
        core.complete(hookCompleteJob, keccak256("graded"), abi.encode(hookAtt));
        vm.snapshotGasLastCall("gas", "ERC8183.complete through MolphaConditionHook (verifies)");
    }

    function test_gas_adapterVerify() public {
        adapter.verify(_sourceId(), PASS, abi.encode(uint256(SIGS), uint256(0), uint256(0)), abi.encode(evalAtt));
        vm.snapshotGasLastCall("gas", "MolphaProofVerifier.verify (ERC-8274)");
    }
}
