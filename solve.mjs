// Per-case wrapper for the v4 WASM transducer (the run(input) contract).
// Used by the differential fuzz harness: it JSON-encodes the single input,
// runs it through the WASM JSON-to-JSON path, and JSON-parses the single
// output. (The graded main.ts / a.cjs path does NOT do this per-case JSON
// round-trip; it feeds the whole cases.json buffer to WASM at once.)
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
const inst = new WebAssembly.Instance(mod, {});
const memory = inst.exports.memory;
inst.exports.init();
const IN_BASE = 0x200000;
const OUT_PTR = inst.exports.out_ptr();

export function run(input) {
  const json = JSON.stringify([{ id: 't', input }]);
  const enc = new TextEncoder().encode(json);
  new Uint8Array(memory.buffer).set(enc, IN_BASE);
  const outLen = inst.exports.run_json(IN_BASE, enc.length);
  const out = Buffer.from(new Uint8Array(memory.buffer, OUT_PTR, outLen));
  return JSON.parse(out.toString('utf8'))[0];
}
