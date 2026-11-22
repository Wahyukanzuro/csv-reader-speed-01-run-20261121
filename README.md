# csv-reader-speed-01 — WASM SIMD128 JSON-to-JSON CSV transducer (v2)

A WASM SIMD128 drop-in for make.fun's own csv-reader 1.0.0: `main.ts` reads
`/input/cases.json` as a raw Buffer, passes it to WASM linear memory, and
writes the WASM output buffer directly to `/output/answers.json` — zero
`JSON.parse` / `JSON.stringify` in the hot path. The WASM (Zig 0.17.1,
`wasm32-freestanding` + `simd128`) parses the JSON, runs the full csv-reader
1.0.0 CSV engine (BOM, stray CR, quoted fields, `""` doubling, CR/CRLF
inside quotes, quote junk, unterminated quotes, short/long rows, errors in
order), and serializes `answers.json` entirely in linear memory.

[![make.fun · csv-reader-speed-01-run-20261121](https://make.fun/badge/csv-reader-speed-01-run-20261121.svg)](https://make.fun/bounty/csv-reader-speed-01-run-20261121?utm_source=github&utm_medium=readme&utm_campaign=csv-reader-speed-01-run-20261121)
[![rank](https://make.fun/badge/csv-reader-speed-01-run-20261121/Wahyukanzuro/csv-reader-speed-01-run-20261121/rank.svg)](https://make.fun/bounty/csv-reader-speed-01-run-20261121/leaderboard)
[![reward](https://make.fun/badge/csv-reader-speed-01-run-20261121/Wahyukanzuro/csv-reader-speed-01-run-20261121/reward.svg)](https://make.fun/bounty/csv-reader-speed-01-run-20261121?utm_source=github&utm_medium=readme&utm_campaign=csv-reader-speed-01-run-20261121)

## Entry

- `main.ts` — the harness driver (raw Buffer → WASM → writeFileSync).
- `wasm.js` — the WASM binary, base64-embedded (no raw `.wasm` file).
- `solve.js` — the per-case `run(input)` wrapper (fuzz harness contract).
- `src/main.zig` — the Zig source for the WASM module.

## License

MIT
