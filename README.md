# csv-reader-speed-01 — fast csv-reader 1.0.0 drop-in

A faster drop-in for make.fun's own csv-reader 1.0.0: `run(input)` returns exactly csv-reader's `{columns, rows, errors}` for every case, using indexOf-driven field slicing and a whole-line fast path for clean records instead of reading character by character.

[![make.fun · csv-reader-speed-01-run-20261121](https://make.fun/badge/csv-reader-speed-01-run-20261121.svg)](https://make.fun/bounty/csv-reader-speed-01-run-20261121?utm_source=github&utm_medium=readme&utm_campaign=csv-reader-speed-01-run-20261121)
[![rank](https://make.fun/badge/csv-reader-speed-01-run-20261121/Wahyukanzuro/csv-reader-speed-01-run-20261121/rank.svg)](https://make.fun/bounty/csv-reader-speed-01-run-20261121/leaderboard)
[![reward](https://make.fun/badge/csv-reader-speed-01-run-20261121/Wahyukanzuro/csv-reader-speed-01-run-20261121/reward.svg)](https://make.fun/bounty/csv-reader-speed-01-run-20261121?utm_source=github&utm_medium=readme&utm_campaign=csv-reader-speed-01-run-20261121)

## Entry

- `solve.js` — the fast reader (`run(input)`).
- `main.ts` — the harness driver (reads `/input/cases.json`, writes `/output/answers.json`).

## License

MIT
