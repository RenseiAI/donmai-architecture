---
status: Accepted
date: 2026-09-17
boundary: shared
split: inline-addenda
---

# Reserved-successor retirement v1 — closed codec

This profile is governed by the [owning session-shim ADR amendment](../ADR-2026-08-17-session-shim-adoption.md#amendment-2026-09-17--reserved-successor-retirement).
Architecture is Accepted; implementation, release and readiness remain gated. It adds no
permission beyond that exact source/CAS transition. Baseline contracts retain
their existing shapes and semantics.

## Closed request/result codec

All objects are closed: exact keys only, duplicate members refused. Request has
23 keys; success result has 27; successor predecessor has 8.

Type aliases use the existing composing authority and Relay conventions:

- `U`: string matching `^(0|[1-9][0-9]*)$`, value ≤18446744073709551615.
- `P`: U with value >0. No JSON numeric substitute, sign, exponent or leading zero.
- `D`: exactly 64 lowercase hexadecimal characters.
- `ID`: canonical lowercase UUID matching Relay's existing versions 1–5/RFC
  variant pattern; zero UUID is invalid.
- `Scope`: valid UTF-8 and Unicode scalar values, nonempty, ≤256 UTF-8 bytes,
  with no leading or trailing member of the fixed boundary-whitespace set below.
  Interior characters and exact identity bytes are preserved.
- `Store`: existing Relay initialized store identity regex
  `^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$`.
- `Ancestor`: existing closed eight-field predecessor object for the actual A;
  its source state is whatever that validated retained predecessor declares,
  never caller substitution. Existing profiles remain valid.

### Scope boundary whitespace — clarification 2026-09-17

For this profile only, both `orgId` and `sessionId` MUST refuse a leading or
trailing member of this **fixed 26-codepoint set**:

```text
U+0009..U+000D, U+0020, U+0085, U+00A0, U+1680, U+2000..U+200A,
U+2028, U+2029, U+202F, U+205F, U+3000, U+FEFF
```

This is the union of Unicode White_Space and U+FEFF, explicitly frozen above;
implementation behavior MUST NOT drift with a runtime's whitespace database.
A valid Scope satisfies both existing composing-identifier and Relay boundary
conventions. Refuse an invalid edge; never trim, strip, normalize or replace it
into another accepted identity. Preserve every interior character unchanged,
including U+0085 and U+FEFF, subject to the existing scalar and UTF-8 byte bounds.
This clarification adds no field, digest, version, capability or authority and
does not alter baseline profiles or general identifier validation.

A runtime's default trim function alone is insufficient. The matrix compares
its boundary predicate (`trim(value) == value`) with the required new-profile
predicate; it applies to both request and paired-result Scope fields:

| Scope example | JavaScript trim alone | Go TrimSpace alone | Required new-profile reader |
|---|---|---|---|
| `org` | accept | accept | accept |
| `\u0085org`, `org\u0085` (NEL at an edge) | accept | refuse | refuse |
| `\uFEFForg`, `org\uFEFF` (BOM at an edge) | refuse | accept | refuse |
| `o\u0085rg` (interior NEL) | accept | accept | accept unchanged |
| `o\uFEFFrg` (interior BOM) | accept | accept | accept unchanged |
| ` org`, `org ` | refuse | refuse | refuse |

The separate [Scope edge matrix](../fixtures/reserved-successor-scope-v1/README.md)
enumerates every fixed codepoint at both edges and internally. It supplements
these codecs without changing any byte or manifest entry in the original seven
reserved-successor-retirement fixtures. Conformance requires actual request and
paired-result parser controls, including literal removal of the NEL/BOM edge
refusals; a library-trim comparison alone is not implementation evidence.

### Exact request members

| Keys | Type/value |
|---|---|
| `schemaVersion` | JSON integer 2 |
| `profile` | literal `reserved_successor_retirement_v1` |
| `cause` | literal `unadmitted_successor_reprepare` |
| `expectedSourceState` | literal `reserved_successor` |
| `abandonmentRequestId` | ID, newly frozen T1 operation |
| `abandonmentRequestDigest` | D |
| `storeAuthorityId` | Store |
| `orgId`, `sessionId` | Scope |
| `ptyEpoch` | U |
| `sourceProofSchemaVersion` | literal string `2` |
| `sourceProofRevision` | P |
| `sourceProofDigest` | D |
| `reservationRequestId` | ID, R1 |
| `reservationRequestDigest` | D, R1 |
| `reservedCandidateCarrierEpoch` | P, R1 |
| `predecessorAbandonment` | Ancestor, exactly A in R1 proof |
| `sourceAuthorityDigest` | D, object below |
| `expectedProofRevision` | P, equals sourceProofRevision |
| `expectedActiveCarrierEpoch`, `expectedPendingCarrierEpoch` | literal string `0` |
| `expectedCarrierEpochFloor` | P, equals R1 reserved proof floor |
| `expectedHighWater` | U, equals R1 proof boundary |

### Exact success result members

| Keys | Type/value |
|---|---|
| `schemaVersion` | JSON integer 2 |
| `profile` | literal `reserved_successor_retirement_v1` |
| `state` | literal `reservation_retired` |
| `cause` | literal `unadmitted_successor_reprepare` |
| `sourceState` | literal `reserved_successor` |
| `abandonmentRequestId`, `abandonmentRequestDigest` | ID/D, exact request echoes |
| `storeAuthorityId` | Store, exact request echo |
| `orgId`, `sessionId` | Scope, exact request echoes |
| `ptyEpoch` | U, exact request echo |
| `sourceProofSchemaVersion` | literal string `2` |
| `sourceProofRevision`, `sourceProofDigest` | P/D, exact request echoes |
| `reservationRequestId`, `reservationRequestDigest` | ID/D, exact R1 request echoes |
| `sourceAuthorityDigest` | D, exact validated request echo |
| `sourceStateRevision` | P, exact locked pre-transition revision and request expectedProofRevision |
| `sourceStateDigest` | D, exact locked object below |
| `abandonmentRevision` | P, sourceStateRevision+1; overflow refuses before mutation |
| `abandonmentDigest` | D, result digest below |
| `abandonedCandidateCarrierEpoch` | P, request reservedCandidateCarrierEpoch |
| `activeCarrierEpoch`, `pendingCarrierEpoch` | literal string `0` |
| `carrierEpochFloor` | P, unchanged request expectedCarrierEpochFloor |
| `highWater`, `boundary` | U, both unchanged request expectedHighWater |

No `replay`, `priorActiveCarrierEpoch`, prepared-correlation, Snapshot, frame,
credential, timestamp, ancestor object, sourceJournalDigest or frameHistoryDigest
member exists in this success object. This is a distinct typed result, not the
legacy admitted result with fabricated members.

### Exact predecessor projection of T1

| Key | Type/value |
|---|---|
| `targetReservationRequestId` | ID = result reservationRequestId |
| `targetReservationRequestDigest` | D = result reservationRequestDigest |
| `sourceCandidateState` | literal `reserved_successor` |
| `abandonmentRequestId` | ID = result abandonmentRequestId |
| `abandonmentRequestDigest` | D = result abandonmentRequestDigest |
| `abandonmentRevision` | P = result abandonmentRevision |
| `abandonmentDigest` | D = result abandonmentDigest |
| `abandonedCandidateCarrierEpoch` | P = result abandonedCandidateCarrierEpoch |

### Exact digest input objects

`sourceAuthorityDigest` hashes precisely these 13 members:

```text
domain = "reserved-successor-source/v1"
storeAuthorityId, orgId, sessionId, ptyEpoch
reservationRequestId, reservationRequestDigest
sourceProofSchemaVersion = "2"
sourceProofRevision, sourceProofDigest
reservedCandidateCarrierEpoch
predecessorAbandonment = A
consumedPredecessor = { abandonmentRequestId: A.id, reservationRequestId: R1.id }
```

`sourceStateDigest` hashes precisely these 9 members:

```text
domain = "reserved-successor-state/v1"
sourceAuthorityDigest
proofRevision = actual locked pre-transition revision
activeCarrierEpoch = "0"
pendingCarrierEpoch = "0"
carrierEpochFloor = actual locked floor
highWater = actual locked high-water
sourceAdmitted = false
sourceAbandoned = false
```

SHA-256 uses RFC-8785 canonical UTF-8 JSON bytes. Request digest omits only
`abandonmentRequestDigest`; result digest omits only `abandonmentDigest`.
Neither source digest includes T1 request/result or R2. The predecessor has no
independent digest: its bytes are bound by the next proof request's existing
digest. Authority and locked state are separate commitments with no circularity.

### Bytes, bounds, replay and refusal behavior

Reuse existing 4096-byte carrier control request/result bounds, exact
`Content-Type: application/json`, identity/no Content-Encoding, bounded read,
strict JSON/UTF-8 and duplicate/unknown-member refusal. Canonical retained
request/result bytes use RFC 8785. Logical request replay compares the same
closed canonical body and digest, not a new id or resampled CAS. The version-2
profile writes/returns canonical success bytes directly; no response replay
flag or regenerated time value changes the body. First success uses HTTP 201;
exact replay uses HTTP 200 with the **same canonical result bytes**. Existing
version-1 response encoding stays unchanged.

Current uint64 revisions and candidate floor must leave room for the necessary
increment; refuse overflow before marker/record mutation. The composing
authority's existing safe-integer carrier ceiling remains an additional composing constraint, not
permission to clamp a uint64. Request/result envelope byte limit is unchanged;
new profile cannot expand it silently.

Reuse current carrier-control status semantics:

- Disabled control endpoint: 404; missing/invalid exact bearer: 401; no mutation.
- Malformed/unknown version/profile/keys/values/digest or wrong JSON media type:
  400 `invalid_carrier_abandonment_request` (existing bounded text error form).
- Missing/zero/oversize body or encoded body: existing 413 size refusal.
- Exact-state/replay/ancestry/CAS conflict: 409 JSON
  `{ "code":"carrier_abandonment_conflict", "rule": <closed reason> }`.
  New profile reasons are a closed enum: `reserved_successor_source_missing`,
  `reserved_successor_source_admitted`, `reserved_successor_source_retired`,
  `reserved_successor_ancestor_mismatch`, `reserved_successor_frontier_changed`,
  `reserved_successor_scope_mismatch`, `reserved_successor_replay_changed`,
  `reserved_successor_competing_retirement`, `reserved_successor_terminal`.
  Reuse existing `stream_quarantined`/closed store-conflict vocabulary where
  applicable; no digest/ID/body/history is placed in diagnostic `rule` text.
- Unsupported/not-ready journal/profile, storage corruption or I/O uncertainty:
  existing 503 `carrier_abandonment_unavailable`, preserving any frozen request
  and possible committed result for exact replay. Known quarantined stream is
  the existing definitive 409 class, not relabeled transport unavailability.
- Quota: existing 507 `carrier_proof_quota`; no new result or lost source.

For readiness: unknown/absent/false feature support cannot license this request.
The composing authority refuses before freezing a new operation or minting
credentials; transient Relay feature unavailability uses existing `carrier_proof_unavailable`/503.
A baseline-only authenticated host cannot be upgraded by inference and gets
existing unsupported-attestation refusal for this new-profile path. None of
these feature checks redefines baseline-v2 readiness or stops an unrelated host
session. An already-frozen new-profile operation retains its immutable bytes on
readiness regression; it never falls back to an admitted profile or ProofEmpty.


## Canonical vectors

The [codec fixture set](../fixtures/reserved-successor-retirement-v1/README.md)
contains the complete source authority, exact digest input objects and canonical
request/result/predecessor bytes. Its manifest freezes every file. These are
codec examples, not issued credentials or evidence that runtime recovery has
been implemented. Real journal/admission, replay, crash and retained-harness
controls remain required.
