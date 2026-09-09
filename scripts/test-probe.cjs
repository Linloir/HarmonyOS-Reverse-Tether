#!/usr/bin/env node
// Tests the exact ArkTS packet/metric implementation with the SDK compiler.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const clt = process.env.HARMONY_CLT_HOME;
if (!clt) throw new Error('Set HARMONY_CLT_HOME to the HarmonyOS command-line-tools directory');
const ts = require(path.join(clt, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const source = path.resolve(__dirname, '../app/entry/src/main/ets/probe/StunPacket.ets');
const output = ts.transpileModule(fs.readFileSync(source, 'utf8'), {
  compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
}).outputText;
const context = { exports: {}, Uint8Array, ArrayBuffer, Error, Number, Math };
vm.runInNewContext(output, context);
const { bindingRequest, matchResponse, summarize } = context.exports;
const id = Uint8Array.from({length: 12}, (_, i) => i + 1);
const request = new Uint8Array(bindingRequest(id));
assert.equal(request.length, 20);
assert.deepEqual([...request.slice(0, 8)], [0, 1, 0, 0, 33, 18, 164, 66]);
const reply = request.slice(); reply[0] = 1;
assert.equal(matchResponse(reply, [id]), 0);
assert.equal(matchResponse(request, [id]), -1); // request is not a response
for (let length = 0; length < 20; length++) assert.equal(matchResponse(reply.slice(0, length), [id]), -1);
const wrongId = reply.slice(); wrongId[19] ^= 1;
assert.equal(matchResponse(wrongId, [id]), -1);
const wrongCookie = reply.slice(); wrongCookie[4] = 0;
assert.equal(matchResponse(wrongCookie, [id]), -1);
const truncated = new Uint8Array(24); truncated.set(reply); truncated[3] = 4; truncated[23] = 8;
assert.equal(matchResponse(truncated, [id]), -1);
const padded = new Uint8Array(28); padded.set(reply); padded[3] = 8; padded[20] = 0x80; padded[21] = 0x22; padded[23] = 1;
assert.equal(matchResponse(padded, [id]), 0);
assert.equal(matchResponse(new Uint8Array(1201), [id]), -1);
let value = summarize(5, [], 'stun.example.org', 3478);
assert.equal(value.median_rtt_ms, null); assert.equal(value.packet_loss_percent, 100);
value = summarize(5, [9, 1, 5, 3], 'stun.example.org', 3478);
assert.equal(value.median_rtt_ms, 4); assert.equal(value.packet_loss_percent, 20);
assert.equal(summarize(5, [6, 1, 4], 'example.org', 3478).median_rtt_ms, 4);
assert.throws(() => summarize(0, [], 'example.org', 3478));
assert.throws(() => summarize(1, [1, 2], 'example.org', 3478));
assert.throws(() => summarize(5, [NaN], 'example.org', 3478));
console.log('STUN codec and measurement validation: PASS');
