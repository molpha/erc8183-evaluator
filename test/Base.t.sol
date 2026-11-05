// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC8183} from "@erc8183/ERC8183.sol";
import {IVerifier} from "@molpha/evm-verifier/interfaces/IVerifier.sol";
import {MolphaTestSigner} from "@molpha/evm-verifier/test-utils/MolphaTestSigner.sol";

import {MolphaEvaluator} from "../src/MolphaEvaluator.sol";
import {IERC8183Core} from "../src/interfaces/IERC8183Core.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @dev The real ERC-8183 core (behind a proxy, as deployed) and the real Molpha `Verifier`
///      (through the test signer, with genuine Schnorr signatures) around one `MolphaEvaluator`.
abstract contract EvaluatorBase is Test {
    uint256 internal constant T0 = 1_800_000_000;
    uint256 internal constant BUDGET = 100e6;
    uint256 internal constant FEE_BP = 50;
    uint48 internal constant WINDOW = 2 hours;
    uint8 internal constant SIGS = 3;

    /// @dev The GitHub source of the demo, in the exact canonical form the SDK and nodes hash.
    string internal constant PR_CONFIG =
        '{"url":"https://api.github.com/repos/molpha/demo/pulls/1","method":"GET","headers":{"Accept":"application/vnd.github+json"},"responseParser":"$.merged","valueTransform":"keccak256"}';
    // `cast keccak true` / `cast keccak false`: what a node signs for "merged" / "not merged".
    bytes32 internal constant PASS = 0x6273151f959616268004b58dbb21e5c851b7b8d04498b4aabee12291d22fc034;
    bytes32 internal constant FAIL = 0xba9154e0baa69c78e0ca563b867df81bae9d177c4ea1452c35c84386a70f0f7a;

    MolphaTestSigner internal signer;
    IVerifier internal verifier;
    ERC8183 internal core;
    IERC8183Core internal icore;
    MockUSDC internal usdc;
    MolphaEvaluator internal evaluator;

    address internal admin = makeAddr("admin");
    address internal treasury = makeAddr("treasury");
    address internal owner = makeAddr("owner");
    address internal client = makeAddr("client");
    address internal provider = makeAddr("provider");
    address internal stranger = makeAddr("stranger");

    function setUp() public virtual {
        vm.warp(T0);
        signer = new MolphaTestSigner(2);
        signer.registerNodes(8);
        verifier = IVerifier(address(signer.verifier()));

        core = ERC8183(
            address(new ERC1967Proxy(address(new ERC8183()), abi.encodeCall(ERC8183.initialize, (treasury, admin))))
        );
        icore = IERC8183Core(address(core));
        usdc = new MockUSDC();
        vm.startPrank(admin);
        core.setPaymentTokenAllowed(address(usdc), true);
        core.setEvaluatorFee(FEE_BP);
        vm.stopPrank();

        evaluator = new MolphaEvaluator(verifier, owner);
        usdc.mint(client, 1_000e6);
    }

    // ------------------------------------------------------------------ helpers

    function _sourceId() internal pure returns (bytes32) {
        return keccak256(bytes(PR_CONFIG));
    }

    /// @dev A job whose evaluator is the Molpha evaluator, created by `client`, expiring WINDOW out.
    function _createJob() internal returns (uint256 jobId) {
        vm.prank(client);
        jobId = core.createJob(
            provider, address(evaluator), uint48(vm.getBlockTimestamp() + WINDOW), "merge PR 1", address(0), 0
        );
    }

    function _register(uint256 jobId, bool hasFail, uint8 minSigs) internal {
        vm.prank(client);
        evaluator.registerTerms(icore, jobId, PR_CONFIG, PASS, hasFail ? FAIL : bytes32(0), hasFail, minSigs);
    }

    function _fund(uint256 jobId) internal {
        vm.prank(provider);
        core.setBudget(jobId, address(usdc), BUDGET, "");
        vm.startPrank(client);
        usdc.approve(address(core), BUDGET);
        core.fund(jobId, address(usdc), BUDGET, "");
        vm.stopPrank();
    }

    function _submit(uint256 jobId) internal {
        vm.prank(provider);
        core.submit(jobId, keccak256("pr-1-work"), "");
    }

    /// @dev Create, register terms, fund and submit. The clock is left at the submission instant.
    function _submittedJob(bool hasFail) internal returns (uint256 jobId) {
        jobId = _createJob();
        _register(jobId, hasFail, SIGS);
        _fund(jobId);
        vm.warp(vm.getBlockTimestamp() + 10 minutes);
        _submit(jobId);
    }

    function _att(bytes32 value, uint256 timestampSeconds) internal view returns (IVerifier.Attestation memory) {
        return signer.attest(_sourceId(), value, SIGS, uint64(timestampSeconds) * 1000);
    }

    function _status(uint256 jobId) internal view returns (IERC8183Core.JobStatus) {
        return icore.getJob(jobId).status;
    }
}
