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
fixtures, not current no-stream or historical-admission evidence.

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
The carrier verifies source epoch<=F; the composing authority verifies its
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
The context is exact; it is not a caller-selectable alternative authority.

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
