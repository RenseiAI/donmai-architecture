# Proposed usage-v2 counting fixtures

These synthetic examples pin part-1 counting laws, not a complete wire schema.
`logical.usage` is a rollup, never another billable attempt. Each attempt has its
own counts; observations correlate to it without adding consumption.

- `direct.json`: successful direct call, measured cache zero and inapplicable reasoning.
- `gateway-stream.json`: gateway forwards one attempt; usage appears only on the terminal chunk.
- `retry-fallback.json`: partial failed attempt and a successful fallback with independent counts.

Run `bash scripts/check-usage-v2-fixtures.sh` from the repo root; `--selftest`
requires corrupted temporary fixtures to fail, including both containment laws
with consistent attempt/logical sums, and a fallback that repeats the failed usage.
Temporary files are removed on exit. No live traffic or vendor conformance is implied.
