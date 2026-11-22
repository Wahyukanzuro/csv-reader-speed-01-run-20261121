# csv-reader-speed-01 — WASM SIMD128 JSON-to-JSON CSV transducer (v4)

A WASM SIMD128 drop-in for make.fun's own csv-reader 1.0.0, built to cut
v3's ~60 ms overhead. `main.ts` is exactly `require('./a.cjs')` — 18 bytes,
no TypeScript syntax, no createRequire — and `a.cjs` uses
`process.getBuiltinModule` (skipping the require machinery) to set V8 flags
(`--liftoff-only --no-incremental-marking`: Liftoff-only WASM, no background
TurboFan tier-up), reads `/input/cases.json` straight into WASM linear
memory, and writes the WASM output buffer directly to
`/output/answers.json` — zero `JSON.parse` / `JSON.stringify` in the hot
path, zero double-copy I/O. The WASM (Zig 0.17.1, `wasm32-freestanding` +
`simd128`, `-fstrip`) parses the JSON, runs the full csv-reader 1.0.0 CSV
engine (BOM, stray CR, quoted fields, `""` doubling, CR/CRLF inside quotes,
quote junk, unterminated quotes, short/long rows, errors in order), and
serializes `answers.json` entirely in linear memory. Single-pass
direct-emitting record parser with a local output pointer (no global
load/store per structural byte) and 32-byte SIMD windows for the
comma/backslash/quote scans; tight 34 MiB linear-memory layout (input 2 MiB,
output ~15 MiB, scratch ~30 MiB).

[![make.fun · csv-reader-speed-01-run-20261121](https://make.fun/badge/csv-reader-speed-01-run-20261121.svg)](https://make.fun/bounty/csv-reader-speed-01-run-20261121?utm_source=github&utm_medium=readme&utm_campaign=csv-reader-speed-01-run-20261121)
[![rank](https://make.fun/badge/csv-reader-speed-01-run-20261121/Wahyukanzuro/csv-reader-speed-01-run-20261121/rank.svg)](https://make.fun/bounty/csv-reader-speed-01-run-20261121/leaderboard)
[![reward](https://make.fun/badge/csv-reader-speed-01-run-20261121/Wahyukanzuro/csv-reader-speed-01-run-20261121/reward.svg)](https://make.fun/bounty/csv-reader-speed-01-run-20261121?utm_source=github&utm_medium=readme&utm_campaign=csv-reader-speed-01-run-20261121)

## Entry

- `main.ts` — exactly `require('./a.cjs')` (18 bytes, no trailing newline).
  `package.json` has no `"type"` field, so Node treats the `.ts` file as CJS
  and the bare `require` works.
- `a.cjs` — V8 flags via `process.getBuiltinModule` + zero-copy I/O + WASM
  instantiate + run.
- `a.wasm` — the raw WASM binary (Zig, SIMD128, stripped, 23,379 bytes).
- `solve.mjs` — the per-case `run(input)` wrapper (fuzz harness contract).
  Named `.mjs` (not `.js`) because `package.json` has no `"type"` field, so
  a `.js` file would be treated as CommonJS while the fuzz harness imports
  this file as ESM.
- `src/main.zig` — the Zig source for the WASM module.

## License

MIT
