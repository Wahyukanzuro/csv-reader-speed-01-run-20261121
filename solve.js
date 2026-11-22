// Per-case wrapper for the WASM transducer (the run(input) contract).
// Used by the differential fuzz harness: it JSON-encodes the single input,
// runs it through the WASM JSON-to-JSON path, and JSON-parses the single
// output. (The graded main.ts path does NOT do this per-case JSON round-trip;
// it feeds the whole cases.json buffer to WASM at once.)
import { WASM_B64 } from './wasm.js';

const wasmBytes = Buffer.from(WASM_B64, 'base64');
const mod = new WebAssembly.Module(wasmBytes);
const inst = new WebAssembly.Instance(mod, {});
const memory = inst.exports.memory;
inst.exports.init();
const IN_BASE = 0x1000000;
const OUT_PTR = inst.exports.out_ptr();

export function run(input) {
  const json = JSON.stringify([{ id: 't', input }]);
  const enc = new TextEncoder().encode(json);
  new Uint8Array(memory.buffer).set(enc, IN_BASE);
  const outLen = inst.exports.run_json(IN_BASE, enc.length);
  const out = Buffer.from(new Uint8Array(memory.buffer, OUT_PTR, outLen));
  return JSON.parse(out.toString('utf8'))[0];
}
