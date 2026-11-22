// csv-reader-speed-01 v2: WASM SIMD128 JSON-to-JSON CSV transducer.
// Zero JSON.parse / JSON.stringify in the hot path: main.ts reads
// /input/cases.json as a raw Buffer, passes it to WASM linear memory, and
// writes the WASM output buffer directly to /output/answers.json.
// The WASM (src/main.zig, Zig 0.17.1, wasm32-freestanding + simd128) parses
// the JSON, runs the csv-reader 1.0.0 CSV engine, and serializes answers.json
// entirely in linear memory. solve.js keeps the per-case run(input) contract
// for the differential fuzz harness.
import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { setFlagsFromString } from 'node:v8';
import { WASM_B64 } from './wasm.js';

// V8's incremental marking off, set before any WASM work (as the house
// baseline does; the rules allow tuning V8's flags).
setFlagsFromString('--no-incremental-marking');

const INPUT_DIR = process.env.MAKEFUN_INPUT_DIR ?? '/input';
const OUTPUT_DIR = process.env.MAKEFUN_OUTPUT_DIR ?? '/output';

const wasmBytes = Buffer.from(WASM_B64, 'base64');
const mod = new WebAssembly.Module(wasmBytes);
const inst = new WebAssembly.Instance(mod, {});
const memory = inst.exports.memory as WebAssembly.Memory;
(inst.exports.init as () => void)();

// Input base: 16 MiB, safely above the WASM data segment (~1 MiB).
// Output lives at 32 MiB, scratch at 48 MiB; memory is 64 MiB.
const IN_BASE = 0x1000000;
const casesBuf = readFileSync(join(INPUT_DIR, 'cases.json'));
new Uint8Array(memory.buffer).set(casesBuf, IN_BASE);
const outLen = (inst.exports.run_json as (p: number, l: number) => number)(IN_BASE, casesBuf.length);
const outPtr = (inst.exports.out_ptr as () => number)();
const out = Buffer.from(new Uint8Array(memory.buffer, outPtr, outLen));
writeFileSync(join(OUTPUT_DIR, 'answers.json'), out);
