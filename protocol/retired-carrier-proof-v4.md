# Reservation-only retired carrier proof schema4

**Boundary:** shared; hosted transport/persistence bindings belong to the
complete-lifecycle architecture extension.

Normative companion to the [Accepted complete lifecycle ADR](../ADR-2026-09-11-retired-source-complete-lifecycle.md),
ratified2026-09-11. Implementation and profile readiness remain unimplemented/
false until the complete consumers and real controls pass. This adds no authority
to inspect, expiry, room events or a request whose result is not reconciled.

## Closed profile and encoding

Profile `retired_source_recovery_v2` selects reconciliation request2/receipt2,
retired reservation request4/proof4, token proof selector4 and Snapshot receipt3.
It does not rename WSS interactive-attach-v2 or local selected shim versions.
All objects are closed, duplicate/unknown/trailing members refuse, and digests
use RFC8785/SHA256 omitting only the object's own digest field. Epochs/cursors/
revisions are canonical uint64 strings; schema selectors are JSON integers;
bounded identifiers/digests retain their existing strict rules. Control bodies
have independent declared/actual32KiB bounds; Snapshot receipts retain4096bytes.

The exact [wire/control vectors](../fixtures/retired-source-recovery-v2/README.md)
are frozen in both corpora. Their synthetic state/digest fields are codec inputs,
not signatures, admission or retirement facts.

## Reconciliation request2

Required members:

```text
schemaVersion = 2
reconciliationRequestId, reconciliationRequestDigest
storeAuthorityId, orgId, sessionId, ptyEpoch
retirementEvidenceDigest
expectedRetiredCarrierEpochFloor, expectedRetiredHighWater
source = {
  kind = reservation_only
  reservationRequestId, reservationRequestDigest, reservedCarrierEpoch
  originProfile = retired_source_recovery_v1 | retired_source_recovery_v2
  originReconciliationRequestId
  originReconciliationReceiptDigest, originProofDigest
}
successorRequest = request4 below
```

No sourceCandidateState or sourceAbandonment field exists. Resolve the actual
origin as reconciled/applied with complete canonical request/receipt/proof; its
exact designated root must equal the source tuple. Preserve any known issued
operations independently. The current NEW actual Retire record and protected
origin projection witness must match the request's store/stream/PTY/digest/F/H.
A currently pending/admitted candidate or current live stream excludes this CAS. Origin
request_frozen, missing/corrupt result or witness remains unavailable.

## Designated reservation request4

The exact retired request3 logical members are retained with schemaVersion4:

```text
schemaVersion = 4
reservationRequestId, reservationRequestDigest
orgId, sessionId, ptyEpoch, localResumeFrom, lastHostSeq
expectedActiveCarrierEpoch = 0
expectedPendingCarrierEpoch = 0
expectedCarrierEpochFloor = current F
reservedCandidateCarrierEpoch = C > F
predecessorAbandonment = null
retirementContext = {
  reconciliationRequestId = immediate request2 ID
  retirementEvidenceDigest = NEW actual retirement digest
  retiredCarrierEpochFloor = current F
  retiredHighWater = current H
}
```

Require positive L, H+1>=L, S>=H and every retained origin/Hello/correlation
cursor maximum, S<maxuint64, and a distinct unused successor above the all-time
floor. An origin S420 cannot be replaced by416 when H remains416. Ordinary
reserve refuses request4; only the combined current-authority CAS creates it.

## Receipt2 and proof4

Receipt2 requires the exact common reconciliation identity/store/stream/PTY,
current retirement digest/F/H, complete source echo, designated successor
ID/digest/C, reconciliationRevision and receiptDigest. Its state is
`retired_source_reserved` and sourceAdmissionOutcome is `unknown`. There is no
priorAbandonmentOutcome field and no claim of non-admission or terminality.
The receipt binds request2 and child request4 digests; it is protected with the
first exact bytes before success and survives actual later retirement.

Proof4 retains the retired proof logical fields with schemaVersion4,
`disposition:retired`, active/pending0, boundary/highWaterH, post-reservation
floorC and null predecessor. Its retirementAnchor adds the independent
reconciliationReceiptDigest to the immediate retirementContext. Every anchor
field refers to the NEW operation/retirement; origin facts live in receipt2.source
and are transitively committed by its digest. ProofDigest covers that anchor.
No anchor value is borrowed from the origin and no digest cycle exists.

A new origin may itself be a reconciled v2 operation; source uniqueness prevents
branching. Exact old and new operation retries return their own first pairs.
Neither replays an ambiguously missing applied projection into existence.

## Consumers, negotiation and disposal

Before any first v1 retired root, authenticated current client selection must
prove the complete `retired_source_lifecycle_v2` bundle. Version4 tokens require
exact `proof_schema_version:"4"`, `retired_source_profile:"retired_source_recovery_v2"`
and `snapshot_receipt_schema_version:"3"`, plus the full immediate anchor and
ordinary signed identity/handoff fields. Snapshot3 retains schema2 fields and
adds `proofSchemaVersion:"4"` and `retiredSourceProfile:"retired_source_recovery_v2"`.
Validate the entire origin/family/request/receipt/proof and credential/frame
chain before mint, persistence, consume or activation.

An actually admitted4 root can use schema1 abandonment with true admitted
selector4 and all existing state/cause/receipt/consume rules. Its one genuine
nonterminal predecessor may produce a NEW ordinary2. Direct3 and fresh2 token/
Snapshot2 consumers remain complete-chain validators, not scalar-only aliases.
Root operations/anchors/correlations remain immutable; terminal causes grant no
successor and consumed candidates remain exact recovery.

The strict marker4 profile discriminator and ledger schema2/profilev2 fence old
readers; no marker5 is needed by convention. Mixed-history upgrade/replay,
actual admission/retirement XOR, first-root capability refusal, unsafe-A scalar
and never-admitted room progress controls must all pass before readiness.
