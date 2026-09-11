# Retired-source codec fixtures

`WIRE-VECTORS.json` is a frozen synthetic codec fixture, not current authority
or historical effect evidence. SHA-256:
`2b059d10e60a05ed929acbe706d3bf892b6a1fadb3aca4693d4ca0f52f61a7e4`.

The two cases exercise H416/L417 and independent F17/C18 versus G2→3, with S>H
requiring normal Gap/Snapshot recovery. Real behavioral tests must produce the
retirement record through the actual journal and execute the complete consumer.
See the [protocol](../../protocol/retired-carrier-proof-v3.md).

`WIRE-NEGATIVE-CASES.json` is a byte-identical companion in both corpora. It
references the unchanged happy-vector hash and specifies 66 executable mutation
cases, their validation entrypoints, and exact re-digest order. SHA-256:
`33915cfbd49158a7a544056b530b9abfcad1e11feb07ddf43eca4cd4acc4cb3f`.

Apply each case to a fresh copy of its named base. Semantic mutations reseal
the complete digest chain, including unknown fields, without repairing the
intentional mismatch. A semantic refusal caused only by an invalid digest does
not cover that case. Replay tests first commit the unchanged request through
the real journal, then submit changed canonical bytes with the same operation
ID and freshly valid digests. Encoding tests inject duplicate identical keys or
trailing documents; frozen-byte checks reject changed stored canonical bytes.
The body-size tests independently exercise declared and actual request/response
limits with legal whitespace padding. The fixture's `rules` member defines the
materialization algorithm; it is not a new network schema.

Materializing cases and checking their digest integrity is not behavioral
acceptance. Source suites must execute the named production boundaries and
record literal predicate-removal RED and restored GREEN controls. Current
store authority, recreated-stream races, journal crash/replay, actual shim
acceptance and full adoption remain separate integration requirements.
