// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC8183Hook} from "@erc8183/IERC8183Hook.sol";
import {IVerifier} from "@molpha/evm-verifier/interfaces/IVerifier.sol";
import {IERC8183HookMetadata} from "@hooks/interfaces/IERC8183HookMetadata.sol";

import {EvaluatorBase} from "./Base.t.sol";
import {MockRouterHook} from "./mocks/MockRouterHook.sol";
import {MockSelectiveRouterHook} from "./mocks/MockSelectiveRouterHook.sol";
import {MockHook} from "./mocks/MockHook.sol";
import {IERC8183Core} from "../src/interfaces/IERC8183Core.sol";
import {MolphaConditionHook, IMolphaVerifier, IERC8183JobReader} from "../src/MolphaConditionHook.sol";

contract MolphaConditionHookTest is EvaluatorBase {
    MolphaConditionHook internal hook;
    address internal judge = makeAddr("judge");

    function setUp() public override {
        super.setUp();
        hook = new MolphaConditionHook(IERC8183JobReader(address(core)), IMolphaVerifier(address(verifier)));
        vm.prank(admin);
        core.setHookWhitelist(address(hook), true);
    }

    // ------------------------------------------------------------------ helpers

    function _terms() internal pure returns (bytes memory) {
        return abi.encode(PR_CONFIG, PASS, SIGS);
    }

    function _newJob() internal returns (uint256 jobId) {
        vm.prank(client);
        jobId = core.createJob(provider, judge, uint48(vm.getBlockTimestamp() + WINDOW), "quality", address(hook), 0);
    }

    /// @dev Created, budget set, and funded with terms.
    function _fundedJob() internal returns (uint256 jobId) {
        jobId = _newJob();
        vm.prank(provider);
        core.setBudget(jobId, address(usdc), BUDGET, "");
        vm.startPrank(client);
        usdc.approve(address(core), BUDGET);
        core.fund(jobId, address(usdc), BUDGET, _terms());
        vm.stopPrank();
    }

    function _submittedJob() internal returns (uint256 jobId) {
        jobId = _fundedJob();
        vm.warp(vm.getBlockTimestamp() + 10 minutes);
        vm.prank(provider);
        core.submit(jobId, keccak256("work"), "");
    }

    function _complete(uint256 jobId, bytes memory optParams) internal {
        vm.prank(judge);
        core.complete(jobId, keccak256("graded: good"), optParams);
    }

    // ------------------------------------------------------------------ callbacks

    function test_onlyTheCoreCallsTheHook() public {
        vm.prank(stranger);
        vm.expectRevert(MolphaConditionHook.OnlyCore.selector);
        hook.beforeAction(1, bytes4(0), "");
        vm.prank(stranger);
        vm.expectRevert(MolphaConditionHook.OnlyCore.selector);
        hook.afterAction(1, bytes4(0), "");
    }

    // ------------------------------------------------------------------ behind a router

    function test_worksAsASubHookBehindARouter() public {
        MockRouterHook router = new MockRouterHook(hook);
        vm.prank(admin);
        core.setHookWhitelist(address(router), true);

        // The job's registered hook is the router: the hook sees the router, not the core, as caller.
        vm.prank(client);
        uint256 jobId =
            core.createJob(provider, judge, uint48(vm.getBlockTimestamp() + WINDOW), "routed", address(router), 0);
        vm.prank(provider);
        core.setBudget(jobId, address(usdc), BUDGET, "");
        vm.startPrank(client);
        usdc.approve(address(core), BUDGET);
        core.fund(jobId, address(usdc), BUDGET, _terms());
        vm.stopPrank();
        assertTrue(hook.termsOf(jobId).set, "terms were frozen through the router");

        vm.warp(vm.getBlockTimestamp() + 10 minutes);
        vm.prank(provider);
        core.submit(jobId, keccak256("work"), "");

        vm.prank(judge);
        vm.expectRevert(abi.encodeWithSelector(MolphaConditionHook.BadAttestation.selector, 0));
        core.complete(jobId, keccak256("g"), "");

        _complete(jobId, abi.encode(_att(PASS, vm.getBlockTimestamp())));
        assertEq(uint8(_status(jobId)), uint8(IERC8183Core.JobStatus.Completed));
    }

    function test_aCallerThatIsNotTheJobsHookIsRefused() public {
        uint256 jobId = _newJob(); // registered with `hook`, not with any other contract
        MockHook other = new MockHook();
        MockRouterHook foreign = new MockRouterHook(hook);
        vm.expectRevert(MolphaConditionHook.OnlyCore.selector);
        foreign.beforeAction(jobId, core.fund.selector, abi.encode(client, _terms()));
        vm.prank(address(other));
        vm.expectRevert(MolphaConditionHook.OnlyCore.selector);
        hook.beforeAction(jobId, core.fund.selector, abi.encode(client, _terms()));
        assertFalse(hook.termsOf(jobId).set);
    }

    /// @dev A job registered with `router` and wired for fund, submit, complete and, if asked,
    ///      submitClaim. Budget set and approved; not yet funded.
    function _routedJob(MockSelectiveRouterHook router, bool wireClaim) internal returns (uint256 jobId) {
        vm.prank(admin);
        core.setHookWhitelist(address(router), true);
        vm.prank(client);
        jobId = core.createJob(provider, judge, uint48(vm.getBlockTimestamp() + WINDOW), "routed", address(router), 0);

        bytes4[] memory sels = new bytes4[](wireClaim ? 4 : 3);
        sels[0] = core.fund.selector;
        sels[1] = core.submit.selector;
        sels[2] = core.complete.selector;
        if (wireClaim) sels[3] = core.submitClaim.selector;
        router.wire(jobId, sels);

        vm.prank(provider);
        core.setBudget(jobId, address(usdc), BUDGET, "");
        vm.prank(client);
        usdc.approve(address(core), BUDGET);
    }

    function test_aRouterCheckingTheMetadataRefusesAWiringWithoutSubmitClaim() public {
        MockSelectiveRouterHook router = new MockSelectiveRouterHook(hook, true);
        uint256 jobId = _routedJob(router, false);

        vm.prank(client);
        vm.expectRevert(
            abi.encodeWithSelector(MockSelectiveRouterHook.IncompleteWiring.selector, core.submitClaim.selector)
        );
        core.fund(jobId, address(usdc), BUDGET, _terms());

        assertEq(uint8(_status(jobId)), uint8(IERC8183Core.JobStatus.Open));
        assertEq(usdc.balanceOf(address(core)), 0);
    }

    function test_aRouterWiredForEveryRequiredSelectorKeepsTheClaimBlock() public {
        MockSelectiveRouterHook router = new MockSelectiveRouterHook(hook, true);
        uint256 jobId = _routedJob(router, true);
        vm.prank(client);
        core.fund(jobId, address(usdc), BUDGET, _terms());
        assertTrue(hook.termsOf(jobId).set);

        vm.prank(provider);
        vm.expectRevert(MolphaConditionHook.ClaimsNotAllowed.selector);
        core.submitClaim(jobId, BUDGET, keccak256("milestone"), "");
    }

    /// @dev The limit the hook cannot close by itself, kept as a test so it stays documented: a
    ///      router that ignores `requiredSelectors` and does not forward `submitClaim` lets the
    ///      evaluator pay out the whole budget through a claim, with no attestation.
    function test_limit_aRouterIgnoringTheMetadataReopensTheClaimPath() public {
        MockSelectiveRouterHook router = new MockSelectiveRouterHook(hook, false);
        uint256 jobId = _routedJob(router, false);
        vm.prank(client);
        core.fund(jobId, address(usdc), BUDGET, _terms());

        bytes32 deliverable = keccak256("milestone");
        vm.prank(provider);
        core.submitClaim(jobId, BUDGET, deliverable, "");
        vm.prank(judge);
        core.approveClaim(jobId, BUDGET, deliverable, "");

        uint256 fee = BUDGET * FEE_BP / 10_000;
        assertEq(usdc.balanceOf(provider), BUDGET - fee, "paid in full without an attestation");
        assertEq(icore.getJob(jobId).settledAmount, BUDGET);
    }

    function test_constructorRefusesZeroAddresses() public {
        vm.expectRevert(MolphaConditionHook.ZeroAddress.selector);
        new MolphaConditionHook(IERC8183JobReader(address(0)), IMolphaVerifier(address(verifier)));
        vm.expectRevert(MolphaConditionHook.ZeroAddress.selector);
        new MolphaConditionHook(IERC8183JobReader(address(core)), IMolphaVerifier(address(0)));
    }

    function test_interfacesAndSelectors() public view {
        assertTrue(hook.supportsInterface(type(IERC8183Hook).interfaceId));
        assertTrue(hook.supportsInterface(type(IERC8183HookMetadata).interfaceId));
        assertTrue(hook.supportsInterface(type(IERC165).interfaceId));
        assertFalse(hook.supportsInterface(0xffffffff));

        bytes4[] memory sels = hook.requiredSelectors();
        assertEq(sels.length, 4);
        assertEq(sels[0], core.fund.selector, "the real four-argument fund selector");
        assertEq(sels[1], core.submit.selector);
        assertEq(sels[2], core.complete.selector);
        assertEq(sels[3], core.submitClaim.selector, "a router must carry the claim block too");

        assertEq(IMolphaVerifier.verify.selector, IVerifier.verify.selector, "same ABI as the deployed verifier");
    }

    // ------------------------------------------------------------------ fund freezes the terms

    function test_fund_freezesTheTermsBeforeMoneyMoves() public {
        uint256 jobId = _newJob();
        vm.prank(provider);
        core.setBudget(jobId, address(usdc), BUDGET, "");

        vm.startPrank(client);
        usdc.approve(address(core), BUDGET);
        vm.expectEmit(true, true, false, true, address(hook));
        emit MolphaConditionHook.TermsFrozen(jobId, _sourceId(), PR_CONFIG, PASS, SIGS);
        core.fund(jobId, address(usdc), BUDGET, _terms());
        vm.stopPrank();

        MolphaConditionHook.Terms memory t = hook.termsOf(jobId);
        assertEq(t.sourceId, _sourceId());
        assertEq(t.passValue, PASS);
        assertEq(t.minSignatures, SIGS);
        assertTrue(t.set);
        assertEq(usdc.balanceOf(address(core)), BUDGET);
    }

    function test_fund_withoutTermsRevertsAndMovesNothing() public {
        uint256 jobId = _newJob();
        vm.prank(provider);
        core.setBudget(jobId, address(usdc), BUDGET, "");
        vm.startPrank(client);
        usdc.approve(address(core), BUDGET);
        vm.expectRevert(MolphaConditionHook.NoTerms.selector);
        core.fund(jobId, address(usdc), BUDGET, "");
        vm.stopPrank();
        assertEq(usdc.balanceOf(address(core)), 0);
        assertEq(uint8(_status(jobId)), uint8(IERC8183Core.JobStatus.Open));
    }

    function test_fund_refusesBadTerms() public {
        uint256 jobId = _newJob();
        vm.prank(provider);
        core.setBudget(jobId, address(usdc), BUDGET, "");
        vm.startPrank(client);
        usdc.approve(address(core), BUDGET);

        vm.expectRevert(MolphaConditionHook.EmptyConfig.selector);
        core.fund(jobId, address(usdc), BUDGET, abi.encode("", PASS, SIGS));

        vm.expectRevert(abi.encodeWithSelector(MolphaConditionHook.ConfigTooLong.selector, 2049));
        core.fund(jobId, address(usdc), BUDGET, abi.encode(string(new bytes(2049)), PASS, SIGS));

        vm.expectRevert(MolphaConditionHook.TemplatePlaceholder.selector);
        core.fund(jobId, address(usdc), BUDGET, abi.encode('{"url":"https://x.test/{{secret.REPO}}"}', PASS, SIGS));
        vm.expectRevert(MolphaConditionHook.TemplatePlaceholder.selector);
        core.fund(jobId, address(usdc), BUDGET, abi.encode('{"url":"https://x.test/{{ secret.REPO }}"}', PASS, SIGS));

        vm.expectRevert(MolphaConditionHook.ZeroPassValue.selector);
        core.fund(jobId, address(usdc), BUDGET, abi.encode(PR_CONFIG, bytes32(0), SIGS));

        vm.expectRevert(abi.encodeWithSelector(MolphaConditionHook.ThresholdBelowFloor.selector, uint8(2), uint8(3)));
        core.fund(jobId, address(usdc), BUDGET, abi.encode(PR_CONFIG, PASS, uint8(2)));

        // The test committee has 8 nodes: a threshold must leave a spare signer.
        vm.expectRevert(abi.encodeWithSelector(MolphaConditionHook.NoSpareSigner.selector, uint8(8), 8));
        core.fund(jobId, address(usdc), BUDGET, abi.encode(PR_CONFIG, PASS, uint8(8)));
        vm.stopPrank();

        assertFalse(hook.termsOf(jobId).set);
    }

    // ------------------------------------------------------------------ submit gate

    function test_submit_isBlockedWithoutTermsEvenOnAZeroBudgetJob() public {
        // An Open job with no budget may be submitted without ever being funded: the only path
        // that would skip `fund`, and with it the terms.
        uint256 jobId = _newJob();
        vm.prank(provider);
        vm.expectRevert(MolphaConditionHook.NoTerms.selector);
        core.submit(jobId, keccak256("work"), "");
    }

    // ------------------------------------------------------------------ complete gate

    function test_complete_withThePassAttestationPaysTheProvider() public {
        uint256 jobId = _submittedJob();
        IVerifier.Attestation memory att = _att(PASS, vm.getBlockTimestamp());
        assertEq(abi.encode(att).length, 256, "a static attestation encodes to eight words");

        _complete(jobId, abi.encode(att));

        assertEq(uint8(_status(jobId)), uint8(IERC8183Core.JobStatus.Completed));
        uint256 fee = BUDGET * FEE_BP / 10_000;
        assertEq(usdc.balanceOf(provider), BUDGET - fee);
        assertEq(usdc.balanceOf(judge), fee, "the quality judge, not the hook, earns the evaluator fee");
    }

    function test_complete_isBlockedWithoutAnAttestation() public {
        uint256 jobId = _submittedJob();
        vm.prank(judge);
        vm.expectRevert(abi.encodeWithSelector(MolphaConditionHook.BadAttestation.selector, 0));
        core.complete(jobId, keccak256("graded: good"), "");
        assertEq(uint8(_status(jobId)), uint8(IERC8183Core.JobStatus.Submitted));
    }

    function test_complete_refusesAMalformedAttestationBlob() public {
        uint256 jobId = _submittedJob();
        vm.prank(judge);
        vm.expectRevert(abi.encodeWithSelector(MolphaConditionHook.BadAttestation.selector, 255));
        core.complete(jobId, keccak256("graded: good"), new bytes(255));
    }

    function test_complete_refusesTheFailWordAndAnyOtherWord() public {
        uint256 jobId = _submittedJob();
        bytes memory notMerged = abi.encode(_att(FAIL, vm.getBlockTimestamp()));
        vm.prank(judge);
        vm.expectRevert(abi.encodeWithSelector(MolphaConditionHook.UnexpectedValue.selector, FAIL));
        core.complete(jobId, keccak256("graded: good"), notMerged);

        bytes memory zero = abi.encode(_att(bytes32(0), vm.getBlockTimestamp()));
        vm.prank(judge);
        vm.expectRevert(abi.encodeWithSelector(MolphaConditionHook.UnexpectedValue.selector, bytes32(0)));
        core.complete(jobId, keccak256("graded: good"), zero);
    }

    function test_complete_refusesAnotherSourceAThinThresholdAndABadSignature() public {
        uint256 jobId = _submittedJob();
        uint64 nowMs = uint64(vm.getBlockTimestamp()) * 1000;

        bytes32 other = keccak256("another source");
        bytes memory wrongSource = abi.encode(signer.attest(other, PASS, SIGS, nowMs));
        vm.prank(judge);
        vm.expectRevert(abi.encodeWithSelector(MolphaConditionHook.WrongSource.selector, _sourceId(), other));
        core.complete(jobId, keccak256("g"), wrongSource);

        // Terms ask for 3; a 3-signer attestation passes the floor, so test a too-thin one with
        // the minimum the verifier allows to be a real signature below the terms.
        IVerifier.Attestation memory thin = signer.attest(_sourceId(), PASS, 1, nowMs);
        vm.prank(judge);
        vm.expectRevert(abi.encodeWithSelector(MolphaConditionHook.ThresholdBelowTerms.selector, uint8(3), uint8(1)));
        core.complete(jobId, keccak256("g"), abi.encode(thin));

        IVerifier.Attestation memory tampered = _att(PASS, vm.getBlockTimestamp());
        tampered.signature.signature = bytes32(uint256(tampered.signature.signature) + 1);
        vm.prank(judge);
        vm.expectRevert(abi.encodeWithSelector(MolphaConditionHook.VerifyFailed.selector, uint8(9)));
        core.complete(jobId, keccak256("g"), abi.encode(tampered));
    }

    function test_complete_enforcesTheJobWindowAndTheSkew() public {
        uint256 jobId = _submittedJob();
        IERC8183Core.Job memory job = icore.getJob(jobId);

        bytes memory early = abi.encode(_att(PASS, job.submittedAt - 1));
        vm.prank(judge);
        vm.expectRevert(
            abi.encodeWithSelector(
                MolphaConditionHook.OutsideWindow.selector, job.submittedAt - 1, job.submittedAt, job.expiredAt
            )
        );
        core.complete(jobId, keccak256("g"), early);

        uint256 nowSec = vm.getBlockTimestamp();
        bytes memory tooFar = abi.encode(_att(PASS, nowSec + 16));
        vm.prank(judge);
        vm.expectRevert(
            abi.encodeWithSelector(MolphaConditionHook.FutureAttestation.selector, nowSec + 16, nowSec + 15)
        );
        core.complete(jobId, keccak256("g"), tooFar);

        // Taken in the last second of the window and graded inside the grace hour.
        bytes memory late = abi.encode(_att(PASS, job.expiredAt - 1));
        vm.warp(uint256(job.expiredAt) + 30 minutes);
        _complete(jobId, late);
        assertEq(uint8(_status(jobId)), uint8(IERC8183Core.JobStatus.Completed));

        // And an attestation taken at the deadline is outside the window.
        uint256 jobId2 = _submittedJob();
        IERC8183Core.Job memory job2 = icore.getJob(jobId2);
        bytes memory atDeadline = abi.encode(_att(PASS, job2.expiredAt));
        vm.warp(job2.expiredAt);
        // (the job can no longer be submitted at the deadline, but it is already Submitted)
        vm.prank(judge);
        vm.expectRevert(
            abi.encodeWithSelector(
                MolphaConditionHook.OutsideWindow.selector, job2.expiredAt, job2.submittedAt, job2.expiredAt
            )
        );
        core.complete(jobId2, keccak256("g"), atDeadline);
    }

    // ------------------------------------------------------------------ reject and claims

    function test_reject_isNotGated() public {
        uint256 jobId = _submittedJob();
        uint256 clientBefore = usdc.balanceOf(client);
        vm.prank(judge);
        core.reject(jobId, keccak256("graded: poor"), "");
        assertEq(uint8(_status(jobId)), uint8(IERC8183Core.JobStatus.Rejected));
        assertEq(usdc.balanceOf(client) - clientBefore, BUDGET);
    }

    function test_submitClaim_isBlockedSoTheClaimPathCannotBypassTheGate() public {
        uint256 jobId = _fundedJob();
        vm.prank(provider);
        vm.expectRevert(MolphaConditionHook.ClaimsNotAllowed.selector);
        core.submitClaim(jobId, 10e6, keccak256("milestone"), "");
    }

    function test_claimRefundStaysOpenToTheClient() public {
        uint256 jobId = _submittedJob();
        vm.warp(uint256(icore.getJob(jobId).expiredAt) + 1 hours);
        core.claimRefund(jobId);
        assertEq(uint8(_status(jobId)), uint8(IERC8183Core.JobStatus.Expired));
    }

    // ------------------------------------------------------------------ property

    function testFuzz_completesOnlyOnThePassWordInsideTheWindow(
        bytes32 value,
        bool usePass,
        uint256 nowOffset,
        uint256 attOffset
    ) public {
        uint256 jobId = _submittedJob();
        IERC8183Core.Job memory job = icore.getJob(jobId);

        uint256 nowSec = bound(nowOffset, job.submittedAt, uint256(job.expiredAt) + 3 hours);
        vm.warp(nowSec);
        uint256 ts = bound(attOffset, job.submittedAt - 120, nowSec + 30);
        bytes32 word = usePass ? PASS : value;
        bytes memory blob = abi.encode(_att(word, ts));

        vm.prank(judge);
        try core.complete(jobId, keccak256("g"), blob) {
            assertEq(word, PASS, "completed on a word that is not the pass word");
            assertGe(ts, job.submittedAt, "completed on a fact from before submission");
            assertLt(ts, job.expiredAt, "completed on a fact from after the deadline");
        } catch {
            assertEq(uint8(_status(jobId)), uint8(IERC8183Core.JobStatus.Submitted), "a refusal moves nothing");
        }
    }
}
