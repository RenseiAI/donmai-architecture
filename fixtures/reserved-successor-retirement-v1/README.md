# Reserved-successor retirement codec fixtures

Accepted architecture on 2026-09-17. Implementation, release and profile
readiness remain gated. These synthetic examples define canonical bytes and
digest relationships; they are not credentials or observed runtime retirement.

The [closed codec](../../protocol/reserved-successor-retirement-v1.md) defines
all 23 request, 27 result and 8 predecessor keys, types, limits and refusals.

- SOURCE.json records the example ancestor receipt A, its predecessor object,
  the reserved successor R1 request/proof and the locked pre-transition facts.
- DIGEST-INPUTS.json holds the exact immutable authority and locked-state
  objects whose canonical SHA-256 digests appear in the new operation.
- REQUEST.json freezes a new T1 retirement request. Its digest excludes only
  abandonmentRequestDigest.
- RESULT.json is the corresponding hypothetical T1 result. Its digest excludes
  only abandonmentDigest; first delivery and exact replay use identical bytes.
- PREDECESSOR.json projects T1 into the exact eight-member object consumed
  once by the next reservation. A remains consumed by R1.

The example uses nonzero high-water 1, carrier floor 2 and source proof/current
revision 6. R1 is unadmitted and unretired in the source; T1 result revision is 7.
High-water, floor and zero active/pending epochs are preserved. No frame-history
hash, Snapshot, admission fact or empty-history fallback is invented.

REQUEST.json, RESULT.json and PREDECESSOR.json are compact canonical UTF-8 JSON
without a trailing newline. SOURCE.json and DIGEST-INPUTS.json are readable
fixture envelopes; digest their selected closed objects after RFC-8785
canonicalization, not their formatted outer file bytes. All values in this
fixture are ASCII and contain no floating point values.

MANIFEST.json gives the byte count and SHA-256 of every other fixture file.
This freezes example integrity; it does not replace real producer/consumer,
journal reopen/corruption, admission-race or harness-survival acceptance.
