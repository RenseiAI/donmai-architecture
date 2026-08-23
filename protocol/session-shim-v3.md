---
title: session-shim selected v3 — exact full host-frame observation
status: Proposed
date: 2026-08-23
revision: v3.0-draft1
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

## 8. Capability and visible incompatibility

Selected local version 3 plus `full_host_frame_v3` is a hard prerequisite for
attach-v2 durable activation. The daemon may still adopt a selected-v2 shim for
ownership conservation and authoritative snapshot inspect/emit, but it reports
the external carrier outcome as
`durable_host_frame_unsupported`, charges the live shim to capacity, and sends
no attach-v2 credential/activation.

Selected v1 retains the existing `authoritative_snapshot_unsupported` outcome.
Neither reason kills the shim, releases a claim, fabricates Marker/Resize, or
substitutes semantic reconstruction for exact bytes.

## 9. Failure/crash matrix

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

## 10. Migration and rollback

1. Publish v3 codec/types and the full-host-frame controller event dormant;
   keep protocol max 2 until the v3 RED/GREEN corpus is present.
2. Release a max-3 shim first. Released max-2 daemons select v2, so no old
   consumer sees the new message.
3. Release a max-3 daemon/client that treats selected v2 as conservation-only
   and selected v3 as the external-durability prerequisite.
4. Update composing attestation to exact max/range/capability evidence, then
   relay/client installed-artifact gates. Keep activation disabled.
5. Enable external durable carrier only after real v3 full-frame/gap/snapshot/
   terminal proofs pass.

Rollback disables new external carrier activation first. A max-3 shim may run
under a max-2 daemon by selecting v2, but that host is carrier-ineligible.
Existing v3 journals, acknowledgements, fence/adoption evidence, and terminal
proof remain readable until every referenced session drains. Rollback never
rewrites a v3 frame as a legacy semantic event or lowers a live controller/
carrier generation.

## 11. Conformance and V16 proof obligations

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
- [ ] Registration/refresh/heartbeat and prepare routes require selected v3 plus
      exact `full_host_frame_v3`; max 3 alone and selected 2 remain refused.
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
