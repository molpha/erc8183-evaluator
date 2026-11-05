#!/usr/bin/env bash
# Local end-to-end run of the six scenarios on a loopback anvil. No remote network, no real keys.
#
#   scripts/e2e-local.sh [scenario ...]      (default: all)
#
# The verifier is the real Molpha `Verifier` behind `MolphaTestSigner`, which signs with genuine
# Schnorr keys, so every attestation is verified by the real contract. The "oracle" is simulated: the
# scenarios decide which word it signs. What this does NOT cover is the gateway and the nodes: the
# live run does (see README).
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HERE"
PORT=18545
RPC="http://127.0.0.1:${PORT}"
SCRATCH="$(mktemp -d)"
PIDFILE="${SCRATCH}/anvil.pid"
MNEMONIC="test test test test test test test test test test test junk"
KEY="$(cast wallet private-key --mnemonic "$MNEMONIC" --mnemonic-index 0)"

cleanup() { [ -f "$PIDFILE" ] && kill "$(cat "$PIDFILE")" 2>/dev/null || true; }
trap cleanup EXIT

# The test signer's initcode embeds the whole Verifier, which exceeds the EIP-3860 initcode limit.
anvil --port "$PORT" --chain-id 31337 --silent --disable-code-size-limit >"${SCRATCH}/anvil.log" 2>&1 &
echo $! >"$PIDFILE"
for _ in $(seq 1 50); do cast chain-id --rpc-url "$RPC" >/dev/null 2>&1 && break; sleep 0.2; done

deployed() { awk '/Deployed to:/ {print $3}'; }

SIGNER="$(forge create lib/molpha-evm-verifier/src/test-utils/MolphaTestSigner.sol:MolphaTestSigner --rpc-url "$RPC" --private-key "$KEY" --broadcast --constructor-args 2 2>&1 | deployed)"
[ -n "$SIGNER" ] || { echo "could not deploy the test signer"; exit 1; }
cast send "$SIGNER" "registerNodes(uint256)" 5 --rpc-url "$RPC" --private-key "$KEY" >/dev/null
VERIFIER="$(cast call "$SIGNER" "verifier()(address)" --rpc-url "$RPC")"
echo "verifier ${VERIFIER} (registry v$(cast call "$VERIFIER" 'getRegistryVersion()(uint256)' --rpc-url "$RPC"), $(cast call "$VERIFIER" 'getTotalNodes()(uint256)' --rpc-url "$RPC") nodes)"

USDC="$(forge create test/mocks/MockUSDC.sol:MockUSDC --rpc-url "$RPC" --private-key "$KEY" --broadcast 2>&1 | deployed)"
rm -f deployments/31337.json
export PRIVATE_KEY="$KEY" PAYMENT_TOKEN="$USDC" VERIFIER
forge script script/DeployCore.s.sol:DeployCore --rpc-url "$RPC" --broadcast >/dev/null 2>&1
forge script script/DeployMolpha.s.sol:DeployMolpha --rpc-url "$RPC" --broadcast >/dev/null 2>&1
unset PRIVATE_KEY PAYMENT_TOKEN VERIFIER
echo "deployed: $(python3 -I -c "import json; print(json.load(open('deployments/31337.json')))")"

export LOCAL=1 LOCAL_SIGNER="$SIGNER" RPC_URL="$RPC"
rm -rf runs/local
pnpm exec tsx scenarios/run.ts "${@:-all}" --local
