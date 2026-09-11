# Retired carrier proof schema 3

Normative companion to [the retired-source reconciliation ADR](../ADR-2026-09-11-retired-carrier-source-reconciliation.md).
This is a registered pre-consume recovery profile, not a replacement for
ordinary proof 1/2. Hosted authentication/transport and persistence policy are
extension concerns.

## Canonical encoding

Objects are closed and reject duplicate/unknown keys. Schema selectors are JSON
integers. Epochs, revisions, floors and cursors are canonical unsigned decimal
strings; IDs are bounded/nonzero UUIDs where the existing profile requires them.
Digests are lowercase SHA-256 over RFC8785 canonical JSON with that object's own
digest member omitted. Request/response bodies have a 32 KiB declared-and-actual
bound. A content digest is not a digital signature.

The exact synthetic [wire vectors](../fixtures/retired-source-recovery-v1/WIRE-VECTORS.json)
are byte-identical in both corpora. Their state/source commitments are codec
fixtures, not current no-stream or historical-admission evidence. The companion
[negative cases](../fixtures/retired-source-recovery-v1/WIRE-NEGATIVE-CASES.json)
fix strict semantic, version, scope, overflow, encoding, size and replay controls
with explicit re-digest rules.

## Inspection

An authenticated owner asks the current journal authority for an exact
store/organization/session/PTY tuple. A closed `retired | live | unavailable`
result is read-only. `retired` carries the exact validated retirement record,
evidenceDigest, known positive floor F and high-water H. Only understood
schema 3-or-later `carrier_idle` records with terminalSequence0 qualify for this
profile. An inspection never authorizes recreation.

## Combined reconciliation request, schema 1

Required members:

```text
schemaVersion = 1
reconciliationRequestId, reconciliationRequestDigest
storeAuthorityId, orgId, sessionId, ptyEpoch
retirementEvidenceDigest
expectedRetiredCarrierEpochFloor, expectedRetiredHighWater
sourceReservationRequestId, sourceReservationRequestDigest
sourceReservedCarrierEpoch
sourceAbandonmentRequestId, sourceAbandonmentRequestDigest
successorRequest = strict proof-request schema 3 below
```

The source is an exact schema 2 pre-receipt prepared candidate with no source
Snapshot/adoption/terminal evidence. Other source profiles are not inferred.
The carrier verifies 0<source epoch<=F; the composing authority verifies its
retained source references and immutable request. Their historical effect is
not inferred from current absence.

## Designated successor request, schema 3

```text
schemaVersion = 3
reservationRequestId, reservationRequestDigest
orgId, sessionId, ptyEpoch
localResumeFrom = L
lastHostSeq = S
expectedActiveCarrierEpoch = 0
expectedPendingCarrierEpoch = 0
expectedCarrierEpochFloor = F
reservedCandidateCarrierEpoch = C
predecessorAbandonment = null
retirementContext = {
  reconciliationRequestId,
  retirementEvidenceDigest,
  retiredCarrierEpochFloor,
  retiredHighWater
}
```

C>F, S>=H, H+1>=L, L>0, S<maxuint64. The composing authority additionally
requires S to cover every retained source/correlation cursor and honors its
existing numeric projection ceiling. Shim generation G is independent of C.
The context is exact: expectedCarrierEpochFloor equals context F, and the
parent and child agree on scope, operation ID, retirement evidence, F and H.
It is not a caller-selectable alternative authority.

## Successful reconciliation receipt, schema 1

The atomic no-stream CAS reserves one designated root successor and retains:

```text
schemaVersion = 1
state = retired_source_reserved
reconciliationRequestId, reconciliationRequestDigest
storeAuthorityId, orgId, sessionId, ptyEpoch
retirementEvidenceDigest, retiredCarrierEpochFloor, retiredHighWater
sourceReservationRequestId, sourceReservationRequestDigest
sourceReservedCarrierEpoch
sourceAbandonmentRequestId, sourceAbandonmentRequestDigest
successorReservationRequestId, successorReservationRequestDigest
reservedCandidateCarrierEpoch
reconciliationRevision
priorAbandonmentOutcome = unknown
receiptDigest
```

All source/retirement/designated-request bindings echo the verified request.
The positive reconciliationRevision belongs to its independent protected ledger
namespace. The state denotes a reservation, not admission, adoption, activation
or terminality. It does not assert that the original abandonment never committed.
Exact replay returns the same first receipt and proof, not a fresh current-
absence assertion or a new allocation right.

## Retired proof, schema 3

The immutable proof contains:

```text
schemaVersion = 3
disposition = retired
storeAuthorityId, orgId, sessionId, ptyEpoch
proofRevision, proofDigest
reservationRequestId, reservationRequestDigest
localResumeFrom, lastHostSeq
activeCarrierEpoch = 0
pendingCarrierEpoch = 0
reservedCandidateCarrierEpoch = C
carrierEpochFloor = C
predecessorAbandonment = null
highWater = H
boundary = H
retirementAnchor = {
  reconciliationRequestId,
  reconciliationReceiptDigest,
  retirementEvidenceDigest,
  retiredCarrierEpochFloor = F,
  retiredHighWater = H
}
```

The anchor points to the complete canonical receipt, and that receipt binds the
designated request. High-water is logical committed position at retirement; the
prefix is explicitly unavailable, not reconstructed bytes. The stream stores a
retired-history seed and refuses silent empty-prefix replay. Ordinary Snapshot,
Gap, proof-consumption and activation requirements still apply.

## Acyclic digest order and signed claims

1. The child request includes the parent operation ID, not its digest.
2. The parent request includes the complete digested child request.
3. The receipt includes parent digest and child ID/digest, not proofDigest.
4. The proof includes receiptDigest in its retirementAnchor, then computes its
   own proofDigest.

The signed host claim explicitly selects `proof_schema_version="3"` and carries
`retirement_anchor` with `reconciliation_request_id`,
`reconciliation_receipt_digest`, `retirement_evidence_digest`,
`retired_carrier_epoch_floor` and `retired_high_water`. Existing scope, validity,
nonce, prepared-correlation and carrier-extension claims remain required. The
proof/request/anchor must be loaded and compared completely, not reduced to a
legacy scalar subset. The vectors' claim projection is not a JWT.

Snapshot-receipt schema 2 may remain byte-identical only when its referenced
versioned proof and reconciliation receipt are validated in full. Consumed
proof 3 recovery preserves the same candidate and original still-valid credential.
Pre-consume follow-ups must follow explicit candidate disposal rules, including
schema 3 reader support; they cannot spend this retired CAS twice.

## Refusal and availability

Unknown/mismatched retirement, wrong current authority, live/recreated stream,
changed replay, second root successor, invalid source or cursor/floor, overflow,
quota and corrupt/incomplete protected state refuse. Transport/5xx ambiguity is
replay-only and never licenses replacement. Missing-stream remains a refusal,
not non-admission. An older proof/storage reader cannot silently accept or
downgrade the new profile.

## Exact inspection envelope

Inspection request schema 1 is the closed object `{schemaVersion:1,
storeAuthorityId, orgId, sessionId, ptyEpoch}`. Its response is the closed object
`{schemaVersion:1, state, storeAuthorityId, orgId, sessionId, ptyEpoch}`, where
state is exactly `retired`, `live` or `unavailable`. Only `retired` adds the
required `retirementRecord`, containing the complete existing canonical record
and its floor, high-water and evidenceDigest. `live` and `unavailable` forbid
that member. No envelope-level floor/high-water aliases are allowed. Validate
record digest/scope/profile eligibility and compare response scope against the
exact request. The service also checks its actual current store authority under
the journal lock; wrong-store/auth is a typed refusal, never a successful stale
echo. Inspection remains read-only and grants no recreation or allocation.

The shared companion `fixtures/retired-source-recovery-v1/INSPECTION-VECTORS.json`
(SHA256 `c035b6c1f7ee547dafd0efbb2d29239c5f3e4a3942cd12c6f6d537b0cc3aa9c4`) contains six positive envelopes
and twelve rejection transformations with record re-digest rules. These are
codec fixtures, not journal authority evidence. The capabilities profile and
endpoint select this profile; the inspection envelope adds no profile member.
Reconciliation success remains the closed `{receipt,proof}` envelope.

## Closed no-new-mutation refusal

The retired control profile uses HTTP409 with the closed object
`{code:"retired_source_conflict",rule}`. The complete rule enum is
`request_invalid`, `store_mismatch`, `retirement_missing`, `retirement_mismatch`,
`stream_live`, `replay_mismatch`, `successor_conflict`. It states only that this
attempt refused before new mutation. It says nothing about a prior same-ID
operation or the historical abandonment. Even a recognized refusal preserves
the immutable operation/source/epoch and grants no remint, retirement or cleanup
authority. Unknown rule, malformed409 or another status remains held ambiguous.
Unsupported profile, quota, corrupt/incomplete protected state or any failure
after durable CAS uses503/held; those cases must never be mapped into this409.

`fixtures/retired-source-recovery-v1/REFUSAL-VECTORS.json` freezes seven positive
and six negative response cases; SHA256
`0f18c41ea520b7fa32001e943773aed53a1ad579b87227b54eeae3b5fbba35f1`. HTTP body limits and closed/duplicate-key
checks apply before recognizing any refusal.
