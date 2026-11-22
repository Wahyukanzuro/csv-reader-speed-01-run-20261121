// csv-reader-speed-01 v7: lean-start CJS driver (from v6).
// True 18B entry: main.ts is exactly `require('./a.cjs')` (bare require,
// no TypeScript syntax, no createRequire). This file is loaded via the
// global require because package.json has NO "type" field (so .ts files
// are detected as CJS by Node's module detection).
//
// V8 flags are set with process.getBuiltinModule (skips the require
// machinery) BEFORE any WASM work. --liftoff-only forces WASM to run on
// Liftoff only (no TurboFan tier-up); --no-incremental-marking matches the
// house baseline. (Step 1 of v6 proved these baseline flags beat the
// anti-background combo by 9.4 ms net, and --single-threaded crashes V8.)
//
// I/O is zero-copy, as in v6: /input/cases.json is read DIRECTLY into WASM
// linear memory (fs.openSync + fs.fstatSync + fs.readSync into the
// Uint8Array view of WASM memory -- no intermediate JS Buffer, no
// readFileSync), and the output is written DIRECTLY from WASM memory.
//
// v7 change (static memory + per-case flush): the WASM memory is STATIC
// (declared at link time, no memory.grow) and the output buffer is ONE
// reusable 2.5 MiB window. After each case the WASM calls the flushOut
// import below, which writeSyncs that case's bytes straight to
// /output/answers.json; the buffer is then reused for the next case.
// Only 2.5 MiB of output pages ever fault in (v6 touched ~12 MiB), and
// there is no memory.grow. The concatenated flushed bytes are
// byte-identical to v6's single answers.json.
const fs = process.getBuiltinModule('fs');
const v8 = process.getBuiltinModule('v8');

v8.setFlagsFromString('--liftoff-only --no-incremental-marking');

const INPUT_DIR = process.env.MAKEFUN_INPUT_DIR || '/input';
const OUTPUT_DIR = process.env.MAKEFUN_OUTPUT_DIR || '/output';

const wasmBytes = fs.readFileSync(__dirname + '/a.wasm');
const mod = new WebAssembly.Module(wasmBytes);

// Output file: opened once, before run_json. flushOut writes each case's
// bytes as soon as the WASM finishes the case.
const outFd = fs.openSync(OUTPUT_DIR + '/answers.json', 'w');
let u8; // Uint8Array view of WASM memory (static, never detaches: no grow)
const inst = new WebAssembly.Instance(mod, { env: { flushOut(ptr, len) {
  let off = ptr;
  let rem = len;
  while (rem > 0) {
    const n = fs.writeSync(outFd, u8, off, rem, null);
    off += n;
    rem -= n;
  }
} } });
const memory = inst.exports.memory;
u8 = new Uint8Array(memory.buffer);
inst.exports.init();

// Input base: 2 MiB, safely above the WASM data segment (~1 MiB).
// Output base is OUT_BASE = 15 MiB (fixed, as in v6); the output buffer
// is 2.5 MiB and is flushed + reused per case. Scratch is at 18 MiB.
// Static memory is 336 pages (21 MiB); see src/main.zig.
const IN_BASE = 0x200000;

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

// run_json processes all cases and flushes each case's output via
// flushOut as it goes; it returns the total bytes flushed.
inst.exports.run_json(IN_BASE, inSize);
fs.closeSync(outFd);
