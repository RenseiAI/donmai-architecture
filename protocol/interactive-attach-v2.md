---
title: interactive-attach-v2 — durable carrier takeover activation
status: Proposed
date: 2026-08-23
revision: v2.0-draft1
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
  "protocol": "interactive-attach-v2",
  "orgId": "string",
  "iat": 0,
  "exp": 0,
  "aud": "relay",
  "jti": "UUID"
}
```

Unknown or duplicate members, trailing JSON, a user role/`userId`, missing or
negative PTY epoch, non-positive carrier epoch, non-canonical nonce/digest/jti,
wrong protocol/audience/algorithm, expiry, or room/organization mismatch is an
auth refusal before room mutation. The v1 verifier rejects every v2-only member;
the v2 verifier rejects the v1 claim shape.

`epoch` remains the PTY-owning shim process generation. `carrier_epoch` is the
strictly increasing attach-carrier generation inside that PTY epoch. The nonce,
digest, and jti are secret/correlation material for strict handoff and receipt
resolution. They never appear in viewer frames, room/control snapshots,
diagnostics, logs, error detail, or the activation controls below.

## 3. V2 control registry additions

V2 inherits every v1 Control type and adds exactly four host-carrier controls.
All are outside the host sequence namespace and therefore use binary-frame
header `seq=0`, `rel_time=0`. Unsigned uint64 values are canonical decimal
strings (`"0"` or a non-zero digit followed by digits); JSON numbers are not
accepted.

| `type` | Direction | Shape | Purpose |
|---|---|---|---|
| `host_gap` | host -> relay | `{ "type":"host_gap", "fromSeq":str, "toSeq":str, "reason":"ring_evicted" }` | Declare the exact shimwire replay gap before its authoritative recovery Snapshot. |
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
- `host-durability-unavailable` — the durable journal cannot append or reload;
- `host-frame-conflict` — the same stream identity/sequence has different raw
  bytes or a changed durable gap disposition.

These controls and codes are never emitted on a selected v1 leg. An older v1
decoder ignoring an unknown Control does not make sending one conformant.

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

A valid strictly higher `carrier_epoch` creates a candidate leg. The relay
atomically fences the incumbent's mutation authority, but it does not install
the candidate as active merely because WSS accepted or `subscribe` matched.
Room state is reconnecting/preparing, not live under the new leg.

Before `active`, the relay may send the candidate only one mandatory
`snapshot_request{reason:"resync"}`. It records a non-zero request id internally
against the exact leg and current durable high-water. Other join,
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

The host answers the mandatory request from the shim-owned VT through local-wire
v2. The first candidate sequence-bearing frame must be the exact next Snapshot
after the durable cursor. If the shim ring cannot supply that point, the host
first sends one exact `host_gap`, then the authoritative Snapshot. No ordinary
Output may overtake this response. After that Snapshot, the generic client holds
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

### 4.3 `adoption-committed`

The composing authority resolves the prepared handoff itself, loads the unique
unconsumed receipt, verifies every binding, and atomically consumes it with the
per-session adoption. No receipt id/revision, nonce, digest, token jti, or
activation selector is supplied by the host.

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

## 5. Exact raw-frame durability and host acknowledgement

The relay's replay ring is a cache, not durability. A v2-capable relay has a
small pluggable durable host-frame journal whose semantic operations are:

```text
Load(stream_ref) -> durable_high_water + retained exact replay tail + gaps
AppendFrame(stream_ref, seq, type, raw_bytes) -> durable_high_water
AppendGap(stream_ref, from_seq, to_seq, reason, recovery_snapshot) -> durable_high_water
```

`stream_ref = (org_id, session_id, PTY-host epoch)`. Carrier epoch and token jti
are ingress correlations only. A self-hosted relay supplies the same interface
to its own durable control plane or local durable store; there is no import from
one hosted platform and no in-memory-success fallback.

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

A journal timeout, I/O failure, unavailable authority, or ambiguous commit
causes no ring/cache mutation, viewer fan-out, or host ack. The relay
backpressures or closes with `host-durability-unavailable`. Retrying uses the
same raw bytes.

At process start the relay reloads the journal before admitting v2 hosts or
viewers. It cannot acknowledge, accept a takeover Snapshot, or advertise v2
readiness until the high-water and retained tail/gaps verify. Corrupt or missing
state refuses v2 instead of resetting sequence to zero under the same PTY epoch.

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
| Local publication succeeds, activation request is lost | Daemon stays non-Ready and retries exact `carrier_activate`; relay either promotes once or returns the already-active acknowledgement. |
| Viewer sends Input before active | Nothing reaches the host and no input ack advances. |
| Resize debounce fires before active | Timer/result is suppressed; no authoritative Resize reaches any host leg. |
| Kill arrives before active | No host frame and no `relayed:true`; typed not-active result. |
| Durable frame append fails | No ring/cache/fan-out/ack; host and shim cursor stay unchanged. |
| Relay crashes after append before ack | Reload high-water, compare exact replay, return same ack without duplicate fan-out. |
| Relay crashes with only in-memory ring state | V2 remains unavailable; memory is not promoted to durability. |
| Same sequence reappears with changed bytes | Terminal conflict; never sanitize/re-encode it into equality. |
| v1 host presents v2 claim/control | Version/auth refusal; v1 room semantics remain unchanged. |

## 7. Migration and rollback

1. Publish the v2 codec/control types and generic client dormant. V1 stays the
   default and its conformance corpus must remain byte-identical.
2. Deploy relay durable journal/reload and candidate state machine with v2
   admission disabled.
3. Deploy the strict receipt/adoption/batch and daemon post-publication seams.
4. Enable v2 only for installed artifacts that pass the conformance obligations
   below. A v1 shim/host remains conservation-only and visibly carrier-ineligible.
5. Rollback first disables new v2 credential mint/admission and lets already
   active v2 legs drain. It never rebinds them as v1, lowers carrier epoch,
   discards durable high-water, or reactivates an incumbent.

Activation is an operator/founder deployment decision outside protocol
acceptance. A source test, mutable checkout, branch reference, or in-memory demo
cannot enable it.

## 8. Conformance and V16 proof obligations

- [ ] WSS `/v2/` offers/echoes only `interactive-attach-v2`; substituting v1
      makes the takeover test RED.
- [ ] V1 verifier rejects the exact v2 claim set and v2 verifier rejects the v1
      set, every unknown/duplicate member, bad nonce/digest/jti, wrong role,
      and stale/lower carrier evidence.
- [ ] At each pre-active state, production Input/Resize/Kill paths produce zero
      host frames and zero acknowledgement/relayed effects. Delete each gate and
      observe its named test RED, then restore GREEN.
- [ ] Exactly one mandatory takeover Snapshot request crosses before active;
      ordinary snapshot requests serialize behind it.
- [ ] Receipt, adoption, all batches, local publication, `carrier_activate`, and
      `carrier_active` occur in order. Deleting the post-publication seam or
      moving activation earlier is RED.
- [ ] The pre-active Snapshot's exact frame journal + strict receipt permit
      adoption publication without advancing the shim cursor; waiting on its
      host ack before publication is RED, and `carrier_active.ackSeq` resolves it
      after activation.
- [ ] A blocked/failed journal append produces no ring/cache/fan-out/`host_ack`;
      deleting the append or moving it later is RED.
- [ ] Every byte value and split boundary persists and replays exactly as
      received. Semantic reconstruction and viewer-sanitized bytes compare
      unequal to source truth.
- [ ] Fresh-process restart reloads the same high-water/tail/gap state and exact
      replay returns the same ack without duplicate fan-out. Removing `Load` is
      RED.
- [ ] The daemon advances its shim heartbeat only after `host_ack`; replacing
      that wait with socket-write completion is RED.
- [ ] Tokens, raw jtis, handoff nonces, raw Output/Snapshot bytes, and journal
      payloads are absent from logs, errors, diagnostics, room snapshots, and
      viewer control frames.
- [ ] A self-hosted compatible journal/sink passes the same corpus without any
      hosted-platform import.

Per Agent Operating Protocol V16, a green suite alone proves none of these.
Each named production seam is removed/disabled independently, the intended
fixture is observed RED for the intended reason, and the restored exact code is
observed GREEN.
