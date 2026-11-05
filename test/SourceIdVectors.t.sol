// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

/// @dev A source's id is `keccak256` of its canonical config text, and the evaluator derives it from
///      the text itself. These are the same three vectors the TypeScript SDK derives
///      (`scenarios/lib/sources.test.ts`) and the Go node derives (`TestERC8183DemoSourceIDs` in
///      molpha-node-client): the three must change together.
contract SourceIdVectorsTest is Test {
    string internal constant PR =
        '{"url":"https://api.github.com/repos/molpha/demo/pulls/1","method":"GET","headers":{"Accept":"application/vnd.github+json"},"responseParser":"$.merged","valueTransform":"keccak256"}';
    // The responseParser holds a JSON-escaped quote (backslash, quote) around the TXT value.
    string internal constant DNS =
        "{\"url\":\"https://cloudflare-dns.com/dns-query?name=demo.molpha.example&type=TXT\",\"method\":\"GET\",\"headers\":{\"Accept\":\"application/dns-json\"},\"responseParser\":\"$.Answer[?(@.data=='\\\"molpha-job=8183\\\"')].type\",\"valueTransform\":\"\"}";
    string internal constant CONTENT =
        '{"url":"https://example.test/app.js","method":"GET","headers":{},"responseParser":"","valueTransform":"keccak256"}';

    function test_githubPrSourceId() public pure {
        assertEq(keccak256(bytes(PR)), 0x904559abd0f84c121073fb7c9ffd385321cb0ce5ad99d62a6470a91284201cef);
    }

    function test_dnsTxtSourceId() public pure {
        assertEq(keccak256(bytes(DNS)), 0xfafd023490f1066a12f6e586590926e2450e84610fc698829117bce4d9241ede);
    }

    function test_contentHashSourceId() public pure {
        assertEq(keccak256(bytes(CONTENT)), 0xc45612f5642f2ac0b84d6833f7f4f42e4846da28a0b9584178254c78dae266f9);
    }

    function test_theWordsANodeSigns() public pure {
        // keccak256("true") / keccak256("false") under `valueTransform: "keccak256"`; and the DNS
        // answer type (TXT = 16) under an empty transform.
        assertEq(keccak256("true"), 0x6273151f959616268004b58dbb21e5c851b7b8d04498b4aabee12291d22fc034);
        assertEq(keccak256("false"), 0xba9154e0baa69c78e0ca563b867df81bae9d177c4ea1452c35c84386a70f0f7a);
        assertEq(bytes32(uint256(16)), 0x0000000000000000000000000000000000000000000000000000000000000010);
    }
}
