---
status: Proposed
date: 2026-09-11
boundary: shared
split: sibling-extensions
---

# ADR-2026-09-11 — Complete retired-source disposal and retry

**Status:** Proposed. This draft does not grant implementation, format upgrade,
release or live-operation authority. The accepted v1 contract remains unchanged
until this amendment and its companion are accepted together.

## Context

The [retired-source reconciliation ADR](ADR-2026-09-11-retired-carrier-source-reconciliation.md)
creates one designated proof3 root while preserving unavailable history and an
unknown original abandonment outcome. Complete recovery must also cover its
next preparation failure. An actually admitted candidate may be abandoned; a
reservation which never reached admission has no such fact. A second operation
cannot manufacture an abandonment identifier or replace the first operation's
immutable successor.

Existing token and Snapshot consumers also need complete ancestry validation.
A leaf whose scalar proof fields match can still refer to a corrupt or foreign
root receipt. This remains true when a disposed root is followed by an ordinary
proof2 and schema2 Snapshot receipt. Introducing a new Snapshot version for a
later branch does not make the earlier scalar-only path authoritative.

## Decision proposed

### A. Actual admitted disposal, then a fresh ordinary proof

Explicitly extend the schema1 abandonment admitted-proof selector to3, and to4
for roots introduced below. Every existing key, canonical digest, cause/state
pair, receipt-nullability rule and old1/2 byte stays unchanged. Under the actual
admission/activation lock, resolve the exact admitted, un-abandoned preparing or
receipt-stored candidate, its complete root proof/receipt, prepared correlation,
current floor/high-water and optional Snapshot receipt. A reservation without
actual admission is not an abandonment candidate. Activation or adoption consume
wins against disposal; post-consume ambiguity retains the exact candidate and
original credential.

Fsync the first exact abandonment request/result before fencing or returning
success. Exact retry returns those first bytes. The original root request,
receipt, proof, unavailable-prefix anchor and historical source operations remain
immutable. A terminal-lineage abandonment is terminal release evidence only; it
never grants a successor.

After an actual nonterminal abandonment, mint one NEW ordinary proof2 using the
exact unconsumed predecessor. Its root-operation link is null; it is not another
designated successor of the old reconciliation and is not a re-encoding of
proof3/4. Its genuine `abandoned` disposition names the immediate predecessor.
The new epoch exceeds the current all-time floor. A missing, foreign or reused
predecessor refuses, including at high-water zero. Preserve the root's unavailable
prefix in journal state; never add an anchor to the closed proof2 body. A real
fresh Snapshot and any required Gap follow the retained cursor maxima.

**Complete consumers are mandatory for A too.** Direct proof3 token minting and
schema2 Snapshot consumption validate the complete canonical root
request/receipt/proof and current correlation authority. Ordinary proof2
descendants additionally traverse every actual abandonment and consumed
predecessor edge to that root. A null immediate root link must not select a
scalar-only fast path or classify missing ancestry as unrelated traffic.
The full unresolved correlation union, current owner, handoff, nonce, JTI,
credential margin and no-consume predicates apply before signing, receipt
persistence or adoption. This also covers proof2 descendants of a proof4 root.
Unrelated ordinary sessions retain their ordinary contract.

### B. A typed reservation-only source after new actual retirement

A source with no genuine issued abandonment cannot populate v1's abandonment
ID/digest or candidate-state fields. Introduce profile
`retired_source_recovery_v2` with closed reconciliation request2/receipt2 and
retired reservation request4/proof4. The source is the exact designated root of
an already reconciled origin, whose canonical request, receipt and proof have
all been validated. A frozen request without its real result is insufficient.
The origin may be v1 or v2, allowing repeated recovery without changing versions
on every attempt.

The closed request2 source contains:

- `kind:reservation_only`;
- reservation request ID/digest and reserved carrier epoch;
- origin profile, reconciliation request ID, receipt digest and proof digest.

It contains no candidate-state or abandonment member. This names reservation
authority without claiming that admission or abandonment did or did not occur.
Known issued operations remain immutable in ancestry; no request is invented,
dropped or renamed to fit the new grammar. Receipt2 echoes the complete source
and states only `sourceAdmissionOutcome:unknown`; it has no
`priorAbandonmentOutcome` member.

The supported room/journal reclaimer must perform a NEW actual eligible Retire.
Only its current canonical retirement record and protected exact projection
witness authorize the next CAS. Elapsed time, absence, an inspection response
or a digest alone does not. A pending admitted candidate blocks retirement and
uses A or exact post-consume recovery instead.

Under one current-store/no-stream CAS lock, verify the complete applied origin,
its exact designated source reservation, the new retirement and witness, the
current floor and every retained/Hello cursor maximum. Require one unused source
and one distinct successor. Persist exact first request2/receipt2/proof4 using
prepared/applied recovery before success. Old and new operations remain
independently replayable; neither authorizes recreation after ambiguous applied
projection loss. A late successful admission or writer races at this boundary
and excludes retirement/CAS.

### Versions and truthful proof anchors

The [frozen proposed vectors](fixtures/retired-source-recovery-v2/README.md)
specify every closed object and digest. Request2 includes the complete child
request4; the child references only the new operation ID. Receipt2 binds both
request digests; proof4 binds receipt2. No digest cycle is introduced.

All five proof4 anchor fields refer to the IMMEDIATE operation:

| Field | Meaning |
|---|---|
| reconciliationRequestId | this new request2's immutable operation |
| reconciliationReceiptDigest | this new receipt2, independently digested |
| retirementEvidenceDigest | the NEW actual retirement of its source projection |
| retiredCarrierEpochFloor | that retirement's floor, not ancestor floor or owner generation |
| retiredHighWater | that retirement's high-water, never inferred empty history |

Origin facts remain in request2/receipt2 source objects and are transitively bound
by the receipt digest. No anchor field borrows an origin value. Proof4 retains
the retired logical shape with active/pending zero, boundary/high-water H,
floor C greater than current F, null predecessor, and the immediate anchor.
Ordinary reserve refuses request4; only the combined new CAS creates this root.
Known source tail S420 cannot regress to416 merely because retirement H is416.

Proof4 is an explicit negotiation fence. An old leaf proof3 decoder can accept
the same logical fields if their selector and digest are replaced; that does not
prove full source-profile support. Signed host claims therefore require
`proof_schema_version:"4"`, `retired_source_profile:"retired_source_recovery_v2"`
and `snapshot_receipt_schema_version:"3"`, plus the complete immediate anchor
and ordinary identity/handoff/credential fields. No relabelling or downgrade is
permitted. Unsigned fixture projections are not credentials.

Snapshot receipt3 retains the schema2 fields and adds only
`proofSchemaVersion:"4"` and `retiredSourceProfile:"retired_source_recovery_v2"`.
Its transactional consumer validates the full root/origin/request2/receipt2/
proof4/family and actual nonce/JTI/cursor/frame bindings. The raw Snapshot frame
format is unchanged. A's direct proof3 and ordinary proof2 descendants still use
schema2 Snapshot receipts with the complete-chain validation required above.
Storage versions, retirement-record3, proof4 and Snapshot3 are separate
namespaces.

### Admit the complete client lifecycle before the first v1 root

Select client bundle `retired_source_lifecycle_v2` BEFORE the first v1 retired
root CAS, new continuation grant, successor reservation or credential mint.
Its minimum is actual proof2/3/4 and Snapshot2/3 support, A3/A4 disposal and retry,
B repeated-origin recovery, complete A token/Snapshot2 ancestry consumers, and
healthy finite room/journal reclaimer progress. The carrier must support both
retired-source profiles. A v1-only client cannot enter a workflow that later
requires proof4.

The client inventory's `supportedRecoveryProfiles` and a preparation selection
`retiredRecoveryProfile` are exact inputs, intersected with authenticated current
process inventory and actual selected shim capability. Omission is unsupported.
These values are derived from implemented/tested consumers, not caller flags.
Freeze the selected bundle in current family/admission/correlation evidence
before I/O and preserve it across A/B descendants. Bind the admission record
to the exact handoff and existing prepared-correlation digest; do not rehash or
change a previously frozen correlation to attach capability claims. Historical operations stay
readable/replayable; missing old capability fields never become fabricated
historical support. New admission requires new truthful current evidence.

Selected local v3/v4 and `full_host_frame_v3` remain necessary but not sufficient.
Unchanged local wire is acceptable only after an actual retained/current
consumer-tuple test proves the entire bundle. Otherwise a separately reviewed
local bridge precedes advertisement. No version number or source inspection can
replace that test. Every enabled standalone composition must ship working
inventory, selection and carrier consumers; an interface-only adapter is not
profile support. Hosted implementations are alternate compositions.

### Refused attempts must not starve normal retirement

A room may exist even when candidate admission never succeeded. Repeated stale
attempts must not bind a host transport, create durable pending admission,
advance hostless clocks, or replace/recreate a reaped room indefinitely.
For the held source, preserve ended-room authority or refuse stale recreation
until normal Retire/CAS resolves. Viewer reconnect cannot make the same held
source perpetually new. A genuinely eligible admission may win; it then blocks
B and uses A or exact recovery. No forced retirement, shortened grace or
unconditional process cleanup is introduced.

Readiness requires finite hostless-room and carrier-idle retirement bounds and
running normal reaper ticks. Tests use the actual admission API, room reaper and
file journal with fake time only. Continue refused requests across room reaping
and journal reclaim ticks; observe real Retire plus the new witness before CAS.
Room-reaped events are transport facts, not adoption or terminal-release proof.
Disabling clock/recreation guards must fail the liveness control; replacing
actual Retire with timer/inspection inference must fail the authority control.

### Protected storage and old-reader refusal

Keep marker schema4 with a distinct storage-profile value. The old strict
marker4 reader rejects an unknown profile; the old ledger reader rejects
schema2/profilev2. A marker5 is not required merely by naming convention.
The new ledger envelope reads tagged old/new operations while preserving all
old canonical request/result bytes.

Under the exclusive supported upgrade path, validate old history and floor,
fsync marker4/profilev2 before new records, then atomically persist the new ledger
before readiness. New startup recognizes marker-v2 with a valid old ledger as
an interrupted upgrade and completes it before Ready. Marker-v1/new ledger,
missing/corrupt history or a lowered floor refuses. Never infer an empty ledger.
Test each real process-crash/fsync boundary, mixed-history replay and rollback.

## Required controls and implementation units

The byte-identical proposed attachments contain9 positive wire scenarios,
71 materialized negatives,12 first-root refusal scenarios and five room-liveness
literal controls. Rehash semantic mutants before testing actual boundaries.
The unsafe-A controls leave immediate token/Snapshot scalars valid while
changing the canonical root receipt; removing full ancestry validation must make
the real consumer accept and the control fail. A separate old-correlation-loss
case exercises the same path. Fixture integrity is not runtime acceptance.

Implementation is split into: admitted disposal/predecessor handling; typed
reservation-only codec/storage/CAS; composing-authority family/selection and
full-chain consumers; carrier control/auth/admission; token/Snapshot versions;
actual daemon/shim negotiation; and integrated room/journal liveness and
adoption/terminal controls. Sequence overlapping store or protocol files.
Every unit needs exact old/new reader controls and literal unsafe mutations,
then an integrated actual-consumer check before any profile is advertised.

## Consequences and alternatives

This adds a typed source family and explicit compatibility obligations, including
validation on older leaf formats. It avoids inventing abandonment or treating a
matching leaf digest as complete authority. Reusing v1's absent fields, silently
relabeling proof4, trusting scalar-only Snapshot2, or relying on perpetual stale
retries would preserve the original stranding failure and is rejected.

## Affected documents

On acceptance, amend the retired-source ADR, session-shim adoption ADR and
`protocol/interactive-attach-v2.md` selector/credential/Snapshot sections in the
same paired change. Local capability consequences belong in
`protocol/session-shim-v3.md`. This draft adds proposal cross-references only;
it does not silently change accepted synchronized rules.
