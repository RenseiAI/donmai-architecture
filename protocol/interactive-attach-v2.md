---
title: interactive-attach-v2 — durable carrier takeover activation
status: Proposed
date: 2026-08-23
revision: v2.0-draft2
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

Unknown or duplicate members, trailing JSON, a user role/`userId`, missing or
negative PTY epoch, non-positive carrier epoch, non-canonical nonce/digest/jti/
proof field,
wrong protocol/audience/algorithm, expiry, or room/organization mismatch is an
auth refusal before room mutation. The v1 verifier rejects every v2-only member;
the v2 verifier rejects the v1 claim shape.

`epoch` remains the PTY-owning shim process generation. `carrier_epoch` is the
strictly increasing attach-carrier generation inside that PTY epoch. The nonce,
digest, and jti are secret/correlation material for strict handoff and receipt
resolution. They never appear in viewer frames, room/control snapshots,
diagnostics, logs, error detail, or the activation controls below.

The proof fields are non-secret comparison authority. Decimal
`resolved_boundary` and `last_host_seq` must match exactly and be no lower than
`carrier_boundary`; `reserved_candidate_carrier_epoch` must equal numeric
`carrier_epoch` exactly.
The signed tuple can authorize only the one retained reservation request and
proof revision/digest/boundary at the named initialized store. A valid signature
with stale or changed proof evidence is still refused before room mutation.

### 2.1 Durable carrier proof reservation

Before credential mint, a control-authenticated caller reserves the exact
carrier-journal boundary through the generic D15 interface. The immutable
canonical request binds:

```text
org_id, session_id, pty_epoch
local_resume_from, last_host_seq
expected_active_carrier_epoch, expected_pending_carrier_epoch
reserved_candidate_carrier_epoch
reservation_request_id, reservation_request_digest
```

The request id is a non-zero UUID minted and persisted once by the composing
authority; its digest is lowercase SHA-256 over the exact canonical request
bytes excluding that digest. The reserved candidate epoch is allocated first
and must be strictly greater than every expected and journal-observed active/
pending epoch. Exact post-crash request replay returns the first result; changed
bytes at the id conflict.

The carrier returns and durably retains:

```text
schema_version = 1
store_authority_id
proof_revision
proof_digest
reservation_request_id, reservation_request_digest
disposition = empty | active | receipt_stored | terminal
org_id, session_id, pty_epoch
local_resume_from, last_host_seq
active_carrier_epoch, pending_carrier_epoch
reserved_candidate_carrier_epoch
high_water, boundary
```

The proof revision is a positive monotonic ordinal scoped to the exact stream
inside the stable initialized store, not a store-global counter. The digest is
SHA-256 over the canonical proof bytes excluding itself. Schema v1 requires
`boundary == high_water`; for `empty`, only prior active/pending epochs and the
two cursors are zero—the newly reserved candidate epoch remains non-zero. The
proof contains no bearer, jti, nonce, raw frame, or frame digest.

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
resolved boundary/last host sequence K, and optional gap field with current
journal state in the same lock or revision-CAS critical section that fences the
incumbent and installs the candidate. Exact replay returns the first candidate
disposition. Drift, terminal state, unavailable/corrupt store, revision rollback,
or mismatch returns a typed refusal before room mutation and requires a fresh
reservation plus strictly greater candidate epoch. One proof can never authorize
two candidate epochs.

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
proof revision/digest, reservation request id/digest, reserved candidate epoch,
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

### 4.3 `adoption-committed`

The composing authority resolves the prepared handoff itself, loads the unique
unconsumed receipt and reserved proof, verifies every binding, and atomically
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
same-token reconnect validates `AckSeq=L` against that current persisted
high-water and retained activated proof binding, not equality with original N
or K. It sends/accepts only the idempotent active acknowledgement before local
publication releases authority callbacks.

## 5. Exact raw-frame durability and host acknowledgement

The relay's replay ring is a cache, not durability. A v2-capable relay has a
small pluggable durable host-frame journal whose semantic operations are:

```text
Load(stream_ref) -> durable_high_water + retained exact replay tail + gaps
ReserveProof(stream_ref, frozen_request) -> immutable proof/reservation
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
monotonic proof ordinal, frozen reservation requests/proofs, pending candidate
proof/receipt, active binding, high-water, and retained tail/gaps before
resolving proof or admitting v2 hosts/viewers. It cannot acknowledge, accept a
takeover Snapshot, or advertise v2 readiness until all verify. Corrupt or
missing state refuses v2 instead of resetting proof/sequence to zero under the
same PTY epoch/store authority.

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
| Shim sidecar ack and carrier boundary are N while composing adoption is M&lt;N and Hello K=N | Resolve proof N, return prepared ResumeFrom N+1, send only Snapshot N+1/atSeq N, and advance M through N only while consuming proof plus receipt. |
| Hello LastHostSeq K exceeds proof boundary N | Hold K, return ResumeFrom K+1, send exact `controller_unforwarded` Gap N+1..K plus Snapshot K+1/atSeq K, and let proof+receipt consume advance M only through K. |
| Hello LastHostSeq K is below proof boundary N or K is max uint64 | Refuse before Welcome with no clamp/gap/candidate. |
| Carrier proof successor N+1 is below `local_resume_from` | Refuse before Welcome; do not regress, infer M/N, or send pre-active replay. |
| Journal advances after proof but before candidate admission | The in-lock proof recheck returns `carrier-proof-drift`; no incumbent fence or room mutation occurs and a higher-epoch reprepare is required. |
| Same reservation request replays after process crash | Return the first proof ordinal/digest/reserved epoch. Changed bytes conflict. |
| One proof is presented under a second candidate epoch | Refuse exact reserved-epoch mismatch before room mutation. |
| Prior candidate is exact `receipt-stored` | Resume pre-stage AckSeq N plus persisted optional gap/proof/receipt/Snapshot K+1 with no second mandatory request, or abandon it before reserving a new higher carrier. |
| Active reconnect presents current AckSeq L after ordinary progress | Accept L only when it equals current persisted high-water and retains the activated proof binding; do not require L==N or K. |
| Prior candidate is preparing only | Abandon/fence and reprepare; do not fabricate proof/receipt state. |
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
   ordinal, frozen reservation/recheck, and candidate state machine with v2
   admission disabled.
4. Deploy the strict proof-bound receipt/adoption/batch, exact five-token
   attestation, and daemon post-publication seams.
5. Enable v2 only for installed artifacts that pass the conformance obligations
   below. A local selected-v1/v2 shim remains conservation-only and visibly
   carrier-ineligible.
6. Rollback first disables new v2 credential mint/admission and lets already
   active v2 legs drain. It never rebinds them as v1, lowers carrier epoch,
   discards store/proof/reservation/high-water state, or reactivates an
   incumbent. A max-3 four-token rollback cannot mint/admit new proof-bound v2.

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
      set including `durable_carrier_proof_v1`; max 3 with the earlier four
      tokens is RED and creates no credential/candidate.
- [ ] With shim sidecar ack N, carrier high-water N, and prior adoption M&lt;N, the
      proof-resolved response/`PreparedAdoption.ResumeFrom` is exactly K+1 for
      Hello-frozen LastHostSeq K>=N. K=N sends only Snapshot N+1/atSeq N; K>N
      sends `controller_unforwarded` Gap N+1..K then Snapshot K+1/atSeq K.
      K<N, barrier drift/overflow, substituting M, daemon N, zero, or ordinary
      replay is RED.
- [ ] The reservation request id/body/digest, reserved candidate epoch, proof
      ordinal/body/digest, store authority, and boundary survive process crash.
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
      proof/store/reservation/pending state; exact replay returns the same ack
      without duplicate fan-out or mandatory Snapshot. Removing `Load` is RED.
- [ ] Pending resume retains AckSeq N and staged Snapshot K+1; active resume may
      carry current AckSeq L>=K+1. Requiring either resume AckSeq to equal the
      original proof boundary, or emitting a second gap/Snapshot, is RED.
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
