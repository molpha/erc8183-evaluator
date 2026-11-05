import { parseAbi } from "viem";

const attestation =
  "((bytes32 value, bytes32 sourceId, uint32 registryVersion, uint8 signaturesRequired, uint64 timestamp) payload, (bytes32 signature, address commitment, uint256 signersBitmap) signature)";

export const evaluatorAbi = parseAbi([
  `function registerTerms(address core, uint256 jobId, string sourceConfig, bytes32 passValue, bytes32 failValue, bool hasFail, uint8 minSignatures)`,
  `function evaluate(address core, uint256 jobId, ${attestation} att)`,
  `function termsOf(address core, uint256 jobId) view returns ((bytes32 sourceId, bytes32 passValue, bytes32 failValue, uint8 minSignatures, bool hasFail, bool set))`,
  `function VERIFIER() view returns (address)`,
  `function withdrawFees(address token, address to, uint256 amount)`,
  `event TermsRegistered(address indexed core, uint256 indexed jobId, bytes32 indexed sourceId, string sourceConfig, bytes32 passValue, bytes32 failValue, bool hasFail, uint8 minSignatures)`,
  `event Evaluated(address indexed core, uint256 indexed jobId, bool passed, bytes32 indexed sourceId, bytes32 value, uint64 timestamp, uint256 signersBitmap)`,
  `error NotClient()`,
  `error NotEvaluator()`,
  `error HookNotAllowed()`,
  `error TermsAlreadySet()`,
  `error NoTerms()`,
  `error WrongStatus(uint8 status)`,
  `error FutureAttestation(uint256 attestedAt, uint256 latestAllowed)`,
  `error OutsideWindow(uint256 attestedAt, uint256 submittedAt, uint256 expiredAt)`,
  `error FailNotYet(uint256 attestedAt, uint256 expiredAt, uint256 failAllowedFrom)`,
  `error UnexpectedValue(bytes32 value)`,
  `error NoSpareSigner(uint8 minimum, uint256 committee)`,
  `error WrongSource(bytes32 expected, bytes32 actual)`,
  `error ThresholdBelowPolicy(uint32 minimum, uint32 actual)`,
  `error VerifyFailed(uint8 code)`,
]);

export const hookAbi = parseAbi([
  `function termsOf(uint256 jobId) view returns ((bytes32 sourceId, bytes32 passValue, uint8 minSignatures, bool set))`,
  `event TermsFrozen(uint256 indexed jobId, bytes32 indexed sourceId, string sourceConfig, bytes32 passValue, uint8 minSignatures)`,
  `error NoTerms()`,
  `error BadAttestation(uint256 length)`,
  `error UnexpectedValue(bytes32 value)`,
  `error WrongSource(bytes32 expected, bytes32 actual)`,
  `error ThresholdBelowTerms(uint8 minimum, uint8 actual)`,
  `error VerifyFailed(uint8 code)`,
  `error FutureAttestation(uint256 attestedAt, uint256 latestAllowed)`,
  `error OutsideWindow(uint256 attestedAt, uint256 submittedAt, uint256 expiredAt)`,
  `error ClaimsNotAllowed()`,
  `error NoSpareSigner(uint8 minimum, uint256 committee)`,
]);

export const coreAbi = parseAbi([
  `function createJob(address provider, address evaluator, uint48 expiredAt, string description, address hook, uint256 providerAgentId) returns (uint256)`,
  `function setBudget(uint256 jobId, address token, uint256 amount, bytes optParams)`,
  `function fund(uint256 jobId, address expectedToken, uint256 expectedBudget, bytes optParams)`,
  `function submit(uint256 jobId, bytes32 deliverable, bytes optParams)`,
  `function complete(uint256 jobId, bytes32 reason, bytes optParams)`,
  `function reject(uint256 jobId, bytes32 reason, bytes optParams)`,
  `function claimRefund(uint256 jobId)`,
  `function getJob(uint256 jobId) view returns ((address client, uint8 status, address provider, uint48 expiredAt, address evaluator, uint48 submittedAt, uint256 budget, address hook, address paymentToken, uint256 providerAgentId, string description, uint256 settledAmount, address payoutReceiver))`,
  `function whitelistedHooks(address) view returns (bool)`,
  `function allowedPaymentTokens(address) view returns (bool)`,
  `function evaluatorFeeBP() view returns (uint256)`,
  `event JobCreated(uint256 indexed jobId, address indexed client, address indexed provider, address evaluator, uint48 expiredAt, address hook)`,
  `event JobCompleted(uint256 indexed jobId, address indexed evaluator, bytes32 reason)`,
  `event JobRejected(uint256 indexed jobId, address indexed rejector, bytes32 reason)`,
]);

export const erc20Abi = parseAbi([
  `function approve(address spender, uint256 amount) returns (bool)`,
  `function balanceOf(address) view returns (uint256)`,
  `function decimals() view returns (uint8)`,
  `function symbol() view returns (string)`,
  `function mint(address to, uint256 amount)`,
]);

export const verifierAbi = parseAbi([
  `function getRegistryVersion() view returns (uint256)`,
  `function getTotalNodes() view returns (uint256)`,
  `function redundancyBuffer() view returns (uint256)`,
  `function activatesAt(uint256 version) view returns (uint256)`,
  `function owner() view returns (address)`,
  `function verify(${attestation} attestation, uint64 maxAge) view returns (bool success, uint8 code)`,
]);

/** `IERC8183Core.JobStatus` as the core stores it. */
export const JobStatus = { Open: 0, Funded: 1, Submitted: 2, Completed: 3, Rejected: 4, Expired: 5 } as const;
