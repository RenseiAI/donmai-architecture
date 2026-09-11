---
status: Accepted
date: 2026-09-11
boundary: shared
split: sibling-extensions
---

# ADR-2026-09-11 — Retired carrier source reconciliation

**Status:** Accepted architecture; implementation, storage migration, release and
consumer acceptance remain gated below.
**Boundary:** the current-authority CAS, retired-history anchor, proof profile and
consumer laws are shared. Hosted policy, persistence and control routes belong
in the companion extension.

## Context

A live shim can outlast a carrier stream retired for inactivity. Its composing
authority may retain a pre-consume proof reservation and an immutable abandonment
request whose historical outcome is unknown. A missing stream prevents the
carrier from looking up that reservation or its first abandonment result.

A typed missing-stream refusal establishes no mutation by that call. It does
not establish that a reservation was never admitted. Retirement metadata records
position and floor, but not the missing reservation/admission/result history.
Its content digest is not a signature or a current authorization.

The accepted retirement contract derives only the all-time carrier-epoch floor
on ordinary stream recreation. It deliberately does not derive disposition or
high-water. That leaves no valid ordinary proof for a retained local floor above
one: an empty proof has high-water zero, whereas a live shim may require resume
from 417 after committed boundary 416. Lowering the local floor, calling that
state empty or abandoned, or inventing an abandonment result loses authority.

## Decision

Register `retired_source_recovery_v1`, a pre-consume-only profile which combines
current retirement reconciliation and one designated successor reservation.
[Proof schema 3](protocol/retired-carrier-proof-v3.md) names an explicit retired
history anchor. The profile is an additional, narrowly scoped exception to the
floor-only reconstruction rule; ordinary creation and proof 1/2 remain unchanged.
It can be implemented by a local durable journal without a hosted service.

### Current authority and one successor

An authenticated recovery owner first obtains a trusted inspection of the
current journal authority. The inspection grants nothing. A separate effectful
operation freezes an exact request naming store/stream/PTY, the validated
retirement digest/floor F/high-water H, original source request bindings and one
designated successor request. The latter chooses C above F and any independently
retained allocation floor. Controller generation G is independent of C.

At the same journal lock and durable commit boundary, require:

- current store authority and supported, ready profile;
- an exact understood retirement record with known positive floor, reason
  `carrier_idle` and terminal sequence zero;
- no current stream or candidate/reservation projection for that stream;
- source epoch at or below F and exact designated request bindings;
- authenticated local tail S at least H, H+1 at least local floor L, positive L,
  and representable next sequence and candidate epoch.

The composing authority additionally checks its retained source and correlation
cursor maxima. Missing/legacy/corrupt retirement state refuses. A late ordinary
recreation, reserve, append or admission races at this same boundary: it and the
retired CAS cannot both win. No generic writer may bypass a committed retired
fence to revive an old epoch.

The successful `retired_source_reserved` receipt fixes one successor ID/digest/C
and records the prior abandonment outcome as `unknown`. It never asserts
non-admission, an old abandonment result, adoption, activation or terminality.
Exact operation ID/body replay returns first bytes, even after the designated
stream appears. Changed replay or another successor conflicts.

### Durable replay and storage versions

A mutex is insufficient. Retain exact request/receipt/proof bytes in protected
write-once state which survives retirement. Multi-file projection needs an
atomic commit or an explicit prepared/applied protocol. After a durable CAS,
ordinary recreation stays fenced until the exact recorded successor projection
is applied. Do not return success or admit a candidate from an incomplete
projection. Ambiguous failure is replay-only, never a new operation or epoch.

Before profile readiness, replay protected operations and verify their exact
projection. An unapplied new operation may finish its recorded projection; an
applied projection that disappeared without a proven later retirement is
unavailable/reconciliation, not permission to recreate. Never reconstruct the
old missing abandonment history. Quota exhaustion refuses rather than evicting
an unresolved outcome.

Storage format and proof versions are distinct namespaces. The existing
storage-authority `minimumWriterSchema="3"` is not proof schema 3. New anchor and
reconciliation records require an independently gated storage-reader/writer
version; an older reader must become non-Ready rather than ignore those records.
Readiness must cover every path which could create or mutate the affected stream.

### Retired history anchor

A fresh successful CAS may seed logical H and F with an explicit
retired-history-anchor record. It marks the prefix through H unavailable and
creates no Frame, Gap, Snapshot, Exit, receipt or adoption fact. This is the only
new permission to derive H from retirement evidence. A bare record/hash,
inspection, timestamp or ordinary stream recreation does not have that power.

Proof 3 has `disposition:retired`, active/pending zero, highWater and boundary H,
post-reservation floor C, and a mandatory content-addressed retirement anchor.
The proof binds the complete designated request and fresh reconciliation
receipt. Proof2's disposition enum remains frozen.

Replay of an unavailable prefix must report that loss rather than return an
empty successful history. Generic appends cannot skip sequence positions across
the anchor. The current shim supplies a real authoritative Snapshot at negotiated
tail S, with normal Gap handling for S>H, and a frame sequence above S. H416,
L417, S416 therefore uses a real Snapshot 417; no old bytes are synthesized.

### Ownership, adoption and release

A non-active reservation is not adoption. Preserve the ordinary fresh
Hello/Welcome/Adopted handshake, authoritative Snapshot receipt, per-session proof
consumption, complete adoption publication and explicit carrier activation.
Credential-validity gates apply before consume. Post-consume loss recovers the
same candidate and original credential; it cannot reserve a replacement.

The original request ID/bytes and historical source fields remain immutable.
A composing authority may record a distinct reconciled-retirement disposition
bound to the new receipt, without inventing the original operation's outcome.
No fence, quarantine or external claim resolves at this stage. Only real
adoption supplies adoption evidence, and only exact ordinary terminal evidence
can discharge terminal release obligations.

A retry involving existing held correlations needs independently fenced current
ownership. New grants must be append-only and carry the complete unresolved
correlation set. They cannot rewrite expired fences, drop an inconvenient
correlation or treat expiry as advancement. Hosted continuation mechanics are
specified separately.

## Compatibility and rollout

Proof 1/2 and ordinary operations retain exact bytes and behavior. Proof 3 and its
signed-claim selectors are explicit; never downgrade3 into2 or weaken strict
readers. Existing daemon prepare/local-v3 wire may remain unchanged only after
an actual retained daemon/shim consumer accepts the opaque credential and
completes the whole chain. Source inspection alone is not compatibility evidence.
If it refuses, require a separately reviewed version-negotiated bridge.

Implement readers, storage recovery and admission before advertising the
profile or enabling writers. Rollback to an unsupported reader refuses safely.
No source promotion precedes the paired normative amendment review. Local tests
and source approval do not establish released or live consumer acceptance.

## Required controls

- Actual journal CAS versus late recreation/reserve/append/admission; one winner.
- Process crashes before/after protected commit, stream fsync, applied marker and
  reply; exact first-result replay or unavailable state after real reopen.
- Changed ID/body/successor, wrong store/PTY/digest/F/H, unknown/legacy/corrupt or
  terminal retirement, quota and numeric overflow refuse without invented facts.
- Actual retained/current daemon and shim with H416/L417, independent F17/C18 and
  G2→3, S>H, unavailable prefix and real Snapshot/adoption/activation.
- Lost receipt or composing commit preserves one root successor; consumed
  recovery retains the same candidate. Unsupported intermediate drift stays held.
- All historical correlations survive until actual adoption and exact terminal
  evidence. No raw process kill, synthetic completion or time-based release.

The [frozen vectors](fixtures/retired-source-recovery-v1/WIRE-VECTORS.json) prove
codec/digest agreement only. Behavioral controls must construct real retirement
state through the journal, not insert the synthetic vector as authority.

## Consequences and alternatives

The profile can recover an unavailable retired pre-consume source while
preserving its cursor and uncertain historical outcome. It adds protected
metadata, a versioned proof reader, explicit crash recovery and compatibility
gates. Those costs are required to keep inspection separate from mutation.

Rejected alternatives: equating a missing stream with non-admission; rebuilding
an old result from metadata; lowering the shim floor; calling retained H empty or
abandoned; inspecting first and reserving later without a CAS; or discarding old
fences to retry. Each either invents authority or loses a race boundary.

## Affected documents

This amends the session-shim adoption ADR (2026-08-17), the carrier-floor
retirement ADR (2026-09-03), the attach-v2 protocol and local-daemon reference.
It does not accept the broader Proposed stateful-link recovery ADR.
