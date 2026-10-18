# Usage-v2 counting fixtures

These synthetic examples pin counting and observation-selection laws, not a complete wire schema.
`logical.usage` is a rollup, never another billable attempt. Each attempt has its
own counts; observations correlate to it without adding consumption.

- `direct.json`: successful direct call, measured cache zero and inapplicable reasoning.
- `gateway-stream.json`: gateway forwards one attempt; usage appears only on the terminal chunk.
- `retry-fallback.json`: partial failed attempt and a successful fallback with independent counts.

Run `bash scripts/check-usage-v2-fixtures.sh` from the repo root; `--selftest`
requires corrupted temporary fixtures to fail, including both containment laws
with consistent attempt/logical sums, and a fallback that repeats the failed usage.
Temporary files are removed on exit. No live traffic or vendor conformance is implied.

- `real-zero-vs-absent.json`: provider-reported output/cache zero remains zero;
  missing cache-write remains absent, reasoning is inapplicable (null).
- `unpriced-subscription.json`: measured usage with explicit subscription mode;
  unpriced does not mean zero cost or zero consumption.
- `transcript-recovery.json`: one atom, selected native observation, correlated
  gateway and terminal-summary checks, then late unselected transcript recovery.

Upgraded observations carry metrics, evidence, completeness and stable atom IDs.
The checker enforces one selection per attempt and sums selected observations;
it rejects missing gateway correlation with `double count`. Selftest also rejects
duplicate selections and unknown evidence. These checks validate contract examples,
not a live ledger or the truth of a vendor measurement.
