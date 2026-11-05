#!/usr/bin/env bash
# Local dry run of the Base Sepolia deployment on a loopback anvil. No remote network, no real keys.
#
#   scripts/dryrun-local.sh <molpha-core-contracts dir> <AddNode broadcast run json>
#
# 1. deploys the Molpha verifier with the verifier repo's own CREATE2 script (from a scratch copy,
#    so the real checkout and its broadcast/ folder are untouched) and checks the canonical address;
# 2. replays the recorded addNode calls through the impersonated protocol admin;
# 3. deploys a mock USDC, the ERC-8183 core, the evaluator, the hook and the adapter with this
#    repo's scripts, and writes deployments/31337.json (ignored by git).
set -euo pipefail

CORE_CONTRACTS="${1:?path to molpha-core-contracts}"
BROADCAST="${2:?path to an AddNode broadcast run json}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
PORT=18545
RPC="http://127.0.0.1:${PORT}"
SCRATCH="$(mktemp -d)"
PIDFILE="${SCRATCH}/anvil.pid"
ADMIN=0x6c6bCc50dDAA6884125e1060DCd6363F8866380A
CANONICAL=0xA6e49A3A1caf3E110cC04765B934C8FF118C2568
MNEMONIC="test test test test test test test test test test test junk"
KEY="$(cast wallet private-key --mnemonic "$MNEMONIC" --mnemonic-index 0)"

cleanup() { [ -f "$PIDFILE" ] && kill "$(cat "$PIDFILE")" 2>/dev/null || true; }
trap cleanup EXIT

anvil --port "$PORT" --chain-id 31337 --silent >"${SCRATCH}/anvil.log" 2>&1 &
echo $! >"$PIDFILE"
for _ in $(seq 1 50); do cast chain-id --rpc-url "$RPC" >/dev/null 2>&1 && break; sleep 0.2; done
echo "anvil up on ${RPC} (chain $(cast chain-id --rpc-url "$RPC"))"

echo "== CREATE2 proxy present: $(cast code 0x4e59b44847b379578588920cA78FbF26c0B4956C --rpc-url "$RPC" | wc -c | tr -d ' ') hex chars"

echo "== 1. verifier"
rsync -a --exclude broadcast --exclude out --exclude cache --exclude .git "${CORE_CONTRACTS}/" "${SCRATCH}/verifier/"
( cd "${SCRATCH}/verifier" && PRIVATE_KEY="$KEY" forge script script/Deploy.s.sol:Deploy --rpc-url "$RPC" --broadcast 2>&1 | grep -E "Verifier|verifier|deployed|address" | head -5 )
CODE_LEN=$(cast code "$CANONICAL" --rpc-url "$RPC" | wc -c | tr -d ' ')
[ "$CODE_LEN" -gt 10 ] || { echo "FAIL: nothing at the canonical verifier address $CANONICAL"; exit 1; }
echo "verifier at canonical address ${CANONICAL}: ok"

echo "== 2. replay addNode through the impersonated admin"
cast rpc anvil_impersonateAccount "$ADMIN" --rpc-url "$RPC" >/dev/null
cast rpc anvil_setBalance "$ADMIN" 0x56bc75e2d63100000 --rpc-url "$RPC" >/dev/null
python3 -I - "$BROADCAST" "$CANONICAL" "$ADMIN" "$RPC" <<'PY'
import json, subprocess, sys
run, verifier, admin, rpc = sys.argv[1:5]
n = 0
for tx in json.load(open(run))["transactions"]:
    if not (tx.get("function") or "").startswith("addNode("):
        continue
    params = json.dumps({"from": admin, "to": verifier, "data": tx["transaction"]["input"]})
    out = subprocess.run(["cast", "rpc", "eth_sendTransaction", params, "--rpc-url", rpc], capture_output=True, text=True)
    if out.returncode != 0:
        sys.exit("addNode replay failed: " + out.stderr.strip()[:200])
    n += 1
print(f"replayed {n} addNode calls")
PY
VERSION=$(cast call "$CANONICAL" "getRegistryVersion()(uint256)" --rpc-url "$RPC")
NODES=$(cast call "$CANONICAL" "getTotalNodes()(uint256)" --rpc-url "$RPC")
BUFFER=$(cast call "$CANONICAL" "redundancyBuffer()(uint256)" --rpc-url "$RPC")
echo "registry version ${VERSION}, nodes ${NODES}, redundancy buffer ${BUFFER}"
[ "$VERSION" = "5" ] && [ "$NODES" = "5" ] && [ "$BUFFER" = "2" ] || { echo "FAIL: expected version 5, 5 nodes, buffer 2"; exit 1; }

echo "== 3. evaluator stack"
cd "$HERE"
rm -f deployments/31337.json
USDC="$(forge create test/mocks/MockUSDC.sol:MockUSDC --rpc-url "$RPC" --private-key "$KEY" --broadcast 2>&1 | awk '/Deployed to:/ {print $3}')"
echo "mock USDC ${USDC}"
export PRIVATE_KEY="$KEY" PAYMENT_TOKEN="$USDC"
forge script script/DeployCore.s.sol:DeployCore --rpc-url "$RPC" --broadcast 2>&1 | grep -E "ERC8183|admin|NOTICE|Error" || true
VERIFIER="$CANONICAL" forge script script/DeployMolpha.s.sol:DeployMolpha --rpc-url "$RPC" --broadcast 2>&1 | grep -E "Molpha|registry|NOTICE|Error" || true
echo "== deployments/31337.json"
cat deployments/31337.json

echo "== 4. the core is configured for the demo"
field() { python3 -I -c "import json,sys; print(json.load(open('deployments/31337.json'))[sys.argv[1]])" "$1"; }
CORE_ADDR="$(field core)"; HOOK_ADDR="$(field hook)"
check() { [ "$2" = "$3" ] && echo "ok   $1 = $2" || { echo "FAIL $1: got $2, want $3"; exit 1; }; }
check "hook whitelisted"        "$(cast call "$CORE_ADDR" 'whitelistedHooks(address)(bool)' "$HOOK_ADDR" --rpc-url "$RPC")" true
check "no-hook jobs allowed"    "$(cast call "$CORE_ADDR" 'whitelistedHooks(address)(bool)' 0x0000000000000000000000000000000000000000 --rpc-url "$RPC")" true
check "payment token allowed"   "$(cast call "$CORE_ADDR" 'allowedPaymentTokens(address)(bool)' "$USDC" --rpc-url "$RPC")" true
check "evaluator fee (bp)"      "$(cast call "$CORE_ADDR" 'evaluatorFeeBP()(uint256)' --rpc-url "$RPC")" 50
echo "dry run passed"
