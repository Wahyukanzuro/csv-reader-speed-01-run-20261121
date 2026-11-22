// csv-reader-speed-01 v4: lean-start CJS driver.
// True 18B entry: main.ts is exactly `require('./a.cjs')` (bare require,
// no TypeScript syntax, no createRequire). This file is loaded via the
// global require because package.json has NO "type" field (so .ts files
// are detected as CJS by Node's module detection).
//
// V8 flags are set with process.getBuiltinModule (skips the require
// machinery) BEFORE any WASM work. --liftoff-only forces WASM to run on
// Liftoff only (no TurboFan tier-up): Step 1 profiling showed the baseline
// flags (--no-incremental-marking --no-wasm-tier-up) burn ~2x CPU vs wall
// on run_json (background TurboFan compilation); --liftoff-only brings
// cpu/wall to ~1.0x and cuts run_json CPU by ~40% (40 ms -> ~22 ms).
// --no-incremental-marking matches the house baseline.
//
// I/O is zero-copy: /input/cases.json is read DIRECTLY into WASM linear
// memory (no intermediate JS Buffer), and /output/answers.json is written
// DIRECTLY from WASM memory (no copy). Zero JSON.parse / JSON.stringify
// in the hot path.
const fs = process.getBuiltinModule('fs');
const v8 = process.getBuiltinModule('v8');

v8.setFlagsFromString('--liftoff-only --no-incremental-marking');

const INPUT_DIR = process.env.MAKEFUN_INPUT_DIR || '/input';
const OUTPUT_DIR = process.env.MAKEFUN_OUTPUT_DIR || '/output';

const wasmBytes = fs.readFileSync(__dirname + '/a.wasm');
const mod = new WebAssembly.Module(wasmBytes);
const inst = new WebAssembly.Instance(mod, {});
const memory = inst.exports.memory;
inst.exports.init();

// Input base: 2 MiB, safely above the WASM data segment (~1 MiB).
// Output base is computed by the Zig side from in_len
// (OUT_BASE = IN_BASE + in_len + 64); the tight v4 layout grows memory
// to 544 pages (34 MiB) total -- IN_BASE 2 MiB, OUT_BASE ~15 MiB,
// scratch ~30 MiB. See src/main.zig.
const IN_BASE = 0x200000;
const u8 = new Uint8Array(memory.buffer);

// Read /input/cases.json DIRECTLY into WASM linear memory.
const inFd = fs.openSync(INPUT_DIR + '/cases.json', 'r');
const inSize = fs.fstatSync(inFd).size;
let off = IN_BASE;
let remaining = inSize;
while (remaining > 0) {
  const n = fs.readSync(inFd, u8, off, remaining, null);
  if (n === 0) break;
  off += n;
  remaining -= n;
}
fs.closeSync(inFd);

const outLen = inst.exports.run_json(IN_BASE, inSize);
const outPtr = inst.exports.out_ptr();

// Write /output/answers.json DIRECTLY from WASM memory.
const outFd = fs.openSync(OUTPUT_DIR + '/answers.json', 'w');
let woff = outPtr;
let wrem = outLen;
while (wrem > 0) {
  const n = fs.writeSync(outFd, u8, woff, wrem, null);
  woff += n;
  wrem -= n;
}
fs.closeSync(outFd);
