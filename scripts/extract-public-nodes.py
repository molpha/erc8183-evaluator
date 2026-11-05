#!/usr/bin/env python3
"""Turn a Foundry broadcast record of `AddNode.s.sol` into a public-only nodes file.

The output holds each node's compressed public key and proof of possession, which are already
public calldata on every chain the verifier is deployed to. It never reads or writes a private
key, so it is safe to commit and to hand to `AddNode.s.sol` (`NODES_FILE`).

    python3 -I scripts/extract-public-nodes.py <broadcast run json> <out nodes json>
"""
import json
import re
import sys

HEX = re.compile(r"0x[0-9a-fA-F]+")


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    src, dst = sys.argv[1], sys.argv[2]
    run = json.load(open(src))

    nodes = []
    for tx in run["transactions"]:
        if not (tx.get("function") or "").startswith("addNode("):
            continue
        pubkey = tx["arguments"][0]
        proof = HEX.findall(tx["arguments"][1])
        if len(proof) != 2 or not re.fullmatch(r"0x[0-9a-fA-F]{66}", pubkey):
            raise SystemExit(f"unexpected addNode arguments in {src}")
        nodes.append({"compressedPubKey": pubkey, "popSignature": proof[0], "popCommitment": proof[1]})

    if not nodes:
        raise SystemExit(f"no addNode calls in {src}")

    json.dump({"nodes": nodes}, open(dst, "w"), indent=2)
    print(f"wrote {len(nodes)} nodes to {dst}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
