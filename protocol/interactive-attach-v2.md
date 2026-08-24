---
title: interactive-attach-v2 — durable carrier takeover activation
status: Proposed
date: 2026-08-23
revision: v2.0-draft5
protocol-version: interactive-attach-v2
boundary: OSS-only
extends: protocol/interactive-attach-v1.md
extends-revision: v1.0-draft5 (2026-07-18)
normative-for: donmai generic attach host/client, compatible relays, self-hosted relays
---

# interactive-attach-v2 — durable carrier takeover activation

**Status:** Proposed; normative successor contract, implementation/release/
activation pending.
**Version token:** `interactive-attach-v2`.
**Owning ADR:**
[`../ADR-2026-08-17-session-shim-adoption.md`](../ADR-2026-08-17-session-shim-adoption.md).
**Predecessor:**
[`interactive-attach-v1.md`](interactive-attach-v1.md), whose v1-frozen bytes,
claim set, and control registry remain unchanged.

This is a successor delta, not an amendment to v1. It inherits v1 at the pinned
`v1.0-draft5` revision: the binary
frame header, type bytes, type-specific payloads, host PTY epoch, sequence
namespaces, sanitizer, snapshot envelope, exit ordering, and viewer semantics
except where this document explicitly replaces a rule. The first v2 profile is
the **host carrier** needed for daemon-adoption takeover. Existing v1 viewer and
driver legs may remain in the same relay room; they receive only v1-defined
viewer messages.

A later edit to a v1-draft section does not silently rewrite v2. Its applicable
delta must be accepted here and this pinned `extends-revision` must move. V1 and
v2 therefore remain independently reproducible.

The external attach version and local daemon↔shim selected version are separate
axes. Durable attach-v2 activation requires selected local shimwire v3 and its
`full_host_frame_v3` capability as specified in
[`session-shim-v3.md`](session-shim-v3.md). Selected local v2 may answer an
authoritative snapshot request but cannot supply every exact host frame, so it
is conservation-only and visibly carrier-ineligible.

Draft 2 also closes unplanned-recovery cursor divergence. The carrier journal,
not a daemon or composing adoption row, now reserves and attests the exact
durable boundary. That proof is bound through credential, atomic admission,
mandatory Snapshot receipt, and adoption consumption. Candidate traffic remains
one Snapshot only.

Draft 3 closes retained-candidate abandonment. Proof schema v1 remains frozen
for exact same-handoff replay/drain. Every new carrier admission uses proof
schema v2 and `durable_carrier_proof_v2`, which add an all-time carrier-epoch
floor and exact predecessor-abandonment lineage. A changed controller must commit
the separate authenticated abandonment operation for unconsumed receipt-stored
state before reserving a successor; an admitted preparing candidate uses the same
operation with null receipt evidence. Existing high-water and any staged
Gap/Snapshot remain durable while both current carrier bindings clear. After
adoption consume, the same candidate instead rehydrates through the retained
original bearer with no new proof/Snapshot/cursor.

Draft 4 closes cutover readiness acknowledgement. A carrier cannot derive the
composing authority's writer closure or recovery support from its own cutover
store. After persisting the exact cutover response, the composing authority
must attest four closed true facts through the brand-neutral
`AcknowledgeV2Cutover` operation. The carrier durably binds and reloads that
acknowledgement before proof-v2 readiness can become true.

Draft 5 makes that acknowledgement an irreversible on-disk compatibility fence.
The frozen cutover response keeps its byte-exact schema-2 minimum, while the ACK
commit raises the live store's minimum writer/readiness schema to 3. An ACK-aware
opener repairs the one forward crash window; an ACK-unaware schema-2 artifact
must mechanically refuse the acknowledged store.

## 1. Version selection is independent and exact

- A v2 WSS host offers `Sec-WebSocket-Protocol: interactive-attach-v2`. The
  relay must echo that exact token. Offering or echoing
  `interactive-attach-v1` selects v1 and makes every v2-only claim/control below
  unavailable.
- The WSS route uses the `/v2/` version segment, conventionally
  `/v2/rooms/<roomId>`. A `/v2/` path negotiated as v1 is a protocol error, not
  a v2 implementation.
- Auth stays in its separate native `Authorization: Bearer` channel. The
  version token contains no credential bytes.
- The first release profile is native host WSS. A network or relay that cannot
  negotiate it refuses takeover visibly; it must not fall back to a v1 host leg
  and then approximate activation. A future v2 degraded-host carrier extends
  this document under the `/v2/` path before it is advertised.
- The v1 host continues to be adoptable and usable under all v1 rules. It is
  simply ineligible for authenticated same-PTY-epoch carrier takeover.

## 2. Strict host-only v2 credential

The v2 host credential uses the same dedicated asymmetric signing posture as
v1, including exact `EdDSA`, short expiry, room/organization binding, and no
in-band refresh. Its exact claim set is independent from v1:

```json
{
  "sessionId": "string",
  "roomId": "same string",
  "role": "host",
  "epoch": 0,
  "carrier_epoch": 1,
  "handoff_nonce": "43-character unpadded base64url",
  "prepared_correlation_digest": "64 lowercase hex SHA-256",
  "proof_schema_version": "2",
  "store_authority_id": "bounded non-empty string",
  "proof_revision": "canonical positive uint64 decimal",
  "proof_digest": "64 lowercase hex SHA-256",
  "carrier_boundary": "canonical uint64 decimal N from the proof",
  "resolved_boundary": "canonical uint64 decimal K",
  "last_host_seq": "same canonical uint64 decimal K",
  "reservation_request_id": "UUID",
  "reservation_request_digest": "64 lowercase hex SHA-256",
  "reserved_candidate_carrier_epoch": "canonical positive uint64 decimal",
  "carrier_epoch_floor": "same canonical positive uint64 decimal",
  "predecessor_abandonment": {
    "target_reservation_request_id": "UUID",
    "target_reservation_request_digest": "64 lowercase hex SHA-256",
    "source_candidate_state": "preparing | receipt_stored",
    "abandonment_request_id": "UUID",
    "abandonment_request_digest": "64 lowercase hex SHA-256",
    "abandonment_revision": "canonical positive uint64 decimal",
    "abandonment_digest": "64 lowercase hex SHA-256",
    "abandoned_candidate_carrier_epoch": "canonical positive uint64 decimal"
  },
  "protocol": "interactive-attach-v2",
  "orgId": "string",
  "iat": 0,
  "exp": 0,
  "aud": "relay",
  "jti": "UUID"
}
```

Unknown or duplicate members, trailing JSON, a user role/`userId`, missing or
negative PTY epoch, non-positive carrier epoch, non-canonical nonce/digest/jti/
proof field,
wrong protocol/audience/algorithm, expiry, or room/organization mismatch is an
auth refusal before room mutation. The v1 verifier rejects every v2-only member;
the v2 verifier rejects the attach-v1 claim shape and accepts only the exact
proof-v2 field set above or §2.0.1's frozen retained proof-v1 field set.

`epoch` remains the PTY-owning shim process generation. `carrier_epoch` is the
strictly increasing attach-carrier generation inside that PTY epoch. The nonce,
digest, and jti are secret/correlation material for strict handoff and receipt
resolution. They never appear in viewer frames, room/control snapshots,
diagnostics, logs, error detail, or the activation controls below.

The proof fields are non-secret comparison authority. `proof_schema_version` is
the JSON string `"2"`, never a number. `carrier_epoch_floor` equals
`reserved_candidate_carrier_epoch`. `predecessor_abandonment` is always present:
it is JSON null unless this proof immediately follows the exact abandonment in
§2.2, otherwise it has exactly the eight members and JSON types shown above.
Decimal
`resolved_boundary` and `last_host_seq` must match exactly and be no lower than
`carrier_boundary`; `reserved_candidate_carrier_epoch` must equal numeric
`carrier_epoch` exactly.
The signed tuple can authorize only the one retained proof-v2 reservation request,
floor/predecessor, and proof revision/digest/boundary at the named initialized store. A valid signature
with stale or changed proof evidence is still refused before room mutation.

### 2.0.1 Frozen retained proof-v1 claim profile

Proof-v2 cutover does not make an already-retained proof-v1 handoff
unauthenticatable. The v2 verifier recognizes exactly one second field set: the
frozen draft-2 proof-v1 host credential below, byte-for-byte and with no
`proof_schema_version`, `carrier_epoch_floor`, or `predecessor_abandonment`:

```json
{
  "sessionId": "string",
  "roomId": "same string",
  "role": "host",
  "epoch": 0,
  "carrier_epoch": 1,
  "handoff_nonce": "43-character unpadded base64url",
  "prepared_correlation_digest": "64 lowercase hex SHA-256",
  "store_authority_id": "bounded non-empty string",
  "proof_revision": "canonical positive uint64 decimal",
  "proof_digest": "64 lowercase hex SHA-256",
  "carrier_boundary": "canonical uint64 decimal N from the proof",
  "resolved_boundary": "canonical uint64 decimal K",
  "last_host_seq": "same canonical uint64 decimal K",
  "reservation_request_id": "UUID",
  "reservation_request_digest": "64 lowercase hex SHA-256",
  "reserved_candidate_carrier_epoch": "canonical positive uint64 decimal",
  "protocol": "interactive-attach-v2",
  "orgId": "string",
  "iat": 0,
  "exp": 0,
  "aud": "relay",
  "jti": "UUID"
}
```

This is a retained-state reader, not a mint profile. After proof-v2 cutover no
credential authority may create or refresh these bytes. Relay accepts them only
when signature/time/room checks pass and every claim, including original jti,
nonce, prepared correlation, proof/reservation, epochs, and boundaries, equals
one live eligible entry in §2.0.2's durable cutover manifest. It may
then exact-replay/drain that same controller handoff; no field may select a new
reservation, candidate, controller, or receipt. A mixed field set, changed jti,
fresh proof-v1 row, expired original credential, or absent retained handoff is an
auth refusal. Receipt-stored state that cannot use its original still-valid
credential crosses the explicit abandonment bridge to proof v2; an active leg
without a valid reconnect credential drains its existing connection and gains no
fallback reconnect.

### 2.0.2 Durable proof-v1 cutover eligibility

“Retained before cutover” is not a clock comparison or process-memory fact. The
carrier journal is the sole producer of one fsync-backed, store-authority-bound
allowset that names every proof-v1 reservation eligible for any migration action.
The composing credential authority first durably closes proof-v1 mint/reserve/
admit writers, then calls the control-authenticated edge:

```text
POST /v1/session-shim/carrier-proofs/v2-cutover
Authorization: Bearer <control credential>
Content-Type: application/json
```

The strict request uses the same 4096-byte dual bound, auth-before-parse,
no-compression, no-unknown/duplicate/trailing-member, canonical UUID/digest, and
RFC 8785 rules as §2.2:

```json
{
  "schemaVersion": 1,
  "cutoverRequestId": "UUID",
  "cutoverRequestDigest": "64 lowercase hex SHA-256"
}
```

The caller never supplies or infers store authority. Relay resolves it from the
opened durable store under the same exclusive lock that freezes the manifest and
returns it in the content-addressed result. An initialized store with zero v1
rows is valid: `entries` is empty and `eligibleEntryCount="0"`; it follows the
same fsync/reload/idempotency law. Zero rows waive no later step: the composing
authority persists that response, proves the identical four facts, sends the
identical acknowledgement, and waits for its schema-3 durable bind, marker
commit/recovery, and reload before readiness.

Under one exclusive journal/store-metadata lock, Relay sets v2 readiness false,
resolves its current stable non-empty `storeAuthorityId`, reloads and verifies
every v1 reservation/candidate/credential record, durably
sets `v1WritesClosed=true`, freezes the exact nonterminal v1 set, commits the
mandatory `minimumWriterSchema="2"`, manifest, and parent/store metadata, then
reloads and verifies all before reply.
File stores use temporary write + file fsync + rename + parent fsync; transactional
stores provide the equivalent commit barrier. Check-then-freeze outside that lock
is a TOCTOU defect.

The immutable manifest is scoped to one `storeAuthorityId` and has exactly:

```json
{
  "schemaVersion": 1,
  "kind": "proof_v1_retained_eligibility_v1",
  "storeAuthorityId": "bounded non-empty string",
  "cutoverId": "UUID",
  "cutoverRevision": "canonical positive uint64 decimal",
  "frozenAtUnixNano": "canonical positive uint64 decimal",
  "v1WritesClosed": true,
  "minimumWriterSchema": "2",
  "entries": [{
    "orgId": "bounded non-empty string",
    "sessionId": "bounded non-empty string",
    "ptyEpoch": "canonical uint64 decimal",
    "reservationRequestId": "UUID",
    "reservationRequestDigest": "64 lowercase hex SHA-256",
    "proofRevision": "canonical positive uint64 decimal",
    "proofDigest": "64 lowercase hex SHA-256",
    "reservedCandidateCarrierEpoch": "canonical positive uint64 decimal",
    "stateAtCutover": "reserved | preparing | receipt_stored | active",
    "attachCredentialDigest": "64 lowercase hex SHA-256 or null",
    "attachTokenJtiDigest": "64 lowercase hex SHA-256 or null",
    "credentialExpiresAt": "canonical positive uint64 decimal or null",
    "entryDigest": "64 lowercase hex SHA-256"
  }],
  "manifestDigest": "64 lowercase hex SHA-256"
}
```

Entries are sorted bytewise by org, session, numeric PTY epoch, then reservation
UUID. `entryDigest` is SHA-256 over RFC 8785 canonical entry bytes excluding that
member; `manifestDigest` is the same over the manifest excluding its digest.
Credential digest is over the exact signed bearer bytes. JTI digest is over the
canonical UUID string; neither raw bearer, jti, nonce, frame, receipt bytes, nor
prepared correlation enters the manifest. The three credential members are all
null or all non-null. Legacy credential replay requires a non-null triple and
exact bearer/JTI digests. Reserved/preparing entries without a credential remain
eligible only for reconciliation (reserved) or exact abandonment/reconciliation
(preparing), never authentication.

The first successful call returns `201`; exact request replay returns the first
bytes with `200`:

```json
{
  "schemaVersion": 1,
  "state": "frozen",
  "cutoverRequestId": "same UUID",
  "cutoverRequestDigest": "same digest",
  "storeAuthorityId": "Relay-resolved bounded non-empty string",
  "cutoverId": "UUID",
  "cutoverRevision": "canonical positive uint64 decimal",
  "manifestDigest": "64 lowercase hex SHA-256",
  "eligibleEntryCount": "canonical uint64 decimal",
  "v1WritesClosed": true,
  "minimumWriterSchema": "2",
  "cutoverResponseDigest": "64 lowercase hex SHA-256"
}
```

The same request id with changed bytes, another/new cutover request for that store,
or any concurrent v1 write is `409 carrier_cutover_conflict`.
Other closed failures are `400 invalid_carrier_cutover_request`, uniform `401`,
`413`, and `503 carrier_cutover_unavailable`. A committed-response-lost retry
returns the first response. There is exactly one base manifest per initialized
store authority; it is never regenerated to add or reopen an entry.
`cutoverResponseDigest` is SHA-256 over RFC 8785 canonical response bytes excluding
that member; exact retry compares and returns the retained bytes.

The frozen response is not readiness by itself. The composing authority first
persists the exact response bytes/digest and verifies its own proof-v1 writer
closure plus all three post-consume recovery supports. It then freezes and calls
the brand-neutral generic `AcknowledgeV2Cutover` operation:

```go
AcknowledgeV2Cutover(context.Context, DurableCarrierV2CutoverAcknowledgement) (DurableCarrierV2CutoverAcknowledgementResult, error)
```

Its HTTP binding is:

```text
POST /v1/session-shim/carrier-proofs/v2-cutover/ack
Authorization: Bearer <control credential>
Content-Type: application/json
```

The strict request has exactly these members:

```json
{
  "schemaVersion": 1,
  "cutoverRequestId": "exact cutover request UUID",
  "cutoverRequestDigest": "exact cutover request digest",
  "storeAuthorityId": "exact carrier-resolved store authority",
  "cutoverResponseDigest": "exact retained cutover response digest",
  "composingProofV1WritesClosed": true,
  "encryptedOriginalCredentialRetained": true,
  "remainingValidityConsumeGate": true,
  "adoptedCandidateRecovery": true,
  "acknowledgementDigest": "64 lowercase hex SHA-256"
}
```

All four facts are literal JSON booleans and all must be true. A false value is
not a degraded acknowledgement. `acknowledgementDigest` is SHA-256 over RFC 8785
canonical request bytes excluding that member. The endpoint applies the same
authentication-before-body handling, exact one `Content-Type: application/json`,
4096-byte declared-and-actual body bound, compression refusal, exact canonical
UUID/digest spellings, and unknown/duplicate/trailing-member refusal as the
cutover edge. The control credential is authentication only and never enters the
body, digest, retained record, diagnostics, or logs.

Under the exclusive cutover/control-metadata lock, the carrier loads the retained
cutover request and response, compares the exact request id/digest,
`storeAuthorityId`, and response digest, and verifies all four facts are true.
It then commits one forward-only compatibility transition:

1. write the exact acknowledgement bytes/digest into the existing schema-2
   `cutoverDisk` control metadata and fsync/transactionally commit it; the frozen
   manifest/response and disk schema version remain 2;
2. atomically replace the same store/manifest authority marker with
   `minimumWriterSchema="3"` and
   `cutoverAcknowledgementDigest="<exact acknowledgementDigest>"`, then fsync the
   marker and parent directory; and
3. reload and verify the schema-2 cutover disk, acknowledgement, and schema-3
   minimum-writer/readiness marker before returning success or setting readiness.

Schema 3 is the store's **minimum writer/readiness schema**: an opener whose
declared maximum is below 3 must refuse before constructing a writer, exposing
proof-v2 readiness, or serving a proof/candidate operation. It is not
`proof_schema_version`. The already-retained cutover response and manifest keep
their exact `minimumWriterSchema="2"` bytes and digest forever; that frozen value
records the pre-ACK cutover format and is never rewritten to impersonate the
live store-open floor. After ACK, the authority marker's value 3 is the current
mechanical floor.

The write order deliberately permits only one recoverable crash shape:
`metadata-committed/marker-not-yet-upgraded`. Under the exclusive store-open
lock, an ACK-aware opener whose supported marker floor includes 3 and that sees
valid ACK-bearing schema-2 cutover metadata bound to the current marker while its
`minimumWriterSchema` is still 2 or its current
`cutoverAcknowledgementDigest` is absent/stale must finish the one-way marker
upgrade/bind at `max(existing floor,3)`, fsync it, reread both objects, and only
then open or report readiness. A successor marker may already inherit floor 3,
but it gains the new store's current ACK digest only after that ACK commits. The
repair never deletes/downgrades the
acknowledgement or reruns the four facts. Here “ACK-aware schema-3 opener” names
its supported marker floor, not a new cutover-disk schema. A marker at 3 with
absent, corrupt, or mismatched
acknowledgement metadata is non-repairable corruption and stays closed. An
ACK-unaware schema-2 opener must strictly reject the newly present
acknowledgement members in the otherwise schema-2 cutover disk even during the
recoverable window; it cannot ignore unknown members and trust the old marker.
Check-then-bind outside the lock, accepting an acknowledgement for
another store/response, or setting readiness before the final reload is a
TOCTOU/durability defect.

First success returns `201`; exact request replay returns the first bytes with
`200`:

```json
{
  "schemaVersion": 1,
  "state": "acknowledged",
  "cutoverRequestId": "same UUID",
  "cutoverRequestDigest": "same digest",
  "storeAuthorityId": "same store authority",
  "cutoverResponseDigest": "same response digest",
  "composingProofV1WritesClosed": true,
  "encryptedOriginalCredentialRetained": true,
  "remainingValidityConsumeGate": true,
  "adoptedCandidateRecovery": true,
  "acknowledgementDigest": "same acknowledgement digest"
}
```

`state` is the response-envelope member and is not part of the request
acknowledgement digest. Changed bytes for the acknowledged cutover, another
store/response binding, or an acknowledgement before the exact cutover exists
is `409 carrier_cutover_acknowledgement_conflict`. Other closed failures are
`400 invalid_carrier_cutover_acknowledgement`, uniform `401`, `413`, and
`503 carrier_cutover_acknowledgement_unavailable`. A committed-response-lost
retry returns the first acknowledged result and does not rewrite the cutover or
resample any fact.

This operation is part of the self-hostable carrier-journal contract. A
compatible composition may call the same route or an equivalent authenticated
in-process `AcknowledgeV2Cutover` seam with identical request, digest,
idempotency, persistence, and reload semantics. It imports no composing-plane
library and requires no SaaS callback.

Exact id/body replay dominates store rotation. Relay's fsync-backed cutover
idempotency ledger lives in durable control metadata outside the rotatable journal
authority and retains the original store-A authority plus exact request/response/
acknowledgement bytes and digests. Rotation must retain or transactionally
migrate that read-only record, manifest, acknowledgement, tombstones, and
referenced secrets. If A commits and its cutover or acknowledgement response is
lost before rotation to B, exact replay returns A's first result; it never runs
the operation against B or binds A's acknowledgement to B. A changed/new request
or acknowledgement against B conflicts while any A manifest entry/reference
remains. After A's set is fully tombstoned with zero live references, B may
freeze and acknowledge its own one-time manifest under a new request id.

Every rotation/history commit includes A's exact acknowledgement bytes/digest in
the content-addressed history, and every rotated or newly initialized successor
authority marker inherits `minimumWriterSchema="3"`. No cutover, empty store,
new store id, archive, compaction, or marker rewrite may lower it to 2 or omit it.
When a current acknowledged cutover exists, the marker binds its exact
`cutoverAcknowledgementDigest`. After rotation, the content-addressed history
digest binds A's ACK and the schema-3 floor remains even when no current cutover
exists. B's new
cutover response still returns its frozen schema-2 value;
installing that response must preserve B's inherited marker floor 3, and B stays
not ready until its own identical four-fact acknowledgement binds and reloads;
A's historical ACK satisfies the inherited rollback fence, never B's current
readiness.
The inherited v1 writer closure remains permanent and B can never admit a new v1
row.

The base manifest is immutable. Eligibility only shrinks through an append-only
fsync-backed tombstone keyed by its exact entry digest:

```json
{
  "schemaVersion": 1,
  "kind": "proof_v1_retained_drain_v1",
  "storeAuthorityId": "same store",
  "cutoverId": "same cutover UUID",
  "entryDigest": "exact manifest entry digest",
  "drainRevision": "canonical positive uint64 decimal",
  "reason": "activated_and_drained | abandoned_to_v2 | terminal | reconciled",
  "finalStateDigest": "64 lowercase hex SHA-256",
  "tombstoneDigest": "64 lowercase hex SHA-256"
}
```

`tombstoneDigest` covers canonical bytes excluding itself. One entry has at most
one exact tombstone; replay returns it and changed reason/evidence conflicts. The
tombstone commits before deleting or making unreachable the retained row or
credential. Eligibility is `manifest entry AND no tombstone`; no API or rollback
can remove a tombstone or append a base entry. State may advance monotonically
from `stateAtCutover`, but identity/proof/reservation/credential digests never
change.
Every reason requires exact durable final evidence bound by `finalStateDigest`:
ordinary drain/terminal proof, the consumed v2-abandonment transition, or an
audited reconciliation resolution. Timeout, missing contact, parse failure, or
operator assertion alone cannot shrink eligibility; uncertainty keeps the entry.

Relay loads the schema-2 cutover disk, manifest, `v1WritesClosed`, exact cutover
acknowledgement, the schema-3 authority marker/floor, all
tombstones, and every referenced row/credential before
`durable_carrier_proof_v2_ready:true`. An unlisted or changed proof-v1 row, a
listed row with missing bytes, a new v1 write attempt, a tombstoned credential,
or an absent/mismatched/unreloadable acknowledgement/schema-3 marker is refusal
plus reconciliation and makes readiness false; none is auto-added or treated as
legacy. The same is true for an empty manifest; count zero is never readiness.
Store-authority rotation retains the old manifest/idempotency/acknowledgement/
tombstones read-only and keeps v2 unavailable on the new
authority while any old reference exists. A new authority may freeze only after
proving the old allowset has zero live references; rotation is never a reset/
reopen mechanism, and the inherited v1 writer remains permanently closed.

Rollback preserves the schema-2 cutover disk, manifest, write-closed flag,
acknowledgement, tombstones, retained secrets, schema-3 markers, cutover control-
idempotency ledger, and exact lookup behavior. A binary that cannot read/enforce
them is not rollback safe and cannot mount the writer or advertise v2 readiness.
Before any v1 writer release, every store opener must reject an unknown/higher
required writer/readiness schema. Freeze raises the frozen cutover response and
the first-ever pre-ACK marker to 2; the durable ACK raises the live, inherited
opener floor to 3 without rewriting that response, and no later/new-store freeze
may lower it. The exact pre-ACK schema-2 artifact at
`508ec69c1f5b81709673dd32a623bde99be34daa` must therefore fail store open after
ACK, both in the metadata-committed/marker-not-yet-upgraded window and after the
marker reaches 3. Re-upgrade with an ACK-aware schema-3 artifact completes any
forward marker repair and resumes the same acknowledged shrink-only allowset; it
never takes a new snapshot of surviving rows. Retaining the acknowledgement does
not make an artifact that lacks any acknowledged support fact ready.

Diagnostics expose only closed readiness/reason plus bounded revision/count. They
exclude store/cutover/request/reservation ids, manifest/entry/credential/JTI/
tombstone/response/acknowledgement digests, exact manifest/tombstone/idempotency/
acknowledgement request/response bytes, and retained secrets.

### 2.1 Durable carrier proof reservation

Before credential mint, a control-authenticated caller reserves the exact
carrier-journal boundary through the generic D15 interface. Proof request/response
schema v1 is frozen with the exact members and four-disposition union from draft
2. It remains decodable only for exact retained same-handoff replay and drain; a
caller never advertises `durable_carrier_proof_v1`, never reserves a new v1
candidate, and never sends v1 proof bytes under a v2 credential.

Every new reservation uses this strict schema-v2 canonical JSON request:

```json
{
  "schemaVersion": 2,
  "orgId": "bounded non-empty string",
  "sessionId": "bounded non-empty string",
  "ptyEpoch": "canonical uint64 decimal",
  "localResumeFrom": "canonical positive uint64 decimal",
  "lastHostSeq": "canonical uint64 decimal",
  "expectedActiveCarrierEpoch": "canonical uint64 decimal",
  "expectedPendingCarrierEpoch": "canonical uint64 decimal",
  "expectedCarrierEpochFloor": "canonical uint64 decimal",
  "reservedCandidateCarrierEpoch": "canonical positive uint64 decimal",
  "predecessorAbandonment": null,
  "reservationRequestId": "UUID",
  "reservationRequestDigest": "64 lowercase hex SHA-256"
}
```

`predecessorAbandonment` is always present. It is null except for the immediate
successor to §2.2, where its exact value is:

```json
{
  "targetReservationRequestId": "UUID",
  "targetReservationRequestDigest": "64 lowercase hex SHA-256",
  "sourceCandidateState": "preparing | receipt_stored",
  "abandonmentRequestId": "UUID",
  "abandonmentRequestDigest": "64 lowercase hex SHA-256",
  "abandonmentRevision": "canonical positive uint64 decimal",
  "abandonmentDigest": "64 lowercase hex SHA-256",
  "abandonedCandidateCarrierEpoch": "canonical positive uint64 decimal"
}
```

The request id is a non-zero UUID minted and persisted once by the composing
authority; its digest is lowercase SHA-256 over RFC 8785 canonical request bytes
excluding that digest. The reserved candidate epoch is allocated first, must be
strictly greater than active, pending, and `expectedCarrierEpochFloor`, and
becomes the new floor when the reservation commits. A non-null predecessor must
equal one retained unconsumed abandonment result and is consumed into exactly
this request. Exact post-crash request replay returns the first result; changed
bytes, a changed/null predecessor, or a second request using that predecessor
conflicts.

The carrier returns and durably retains this strict proof-v2 object:

```json
{
  "schemaVersion": 2,
  "storeAuthorityId": "bounded non-empty string",
  "proofRevision": "canonical positive uint64 decimal",
  "proofDigest": "64 lowercase hex SHA-256",
  "reservationRequestId": "same UUID",
  "reservationRequestDigest": "same digest",
  "disposition": "empty | active | receipt_stored | abandoned | terminal",
  "orgId": "same string",
  "sessionId": "same string",
  "ptyEpoch": "same canonical uint64 decimal",
  "localResumeFrom": "same canonical positive uint64 decimal",
  "lastHostSeq": "same canonical uint64 decimal",
  "activeCarrierEpoch": "canonical uint64 decimal",
  "pendingCarrierEpoch": "canonical uint64 decimal",
  "reservedCandidateCarrierEpoch": "same positive decimal",
  "carrierEpochFloor": "same positive decimal",
  "predecessorAbandonment": null,
  "highWater": "canonical uint64 decimal",
  "boundary": "same canonical uint64 decimal as highWater"
}
```

The proof digest is SHA-256 over RFC 8785 canonical proof bytes excluding
`proofDigest`. The proof revision is a positive monotonic ordinal scoped to the
exact stream inside the stable initialized store, not a store-global counter.
`carrierEpochFloor == reservedCandidateCarrierEpoch` and never decreases. For
`empty`, active/pending/high-water/boundary and the predecessor are zero/null.
For `abandoned`, active/pending are zero, high-water/boundary may be zero, and
the predecessor object is the exact non-null value shown above. `abandoned` does
not grant authority to either old carrier. Other dispositions require null
predecessor. The proof contains no bearer, jti, nonce, raw frame, or frame digest.

`durable_carrier_proof_v2` replaces v1 in the exact five-token eligibility set.
Advertising v2 requires the frozen v1 decoder and exact replay/drain path but not
a second v1 capability token; advertising both tokens or inferring v1 new
admission is a protocol refusal.

Carrier health/readiness exposes the exact JSON boolean field
`durable_carrier_proof_v2_ready`. It becomes true only after stable store
authority, the one v1 cutover manifest/write-closed flag/shrink-only tombstones
and every referenced row/credential, the exact cutover acknowledgement with all
four true facts, ACK-bearing metadata, inherited
`minimumWriterSchema="3"` authority marker, proof-v1/v2 readers, proof-v2
reservation, abandonment request/results and consume index, carrier-epoch floors,
pending/active state, and high-water all reload and verify. The acknowledged
encrypted original-credential retention, remaining-validity consume gate, and
typed adopted-candidate recovery must also remain available in the running
composition. Missing/unacknowledged/
false, a v1-specific value, or the prior unversioned
`durable_carrier_proof_ready:true` is not v2 evidence and blocks credential mint,
WSS candidate admission, and activation.

An empty manifest takes this identical path. Its count zero cannot set readiness
until the four-fact acknowledgement, schema-2 ACK-bearing disk, schema-3 marker,
and final
reload all succeed.

Let proof `boundary=high_water=N` and the selected-v3 Hello-frozen
`last_host_seq=K`. The resolver requires `N+1 >= local_resume_from`, `K >= N`,
and no K+1 overflow. It returns signed `carrier_boundary=N`,
`resolved_boundary=K`, and `last_host_seq=K`. For K=N, the mandatory Snapshot is
N+1/atSeq N. For K>N, the host sends one exact
`host_gap{fromSeq:N+1,toSeq:K,reason:"controller_unforwarded"}` immediately
before Snapshot K+1/atSeq K. Selected-v3 holds its Hello-time output boundary K
until that Snapshot is allocated; barrier timeout/overflow aborts preparation
rather than changing K.

WSS admission authenticates the signed claim, loads the exact retained
reservation, and compares every proof/request/epoch, carrier boundary N,
resolved boundary/last host sequence K, carrier-epoch floor, nullable predecessor,
and optional gap field with current
journal state in the same lock or revision-CAS critical section that fences the
incumbent and installs the candidate. Exact replay returns the first candidate
disposition. Drift, terminal state, unavailable/corrupt store, revision rollback,
or mismatch returns a typed refusal before room mutation and requires a fresh
reservation plus strictly greater candidate epoch. One proof can never authorize
two candidate epochs.

### 2.2 Exact admitted pre-active candidate abandonment

An exact same-controller handoff in `receipt_stored` replays its retained proof,
receipt, optional Gap, and staged Snapshot and never calls this operation. A
changed controller cannot inherit or rebind that handoff. An admitted
`preparing` candidate has no retained Snapshot to replay and must use this
operation before reprepare, whether its controller stayed or changed. Only a
socket that died before reservation/in-lock admission uses the non-durable fence.
A same controller presenting changed receipt-stored handoff bytes receives the
existing changed-replay conflict; it cannot use abandonment to resample
authority. The endpoint is:

```text
POST /v1/session-shim/carrier-proofs/abandon
Authorization: Bearer <control credential>
Content-Type: application/json
```

The strict request is capped at 4096 bytes by both declared and actual body size,
rejects compression, unknown/duplicate members, trailing JSON, JSON numbers, and
non-canonical spellings, and is frozen durably before I/O:

```json
{
  "schemaVersion": 1,
  "abandonmentRequestId": "UUID",
  "abandonmentRequestDigest": "64 lowercase hex SHA-256",
  "reason": "superseded_before_activation",
  "cause": "controller_changed | preparing_reprepare | credential_lifetime_insufficient",
  "expectedCandidateState": "preparing | receipt_stored",
  "storeAuthorityId": "bounded non-empty string",
  "orgId": "bounded non-empty string",
  "sessionId": "bounded non-empty string",
  "ptyEpoch": "canonical uint64 decimal",
  "admittedProofSchemaVersion": "1 or 2 as a canonical positive uint64 decimal",
  "admittedProofRevision": "canonical positive uint64 decimal",
  "admittedProofDigest": "64 lowercase hex SHA-256",
  "reservationRequestId": "UUID",
  "reservationRequestDigest": "64 lowercase hex SHA-256",
  "preparedCorrelationDigest": "64 lowercase hex SHA-256",
  "snapshotReceiptRequestDigest": "64 lowercase hex SHA-256 or null",
  "snapshotReceiptRevision": "bounded non-empty opaque string or null",
  "expectedActiveCarrierEpoch": "canonical uint64 decimal",
  "expectedPendingCarrierEpoch": "canonical positive uint64 decimal",
  "reservedCandidateCarrierEpoch": "same canonical positive uint64 decimal",
  "expectedCarrierEpochFloor": "canonical positive uint64 decimal",
  "expectedHighWater": "canonical uint64 decimal"
}
```

The abandonment digest is SHA-256 over RFC 8785 canonical request JSON excluding
that member. The caller cannot supply Relay's private current-state root. Under
the abandonment/activation journal lock, Relay resolves the unique exact current
admitted `preparing` or `receipt_stored` state matching every request binding and returns its state
revision/digest. That digest commits admitted proof/reservation, prepared
correlation, nullable Snapshot-receipt digest/revision, nullable Gap/staged
Snapshot identity, active/pending epochs, epoch floor, and high-water. No or
multiple matches conflict. Pending equals the reserved candidate. The
admitted proof schema spelling is exactly string `"1"` or `"2"`; a JSON number is
invalid. The expected floor is at least every expected active/pending/reserved
epoch and must equal the locked source state. Receipt digest/revision are both
JSON null exactly for `preparing` and both non-null exactly for `receipt_stored`;
partial or reversed nullability conflicts. `preparing_reprepare` requires
preparing; `controller_changed` requires receipt_stored plus distinct source/
current controllers; `credential_lifetime_insufficient` requires receipt_stored
plus server proof that the original token lacks the post-consume recovery margin
and is the only same-controller receipt-stored abandonment. Other combinations
conflict. Expected high-water may be zero.

Under the same journal lock that serializes activation and admission, the first
successful request fsyncs and returns `201` with this immutable response; exact
replay returns the same bytes with `200`:

```json
{
  "schemaVersion": 1,
  "state": "abandoned",
  "cause": "same closed value",
  "abandonmentRequestId": "same UUID",
  "abandonmentRequestDigest": "same digest",
  "storeAuthorityId": "same string",
  "orgId": "same string",
  "sessionId": "same string",
  "ptyEpoch": "same canonical uint64 decimal",
  "admittedProofSchemaVersion": "same canonical string",
  "admittedProofRevision": "same canonical positive uint64 decimal",
  "admittedProofDigest": "same digest",
  "sourceCandidateState": "same preparing or receipt_stored string",
  "sourceStateRevision": "Relay-resolved canonical positive uint64 decimal",
  "sourceStateDigest": "Relay-resolved 64 lowercase hex SHA-256",
  "reservationRequestId": "same UUID",
  "reservationRequestDigest": "same digest",
  "preparedCorrelationDigest": "same digest",
  "snapshotReceiptRequestDigest": "same digest or null",
  "snapshotReceiptRevision": "same opaque string or null",
  "abandonmentRevision": "canonical positive uint64 decimal",
  "abandonmentDigest": "64 lowercase hex SHA-256",
  "abandonedCandidateCarrierEpoch": "same pending/reserved positive decimal",
  "priorActiveCarrierEpoch": "same canonical uint64 decimal",
  "activeCarrierEpoch": "0",
  "pendingCarrierEpoch": "0",
  "carrierEpochFloor": "canonical positive uint64 decimal",
  "highWater": "same canonical uint64 decimal",
  "boundary": "same canonical uint64 decimal"
}
```

The abandonment revision is the next ordinal in the stream's proof-revision
domain. Its digest is SHA-256 over canonical response bytes excluding that
member. `sourceCandidateState` echoes the locked exact state. The floor equals the request's expected floor, is at least every active,
pending, reserved, or abandoned epoch ever observed, and never decreases.
High-water and boundary both equal the
request's value, including zero. For `receipt_stored`, the exact staged
Gap/Snapshot remains durable while the old candidate and receipt become
permanently non-publishable, non-activatable, and non-consumable. For `preparing`,
no Snapshot or receipt is invented. The same journal commit marks the exact target proof
reservation abandoned, so no old proof/receipt/candidate path can later consume
it. Prior active is retained only in the result; current active
and pending both clear, so no incumbent is restored.

The same request id with changed bytes, another id for the same candidate,
changed source/proof/reservation/receipt/epoch/high-water, or a concurrent
activation/adoption winner returns `409 carrier_abandonment_conflict` with no
mutation. The other closed results are `400 invalid_carrier_abandonment_request`,
uniform `401`, `413`, and `503 carrier_abandonment_unavailable`. Exact retry is
the only recovery from an ambiguous response. Missing or corrupt possibly-
committed abandonment bytes make proof v2 unavailable; room state, timeout, or a
zero reset cannot reconstruct them.

For admitted proof schema `"1"`, every request binding must match one live
untombstoned §2.0.2 entry. The serialized abandonment appends its exact
`abandoned_to_v2` tombstone before removing the v1 row/credential or enabling the
successor. Unlisted/changed/tombstoned v1 evidence reconciles instead.

The composing authority persists the exact response before allocating another
epoch. The next schema-v2 Reserve names the exact predecessor object derived from
this result and chooses above its floor. One abandonment authorizes one successor
reservation. If its preserved high-water is H and replacement Hello tail is K,
K<H or K=max uint64 refuses; K=H stages only Snapshot H+1/atSeq H; K>H stages
exact `controller_unforwarded` Gap H+1..K then Snapshot K+1/atSeq K. The old
staged Snapshot from a receipt-stored source is never reused as the successor
request; a preparing source has none.

## 3. V2 control registry additions

V2 inherits every v1 Control type and adds exactly four host-carrier controls.
All are outside the host sequence namespace and therefore use binary-frame
header `seq=0`, `rel_time=0`. Unsigned uint64 values are canonical decimal
strings (`"0"` or a non-zero digit followed by digits); JSON numbers are not
accepted.

| `type` | Direction | Shape | Purpose |
|---|---|---|---|
| `host_gap` | host -> relay | `{ "type":"host_gap", "fromSeq":str, "toSeq":str, "reason":"ring_evicted"\|"controller_unforwarded" }` | Declare an exact unavailable replay range before its authoritative recovery Snapshot. `controller_unforwarded` is reserved to proof-bound N+1..K recovery. |
| `carrier_activate` | host -> relay | `{ "type":"carrier_activate", "ptyEpoch":str, "carrierEpoch":str }` | Post-publication request to make the exact prepared v2 candidate active. |
| `carrier_active` | relay -> host | `{ "type":"carrier_active", "ptyEpoch":str, "carrierEpoch":str, "ackSeq":str }` | Idempotent acknowledgement that candidate activation committed; includes the current contiguous durable cursor. |
| `host_ack` | relay -> host | `{ "type":"host_ack", "ptyEpoch":str, "carrierEpoch":str, "ackSeq":str }` | Acknowledge the highest contiguous durable host-sequence disposition. |

The `ptyEpoch`/`carrierEpoch` values are comparison evidence against the already
verified live leg; they do not select a room or confer authority. A mismatch is
a typed protocol refusal. `ackSeq=0` is valid when nothing in the PTY epoch has
a durable disposition.

V2 adds these closed error codes:

- `carrier-not-active` — an authority-bearing operation reached a candidate;
- `carrier-activation-order` — activation arrived before its receipt or from
  the wrong/stale exact leg;
- `carrier-proof-unavailable` — the control-authenticated journal proof cannot
  be resolved/reloaded;
- `carrier-proof-drift` — proof revision/digest/boundary or its reserved epoch
  changed before the in-lock candidate fence/install;
- `carrier-cursor-regression` — the proof-resolved successor is below the
  shim's fsync-backed local resume floor;
- `host-durability-unavailable` — the durable journal cannot append or reload;
- `host-frame-conflict` — the same stream identity/sequence has different raw
  bytes or a changed durable gap disposition.

These controls and codes are never emitted on a selected v1 leg. An older v1
decoder ignoring an unknown Control does not make sending one conformant.

The generic host client keeps its existing `DeclareHostGap(from,to)` behavior
as the source-compatible `ring_evicted` default and adds
`DeclareHostGapWithReason(from,to,reason)` over the closed reason union. Only a
proof-bound prepared recovery may select `controller_unforwarded`; accepting it
from an ordinary active/ring-miss caller is a proof mismatch.

## 4. Carrier takeover state machine

The cross-layer order is fixed:

```text
preparing
  -> receipt-stored
  -> adoption-committed
  -> batch-committed/local-published
  -> active
```

The relay may retain additional diagnostic substates, but it cannot skip,
collapse, or infer one of these transitions.

### 4.1 `preparing`

A valid strictly higher `carrier_epoch` creates a candidate leg only after the
signed proof reservation passes §2.1's atomic current-journal recheck. The
proof schema string, revision/digest, reservation request id/digest, reserved
candidate epoch, carrier-epoch floor, nullable exact predecessor abandonment,
store authority, carrier boundary N, and resolved boundary/last-host sequence K
are frozen in the credential. The relay compares them in the same lock that
atomically fences the incumbent's mutation authority and installs the candidate.
Drift changes neither. A successful recheck does not install
the candidate as active merely because WSS accepted or `subscribe` matched.
Room state is reconnecting/preparing, not live under the new leg.

Before `active`, the relay may send the candidate only one mandatory
`snapshot_request{reason:"resync"}`. It records a non-zero request id internally
against the exact leg and proof/resolved boundaries. Other join,
backpressure, and resync snapshot requests serialize behind it.

No viewer authority crosses the boundary while preparing:

- driver/viewer `Input` is not forwarded and does not advance or emit
  `input_ack`;
- viewport advertisements may update the viewer's local observation, but no
  authoritative `Resize` is scheduled, flushed, or sent;
- `Kill` is not sent and no API may report `relayed:true`; it returns the typed
  not-active outcome;
- no best-effort callback, socket fact, or cached room state advances the
  takeover.

The host answers the mandatory request from the shim-owned VT through selected
local shimwire v3. If K>N it first sends exactly
`host_gap{fromSeq:N+1,toSeq:K,reason:"controller_unforwarded"}`. K=N sends no
gap. The one request-correlated raw HostFrame is then exactly Snapshot sequence
K+1 with `atSeq=K`. K<N, another gap reason/range, or another Snapshot sequence
is a proof conflict. There is no replay of ordinary frames from an older
composing cursor and no ring-miss inference: K was frozen under the selected-v3
Hello output barrier. No ordinary Output may overtake this response. After that Snapshot, the generic client holds
later host frames under bounded backpressure until `carrier_active`; the relay
does not journal, ring, fan out, or acknowledge them while the leg is a
candidate. The shim ring remains the source of exact replay if the candidate
never activates.

### 4.2 `receipt-stored`

The relay validates the new leg's next contiguous Snapshot, appends its exact raw
encoded frame to the host-frame journal, hashes those same bytes before
decode/sanitization, freezes the strict receipt bytes, and waits for a durable
receipt-sink acknowledgement. Only **both** committed writes advance the state.
The Snapshot is not yet inserted into the live ring/cache/fan-out and no
`host_ack` is sent. Transport success, delivery-in-progress, an empty receipt
revision, cached Snapshot, or best-effort lifecycle callback does not qualify.
The host/client retains this exact Snapshot as a pending sequence
acknowledgement. Its strict receipt may drive adoption commit, but the shim
heartbeat cursor remains unchanged.
The receipt echoes the exact store authority, proof revision/digest, reservation
request id/digest, reserved candidate epoch, carrier boundary N, resolved
boundary/last host sequence K, and nullable recovery gap; an otherwise valid
Snapshot cannot satisfy another reservation.

The generic frozen receipt uses these exact additive proof members beside its
existing lifecycle/handoff/frame correlation:

```text
storeAuthorityId
proofRevision
proofDigest
carrierBoundary
resolvedBoundary
lastHostSeq
reservationRequestId
reservationRequestDigest
reservedCandidateCarrierEpoch
gapFromSeq
gapToSeq
gapReason
```

The revision/boundary/last-sequence/reserved-epoch values are canonical uint64
decimal strings. The reserved candidate value must equal the receipt's existing
`carrierEpoch`; `resolvedBoundary == lastHostSeq == K`,
`frameSeq == K + 1`, and `atSeq == K`. `gapFromSeq`, `gapToSeq`, and
`gapReason` are all JSON null iff K==carrierBoundary N. Otherwise they are exact
canonical strings N+1, K, and `controller_unforwarded`. Partial nullability,
`ring_evicted`, another range, unknown/duplicate/missing members, overflow, or
any proof/credential/current-journal mismatch is a changed-proof refusal. Exact
receipt retry reuses the first frozen bytes; no retry mutates a proof field.
The Gap/Snapshot append may advance the journal's current proof ordinal, but the
frozen receipt continues to name the admitted reservation proof at boundary N.
The journal retains the exact proof-descended pending transition through
Snapshot K+1; adoption consume verifies that ancestry rather than requiring the
current ordinal to remain equal to the pre-append proof revision.
The strict Snapshot-receipt schema itself remains v2: `proofDigest` and
`reservationRequestDigest` content-address the complete retained proof-v2/request
bytes, including floor and predecessor. Receipt/adoption validation must load
those exact bytes; copying only the legacy scalar projection is a mismatch.

### 4.3 `adoption-committed`

The composing authority resolves the prepared handoff itself, loads the unique
unconsumed receipt and reserved proof-v2 plus any predecessor abandonment,
verifies every binding, and atomically
consumes both with the per-session adoption. Only that transaction may advance
an older composing adoption cursor through resolved boundary K. No receipt id/
revision, nonce, digest, token jti, proof selector, or activation selector is
supplied by the host.

### 4.4 `batch-committed/local-published`

Every served authority scope, including an empty scan, commits its complete
adoption batch. The daemon then atomically publishes its complete local
adopted/quarantined/tombstoned set and records local `adoptionComplete`. Durable
remote commits are not rolled back if later activation fails.

### 4.5 `active`

Only the daemon's post-publication seam sends `carrier_activate` on the exact
candidate. The relay requires the same authenticated PTY/carrier epochs and its
own `receipt-stored` fact, atomically promotes the candidate, exposes the room as
live, publishes the already-durable mandatory Snapshot into the ring/cache
without duplicate viewer fan-out, and replies `carrier_active` with its durable
cursor. The acknowledgement is not sent until that promotion commits.
`carrier_active.ackSeq` resolves the pending mandatory Snapshot; a later exact
replay/`host_ack` is idempotent. This breaks no ordering cycle: adoption uses the
strict receipt, while shim acknowledgement waits for activation.

Exact replay on the same leg is idempotent and returns the same state/current
durable cursor. Early, changed, stale, wrong-leg, lower/equal-unauthorized,
receipt-less, or v1 activation is refused without disturbing the room. Only
after `carrier_active` may Input, authoritative Resize, Kill, ordinary snapshot
requests, live output fan-out, and viewer acknowledgements resume.

Resume evidence distinguishes pending from active without freezing the stream at
its original proof boundary. A `receipt_stored` resume carries pre-stage
`AckSeq=N`, optional Gap N+1..K, and the exact staged Snapshot K+1; it emits no
second gap/Snapshot and activation acknowledges K+1. After activation, ordinary
frames may advance current durable high-water to L>=K+1. An equal-active
same-controller, same-token reconnect validates `AckSeq=L` against that current persisted
high-water and retained activated proof binding, not equality with original N
or K. It sends/accepts only the idempotent active acknowledgement before local
publication releases authority callbacks.

A changed controller or fresh jti cannot use equal-active A. It takes the normal
proof-v2 `active` path, reserves B above A and the all-time floor, and completes
the full candidate pipeline. Equal/lower evidence is a refusal, never rebind.

### 4.6 Consumed-adoption candidate recovery

If the controller dies after exact proof/receipt adoption consume but before
`carrier_active`, the candidate is not abandonable. The composing authority
server-resolves the consumed adoption from current authenticated controller/
host/lifecycle/Hello facts, retains the original encrypted credential envelope,
and returns a typed `adopted_candidate_recovery` outcome. The host supplies no
adoption/proof/receipt/token/carrier selector. The outcome carries the exact
original still-valid bearer bytes and carrier epoch C, original pre-stage AckSeq
N, staged high-water H, opaque recovery correlation, and exact
`ResumeFrom=H+1`. Exact retry returns the first outcome; no credential is minted,
refreshed, re-signed, or reconstructed.

The original credential's remaining validity must cover the configured orphan +
recovery + activation + clock/propagation margin **before** adoption consume. If
not, the still-unconsumed candidate uses §2.2 cause
`credential_lifetime_insufficient`. Loss/corruption/expiry after consume is
reconciliation, never abandonment or remint.

Relay accepts the unchanged same-jti token only for the exact retained pending
candidate and only when its old transport is absent or closed. A still-live
transport returns a retryable refusal; token replay never evicts it. Reconnect
replaces transport only, returns the original `receipt_stored` disposition with
AckSeq N and already-retained optional Gap/Snapshot through H, and sends no
mandatory Snapshot request or journal append. The client/Donmai skips H via
`PreparedAdoption.ResumeFrom=H+1`, stages later frames locally until activation,
exact-replays the consumed adoption result, finishes batch/local publication,
and activates C. `carrier_active.ackSeq=H` resolves the original pending Snapshot.
No proof, receipt, Snapshot, carrier epoch, or cursor advances a second time.

## 5. Exact raw-frame durability and host acknowledgement

The relay's replay ring is a cache, not durability. A v2-capable relay has a
small pluggable durable host-frame journal whose semantic operations are:

```text
Load(stream_ref) -> durable_high_water + retained exact replay tail + gaps
ReserveProof(stream_ref, frozen_request) -> immutable proof/reservation
AbandonCandidate(stream_ref, frozen_request) -> immutable abandonment result
RecheckAndFence(proof, signed_candidate) -> exact replay or installed candidate
AppendFrame(stream_ref, seq, type, raw_bytes) -> durable_high_water
AppendGap(stream_ref, from_seq, to_seq, reason, recovery_snapshot) -> durable_high_water
```

`stream_ref = (org_id, session_id, PTY-host epoch)`. Carrier epoch and token jti
are ingress correlations only. A self-hosted relay supplies the same interface
to its own durable control plane or local durable store; there is no import from
one hosted platform and no in-memory-success fallback.

Every ordinary frame admitted here originates in the selected-local-v3
`HostFrame` event, which carries the complete raw attach-frame bytes for Output,
applied Resize, Marker, Snapshot, and Exit. Selected-v2 semantic observations
are not inputs to this journal. A live requested Snapshot uses its one raw
HostFrame; the adjacent local `SnapshotResult` is correlation-only and cannot
create a second relay frame.

For every sequence-bearing host frame, the relay order is:

1. verify the exact currently authenticated leg and bounded frame syntax;
2. retain the exact encoded binary-frame bytes before any semantic re-encoding
   or viewer sanitization;
3. commit/fsync the frame and advance the highest contiguous durable
   disposition;
4. apply the inherited per-type ring/cache/fan-out behavior, deriving sanitized
   viewer bytes where that behavior fans out;
5. emit `host_ack` with that durable cursor.

An exact replay at or below the cursor compares raw bytes and is idempotent. It
may return the existing ack without duplicate ring insertion or fan-out. Changed
bytes at the same stream sequence are `host-frame-conflict`. A frame above the
next expected sequence waits/refuses and cannot advance the ack.

`host_gap` is durable truth that bytes are unavailable, not permission to invent
them. Its range must begin at the prior durable cursor plus one and end before
the following authoritative Snapshot sequence. The relay advances beyond the
range only by atomically retaining the gap plus the exact recovery Snapshot.
The resulting `ackSeq` means every covered sequence has a durable disposition
(exact raw frame or explicit gap); it never claims the missing bytes exist.
`ring_evicted` means the shim no longer retains those bytes. The proof-only
`controller_unforwarded` reason means exact frames N+1..K existed at the shim but
never reached external carrier durability before controller loss and are now
truthfully superseded by Snapshot K+1/atSeq K. The latter is accepted only when
the signed proof/resolved boundary and receipt carry that exact range/reason.

A journal timeout, I/O failure, unavailable authority, or ambiguous commit
causes no ring/cache mutation, viewer fan-out, or host ack. The relay
backpressures or closes with `host-durability-unavailable`. Retrying uses the
same raw bytes.

At process start the relay reloads stable store authority, each stream's
monotonic proof ordinal, frozen proof-v1/v2 reservation requests/proofs,
abandonment requests/results and predecessor-consume index, carrier-epoch floor,
pending candidate proof/receipt, active binding, high-water, and retained tail/gaps before
resolving proof or admitting v2 hosts/viewers. It cannot acknowledge, accept a
takeover Snapshot, or advertise v2 readiness until all verify. Corrupt or
missing state refuses v2 instead of resetting proof/sequence to zero under the
same PTY epoch/store authority.

Abandonment diagnostics expose only a closed outcome/reason and bounded numeric
revision/high-water. The control bearer, exact request/result bytes, UUIDs,
store authority, proof/state/request/receipt/prepared-correlation/abandonment
digests, receipt revision, token/jti/nonce, and raw frame bytes never enter logs,
traces, errors, room/control snapshots, or viewer frames.

The host-side generic attach client considers a sequence-bearing send durable
only when the matching current-leg `host_ack` covers it. A WSS write completion
is not success. It returns durable callback success to the daemon only then;
the daemon may consequently advance `last_forwarded_seq` and the shimwire
Heartbeat acknowledgement. A disconnect or timeout before ack preserves the old
cursor and replays the exact frame.

Post-Exit sequence-zero final Snapshots remain outside the host sequence. If a
composition retains them, it does so under the existing exact final-snapshot/
terminal receipt authority; they never move `host_ack`.

## 6. Failure matrix

| Failure | Required result |
|---|---|
| Higher carrier authenticates, receipt absent | Candidate remains preparing; incumbent has no mutation authority; only mandatory Snapshot request is sent. |
| Receipt commits but response is lost | Exact frozen receipt retry returns the first revision; candidate still is not active. |
| Per-session adoption or any batch fails | Candidate remains non-active; completed durable steps retry idempotently. |
| Controller dies after adoption consume and before activation | Server-resolve `adopted_candidate_recovery`, return the unchanged still-valid bearer/epoch and ResumeFrom H+1, require old transport absent/closed, exact-replay adoption/batches, then activate the original candidate with no new proof/receipt/Snapshot/cursor. |
| Old same-jti candidate transport is still live during adopted recovery | Retryable refusal; bearer replay cannot evict the live transport. |
| Original credential lacks required validity before adoption consume | Keep proof/receipt unconsumed and abandon with `credential_lifetime_insufficient` before reserving higher. Expiry/loss/corruption after consume is reconciliation, not remint. |
| Local publication succeeds, activation request is lost | Daemon stays non-Ready and retries exact `carrier_activate`; relay either promotes once or returns the already-active acknowledgement. |
| Viewer sends Input before active | Nothing reaches the host and no input ack advances. |
| Resize debounce fires before active | Timer/result is suppressed; no authoritative Resize reaches any host leg. |
| Kill arrives before active | No host frame and no `relayed:true`; typed not-active result. |
| Durable frame append fails | No ring/cache/fan-out/ack; host and shim cursor stay unchanged. |
| Relay crashes after append before ack | Reload high-water, compare exact replay, return same ack without duplicate fan-out. |
| Relay crashes with only in-memory ring state | V2 remains unavailable; memory is not promoted to durability. |
| Shim sidecar ack and carrier boundary are N while composing adoption is M&lt;N and Hello K=N | Resolve proof N, return prepared ResumeFrom N+1, send only Snapshot N+1/atSeq N, and advance M through N only while consuming proof plus receipt. |
| Hello LastHostSeq K exceeds proof boundary N | Hold K, return ResumeFrom K+1, send exact `controller_unforwarded` Gap N+1..K plus Snapshot K+1/atSeq K, and let proof+receipt consume advance M only through K. |
| Hello LastHostSeq K is below proof boundary N or K is max uint64 | Refuse before Welcome with no clamp/gap/candidate. |
| Carrier proof successor N+1 is below `local_resume_from` | Refuse before Welcome; do not regress, infer M/N, or send pre-active replay. |
| Journal advances after proof but before candidate admission | The in-lock proof recheck returns `carrier-proof-drift`; no incumbent fence or room mutation occurs and a higher-epoch reprepare is required. |
| Same reservation request replays after process crash | Return the first proof ordinal/digest/reserved epoch. Changed bytes conflict. |
| Cutover crashes before write-closed flag + manifest commit | V2 readiness stays false and no partial manifest authorizes legacy state. Exact request retries under the exclusive lock. |
| Cutover commits but response is lost | Exact request replay returns the first store-bound cutover id/revision/manifest digest and count. It never resnapshots rows. |
| Cutover response is durable but no exact composing acknowledgement exists | Keep v2 readiness false. The carrier cannot infer composing writer closure or any of the three recovery-support facts from its store. |
| Acknowledgement crashes before metadata commit | Readiness stays false and the marker remains at its prior floor: 2 on first ACK or inherited 3. Exact retry uses the same bytes. |
| Acknowledgement metadata commits but marker floor/digest is not current | An ACK-aware opener verifies the ACK-bearing schema-2 disk under lock, installs floor `max(existing,3)` plus the exact current `cutoverAcknowledgementDigest`, fsyncs/rereads, then returns the first result. The exact ACK-unaware schema-2 decoder refuses the new members/floor and cannot serve. |
| Marker reaches 3 but acknowledgement response is lost | Restart requires exact schema-2 disk/ACK plus schema-3 marker binding and returns the first acknowledged result with `200`; it never repeats facts or lowers the marker. |
| Cutover/acknowledgement commits on A, a response is lost, then store rotates to B | Retained/migrated control idempotency returns A's first result on exact replay. New/changed B cutover or acknowledgement conflicts until every A entry/reference is tombstoned/drained; B inherits permanent v1 closure and the schema-3 marker floor but requires its own cutover and acknowledgement. |
| Initialized store has zero v1 rows and no proof response has exposed store authority | Relay resolves its own authority under the cutover lock and freezes empty entries/count zero. The composing authority then persists that exact response and performs the same four-fact ACK; only schema-3 durable bind/marker/reload permits readiness. |
| New/unlisted/changed v1 row appears after cutover | Refuse the row into reconciliation and set v2 readiness false; never append it to the base manifest. |
| Retained v1 entry drains or crosses abandonment to v2 | Fsync the exact shrink-only tombstone before deleting/unlinking its row/credential. Restart reload keeps it ineligible forever. |
| Exact pre-ACK schema-2 artifact `508ec69c1f5b81709673dd32a623bde99be34daa` opens after ACK | Literal refusal before writer/readiness in both the ACK-bytes-present/marker-at-2 crash window and completed marker-at-3 state. Restored ACK-aware code repairs/reloads forward and never downgrades. |
| One proof is presented under a second candidate epoch | Refuse exact reserved-epoch mismatch before room mutation. |
| Prior candidate is exact `receipt-stored` under the same controller/handoff | Resume pre-stage AckSeq N plus persisted optional gap/proof/receipt/Snapshot K+1 with no abandonment or second mandatory request. |
| Changed controller finds exact `receipt-stored` candidate | Persist §2.2 request/result first; preserve staged high-water H, clear active/pending, keep the all-time epoch floor, and reserve one proof-v2 successor through the exact predecessor above that floor. |
| Relay commits abandonment but caller loses the response | Exact request replay returns the first response bytes/revision/digest; changed bytes or another id for that candidate conflicts. |
| Abandonment lineage is lost/corrupt after possible commit | External v2 remains unavailable in reconciliation; never reconstruct, zero high-water, or fall back to proof v1. |
| Abandoned high-water is H and replacement Hello is K | K&lt;H or K=max refuses; K=H sends only Snapshot H+1/atSeq H; K&gt;H sends exact Gap H+1..K then Snapshot K+1/atSeq K. Old staged bytes remain non-publishable. |
| Same-controller same-token active reconnect presents current AckSeq L after ordinary progress | Accept L only when it equals current persisted high-water and retains the activated proof binding; do not require L==N or K. |
| Changed controller or fresh JTI presents equal-active epoch A | Refuse. Normal proof-v2 active-state takeover allocates B>A/floor and completes the full candidate pipeline; equal/lower never rebinds. |
| Socket dies before reservation/in-lock admission | Apply the non-durable socket fence; create no carrier abandonment or receipt evidence. |
| Admitted candidate is `preparing` with no receipt | Commit §2.2 with both receipt members null, preserve existing high-water/floor, clear active/pending without incumbent rebind, and reserve the successor through its exact predecessor. |
| Proof is terminal, missing, corrupt, timed out, store-rotated, or revision-regressed | External v2 remains unavailable; no in-memory/zero/prior-adoption fallback. |
| Same sequence reappears with changed bytes | Terminal conflict; never sanitize/re-encode it into equality. |
| v1 host presents v2 claim/control | Version/auth refusal; v1 room semantics remain unchanged. |
| Local selected-v2 shim reaches carrier preparation | Adopt/conserve it, return `durable_host_frame_unsupported`, charge capacity, and create no attach-v2 candidate. |
| V3 live Snapshot result carries frame bytes or generates a second event | Duplicate-host-frame refusal; receipt, journal, and acknowledgement do not advance. |

## 7. Migration and rollback

1. Publish local shimwire v3/full-host-frame/ACK-sidecar support,
   proof-resolved `PreparedAdoption.ResumeFrom`, and both max-2 overlap
   directions before attach-v2 activation. Selected v1/v2 stay byte-identical.
2. Publish the attach-v2 codec/control types and generic client dormant.
3. Deploy relay durable journal/reload, stable store authority, per-stream proof
   ordinal, frozen proof-v1 journal and exact legacy-credential readers,
   v1 cutover manifest/tombstone codecs, cutover and acknowledgement control
   edges, ACK-bearing schema-2 cutover-disk decoding, current/rotated/new-store
   `minimumWriterSchema="3"` markers and interrupted-upgrade recovery, proof-v2
   reservation/recheck,
   schema-v1 abandonment ledger/route, all-time carrier-epoch floor, single-use
   predecessor index, and candidate state machine with v2 admission disabled.
4. Deploy the strict proof-bound receipt/adoption/batch, exact five-token
   attestation containing `durable_carrier_proof_v2` instead of v1, and daemon
   post-publication seams, plus encrypted original-credential retention,
   remaining-validity consume gate, and typed consumed-adoption recovery. Never
   advertise both proof tokens. In order: durably close the composing v1 writers;
   obtain Relay's frozen/reloaded response after its own writer closure; persist
   that exact response; verify all four acknowledgement facts true; invoke the
   authenticated acknowledgement with frozen bytes; and require Relay to durably
   bind exact ACK bytes in the schema-2 disk, upgrade/fsync the marker to 3 with
   the exact current `cutoverAcknowledgementDigest`, and reload both. Every
   retained v1 row must be listed, zero rows follow the same acknowledgement
   path, and no v2 readiness may become true before the last step.
5. Enable v2 only for installed artifacts that pass the conformance obligations
   below. A local selected-v1/v2 shim remains conservation-only and visibly
   carrier-ineligible.
6. Rollback first disables new v2 credential mint/admission and lets already
   active v2 legs drain. It retains proof-v1/v2 bytes, abandonment request/results
   and predecessor-consume state, carrier-epoch floors, receipts, and high-water.
   After the first acknowledgement or abandonment, only an artifact that decodes
   those records and declares writer/readiness schema max at least 3 is a valid
   rollback. It never rebinds a leg as v1, lowers an epoch/floor/schema marker,
   discards store state, or reactivates an incumbent. A max-3 four-token,
   proof-v1-only, or ACK-unaware schema-2 rollback cannot mint/admit a new proof-
   bound v2 carrier or open the acknowledged store.
   Retained original bearers/recovery correlations survive until activation or
   reconciliation and are never reminted after loss/expiry/corruption.
   The v1 cutover manifest, write-closed flag, exact acknowledgement, schema-2
   cutover disk, schema-3 marker/history fence, tombstones, and referenced secrets also
   survive; rollback never regenerates, enlarges, clears, reopens, or lowers them.

Activation is an operator/founder deployment decision outside protocol
acceptance. A source test, mutable checkout, branch reference, or in-memory demo
cannot enable it.

## 8. Conformance and V16 proof obligations

- [ ] WSS `/v2/` offers/echoes only `interactive-attach-v2`; substituting v1
      makes the takeover test RED.
- [ ] V1 verifier rejects the exact v2 claim set and v2 verifier rejects the v1
      set, every unknown/duplicate member, bad nonce/digest/jti, wrong role,
      and stale/lower carrier evidence.
- [ ] Registration/refresh eligibility requires the exact lexical five-token
      set including `durable_carrier_proof_v2` instead of v1; max 3 with the
      earlier four tokens, v1 alone, or both proof tokens is RED and creates no
      credential/candidate. The v1 decoder still exact-replays/drains retained
      same-handoff state without authorizing new admission, and the exact legacy
      claim profile authenticates only those already-retained original bytes.
- [ ] Against the real persistent carrier store, create exact v1 rows in
      reserved/preparing/receipt-stored/active states, durably close every v1
      writer, and run the authenticated v2 cutover. Crash before manifest commit
      and prove readiness false/no partial eligibility; crash after commit before
      response and prove exact retry returns the first store authority, cutover
      id/revision, manifest digest, entry count, and write-closed fact without
      resnapshot. Delete the exclusive lock, store binding, fsync/transaction,
      writer-close ordering, minimum-writer-schema store-open refusal, or reload
      check and observe RED.
- [ ] Persist the exact cutover response in the composing authority, verify the
      four facts, and send the strict authenticated acknowledgement. False/omitted
      facts, wrong request/response/store binding, changed digest/body, missing or
      repeated auth, compression, declared/actual byte 4096+1, unknown/duplicate/
      trailing members, JSON-number substitutions for string fields, and non-
      canonical UUID/digests are RED with no readiness mutation. Crash before
      metadata commit and prove the marker/readiness stay at 2/false. Crash after
      exact acknowledgement bytes commit in the schema-2 disk but before marker
      upgrade; an
      ACK-aware fresh opener must set the floor to 3, bind the exact
      `cutoverAcknowledgementDigest`, and fsync/reread under lock before readiness,
      while the
      exact pre-ACK artifact
      `508ec69c1f5b81709673dd32a623bde99be34daa` is literal RED before writer/
      readiness. Repeat after the marker reaches 3 and require the same artifact
      RED; restored ACK-aware code returns the first acknowledged bytes with
      `200`. Marker 3 with missing/mismatched ACK metadata is closed corruption.
      Delete strict unknown-ACK-member refusal in the pre-ACK decoder, marker
      ACK-digest binding, monotonic floor, durable write, fsync/transaction barrier,
      forward-repair lock/reread, or
      readiness dependency independently and observe RED before restoring GREEN.
- [ ] Commit cutover on store A, drop the response, rotate to B, then exact-retry
      the same id/body. It must return A's first response from retained/migrated
      read-only control idempotency and must not run against B. A changed/new B
      request is RED while any A entry/reference remains. Tombstone/drain all A
      entries, prove zero references, then freeze and separately acknowledge B
      with a new request while v1 writers stay permanently closed. Repeat with a
      lost A acknowledgement response; A's first acknowledged result must replay
      and must not bind to B. Assert every rotated/history/new-store marker keeps
      minimum writer/readiness schema 3; B's schema-2 response cannot lower it,
      and B needs its own ACK before readiness despite A history. B's already-
      floor-3 marker must bind B's exact current ACK digest, and open must validate/
      reload B's current ACK before readiness. Dropping/mis-scoping either
      idempotency record, returning B on exact A replay, lowering the marker, or
      reopening v1 is RED.
- [ ] Repeat cutover on a freshly initialized store with zero v1 rows and no prior
      proof reservation response. Relay must resolve/return its own non-empty
      store authority, freeze an empty manifest, and return count zero. The
      composing authority must persist that exact response, prove the identical
      four facts, send the identical acknowledgement, and reach readiness only
      after ACK-disk/marker-3 durable bind and reload. Bypassing the ACK
      because the manifest is empty, requiring caller-supplied store authority,
      or substituting empty/guessed authority is RED; the full zero-row
      acknowledgement path is GREEN.
- [ ] Verify every manifest entry id/digest/proof/epoch/state and nullable
      credential digest triple against retained bytes. Insert or mutate a v1 row
      after cutover and prove auth/action refusal, reconciliation, and v2 readiness
      false with no auto-add. Drain/abandon/terminalize entries and prove exact
      tombstones commit before row/secret deletion, eligibility only shrinks, and
      restart reload never reopens them. Roll back to an artifact lacking manifest
      enforcement and prove all writers/readiness remain disabled; restore a
      compatible artifact and observe the same smaller allowset GREEN.
- [ ] Replay one immutable manifest-listed proof-v1 credential whose original jti,
      nonce, prepared correlation, proof/reservation, epochs, boundary, and expiry
      still match the retained same-controller handoff. Deleting the legacy
      profile reader is RED. Minting a fresh profile, changing any claim, mixing
      v1/v2 members, accepting an expired credential, or selecting a new
      reservation/controller is RED; the restored exact retained replay/drain is
      GREEN and produces no new credential or candidate.
- [ ] The strict JWT carries `proof_schema_version` exactly as JSON string `"2"`,
      `carrier_epoch_floor` as a canonical positive decimal string equal to the
      reserved candidate, and always-present `predecessor_abandonment` as null or
      the exact eight-member object. A JSON number, omission, partial object,
      changed target/abandonment member, or v1 retained proof is RED before room
      mutation.
- [ ] With shim sidecar ack N, carrier high-water N, and prior adoption M&lt;N, the
      proof-resolved response/`PreparedAdoption.ResumeFrom` is exactly K+1 for
      Hello-frozen LastHostSeq K>=N. K=N sends only Snapshot N+1/atSeq N; K>N
      sends `controller_unforwarded` Gap N+1..K then Snapshot K+1/atSeq K.
      K<N, barrier drift/overflow, substituting M, daemon N, zero, or ordinary
      replay is RED.
- [ ] The reservation request id/body/digest, reserved candidate epoch, proof
      ordinal/body/digest, store authority, carrier-epoch floor, nullable
      predecessor, and boundary survive process crash.
      Exact replay returns the first values; changing a byte or reusing one
      proof for another epoch is RED.
- [ ] Advance the journal after proof but before WSS admission. The production
      in-lock recheck must refuse before incumbent fence/candidate install; move
      the check outside that critical section and observe RED.
- [ ] At each pre-active state, production Input/Resize/Kill paths produce zero
      host frames and zero acknowledgement/relayed effects. Delete each gate and
      observe its named test RED, then restore GREEN.
- [ ] Exactly one mandatory takeover Snapshot request crosses before active;
      its optional proof-bound Gap is the only preceding candidate control and
      ordinary snapshot requests serialize behind it. Existing
      `DeclareHostGap` remains `ring_evicted`; only the additive reason-aware API
      can send `controller_unforwarded`.
- [ ] The host leg proves actual selected local v3 plus
      `full_host_frame_v3`. Selected local v2 returns the visible durable-frame
      incompatibility and never creates a candidate.
- [ ] Output, applied Resize, Marker, Snapshot, and Exit journal bytes come from
      the one raw local HostFrame event. A legacy semantic input or live
      SnapshotResult-derived duplicate is RED.
- [ ] Receipt, adoption, all batches, local publication, `carrier_activate`, and
      `carrier_active` occur in order. Deleting the post-publication seam or
      moving activation earlier is RED.
- [ ] The pre-active Snapshot's exact frame journal + strict receipt permit
      adoption publication without advancing the shim cursor; waiting on its
      host ack before publication is RED, and `carrier_active.ackSeq` resolves it
      after activation.
- [ ] The receipt echoes every proof/reservation/store/boundary field and exact
      carrier boundary N, resolved boundary/last host K, nullable exact gap, and
      `frameSeq=K+1`, `atSeq=K`; adoption advances an older cursor only through K
      while atomically consuming that exact proof plus receipt. Omit,
      mutate, cross-replay, or check-then-consume and observe RED.
- [ ] A blocked/failed journal append produces no ring/cache/fan-out/`host_ack`;
      deleting the append or moving it later is RED.
- [ ] Every byte value and split boundary persists and replays exactly as
      received. Semantic reconstruction and viewer-sanitized bytes compare
      unequal to source truth.
- [ ] Fresh-process restart reloads the same high-water/tail/gap state and exact
      proof-v1/v2/store/reservation/pending state, cutover acknowledgement,
      abandonment request/results and consume index, and carrier-epoch floor;
      exact replay returns the same ack without duplicate fan-out or mandatory
      Snapshot. Removing `Load` is RED.
- [ ] With immutable installed daemon/shim/client/composer/relay binaries, make
      the first candidate `receipt_stored` with active zero and positive staged
      high-water H, then change controller. Disabling the real abandonment route
      or proof-v2 decoder is RED/non-Ready. Restored GREEN commits one exact
      request/result across a response-lost crash, clears active/pending without
      publishing/acking the old leg, and reserves one successor above the floor
      through its single-use predecessor. Independently mutate each source field,
      remove the durable write/floor/predecessor/controller gate, race activation,
      leave the target proof reservation consumable, or restore the incumbent and
      observe the named fixture RED. Same-controller
      exact replay remains GREEN with no abandonment or second Snapshot.
- [ ] With active A and durable high-water H&gt;0, admit higher C through the real
      in-lock WSS fence, then kill it in `preparing` before receipt storage. The
      abandonment request must carry preparing plus both receipt fields null,
      preserve H/floor, clear A/C without reactivating A, mark C's reservation
      abandoned, and admit only a successor above the floor. Repeat at H=0.
      Treating preparing as a socket-only fence, requiring positive H, supplying
      either receipt field, relabeling the state empty/active, or reusing A/C is
      RED; a pre-admission socket death remains the non-durable control.
- [ ] Crash the controller independently at `adoption-committed` and
      `batch-committed/local-published`. The authenticated replacement receives
      the first typed recovery outcome with exact original bearer/epoch,
      AckSeq N, H, and ResumeFrom H+1; Relay requires old transport absent/closed,
      sends no Snapshot/append, exact-replays adoption/batches, and activates C.
      Abandoning, reminting/changing the JWT or JTI, advancing proof/receipt/
      cursor, replaying H, or evicting a live same-jti transport is RED.
- [ ] Reduce original credential remaining validity below the configured orphan/
      recovery margin before adoption consume and prove
      `credential_lifetime_insufficient` abandonment stays pre-consume and admits
      only a higher successor. Delete the validity gate and observe RED. Expire,
      lose, or corrupt the retained encrypted bearer after consume and prove
      reconciliation with zero remint/log/diagnostic exposure.
- [ ] For active A, same-controller same-token reconnect at current L remains
      idempotent. Change controller or JTI and present A/equal/lower: RED. Normal
      proof-v2 `active` takeover at B above A/floor completes the full candidate
      pipeline and is GREEN.
- [ ] From preserved H, replacement K=H produces only Snapshot H+1; K&gt;H produces
      Gap H+1..K then Snapshot K+1; K&lt;H and overflow are RED. Zeroing H, relabeling
      it empty, or replaying the abandoned Snapshot as the successor is RED.
- [ ] Pending resume retains AckSeq N and staged Snapshot K+1; active resume may
      carry current AckSeq L>=K+1. Requiring either resume AckSeq to equal the
      original proof boundary, or emitting a second gap/Snapshot, is RED.
- [ ] The daemon advances its shim heartbeat only after `host_ack`; replacing
      that wait with socket-write completion is RED.
- [ ] Tokens, raw jtis, handoff nonces, raw Output/Snapshot bytes, journal
      payloads, abandonment request/result bytes, UUIDs, store authority,
      proof/state/request/receipt/prepared-correlation/abandonment digests, and
      receipt revisions, adopted-recovery correlations, and retained bearer
      envelopes, cutover manifests/tombstones, and cutover/entry/credential/JTI/
      tombstone/acknowledgement ids/digests/bytes are absent from logs, errors,
      diagnostics, room snapshots, and viewer control frames.
- [ ] A self-hosted compatible journal/sink passes the same corpus without any
      hosted-platform import.

Per Agent Operating Protocol V16, a green suite alone proves none of these.
Each named production seam is removed/disabled independently, the intended
fixture is observed RED for the intended reason, and the restored exact code is
observed GREEN.
