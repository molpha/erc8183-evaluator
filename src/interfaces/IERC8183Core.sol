// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IERC8183Core
/// @notice The part of an ERC-8183 core the Molpha evaluator touches: read a job, finish it.
/// @dev Matches `erc-8183/base-contracts` at 142e669 (`Job` field order, `complete`/`reject`
///      signatures). The evaluator depends on this ABI only, never on the core's storage layout or
///      upgradeability, so any core with the same ABI can use it.
interface IERC8183Core {
    enum JobStatus {
        Open,
        Funded,
        Submitted,
        Completed,
        Rejected,
        Expired
    }

    struct Job {
        address client;
        JobStatus status;
        address provider;
        uint48 expiredAt;
        address evaluator;
        uint48 submittedAt;
        uint256 budget;
        address hook;
        address paymentToken;
        uint256 providerAgentId;
        string description;
        uint256 settledAmount;
        address payoutReceiver;
    }

    function getJob(uint256 jobId) external view returns (Job memory);

    function complete(uint256 jobId, bytes32 reason, bytes calldata optParams) external;

    function reject(uint256 jobId, bytes32 reason, bytes calldata optParams) external;
}
