---
status: Accepted
date: 2026-09-03
boundary: shared
split: synchronized-mirror
---

# ADR-2026-09-03 — Carrier-epoch floor survives stream retirement

**Status:** Accepted
**Date:** 2026-09-03
**Boundary:** shared (the write-once retirement-evidence schema, the
per-lineage floor-watermark derivation, and the successor-admission rule are
OSS-canonical here; a composing control plane's memory-pressure tiering,
retirement triggers, and deploy/operations response are a platform extension)
**Authors:** session-continuity design lane

## Context

`ADR-2026-08-17-session-shim-adoption.md` D14/D15 defines the durable-carrier
proof journal: one append-only stream per `(store_authority_id, org_id,
session_id, pty_epoch)` lineage, holding that lineage's reservation,
disposition, and an all-time carrier-epoch floor that "is durable, monotonic,
... and exercised across fresh-process reload" (owning ADR, Consequences §
Risks). The floor exists precisely so a changed controller's successor
reservation can never reuse an epoch a prior candidate already burned, even
after the active/pending fields that named that candidate have cleared back
to zero on abandonment.

A journal that never forgot a lineage would grow without bound: every session
a daemon ever launched would hold journal memory forever. A real
implementation of this contract is therefore memory-bounded and reclaims
per-stream state under pressure — the OSS-canonical journal, because a
self-hosted deployment needs the same bound a hosted one does, and any
composing external carrier for the same reason. Retiring a stream is
sound in general: once a lineage is done, its reservation, disposition, and
staged bytes have no further reader.

The defect is what retirement did to the floor. A first implementation of the
memory bound retired a stream by deleting its state outright once a
retirability ground was met (a journaled `Exit`, in one observed instance),
with no separate durable record of anything the stream had held. Deleting the
stream deleted its carrier-epoch floor along with its reservation. Two things
then went wrong for a lineage that later needed a successor reservation:

1. A control plane that had correctly retained the lineage's carrier-epoch
   floor from before retirement presented it on the next reservation attempt
   (per D15.2, `expected_carrier_epoch_floor` in proof-request schema v2) —
   and the journal, holding nothing for that lineage any more, could not
   resolve the comparison and refused the reservation as stale. The lineage
   was wedged: correct on both sides, unable to proceed.
2. Absent a floor to compare against, a reservation attempt that fell back to
   treating the lineage as new allocated an epoch from zero — an epoch the
   retired stream's own last candidate may already have held. This directly
   violates the invariant the floor exists to enforce: "the all-time
   carrier-epoch floor never decreases" is not just monotonic non-decrease
   within a live stream's lifetime, it is a promise that survives the stream
   no longer being live.

Refusing to retire a stream that still holds unadmitted reservations was
considered and rejected: it reintroduces the unbounded-memory leak the
retirement mechanism exists to prevent, for no benefit — an unadmitted
reservation is not a candidate a retiring stream owes anything to (see
Decision below).

## Decision

The carrier-epoch floor survives stream retirement. The normative rule lands
directly inside `ADR-2026-08-17-session-shim-adoption.md`'s synchronized core
contract as *Amendment 2026-09-03 — carrier-epoch floor survives stream
retirement (rule 14)*, landed in the same commit as this ADR via paired PRs to
both corpora. Summarized:

- Before a stream is dropped, the journal persists **write-once retirement
  evidence** naming the retired stream and its last carrier-epoch floor.
  This is retirement-evidence **schema 3**; the schema-2 retirement evidence
  a first implementation already wrote named only the stream and a retirement
  cause, with no floor.
- The journal derives a **durable per-lineage floor watermark** from
  retirement evidence — at retirement time, and again by replaying every
  retained retirement record before v2 readiness on restart, exactly as
  every other durable proof-journal state is replayed.
- A **successor reservation for a retired lineage is admitted** under
  proof-request schema v2 when the caller's `expected_carrier_epoch_floor`
  equals that watermark, exactly as if the stream's live state had never
  been dropped.
- **No epoch at or below a retired floor is ever re-issued.** The watermark
  is exercised by the same comparison D15.2 already defines for a live
  stream's `carrier_epoch_floor`; retirement changes where the floor is read
  from, never the comparison itself.
- A **schema-2 retirement record decodes with an unknown floor**, treated as
  zero with a warning, never as corruption. It predates this amendment and
  names a stream whose true floor the journal can no longer prove — not a
  stream that never had one. Treating "unknown" as "corrupt" would refuse to
  start a journal that has ever retired anything before this amendment
  shipped; treating it silently as a known zero would understate a floor that
  may have been positive. A warning is the honest middle: proceed, but say so.
- The **retirement ledger remains write-once**, unaltered in every other
  respect the owning ADR already establishes for durable proof-journal
  ledgers. This amendment is the one documented case where the journal
  *derives state from* retirement evidence after writing it — previously,
  nothing in the journal ever read it back. Deriving the floor watermark from
  it does not make it mutable, and does not make it a second reservation
  authority: the watermark it produces is consulted only for the floor
  comparison, never for disposition, high-water, or any other field a live
  stream's proof carries.

**Clarification to the abandonment rule.** A reservation `Reserve` returns is
not itself a candidate — admission is what installs one. A reservation that
never reaches in-lock admission is therefore not an abandonment candidate and
needs no relay operation: the composing authority closes its own row through
the existing non-durable socket/generation fence, and a successor reservation
for the lineage proceeds directly. This was already true for a live stream
(the owning ADR's "Exact retained-candidate abandonment" section: "Only a
socket that dies before proof reservation/admission uses the non-durable
fence"); it holds identically whether the unadmitted reservation's stream is
still live or has since been retired, because retiring an unadmitted
reservation deletes nothing a release operation would otherwise have needed
to clear.

## Consequences

### Positive

- A lineage whose control plane correctly retained its carrier-epoch floor
  can always present it and be admitted, whether or not the journal has since
  retired the underlying stream. Retirement stops being observable as a
  correctness failure from outside the journal.
- The all-time-floor invariant — "never re-issue a burned epoch" — now holds
  across the journal's full lifetime, not just within one stream's
  in-memory residency. A journal that retires aggressively under memory
  pressure is exactly as safe as one that never retires anything.
- The fix is additive to the existing schema-versioning discipline D15.2
  already established for proof requests and proofs (schema 1 → schema 2):
  retirement evidence gets its own schema 2 → schema 3 step, decoded the same
  fail-honest way.

### Negative

- The journal now retains one small durable record (retirement evidence) per
  retired lineage indefinitely, rather than reclaiming it fully. This is
  bounded — one fixed-shape record per lineage ever retired, not per frame or
  per reservation attempt — but it is not zero, and a composing deployment's
  own retention policy for retirement evidence (if any) is out of this ADR's
  scope.
- A journal implementation that retires streams must now write retirement
  evidence synchronously with the retirement, rather than simply deleting
  state; a retirement path that drops state first and writes evidence after
  (or not at all) reintroduces exactly the defect this ADR fixes, silently.

### Risks

- **A composing control plane never retains its own floor and always asks
  the journal cold.** This amendment does not help a caller that discards
  what it knew; it only ensures the journal itself never forgets. A caller
  that never retained a floor still gets a correct answer, because the
  watermark is real journal state — it just could have gotten that same
  answer for free by not discarding what it already had.
- **Retirement evidence write and stream deletion are not one atomic
  operation.** A crash between them could retire a stream without a durable
  floor record, reintroducing the wedge for that one lineage. Implementations
  MUST write retirement evidence durably before or atomically with dropping
  the live stream state, never after.
- **The watermark index grows without its own bound.** Unlike the per-stream
  memory this ADR exists to reclaim, the derived watermark is intentionally
  retained forever per lineage. A composing deployment that needs to bound
  this too needs its own retention policy; this ADR does not define one.

## Alternatives considered

- **Refuse to retire a stream that still holds unadmitted reservations.**
  Rejected: this reintroduces the unbounded-memory leak the retirement
  mechanism exists to prevent, and for no correctness benefit — the
  Clarification above already establishes that an unadmitted reservation
  needs no release operation, so there is nothing retirement would be
  interrupting.
- **Reset the floor to zero (or to the reservation's own epoch) on
  retirement, and let the next reservation start fresh.** Rejected: this is
  the defect being fixed, restated as a policy. It directly reissues an
  epoch the retired stream's last candidate may have already held, violating
  the floor's non-decrease invariant.
- **Keep a separate, always-live floor index outside the retirement ledger,
  updated on every reservation rather than derived from retirement
  evidence.** Rejected: this duplicates state the journal already durably
  records (the reservation itself carries its own floor) and adds a second
  write path that can drift from the ledger it shadows. Deriving the
  watermark from write-once retirement evidence — which the journal already
  had to write to close out a stream — adds one field to an existing record
  instead of a new durable index with its own write discipline.
- **Treat a schema-2 retirement record (no floor) as corruption and refuse to
  start.** Rejected: every retirement ever written before this amendment
  shipped is schema 2. Refusing to start on that would make adoption of this
  amendment itself an outage. Treating the floor as unknown-and-warned is
  honest about what the journal can no longer prove without making the
  journal unusable.

## Affected documents

- `ADR-2026-08-17-session-shim-adoption.md` — the normative rule lands as
  *Amendment 2026-09-03 — carrier-epoch floor survives stream retirement
  (rule 14)*, **inside the `adr-2026-08-17-session-shim-core-contract`
  synchronized region**, shipped via paired PRs to both corpora per
  `BOUNDARY.md` § "Simultaneous-PR rule for synchronized sections";
  `scripts/check-boundary-sync.sh` passes before either PR merges. A short
  non-synchronized clarification also lands in the "Exact retained-candidate
  abandonment" section, restating that an unadmitted reservation needs no
  abandonment call and cross-referencing the amendment.

## Affected work items

None cited in this corpus — tracker issue references belong in the platform
mirror per `BOUNDARY.md`.

## Implementation notes

Architecture only; implementation, release, migration, and activation remain
pending, consistent with the owning ADR's overall D14/D15 status. When
implemented, the retirement-evidence schema, floor-watermark derivation, and
successor-admission check apply identically to the OSS-shipped self-hosted
journal and to any composing external carrier journal — D15.2's "an
OSS/self-hosted relay ships a working local-journal implementation" clause
covers this amendment the same way it covers everything else in D14/D15. A
composing control plane's choice of *when* to retire a stream (memory-pressure
tiers, idle windows, external-evidence attestation) is a platform extension
and out of scope here; this ADR fixes what retirement must preserve, not when
it fires.
