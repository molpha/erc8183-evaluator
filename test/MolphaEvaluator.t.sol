// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC8183} from "@erc8183/ERC8183.sol";
import {IVerifier} from "@molpha/evm-verifier/interfaces/IVerifier.sol";
import {MolphaLib} from "@molpha/evm-verifier/consumer/MolphaLib.sol";

import {EvaluatorBase} from "./Base.t.sol";
import {MockHook} from "./mocks/MockHook.sol";
import {MolphaEvaluator} from "../src/MolphaEvaluator.sol";
import {MolphaJobTerms} from "../src/lib/MolphaJobTerms.sol";
import {IERC8183Core} from "../src/interfaces/IERC8183Core.sol";

contract MolphaEvaluatorTest is EvaluatorBase {
    // ================================================================== registerTerms

    function test_registerTerms_storesAndEmitsPublicTerms() public {
        uint256 jobId = _createJob();

        vm.expectEmit(true, true, true, true, address(evaluator));
        emit MolphaEvaluator.TermsRegistered(address(core), jobId, _sourceId(), PR_CONFIG, PASS, FAIL, true, SIGS);
        _register(jobId, true, SIGS);

        MolphaJobTerms.Terms memory t = evaluator.termsOf(address(core), jobId);
        assertEq(t.sourceId, _sourceId());
        assertEq(t.passValue, PASS);
        assertEq(t.failValue, FAIL);
        assertEq(t.minSignatures, SIGS);
        assertTrue(t.hasFail);
        assertTrue(t.set);
    }

    function test_registerTerms_withoutFailStoresNoFailWord() public {
        uint256 jobId = _createJob();
        vm.prank(client);
        evaluator.registerTerms(icore, jobId, PR_CONFIG, PASS, FAIL, false, SIGS);
        MolphaJobTerms.Terms memory t = evaluator.termsOf(address(core), jobId);
        assertFalse(t.hasFail);
        assertEq(t.failValue, bytes32(0), "an unused fail word is not stored");
    }

    function test_registerTerms_onlyTheClient() public {
        uint256 jobId = _createJob();
        vm.prank(stranger);
        vm.expectRevert(MolphaEvaluator.NotClient.selector);
        evaluator.registerTerms(icore, jobId, PR_CONFIG, PASS, FAIL, true, SIGS);

        vm.prank(provider);
        vm.expectRevert(MolphaEvaluator.NotClient.selector);
        evaluator.registerTerms(icore, jobId, PR_CONFIG, PASS, FAIL, true, SIGS);
    }

    function test_registerTerms_unknownJobIsNotClients() public {
        vm.prank(client);
        vm.expectRevert(MolphaEvaluator.NotClient.selector);
        evaluator.registerTerms(icore, 999, PR_CONFIG, PASS, FAIL, true, SIGS);
    }

    function test_registerTerms_onlyWhileOpen() public {
        uint256 jobId = _createJob();
        _fund(jobId);
        vm.prank(client);
        vm.expectRevert(abi.encodeWithSelector(MolphaEvaluator.WrongStatus.selector, IERC8183Core.JobStatus.Funded));
        evaluator.registerTerms(icore, jobId, PR_CONFIG, PASS, FAIL, true, SIGS);
    }

    function test_registerTerms_onlyForJobsNamingThisEvaluator() public {
        vm.prank(client);
        uint256 jobId = core.createJob(provider, stranger, uint48(vm.getBlockTimestamp() + WINDOW), "x", address(0), 0);
        vm.prank(client);
        vm.expectRevert(MolphaEvaluator.NotEvaluator.selector);
        evaluator.registerTerms(icore, jobId, PR_CONFIG, PASS, FAIL, true, SIGS);
    }

    function test_registerTerms_refusesAClientHook() public {
        MockHook hook = new MockHook();
        vm.prank(admin);
        core.setHookWhitelist(address(hook), true);
        vm.prank(client);
        uint256 jobId = core.createJob(
            provider, address(evaluator), uint48(vm.getBlockTimestamp() + WINDOW), "x", address(hook), 0
        );

        vm.prank(client);
        vm.expectRevert(MolphaEvaluator.HookNotAllowed.selector);
        evaluator.registerTerms(icore, jobId, PR_CONFIG, PASS, FAIL, true, SIGS);
    }

    function test_registerTerms_onlyOnce() public {
        uint256 jobId = _createJob();
        _register(jobId, true, SIGS);
        vm.prank(client);
        vm.expectRevert(MolphaEvaluator.TermsAlreadySet.selector);
        evaluator.registerTerms(icore, jobId, PR_CONFIG, PASS, FAIL, true, SIGS);
    }

    function test_registerTerms_refusesBadTerms() public {
        uint256 jobId = _createJob();
        vm.startPrank(client);

        vm.expectRevert(MolphaJobTerms.EmptyConfig.selector);
        evaluator.registerTerms(icore, jobId, "", PASS, FAIL, true, SIGS);

        vm.expectRevert(abi.encodeWithSelector(MolphaJobTerms.ConfigTooLong.selector, 2049));
        evaluator.registerTerms(icore, jobId, string(new bytes(2049)), PASS, FAIL, true, SIGS);

        // A template placeholder lets whoever requests the round choose what is fetched; any
        // spelling of one is refused, not only the exact `{{secret.` form.
        string[3] memory templated = [
            '{"url":"https://x.test/{{secret.REPO}}","method":"GET"}',
            '{"url":"https://x.test/{{ secret.REPO }}","method":"GET"}',
            '{"url":"https://x.test/{{SECRET.REPO}}","method":"GET"}'
        ];
        for (uint256 i; i < templated.length; ++i) {
            vm.expectRevert(MolphaJobTerms.TemplatePlaceholder.selector);
            evaluator.registerTerms(icore, jobId, templated[i], PASS, FAIL, true, SIGS);
        }

        // Zero is what a node signs for a value it could not read.
        vm.expectRevert(MolphaJobTerms.ZeroPassValue.selector);
        evaluator.registerTerms(icore, jobId, PR_CONFIG, bytes32(0), FAIL, true, SIGS);
        vm.expectRevert(MolphaJobTerms.ZeroFailValue.selector);
        evaluator.registerTerms(icore, jobId, PR_CONFIG, PASS, bytes32(0), true, SIGS);

        vm.expectRevert(MolphaJobTerms.PassEqualsFail.selector);
        evaluator.registerTerms(icore, jobId, PR_CONFIG, PASS, PASS, true, SIGS);

        vm.expectRevert(abi.encodeWithSelector(MolphaJobTerms.ThresholdBelowFloor.selector, uint8(2), uint8(3)));
        evaluator.registerTerms(icore, jobId, PR_CONFIG, PASS, FAIL, true, 2);

        // The test committee has 8 nodes. 8 of 8 would need every node, so one node offline would
        // block every pass; 9 could never be signed at all.
        vm.expectRevert(abi.encodeWithSelector(MolphaEvaluator.NoSpareSigner.selector, uint8(8), 8));
        evaluator.registerTerms(icore, jobId, PR_CONFIG, PASS, FAIL, true, 8);
        vm.expectRevert(abi.encodeWithSelector(MolphaEvaluator.NoSpareSigner.selector, uint8(9), 8));
        evaluator.registerTerms(icore, jobId, PR_CONFIG, PASS, FAIL, true, 9);

        vm.stopPrank();
        assertFalse(evaluator.termsOf(address(core), jobId).set, "a refused registration leaves nothing behind");
    }

    function test_registerTerms_acceptsAThresholdThatLeavesOneSpareSigner() public {
        uint256 jobId = _createJob();
        _register(jobId, false, 7);
        assertEq(evaluator.termsOf(address(core), jobId).minSignatures, 7);
    }

    // ================================================================== evaluate: pass

    function test_evaluate_passCompletesTheJobForAThirdParty() public {
        uint256 jobId = _submittedJob(false);
        IVerifier.Attestation memory att = _att(PASS, vm.getBlockTimestamp());
        bytes32 digest = _digest(att);

        vm.expectEmit(true, true, true, true, address(evaluator));
        emit MolphaEvaluator.Evaluated(
            address(core), jobId, true, _sourceId(), PASS, att.payload.timestamp, att.signature.signersBitmap
        );
        vm.expectEmit(true, true, false, true, address(core));
        emit ERC8183.JobCompleted(jobId, address(evaluator), digest);

        vm.prank(stranger);
        evaluator.evaluate(icore, jobId, att);

        assertEq(uint8(_status(jobId)), uint8(IERC8183Core.JobStatus.Completed));
        uint256 fee = BUDGET * FEE_BP / 10_000;
        assertEq(usdc.balanceOf(provider), BUDGET - fee, "provider is paid the net budget");
        assertEq(usdc.balanceOf(address(evaluator)), fee, "the evaluator fee accrues to the evaluator");
    }

    function test_evaluate_passWindowEdges() public {
        // submittedAt .. expiredAt - 1 are inside the window; one second either side is not.
        uint256 jobId = _submittedJob(false);
        IERC8183Core.Job memory job = icore.getJob(jobId);
        uint256 submittedAt = job.submittedAt;
        uint256 expiredAt = job.expiredAt;

        IVerifier.Attestation memory early = _att(PASS, submittedAt - 1);
        vm.expectRevert(
            abi.encodeWithSelector(MolphaEvaluator.OutsideWindow.selector, submittedAt - 1, submittedAt, expiredAt)
        );
        evaluator.evaluate(icore, jobId, early);

        vm.warp(expiredAt + 10 minutes);
        IVerifier.Attestation memory atDeadline = _att(PASS, expiredAt);
        vm.expectRevert(
            abi.encodeWithSelector(MolphaEvaluator.OutsideWindow.selector, expiredAt, submittedAt, expiredAt)
        );
        evaluator.evaluate(icore, jobId, atDeadline);

        // Taken in the last second of the window, finalized well after it (a pass keeps priority).
        evaluator.evaluate(icore, jobId, _att(PASS, expiredAt - 1));
        assertEq(uint8(_status(jobId)), uint8(IERC8183Core.JobStatus.Completed));
    }

    function test_evaluate_passAtTheSubmissionSecondCompletes() public {
        uint256 jobId = _submittedJob(false);
        uint256 submittedAt = icore.getJob(jobId).submittedAt;
        vm.warp(submittedAt + 5 minutes);
        evaluator.evaluate(icore, jobId, _att(PASS, submittedAt));
        assertEq(uint8(_status(jobId)), uint8(IERC8183Core.JobStatus.Completed));
    }

    function test_evaluate_finalizesInsideTheGraceHourWithNoMolphaService() public {
        // The attestation is a file: nothing here talks to Molpha after it was taken.
        uint256 jobId = _submittedJob(false);
        IVerifier.Attestation memory saved = _att(PASS, vm.getBlockTimestamp());
        uint256 expiredAt = icore.getJob(jobId).expiredAt;

        vm.warp(expiredAt + 59 minutes);
        vm.prank(stranger);
        evaluator.evaluate(icore, jobId, saved);
        assertEq(uint8(_status(jobId)), uint8(IERC8183Core.JobStatus.Completed));
    }

    function test_evaluate_afterClaimRefundTheJobIsGone() public {
        uint256 jobId = _submittedJob(false);
        IVerifier.Attestation memory saved = _att(PASS, vm.getBlockTimestamp());
        vm.warp(icore.getJob(jobId).expiredAt + 1 hours);
        core.claimRefund(jobId);

        vm.expectRevert(abi.encodeWithSelector(MolphaEvaluator.WrongStatus.selector, IERC8183Core.JobStatus.Expired));
        evaluator.evaluate(icore, jobId, saved);
    }

    function test_evaluate_clockSkewAllowance() public {
        uint256 jobId = _submittedJob(false);
        evaluator.evaluate(icore, jobId, _att(PASS, vm.getBlockTimestamp() + 15));
        assertEq(uint8(_status(jobId)), uint8(IERC8183Core.JobStatus.Completed));

        uint256 jobId2 = _submittedJob(false);
        uint256 now_ = vm.getBlockTimestamp();
        IVerifier.Attestation memory tooFar = _att(PASS, now_ + 16);
        vm.expectRevert(abi.encodeWithSelector(MolphaEvaluator.FutureAttestation.selector, now_ + 16, now_ + 15));
        evaluator.evaluate(icore, jobId2, tooFar);
    }

    function test_evaluate_aJustProducedRoundVerifiesOnTheNextBlock() public {
        // The gateway stamps a round slightly ahead of a block that is a couple of seconds old.
        uint256 jobId = _submittedJob(false);
        IVerifier.Attestation memory att = _att(PASS, vm.getBlockTimestamp() + 2);
        evaluator.evaluate(icore, jobId, att);
        assertEq(uint8(_status(jobId)), uint8(IERC8183Core.JobStatus.Completed));
    }

    // ================================================================== evaluate: refusals

    function test_evaluate_needsTerms() public {
        uint256 jobId = _createJob();
        _fund(jobId);
        vm.warp(vm.getBlockTimestamp() + 1 minutes);
        _submit(jobId);
        IVerifier.Attestation memory att = _att(PASS, vm.getBlockTimestamp());
        vm.expectRevert(MolphaEvaluator.NoTerms.selector);
        evaluator.evaluate(icore, jobId, att);
    }

    function test_evaluate_onlyASubmittedJob() public {
        uint256 jobId = _createJob();
        _register(jobId, false, SIGS);
        _fund(jobId);
        IVerifier.Attestation memory att = _att(PASS, vm.getBlockTimestamp());
        vm.expectRevert(abi.encodeWithSelector(MolphaEvaluator.WrongStatus.selector, IERC8183Core.JobStatus.Funded));
        evaluator.evaluate(icore, jobId, att);
    }

    function test_evaluate_aCompletedJobCannotBeReplayed() public {
        uint256 jobId = _submittedJob(false);
        IVerifier.Attestation memory att = _att(PASS, vm.getBlockTimestamp());
        evaluator.evaluate(icore, jobId, att);
        vm.expectRevert(abi.encodeWithSelector(MolphaEvaluator.WrongStatus.selector, IERC8183Core.JobStatus.Completed));
        evaluator.evaluate(icore, jobId, att);
    }

    function test_evaluate_refusesAnotherSource() public {
        uint256 jobId = _submittedJob(false);
        bytes32 other = keccak256("some other source");
        IVerifier.Attestation memory att = signer.attest(other, PASS, SIGS, uint64(vm.getBlockTimestamp()) * 1000);
        vm.expectRevert(abi.encodeWithSelector(MolphaLib.WrongSource.selector, _sourceId(), other));
        evaluator.evaluate(icore, jobId, att);
    }

    function test_evaluate_refusesAThresholdBelowTheTerms() public {
        uint256 jobId = _createJob();
        _register(jobId, false, 5);
        _fund(jobId);
        vm.warp(vm.getBlockTimestamp() + 10 minutes);
        _submit(jobId);
        // Signed by 3 of the committee: genuine, but below what these terms ask for.
        IVerifier.Attestation memory att = _att(PASS, vm.getBlockTimestamp());
        vm.expectRevert(abi.encodeWithSelector(MolphaLib.ThresholdBelowPolicy.selector, uint32(5), uint32(3)));
        evaluator.evaluate(icore, jobId, att);
    }

    function test_evaluate_refusesATamperedSignature() public {
        uint256 jobId = _submittedJob(false);
        IVerifier.Attestation memory att = _att(PASS, vm.getBlockTimestamp());
        att.signature.signature = bytes32(uint256(att.signature.signature) + 1);
        vm.expectRevert(abi.encodeWithSelector(MolphaLib.VerifyFailed.selector, uint8(9)));
        evaluator.evaluate(icore, jobId, att);
    }

    function test_evaluate_refusesAForgedValue() public {
        // A genuine signature over "not merged" cannot be relabelled as "merged".
        uint256 jobId = _submittedJob(false);
        IVerifier.Attestation memory att = _att(FAIL, vm.getBlockTimestamp());
        att.payload.value = PASS;
        vm.expectRevert(abi.encodeWithSelector(MolphaLib.VerifyFailed.selector, uint8(9)));
        evaluator.evaluate(icore, jobId, att);
    }

    function test_evaluate_refusesAWordThatIsNeitherPassNorFail() public {
        uint256 jobId = _submittedJob(true);
        bytes32 junk = keccak256("maybe");
        IVerifier.Attestation memory junkAtt = _att(junk, vm.getBlockTimestamp());
        vm.expectRevert(abi.encodeWithSelector(MolphaEvaluator.UnexpectedValue.selector, junk));
        evaluator.evaluate(icore, jobId, junkAtt);

        // Zero is what an unreadable value signs as: never a verdict.
        IVerifier.Attestation memory zeroAtt = _att(bytes32(0), vm.getBlockTimestamp());
        vm.expectRevert(abi.encodeWithSelector(MolphaEvaluator.UnexpectedValue.selector, bytes32(0)));
        evaluator.evaluate(icore, jobId, zeroAtt);
    }

    // ================================================================== evaluate: fail

    function test_evaluate_failRejectsAndRefundsTheClientAfterTheDelay() public {
        uint256 jobId = _submittedJob(true);
        uint256 expiredAt = icore.getJob(jobId).expiredAt;
        uint256 clientBefore = usdc.balanceOf(client);

        vm.warp(expiredAt + 30 minutes);
        IVerifier.Attestation memory att = _att(FAIL, expiredAt);
        vm.prank(stranger);
        evaluator.evaluate(icore, jobId, att);

        assertEq(uint8(_status(jobId)), uint8(IERC8183Core.JobStatus.Rejected));
        assertEq(usdc.balanceOf(client) - clientBefore, BUDGET, "the whole budget goes back");
        assertEq(usdc.balanceOf(address(evaluator)), 0, "no fee is earned on a rejection");
    }

    function test_evaluate_failWaitsForTheDelayAndTheDeadline() public {
        uint256 jobId = _submittedJob(true);
        uint256 expiredAt = icore.getJob(jobId).expiredAt;

        vm.warp(expiredAt + 30 minutes - 1);
        IVerifier.Attestation memory early = _att(FAIL, expiredAt);
        vm.expectRevert(
            abi.encodeWithSelector(MolphaEvaluator.FailNotYet.selector, expiredAt, expiredAt, expiredAt + 30 minutes)
        );
        evaluator.evaluate(icore, jobId, early);

        // Taken before the deadline: the provider still had time to make the fact true.
        vm.warp(expiredAt + 30 minutes);
        IVerifier.Attestation memory beforeDeadline = _att(FAIL, expiredAt - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                MolphaEvaluator.FailNotYet.selector, expiredAt - 1, expiredAt, expiredAt + 30 minutes
            )
        );
        evaluator.evaluate(icore, jobId, beforeDeadline);
    }

    function test_evaluate_failWordIsRefusedWhenTermsHaveNoFail() public {
        uint256 jobId = _submittedJob(false);
        uint256 expiredAt = icore.getJob(jobId).expiredAt;
        vm.warp(expiredAt + 30 minutes);
        IVerifier.Attestation memory att = _att(FAIL, expiredAt);
        vm.expectRevert(abi.encodeWithSelector(MolphaEvaluator.UnexpectedValue.selector, FAIL));
        evaluator.evaluate(icore, jobId, att);
    }

    function test_evaluate_aLatePassBeatsTheFailDelay() public {
        // The fact became true in the last second; a fail taken after the deadline loses the race.
        uint256 jobId = _submittedJob(true);
        uint256 expiredAt = icore.getJob(jobId).expiredAt;
        vm.warp(expiredAt + 10 minutes);
        evaluator.evaluate(icore, jobId, _att(PASS, expiredAt - 1));
        assertEq(uint8(_status(jobId)), uint8(IERC8183Core.JobStatus.Completed));
    }

    /// @dev Documents the replay model: the guard is each job's own status change, so two jobs
    ///      with the same source and pass word settle on one attestation. The source has to name
    ///      the job's deliverable.
    function test_oneAttestationSettlesEveryJobWithTheSameTerms() public {
        uint256 first = _submittedJob(false);
        uint256 second = _submittedJob(false);
        IVerifier.Attestation memory att = _att(PASS, vm.getBlockTimestamp());
        evaluator.evaluate(icore, first, att);
        evaluator.evaluate(icore, second, att);
        assertEq(uint8(_status(first)), uint8(IERC8183Core.JobStatus.Completed));
        assertEq(uint8(_status(second)), uint8(IERC8183Core.JobStatus.Completed));
    }

    // ================================================================== isolation and admin

    function test_aHostileCoreOnlyAffectsItsOwnTerms() public {
        uint256 realJob = _submittedJob(false);

        FakeCore fake = new FakeCore(address(evaluator), stranger);
        vm.prank(stranger);
        evaluator.registerTerms(IERC8183Core(address(fake)), realJob, PR_CONFIG, PASS, FAIL, true, SIGS);

        // Registered under the fake core's address; the real core's job is untouched.
        assertTrue(evaluator.termsOf(address(fake), realJob).set);
        assertTrue(evaluator.termsOf(address(core), realJob).set, "the real client's own terms are still there");
        assertEq(evaluator.termsOf(address(core), realJob).failValue, bytes32(0), "and are not overwritten");

        fake.setStatus(IERC8183Core.JobStatus.Submitted);
        fake.setWindow(uint48(vm.getBlockTimestamp() - 5 minutes), uint48(vm.getBlockTimestamp() + 1 hours));
        evaluator.evaluate(IERC8183Core(address(fake)), realJob, _att(PASS, vm.getBlockTimestamp()));
        assertEq(fake.completed(), realJob, "the fake core saw its own completion");
        assertEq(uint8(_status(realJob)), uint8(IERC8183Core.JobStatus.Submitted), "the real job did not move");
    }

    function test_onlyTheOwnerWithdrawsFees() public {
        uint256 jobId = _submittedJob(false);
        evaluator.evaluate(icore, jobId, _att(PASS, vm.getBlockTimestamp()));
        uint256 fee = usdc.balanceOf(address(evaluator));
        assertGt(fee, 0);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        evaluator.withdrawFees(usdc, stranger, fee);

        vm.prank(owner);
        evaluator.withdrawFees(usdc, owner, fee);
        assertEq(usdc.balanceOf(owner), fee);
    }

    function test_ownershipMovesInTwoSteps() public {
        vm.prank(owner);
        evaluator.transferOwnership(stranger);
        assertEq(evaluator.owner(), owner, "not moved until accepted");
        vm.prank(stranger);
        evaluator.acceptOwnership();
        assertEq(evaluator.owner(), stranger);
    }

    function test_constructorRefusesAZeroVerifier() public {
        vm.expectRevert(MolphaEvaluator.ZeroVerifier.selector);
        new MolphaEvaluator(IVerifier(address(0)), owner);
    }

    // ================================================================== property

    /// @dev Whatever is signed and whenever it is sent, a job completes only on the pass word taken
    ///      inside [submittedAt, expiredAt).
    function testFuzz_completesOnlyOnThePassWordInsideTheWindow(
        bytes32 value,
        bool usePass,
        uint256 nowOffset,
        uint256 attOffset
    ) public {
        uint256 jobId = _submittedJob(true);
        IERC8183Core.Job memory job = icore.getJob(jobId);

        uint256 now_ = bound(nowOffset, job.submittedAt, uint256(job.expiredAt) + 3 hours);
        vm.warp(now_);
        uint256 ts = bound(attOffset, job.submittedAt - 120, now_ + 30);
        bytes32 word = usePass ? PASS : value;

        try evaluator.evaluate(icore, jobId, _att(word, ts)) {
            if (_status(jobId) == IERC8183Core.JobStatus.Completed) {
                assertEq(word, PASS, "completed on a word that is not the pass word");
                assertGe(ts, job.submittedAt, "completed on a fact from before submission");
                assertLt(ts, job.expiredAt, "completed on a fact from after the deadline");
            } else {
                assertEq(word, FAIL, "only the fail word may reject");
                assertGe(ts, job.expiredAt);
                assertGe(vm.getBlockTimestamp(), uint256(job.expiredAt) + 30 minutes);
            }
        } catch {
            assertEq(uint8(_status(jobId)), uint8(IERC8183Core.JobStatus.Submitted), "a refusal moves nothing");
        }
    }

    // ------------------------------------------------------------------ helpers

    function _digest(IVerifier.Attestation memory a) internal pure returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                keccak256("MOLPHA_MESSAGE_V1"),
                a.payload.value,
                a.payload.sourceId,
                a.payload.registryVersion,
                a.payload.signaturesRequired,
                a.payload.timestamp,
                a.signature.signersBitmap
            )
        );
    }
}

/// @dev A core that reports whatever it is told to, to show a hostile core cannot reach another
///      core's jobs or terms.
contract FakeCore {
    address internal immutable _evaluator;
    address internal immutable _client;
    IERC8183Core.JobStatus internal _jobStatus = IERC8183Core.JobStatus.Open;
    uint48 internal _submittedAt;
    uint48 internal _expiredAt;
    uint256 public completed;

    constructor(address evaluator_, address client_) {
        _evaluator = evaluator_;
        _client = client_;
    }

    function setStatus(IERC8183Core.JobStatus s) external {
        _jobStatus = s;
    }

    function setWindow(uint48 submittedAt_, uint48 expiredAt_) external {
        _submittedAt = submittedAt_;
        _expiredAt = expiredAt_;
    }

    function getJob(uint256) external view returns (IERC8183Core.Job memory job) {
        job.client = _client;
        job.status = _jobStatus;
        job.evaluator = _evaluator;
        job.submittedAt = _submittedAt;
        job.expiredAt = _expiredAt;
    }

    function complete(uint256 jobId, bytes32, bytes calldata) external {
        completed = jobId;
    }

    function reject(uint256, bytes32, bytes calldata) external {}
}
