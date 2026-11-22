// Per-case wrapper for the v7 WASM transducer (the run(input) contract).
// Used by the differential fuzz harness: it JSON-encodes the single input,
// runs it through the WASM JSON-to-JSON path, and JSON-parses the single
// output. (The graded main.ts / a.cjs path does NOT do this per-case JSON
// round-trip; it feeds the whole cases.json buffer to WASM at once.)
//
// v7 change: the WASM imports flushOut from "env" (it flushes each case's
// output through the import instead of returning one big buffer), so this
// wrapper MUST provide it at instantiation -- otherwise instantiation
// fails with a missing-import error. Here flushOut accumulates the
// flushed chunks; run() concatenates them and parses the single-case
// output. (The graded a.cjs path provides a flushOut that writeSyncs
// straight to /output/answers.json.)
//
// NOTE: this file is solve.mjs (not solve.js) because v4's package.json has
// NO "type" field (required so the 18-byte main.ts bare `require` works in
// CJS mode). A .js file would therefore be treated as CommonJS, and the
// fuzz harness imports this file as ESM -- so it must be .mjs.
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const __dirname = dirname(fileURLToPath(import.meta.url));
const wasmBytes = readFileSync(join(__dirname, 'a.wasm'));
const mod = new WebAssembly.Module(wasmBytes);
let memory;
let chunks = [];
const inst = new WebAssembly.Instance(mod, { env: { flushOut(ptr, len) {
  chunks.push(Buffer.from(new Uint8Array(memory.buffer, ptr, len)));
} } });
memory = inst.exports.memory;
inst.exports.init();
const IN_BASE = 0x200000;

export function run(input) {
  const json = JSON.stringify([{ id: 't', input }]);
  const enc = new TextEncoder().encode(json);
  new Uint8Array(memory.buffer).set(enc, IN_BASE);
  chunks = [];
  inst.exports.run_json(IN_BASE, enc.length);
  const out = Buffer.concat(chunks);
  return JSON.parse(out.toString('utf8'))[0];
}
