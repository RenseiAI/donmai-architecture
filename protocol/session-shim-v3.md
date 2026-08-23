---
title: session-shim selected v3 — exact full host-frame observation
status: Proposed
date: 2026-08-23
revision: v3.0-draft3
protocol-family: session-shim-v1
selected-version: 3
boundary: OSS-only
normative-for: donmai session shim, daemon controller, composing durable carriers
---

# session-shim selected v3 — exact full host-frame observation

**Status:** Proposed; normative successor contract, implementation/release/
activation pending.
**Owning ADR:**
[`../ADR-2026-08-17-session-shim-adoption.md`](../ADR-2026-08-17-session-shim-adoption.md)
§D3/D14.
**Protocol family:** `session-shim-v1` (unchanged).
**Selected version:** `3`.

Draft 2 adds the incarnation-bound externally acknowledged cursor sidecar and
the proof-resolved adoption cursor override. It does not change message type
`0x0F`, selected-v1/v2 bytes, or the one-event mapping.

Draft 3 binds pre-consume recovery after an admitted preparing/receipt-stored
candidate is durably abandoned, plus post-consume recovery of the original
candidate. It changes no shimwire byte. Proof v2 preserves existing high-water as
the next carrier boundary, carries exact abandonment lineage and an all-time
carrier-epoch floor, and requires the replacement candidate to allocate its new
Snapshot after that boundary. Consumed-adoption recovery instead resumes at H+1
with no duplicate H. Exact same-handoff replay remains unchanged.

This is a selected-version delta for the local daemon↔shim wire. It does not
rename the protocol family and does not amend selected v1 or selected v2.
Selected v3 retains every v1/v2 message type and meaning, except for the
explicit selected-v3 live-`SnapshotResult` disposition below, and adds exactly
one shim-produced observation carrying a complete interactive-attach host frame.

The reason for v3 is structural. A PTY host sequence contains `Output`, applied
`Resize`, `Marker`, ordinary/live `Snapshot`, and `Exit`. Released selected v2
transports Output and Exit semantically, transports some Snapshots semantically
or through `SnapshotResult`, and deliberately drops applied Resize and Marker.
It cannot satisfy a downstream promise to durably retain the exact raw bytes of
**every** sequence-bearing host frame. Adding a type to selected v2 would mutate
the closed vocabulary spoken by live released shims, so it is forbidden.

## 1. Compatibility and selection

The daemon remains the highest-overlap selector:

| Shim range | Daemon range | Selected | Required behavior |
|---|---|---:|---|
| released `[1,2]` | new `[1,3]` | 2 | Adopt ownership and use the v2 snapshot proxy. Durable external carrier is visibly ineligible. No v3 message is sent. |
| new `[1,3]` | released `[1,2]` | 2 | New shim uses the exact released v2 behavior, including its old observation omissions. No v3 message is sent. |
| new `[1,3]` | new `[1,3]` | 3 | Full-host-frame observation is mandatory and external durable carrier may proceed. |
| disjoint | any | none | Existing version-mismatch quarantine. |

`ProtocolMin` remains 1. `ProtocolMax` becomes 3 only in an implementation that
passes the v3 conformance corpus. A max of 3 is not evidence by itself: an
external composition also requires the exact attested capability token
`full_host_frame_v3` and the actual selected version 3 for that shim.

Raising the minimum above 1 remains a separate migration decision after the
maximum supported live-session overlap. Rollback may put a new shim behind an
old daemon, selecting v2, but it may not claim durable external output while
that downgrade is in force.

## 2. Closed v3 vocabulary

Selected v3 retains the selected-v2 registry `0x01`–`0x0E` unchanged and assigns:

```text
0x0F HostFrame  shim -> daemon
```

`HostFrame` is illegal under selected v1 or v2. A selected-v3 shim sends exactly
one `HostFrame` for every sequence-bearing interactive-attach host frame and
does not additionally send legacy `Output`, `Snapshot`, or `Exit` observations
for that same frame. Applied Resize and Marker now cross this same one rail.

The retained legacy observation types remain decodable as part of the inherited
vocabulary, but a selected-v3 shim using one as an alternate delivery of a
sequence-bearing host frame is a typed `duplicate_host_frame` protocol error.
There is one authoritative event source in v3: `HostFrame`.

## 3. Exact `HostFrame` body

The body is binary and length-delimited by the existing shimwire envelope:

```text
[request_id:u64 big-endian][frame_bytes:remainder]
```

- `frame_bytes` is the complete, exact output of the interactive-attach frame
  encoder: type byte, canonical varint sequence, canonical varint relative time,
  and payload bytes. It is never JSON/base64, decoded-and-reencoded, Unicode,
  newline-normalized, or sanitized.
- The decoded attach frame type is exactly one of `Output`, applied `Resize`,
  `Marker`, `Snapshot`, or `Exit`.
- The decoded attach header sequence is positive. Sequence-zero post-Exit final
  Snapshot is not a `HostFrame` and never advances the durable high-water.
- `request_id` is zero for every ordinary/replayed frame. It is the non-zero
  connection-local `SnapshotRequest.request_id` only for the one live Snapshot
  emitted by that request.
- A non-zero request id on a non-Snapshot, a zero request id on a live requested
  Snapshot pair, trailing/undecodable frame bytes, an illegal type, sequence
  zero, or a body that exceeds the existing shimwire message bound is a typed
  refusal. The PTY host must enforce a frame-size ceiling that leaves room for
  the eight-byte v3 header; an unrepresentable frame makes durable external
  carrier admission unavailable rather than truncating bytes.

The daemon validates metadata for routing and terminal handling but retains and
hands downstream the original `frame_bytes`. The decoded view never replaces
the byte authority.

## 4. One event, one delivery

The shim subscription walks the PTY host sequence once and applies this mapping:

| Attach host frame | Selected-v3 local observation |
|---|---|
| `Output` | one `HostFrame(request_id=0, exact frame)` |
| applied `Resize` | one `HostFrame(request_id=0, exact frame)` |
| `Marker` | one `HostFrame(request_id=0, exact frame)` |
| ordinary or replay Snapshot | one `HostFrame(request_id=0, exact frame)` |
| live `SnapshotEmit` frame | one `HostFrame(request_id=request id, exact frame)` plus the correlation-only result in §5 |
| `Exit` | one `HostFrame(request_id=0, exact frame)` |

The daemon controller exposes one raw host-frame event per host sequence. It may
attach a validated type-specific view (for example Exit code/signal) to that
same event so existing lifecycle logic can act, but it must not invoke a second
legacy event/durable callback for the same sequence. Downstream dedupe identity
remains `(org_id, session_id, PTY-host epoch, host sequence)` and exact replay
compares the original frame bytes.

## 5. `SnapshotRequest` / `SnapshotResult` interaction

Selected v2 behavior remains exactly as released. Selected v3 changes only the
live emitting result so the complete frame bytes do not cross twice.

### 5.1 Inspect

`mode=inspect` is unchanged from v2: `SnapshotResult` has `in_stream=false`,
the exact encoded screen bytes, and the exact `at_seq`. It allocates no host
sequence and emits no `HostFrame`.

### 5.2 Live emit before Exit

The shim-owned PTY host allocates and publishes one sequence-bearing Snapshot.
Selected v3 sends, under one shim→daemon write serialization with nothing
interleaved:

1. `HostFrame(request_id=R, frame_bytes=F)` in host-sequence order;
2. `SnapshotResult(request_id=R, mode=emit, at_seq=F.seq-1,
   in_stream=true, bytes=empty)`.

The result is correlation-only. Non-empty `SnapshotResult.bytes` in this v3
live-emitting disposition is `duplicate_host_frame`. The controller buffers the
first item, requires the adjacent result to match request id/generation/mode and
the decoded frame sequence/`at_seq`, then:

- completes the request once;
- publishes the buffered raw host-frame event once;
- never synthesizes a second event from `SnapshotResult`.

The request-return path exposes only the correlation/disposition; it does not
separately hand frame bytes to the composing carrier. The one correlated
HostFrame event is the sole byte delivery and is what the adoption-time staging
path journals/receipts. A local convenience API may point at that already-owned
event, but it may not copy it into a second durable callback or network send.

If the pair is incomplete or changed, neither event nor shim acknowledgement is
published. A later controller replays the already-real host frame from the shim
ring as ordinary `HostFrame(request_id=0)`; it does not revive the old
connection-local request id. An exact same-connection request retry returns the
first immutable correlation result and emits no second HostFrame.

### 5.3 Emit after Exit

The post-Exit final Snapshot is unchanged from v2: `in_stream=false`, header
sequence and relative time are zero, `at_seq == Exit.seq`, and the complete
encoded final Snapshot bytes ride `SnapshotResult` directly. It emits no
`HostFrame`, does not enter the ordinary host-frame journal, and does not move
`host_ack` or the shim heartbeat cursor.

## 6. Gap and replay ordering

On a ring hit, `HostFrame` observations are contiguous and in host-sequence
order.

On a ring miss selected v3 emits this order after `Adopted`:

```text
Gap(from_seq, to_seq, reason)
HostFrame(request_id=0, exact sequence-bearing recovery Snapshot)
HostFrame(request_id=0, next frame)
...
```

It does not also emit legacy `Snapshot`. The daemon must deliver the Gap before
the raw recovery Snapshot, enabling attach-v2 to durably store `host_gap` plus
the following exact Snapshot as one recovery transition. The acknowledgement
may advance across that range only after both durable dispositions commit.

`ahead_of_stream` remains a disagreement, not permission to fabricate a
snapshot or rewind the shim sequence.

## 7. Exit and terminal posture

The in-stream `Exit` frame is one positive-sequence `HostFrame`. The controller
derives the immutable terminal observation and process-reap workflow from that
same event while preserving its exact raw bytes for downstream durability. It
does not also require or accept a legacy `Exit` observation for the sequence.

Flush-before-Exit and “Exit is final sequence-bearing frame” remain inherited
from interactive attach. The only later Snapshot is the sequence-zero direct
result in §5.3. A sequence-bearing HostFrame after Exit is a protocol error.

## 8. Durable acknowledgement sidecar and resolved resume

After a selected-v3 controller has received an external carrier's exact durable
acknowledgement, it sends the covered sequence in the existing generation-
fenced shimwire Heartbeat. The shim validates that the cursor is positive,
non-regressing, no later than its emitted stream, and from its current controller
generation. Before replying, it atomically persists a strict bounded JSON body
to an exact mode-`0600` `.ack` sidecar under the exact mode-`0700` registry
directory with file and parent-directory fsync:

```text
schema_version
org_id, session_id
shim_id, process_epoch
controller_generation
acked_seq
```

The sidecar filename is a fixed digest of lifecycle/shim/process correlation
with suffix `.ack`. Released registry scanners enumerate only their frozen
`.json` discovery records and ignore it. The body contains no controller id,
stable host id, bearer, jti, raw frame, frame digest, terminal bytes, or prompt.
Identity mismatch, stale generation, regression, ahead-of-stream, malformed
body, mode/ownership failure, or ambiguous fsync refuses the Heartbeat and
leaves the prior sidecar unchanged.

Selected-v3 cold adoption additionally requires sidecar
`controller_generation <= Hello.Generation` and `acked_seq <= Hello.LastSeq`.
Selected v2 ignores the `.ack` file entirely, including corrupt contents. On
cold v3 adoption, `acked_seq + 1` is `LocalResumeFrom` (absence normalizes to
start sequence 1; max uint64 refuses). After authenticated `Hello`,
`AdoptionPreparation` exposes exact `LocalResumeFrom uint64` and
`LastHostSeq uint64`. The composing prepare hook receives both.
`PreparedAdoption` adds optional
`ResumeFrom *uint64`: nil uses the local floor; non-nil may equal or raise it
and becomes exact `Welcome.resume_from`; a lower value refuses rather than
silently clamping. For an external durable carrier, the value must come from the
control-authenticated proof reservation in the owning ADR D15. A daemon cache,
prior composing adoption cursor, or raw sidecar assertion cannot substitute.
The free-standing resume callback and proof-resolving prepare hook cannot both
be configured. Proof-bound external preparation requires non-nil ResumeFrom.
The shim also holds its in-memory ack floor and independently refuses Welcome
below it.

Adding `ResumeFrom` to the public struct is an explicit pre-release exception
for unkeyed external composite literals; keyed literals and zero behavior remain
compatible, and the migration gate compiles/converts known consumers before
capability advertisement.

This sidecar closes the current-frame crash ambiguity but does not become a
second output/journal authority. The external carrier proof may be ahead of the
sidecar and raise the cursor; it may never be behind. Sending selected-v3 Hello
establishes a bounded output barrier at `LastHostSeq=K` for proof-bound adoption:
no positive host sequence is allocated before the mandatory Snapshot. Timeout/
buffer exhaustion aborts the prepare and releases the barrier without inventing
output.

Let carrier proof boundary/high-water be N. K&lt;N or K+1 overflow refuses. K=N
sets ResumeFrom N+1 and emits only Snapshot N+1/atSeq N. K&gt;N sets ResumeFrom
K+1 and the external host client uses additive
`DeclareHostGapWithReason(N+1,K,"controller_unforwarded")` immediately before
Snapshot K+1/atSeq K. The existing `DeclareHostGap` remains the
source-compatible `ring_evicted` default. Pre-active ordinary replay remains
forbidden.

If a changed controller abandons a retained `receipt_stored` candidate, or an
admitted `preparing` candidate is abandoned before reprepare, existing carrier
high-water H is preserved, including zero. A receipt-stored source also preserves
its abandoned Snapshot as unacknowledged/non-publishable; a preparing source has
none. The replacement proof-v2 boundary is H. A new Hello-frozen K must satisfy K>=H: K=H emits only Snapshot
H+1/atSeq H; K>H emits `controller_unforwarded` Gap H+1..K then Snapshot
K+1/atSeq K; K<H or K=max refuses. The shim does not reuse the abandoned
Snapshot as the new mandatory response. Under the same controller and exact
handoff, retained replay uses the original Gap/Snapshot and emits no new request.

If proof/receipt adoption already consumed before controller loss, the exact
retained staged Snapshot sequence H is authoritative. Server-resolved adopted-
candidate recovery sets `PreparedAdoption.ResumeFrom=H+1`; the shim does not
replay H, and later frames remain locally staged until the original carrier C
activates and acknowledges H. No new proof/Snapshot/cursor is allocated. H=max
uint64 refuses consume/recovery because the successor cursor is unrepresentable.

## 9. Capability and visible incompatibility

Selected local version 3 plus `full_host_frame_v3` is a hard prerequisite for
attach-v2 durable activation. Proof-bound hosted/external activation also
requires the exact lexically sorted attestation token
`durable_carrier_proof_v2`; max 3 with the earlier four tokens remains
ineligible. The daemon may still adopt a selected-v2 shim for
ownership conservation and authoritative snapshot inspect/emit, but it reports
the external carrier outcome as
`durable_host_frame_unsupported`, charges the live shim to capacity, and sends
no attach-v2 credential/activation.

Selected v1 retains the existing `authoritative_snapshot_unsupported` outcome.
Neither reason kills the shim, releases a claim, fabricates Marker/Resize, or
substitutes semantic reconstruction for exact bytes.

## 10. Failure/crash matrix

| Failure | Required result |
|---|---|
| New daemon adopts released v2 shim | Ownership and snapshot proxy remain available; external durable carrier is visibly ineligible and capacity remains charged. |
| Released daemon adopts new v3 shim | Highest overlap selects v2; shim emits no HostFrame and behaves exactly like the released implementation. |
| HostFrame and live SnapshotResult disagree | Close/refuse the controller; publish neither duplicate nor partial event and advance no acknowledgement. |
| HostFrame arrives and connection dies before its paired result | Buffer is discarded; new adoption replays the real frame with request id zero. |
| Result exact retry follows completed pair | Return the immutable result; emit no second HostFrame/event. |
| Gap persists but recovery Snapshot does not | Durable cursor stays before the gap; no host ack advances. |
| Exit HostFrame persists but terminal callback fails | Exact frame remains replayable; lifecycle release remains held until existing terminal proof commits. |
| Sequence-zero final Snapshot is presented as HostFrame | Typed protocol refusal; high-water unchanged. |
| Heartbeat ack sidecar fsync is blocked/ambiguous | Do not confirm the Heartbeat; replacement adoption retains the prior floor and exact frame replay remains possible. |
| External proof boundary successor is below `LocalResumeFrom` | Refuse preparation before Welcome; do not regress or replay ordinary candidate frames. |
| External proof boundary N is at or ahead of the sidecar ack and Hello K=N | `PreparedAdoption.ResumeFrom` raises exactly to N+1; the proof, not the daemon, is authority. |
| Hello LastHostSeq K exceeds proof boundary N | Hold K; set ResumeFrom K+1; send `controller_unforwarded` Gap N+1..K then Snapshot K+1/atSeq K. |
| Hello LastHostSeq is below proof boundary or max uint64 | Refuse before Welcome; release the output barrier with no candidate/gap/Snapshot. |
| Max-3 attestation omits `durable_carrier_proof_v2`, advertises v1 instead, or advertises both | Preserve v3 ownership/full-frame observation but withhold proof-bound attach-v2 credential/candidate/activation. Frozen v1 remains decode/replay/drain only. |
| Receipt-stored or admitted-preparing candidate is durably abandoned at high-water H | Preserve H/floor and any staged bytes, clear active/pending without rebind, and accept only proof-v2 boundary H plus a successor above the floor. K=H emits Snapshot H+1, K>H emits Gap H+1..K plus Snapshot K+1, and K<H refuses. |
| Controller changes after adoption consume but before activation | Server-resolved recovery uses original candidate C and exact ResumeFrom H+1. Shim emits no H duplicate; H+1 onward stays locally staged until same-token Relay reconnect and activation acknowledge H. |

## 11. Migration and rollback

1. Publish v3 codec/types, ACK sidecar, proof-resolved prepared cursor, and the
   full-host-frame controller event dormant;
   keep protocol max 2 until the v3 RED/GREEN corpus is present.
2. Release a max-3 shim first. Released max-2 daemons select v2, so no old
   consumer sees the new message.
3. Release a max-3 daemon/client that treats selected v2 as conservation-only
   and selected v3 as the external-durability prerequisite.
4. Update composing attestation to the exact lexical five-token set including
   `durable_carrier_proof_v2` instead of v1, then relay/client installed-artifact
   gates. Retain frozen v1 decode/exact same-handoff replay/drain, but never
   advertise both proof tokens or use v1 for new admission. Keep activation
   disabled; max 3/four tokens remains ineligible.
5. Enable external durable carrier only after real v3 full-frame/gap/snapshot/
   terminal proofs pass.

Rollback disables new external carrier activation first. A max-3 shim may run
under a max-2 daemon by selecting v2, but that host is carrier-ineligible.
Existing v3 journals, acknowledgements, proof-v1/v2 and abandonment lineage,
carrier-epoch floors, fence/adoption evidence, and terminal proof remain readable
until every referenced session drains. Rollback never
rewrites a v3 frame as a legacy semantic event or lowers a live controller/
carrier generation.

## 12. Conformance and V16 proof obligations

- [ ] The released max-2 shim and new max-3 daemon select 2; removing the
      selected-v2 carrier-ineligibility gate is RED.
- [ ] The new max-3 shim and released max-2 daemon select 2 and emit byte-exact
      released-v2 traffic; sending 0x0F is RED.
- [ ] Selected v3 emits exactly one HostFrame for Output, applied Resize,
      Marker, ordinary Snapshot, requested live Snapshot, and Exit, preserving
      every byte and split boundary. Deleting any case or restoring the released
      Marker/Resize drop is RED.
- [ ] Selected v3 emits no legacy Output/Snapshot/Exit duplicate for the same
      sequence. Enabling either rail makes the count/dedupe fixture RED.
- [ ] Live SnapshotEmit carries the raw frame once in HostFrame and an empty,
      adjacent correlation result. Restoring v2 result bytes, emitting a result-
      derived event, changing order/correlation, or retrying a second frame is
      RED.
- [ ] Inspect and post-Exit direct SnapshotResult retain the released v2 bytes;
      neither produces HostFrame or advances high-water.
- [ ] Gap precedes the exact raw recovery Snapshot and legacy Snapshot is absent;
      reversing/omitting/duplicating either disposition is RED.
- [ ] Exit uses the one raw event for both durable bytes and terminal semantics;
      a post-Exit sequence-bearing HostFrame and a sequence-zero HostFrame are
      RED.
- [ ] Registration/refresh/heartbeat require the max-3 exact lexical five-token
      attestation including `durable_carrier_proof_v2` instead of v1 and
      `full_host_frame_v3`. Per-shim external prepare additionally requires
      actual selected v3. Max 3 alone, the earlier four-token set, v1 alone, and
      both proof tokens refuse hosted auth; selected 2 remains conserved but
      carrier-ineligible. V1 decode/exact retained replay/drain still works only
      for a live untombstoned store-bound cutover-manifest entry.
- [ ] For every durable host acknowledgement, block/fail the real `.ack` file
      write/fsync and prove the Heartbeat does not confirm. Restore and prove a
      cold adoption loads the exact lifecycle/shim/process/generation cursor.
      Wrong exact file/directory mode, generation beyond Hello, and ack beyond
      Hello LastSeq are RED. Released selected-v2 registry scanning must ignore
      even a corrupt sidecar.
- [ ] With sidecar ack/proof boundary N and Hello LastHostSeq K, exact
      `PreparedAdoption.ResumeFrom` is K+1. K=N yields no gap; K>N yields
      `controller_unforwarded` Gap N+1..K then Snapshot K+1/atSeq K; K<N,
      output-barrier drift/overflow, a lower override, simultaneous free resume
      callback/proof prepare, daemon/prior-adoption inference, or silent clamp
      is RED. No ordinary frame crosses a pre-active carrier, and the shim
      independently refuses Welcome below its in-memory floor.
- [ ] With immutable installed binaries, stage a first receipt-stored candidate
      at active zero/high-water H, change controller, and cross the real durable
      abandonment/proof-v2 path. The old Snapshot remains non-publishable and the
      successor boundary is H: K=H emits only Snapshot H+1, K>H emits Gap H+1..K
      then Snapshot K+1, and K<H/overflow refuses. Disabling abandonment, floor,
      predecessor, or high-water preservation is V16 RED; exact same-controller
      handoff replay remains one original Snapshot with no new request.
- [ ] Crash after adoption consume before activation. Exact recovery sets
      ResumeFrom H+1, emits no duplicate H, stages later frames until original C
      activates, and advances sidecar only after ack H. Replaying H, allocating a
      new proof/Snapshot, or accepting H=max is RED.
- [ ] With active A and H&gt;0, admit C and kill it in preparing before Snapshot
      receipt. Exact abandonment carries preparing with null receipt evidence,
      preserves H/floor, clears A/C without rebind, and accepts only a higher
      successor. Repeat H=0. Treating it as a socket-only fence, inventing a
      Snapshot/receipt, or relabeling zero-H abandoned as empty is RED.
- [ ] Tokens, jtis, prompts, raw frame bytes, and frame digests never enter
      logs, errors, discovery records, heartbeat diagnostics, or quarantine
      display detail.
- [ ] Installed compatibility uses immutable released artifacts and exercises
      both overlap directions. A same-source fixture or mutable checkout cannot
      satisfy it.

Every claimed coverage item follows Agent Operating Protocol V16: disable the
named production seam, observe the discriminating fixture RED for the intended
reason, restore it, and observe GREEN. A copied encoder, hand-authored frame, or
argument-discarding fake is not evidence.
