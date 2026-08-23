---
status: Accepted
date: 2026-08-17
boundary: shared
split: synchronized-mirror
---

# ADR-2026-08-17 — Per-session shim ownership and daemon adoption

**Status:** Accepted — architecture decision; implementation, release, migration,
and activation remain pending behind the proof obligations below.
**Date:** 2026-08-17
**Boundary:** shared (the per-session process boundary, local shim wire,
adoption protocol, sequence ownership, crash semantics, registry safety,
quarantine contract, typed recovery composition seams, attach-v2 activation/
durable-ack protocol, selected-v3 full-host-frame local wire, and migration law
are OSS-canonical here; hosted relay,
credential authority, restart-fence/frame-journal persistence, and control-plane
reaper integration live in the platform mirror)
**Authors:** session-continuity design lane

> **Accepted 2026-08-18.** Acceptance fixes the ownership, identity, adoption,
> fencing, gap, quarantine, orphan, and restart-fence contracts. It does not
> claim a shim binary, service-manager survival, hosted restart fence, release,
> migration, or activation. Those require the real-binary and cross-layer proof
> obligations in this ADR.
> The three review amendments are ratified decisions: planned hosted restarts
> use the platform-pre-announced durable fence in D9 (not a measured-gap option),
> relay identity rides the generic optional carrier-extension point in D3, and
> quarantined shims are always visible capacity in D7.

> **Corrected 2026-08-22.** The accepting text left three ambiguities that are
> unsafe at implementation time. `controller_generation` is per shim and is
> never a host- or fence-level scalar; a stable host identity is independent of
> a daemon/controller or worker-registration correlation; and one physical
> multi-scope restart requires one exact durable acknowledgement per authority
> scope before stop. Duplicate lifecycle identities retain every observed live
> shim/process correlation, exact request and output bytes remain lossless, and
> release stays held until every covered correlation has positive terminal
> proof. Carrier setup now has an explicit prepare-before-`Welcome`,
> commit-after-`Adopted` order. This correction is normative and does not change
> the pending implementation/release/activation status.

> **Recovery clarification 2026-08-22.** A planned-restart fence receipt is
> authority for the old controller to stop; it is not a recovery credential the
> replacement controller must inherit. Carrier preparation after an
> authenticated `Hello` uses the exact live correlation and lets the composing
> authority resolve its own durable obligations. No matching fence is the valid
> unplanned-crash case, not a reason to refuse adoption or fabricate a fence.
> Conflicting authority or correlation still fails closed. This clarification
> is normative and preserves the implementation/release/activation gates.

> **Controller-identity and snapshot correction 2026-08-22.** A controller id
> is one immutable, opaque daemon-process correlation. It is neither a worker
> registration id nor a token-generation value, and routine credential refresh
> cannot change it. The v1 local-wire vocabulary is closed and cannot carry the
> on-demand authoritative snapshot operation an adopted external attach host
> requires. Selected protocol version 2 adds that exact request/reply proxy while
> version 1 remains adoptable during the overlap. A daemon-side VT reconstruction
> or a cache presented as a fresh shim snapshot is forbidden. This correction is
> normative; external-carrier activation remains pending on the v2 proof below.

> **Activation-seam and output-durability correction 2026-08-23.** Boundary
> verification against the released daemon and the candidate relay proved three
> remaining composition holes: registration, refresh, and heartbeat had no typed
> session-shim attestation surface; a higher carrier became authoritative before
> its snapshot receipt, adoption, batch publication, and local publication were
> complete; and ordinary host frames could enter a relay ring/fan-out before any
> durable raw-frame acknowledgement existed. The correction below is normative.
> Recovery may acquire scoped credentials before adoption, but no heartbeat,
> capacity, poll, claim, or viewer mutation starts during that auth-only phase.
> `interactive-attach-v1` remains frozen; its correctly versioned v2 successor
> owns carrier activation, durable host acknowledgement, and gap-disposition
> controls. Implementation, release, migration, and activation remain pending.

> **Full-host-frame local-wire correction 2026-08-23.** Released selected
> shimwire v2 adds only `SnapshotRequest`/`SnapshotResult`; its shim output pump
> transports Output/Exit/Snapshot semantically and intentionally drops the
> sequence-bearing applied Resize and Marker frames. D14 therefore cannot be
> satisfied over selected v2 without reconstructing or losing host history.
> Selected version 3, under the unchanged `session-shim-v1` family token, adds
> one exact full-host-frame observation for every sequence-bearing attach frame.
> Selected v1/v2 remain frozen. Released v2 shims stay adoptable for ownership
> and snapshots but are visibly ineligible for a durable external carrier; new
> v3 shims downgrade to exact v2 behavior with a released daemon. This
> correction is normative and keeps activation pending.

## Context

An interactive session is currently only as durable as the daemon process that
launched it. The daemon's worker path eventually calls the shared interactive
driver, which constructs a `ptyhost.Session`; that object owns the `exec.Cmd`,
PTY master, output sequence, ring, VT, recorder, subscriptions, and terminal
teardown in one process (`donmai/ptyhost/session.go:30-147`). The driver holds
that object directly and cancels it when its parent context is cancelled
(`donmai/provider/harness/ptycli/handle.go:23-34,157-168`). The implementation is
internally coherent, but its process boundary is wrong for daemon upgrades: the
daemon's service lifetime is also the session host's lifetime.

This makes an ordinary service restart destructive. A package upgrade replaces
the daemon and the service manager stops the old job. Every daemon-parented
interactive worker loses its owning process, closes its PTY master, and ends the
harness. The relay can reconnect viewers only to a host that still exists; a
monotonic attach epoch cannot resurrect a dead PTY.

The desired property is the same one container runtimes obtain from a
per-container shim: the long-lived workload is owned by a small, stable process,
while the replaceable manager discovers and adopts that process after restart.
For an interactive session, the durable workload boundary is one PTY, one
harness process group, one output sequence, and one bounded replay ring.

Three existing contracts constrain the design:

1. `ADR-2026-07-12-interactive-pty-session-host.md` makes the PTY host, framing,
   and outbound attach client OSS and assigns host output sequence to the
   PTY-owning process. The shim must preserve that ownership; moving sequence
   allocation back into a restarted daemon would fabricate continuity.
2. `ADR-2026-08-05-versioned-execution-cell-and-session-reference.md` makes the
   `SessionRef` the lifecycle identity. A shim instance is an execution detail,
   not a second session namespace.
3. `ADR-2026-08-13-capability-realization-registry-and-viability-of-absence.md`
   makes an adapter version and delivered surface explicit. Adoption may not
   bypass adaptation or turn a protocol mismatch into a silent downgrade.

The design must also survive the failure mode one layer above the host. A
daemon may disappear while a platform still holds a claim and applies stale-
claim or heartbeat reaping. If the platform releases that claim while a shim is
still faithfully running the harness, process continuity has recreated
split-brain at the lifecycle layer. A planned restart therefore needs a durable
restart fence, and an unplanned orphan needs a bounded self-termination rule.

## Decision

Introduce one stable **session shim** process per interactive session. The shim,
not the daemon, owns the harness process group and the interactive PTY state.
The daemon becomes a replaceable controller and carrier: it creates a shim for a
new session, or adopts an existing shim over a local versioned wire after a
restart.

The first delivery is interactive-only. The architecture converges on this same
ownership model for every session class that needs daemon-restart survival; it
does not preserve a permanent second ownership model.

### Shared contract synopsis

The following region is deliberately mirrored byte-for-byte in the platform
stub. It is the minimum contract both the execution layer and any composing
control plane must implement consistently.

<!-- BOUNDARY-SYNC-START: adr-2026-08-17-session-shim-core-contract -->
**Session-shim core contract.**

1. **Ownership:** one session shim owns one harness process group, the PTY
   master, VT/snapshot state, recorder, output sequence, replay ring, and final
   exit observation. The daemon owns none of those resources after launch.
2. **Identity:** `(org_id, session_id)` is the sole lifecycle identity.
   `shim_id`, `process_epoch`, PID, socket path, and controller generation are
   correlation or fencing values only; none can create, release, terminalize,
   or re-key a session. Stable host identity is a separate durable machine
   authority; daemon/controller ids and worker-registration ids are replaceable
   process correlations and may never substitute for it.
3. **Adoption before advertisement:** a starting daemon discovers and classifies
   every registry entry, adopts every compatible live shim, rehydrates its
   external carriers by session identity, and accounts for every quarantined
   shim before it advertises ready capacity or claims new work.
4. **Single controller:** every successful adoption advances that shim's own
   monotonic `controller_generation`; there is no host-wide or fence-wide
   controller generation. Every mutating controller frame carries the target
   shim's generation. The shim rejects stale generations, so an old daemon can
   never regain the input, resize, stop, or acknowledgement authority after a
   newer daemon adopts.
5. **Sequence and byte truth:** the shim is the sole allocator of host output
   sequence, and its length-delimited output payload is transported losslessly
   as bytes. Adoption resumes from an acknowledged sequence. If the requested
   position has fallen out of the ring, the shim emits an explicit `Gap`
   followed by a snapshot; no daemon or carrier may normalize bytes, invent
   missing output, or reset sequence while claiming continuity.
6. **Registry safety:** discovery records are atomic, bounded, mode `0600` under
   a mode `0700` directory, and contain no bearer, provider credential, prompt,
   terminal bytes, or other secret. External credentials are rehydrated after
   adoption from the authoritative session identity.
7. **Quarantine, not kill:** an incompatible, malformed, ambiguous, or
   unauthenticated shim is quarantined. Adoption refusal never kills its harness.
   Quarantined shims always count against host capacity and are always present in
   host diagnostics and heartbeat payloads until they exit or are reconciled.
8. **Bounded orphaning:** loss of the controller starts a bounded shim-owned
   orphan deadline. Expiry makes the shim terminate and reap its own harness
   process group, persist the terminal observation, and retain a tombstone for
   later adoption. It never authorizes a claim release by itself.
9. **Fence before restart:** a planned daemon restart deterministically
   partitions every adopted and quarantined shim correlation by authority
   scope, obtains a durable byte-exact acknowledgement for every partition, and
   stops only after all acknowledgements succeed. Duplicate lifecycle
   identities remain separate correlation rows. While fenced, heartbeat,
   stale-claim, and session reapers may observe but may not release, requeue, or
   terminalize any unresolved correlation.
10. **Expiry is not proof of death:** fence expiry never releases a claim merely
    because time elapsed. Every covered correlation requires either an ordinary
    terminal receipt from its adopted live owner or a durable shim terminal
    tombstone proving that exact harness process group was reaped. Without proof
    for all correlations, the session and claim enter visible reconciliation
    quarantine.
11. **Typed recovery admission:** an externally composed daemon uses additive
    typed registration, refresh, and heartbeat seams. One process presents the
    same once-resolved controller id and exact
    `(controller_id, protocol_min, protocol_max, capabilities)` tuple on initial
    registration and every refresh. A successful response echoes that tuple,
    the stable scope-local host authority, and the adoption revision before its
    credential may be installed or cached. Missing, changed, or stale cached
    evidence is a refusal. Auth-only registration/refresh may run in
    `recovering` before adoption; heartbeat, capacity publication, poll, claim,
    and `Ready` remain stopped.
12. **Activation and durable output:** a v2 carrier takeover advances only
    `preparing -> receipt-stored -> adoption-committed ->
    batch-committed/local-published -> active`. Before `active`, the relay may
    send only the mandatory authoritative snapshot request to the candidate
    host; viewer `Input`, authoritative `Resize`, and `Kill` are neither
    forwarded nor acknowledged, and later ordinary host frames remain
    backpressured outside the relay journal/ring/fan-out. An explicit
    `interactive-attach-v2` activation
    exchange follows the daemon's post-publication seam. Every sequence-bearing
    host frame is persisted as its exact raw bytes before ring insertion or
    fan-out; the host receives only a contiguous durable acknowledgement, that
    high-water reloads after relay restart, and the daemon advances the shim's
    heartbeat acknowledgement only after receiving it.
13. **Complete local observation:** selected local shimwire v1 and v2 remain
    unchanged. Selected v3 emits exactly one `HostFrame` observation containing
    the complete encoded interactive-attach bytes for every sequence-bearing
    Output, applied Resize, Marker, Snapshot, and Exit. No legacy observation or
    emitting `SnapshotResult` delivers the same frame twice. Durable external
    activation requires selected v3 plus `full_host_frame_v3`; selected v2 is
    ownership/snapshot-compatible but visibly carrier-ineligible. A Gap precedes
    its exact raw recovery Snapshot, while a post-Exit sequence-zero Snapshot
    remains a direct result outside the durable high-water.
<!-- BOUNDARY-SYNC-END: adr-2026-08-17-session-shim-core-contract -->

### D1 — Process ownership moves to a per-session shim

For an interactive session, the shim process contains the runner-side
interactive driver and `ptyhost.Session`. It launches the harness under the PTY,
becomes the sole process that can write the master fd, and remains the parent
responsible for reaping the harness process group. The daemon receives a proxy
`SessionHandle` backed by shimwire; it never receives the fd, `exec.Cmd`, or an
in-process `*ptyhost.Session`.

This is a real ownership move, not a keepalive wrapper. A design in which the
shim merely supervises a daemon-resident PTY, or the daemon retains an fd copy,
does not survive daemon death and is out of contract.

The shim is deliberately small and version-stable. It contains only the
session runner boundary, PTY host, local wire endpoint, registry/tombstone
writer, and the minimum credential-reference resolver needed at launch. It does
not contain the daemon poller, scheduler, host-registration loop, mutation
consumer, update mechanism, or a general control-plane client.

On Unix the shim starts in a session/process group outside the service manager's
daemon kill scope. On macOS, `setsid` alone is not accepted as proof: the
launchd job definition and spawn path must be configured so restarting the
daemon job does not reap descendants, then demonstrated with a real launchd
smoke. On systemd the equivalent unit posture must kill the daemon process, not
the adopted shim cgroup. Unsupported service managers keep adoption disabled
until a real process-survival fixture exists.

### D2 — Lifecycle identity remains `(org_id, session_id)`

The registry key and every adoption request carry `org_id` and `session_id`.
Together they identify the pre-existing session. These are the only fields from
which the daemon may rehydrate credentials, reconnect a carrier, resume
heartbeats, or report terminal state.

The shim also has:

- `shim_id`: a random identifier for one shim process,
- `process_epoch`: a monotonic per-session value for one shim incarnation,
- `controller_generation`: that shim's monotonic fencing number advanced on
  adoption,
- PID and process start identity: diagnostic/janitor correlation,
- socket path and protocol range: discovery and negotiation.

None is a lifecycle identity. A new `shim_id` under the same session is not a new
session. The daemon also has a replaceable `controller_id`, and a composing
deployment may expose a worker-registration id; both identify one process or
registration leg, not the physical host. A restart fence names the stable host
identity minted and persisted independently of those correlations. A composing
plane may map that stable identity to a scope-local host row, but it may not
fall back to a controller or worker id when that lookup fails.

One daemon process resolves its `controller_id` exactly once before it adopts a
shim, registers externally, or starts a credential-refresh loop. A composing
binary may provide a non-empty id through an additive configuration seam; the
OSS default generates an opaque high-entropy id once at daemon construction.
The resolved value is immutable for that process and is reused across every
served scope, shim `Welcome`, prepare/commit callback, registration, refresh,
heartbeat, and diagnostic projection. A routine token refresh or a new worker
registration leg keeps it; a replacement daemon process gets a new value.

The default and override both refuse equality with a known stable-host id or
worker-registration id. Deriving the value from a worker id, runtime-token jti,
mutable hostname, or a literal such as `daemon` is out of contract. PID/start
identity may be reported beside it but is not a sufficient id by itself. The
controller id remains comparison and diagnostic evidence, never a bearer or a
substitute for authenticated host authority.

Two or more live shim ids claiming the same `(org_id, session_id)` are an
ambiguity that quarantines **every** observed record until reconciled. Discovery,
capacity, fencing, and terminal reconciliation retain each full
`(shim_id, process_epoch, controller_generation)` correlation; a map or set
keyed only by lifecycle identity is forbidden because it would discard a
possibly live process. A PID is never trusted without its process-start identity
because PID reuse is normal.

### D3 — The stable local adoption wire has a v1/v2/v3 overlap

The shim listens on one Unix-domain socket under the injected state directory.
The socket directory is `0700`; the socket and registry record are `0600` and
owned by the daemon user. Implementations verify peer credentials and process
start identity on every supported OS; a platform without a trustworthy peer-
credential primitive keeps adoption disabled. The registry's socket device/
inode and PID/start tuple bind discovery to the live peer. No shared secret is
written to the discovery record, and same-UID processes remain inside the
daemon user's existing local trust boundary.

The wire is length-delimited and versioned independently of the daemon release.
The v1 message vocabulary is closed:

```text
Hello      shim -> daemon   protocol range, identity, shim/process ids,
                            lifecycle phase, current controller generation,
                            output/ring bounds, optional extension names
Welcome    daemon -> shim   selected version, controller id, proposed next
                            generation, resume sequence, prepared extensions
Adopted    shim -> daemon   accepted generation, exact extension echo, and
                            exact replay disposition
Output     shim -> daemon   shim-owned sequence + raw bytes
Gap        shim -> daemon   missing inclusive range + closed reason
Snapshot   shim -> daemon   state after an adoption-time replay gap
Input      daemon -> shim   generation + attributed input bytes
Resize     daemon -> shim   generation + authoritative geometry
Stop       daemon -> shim   generation + typed reason
Heartbeat  both ways       liveness and acknowledged sequence
Exit       shim -> daemon   immutable terminal observation
Error      either way      closed code + display-only detail
```

The existing protocol-family token remains stable during the overlap; the
selected integer version, not a suffix inferred from that token, decides the
message vocabulary. A released v2 peer advertises `[1,2]`; a v3 peer advertises
`[1,3]`. The daemon selects the highest overlap and both speak only that selected
vocabulary. A new daemon therefore selects v2 with a released live shim, and a
new v3 shim selects v2 with a released daemon. Neither direction sends a v3
message. Renaming the family token or raising the minimum above 1 is a later
migration decision, not part of this correction.

Selected version 2 retains every v1 type and adds one request-correlated
authoritative snapshot operation:

```text
SnapshotRequest  daemon -> shim   non-zero connection-local request id,
                                  current controller generation,
                                  mode = inspect | emit
SnapshotResult   shim -> daemon   same request id/mode plus the exact
                                  authoritative result or a closed refusal
```

`inspect` calls the shim-owned PTY host's read-only snapshot operation. It
returns the exact encoded screen bytes and the exact `at_seq` they describe,
allocates no output sequence, and emits no host frame. `emit` calls the
shim-owned PTY host's emitting snapshot operation exactly once. Its result
carries the exact encoded interactive-attach `Snapshot` frame bytes and the
exact `in_stream` disposition: before Exit the frame is sequence-bearing and is
delivered once, in host-stream order, through the controller's subscription;
after Exit it has header sequence zero, retains `at_seq == Exit.seq`, and is
returned for direct transmission. The result bytes are length-delimited opaque
bytes, never JSON/base64 or a reconstructed semantic object.

Every request carries the currently adopted controller generation. An `emit`
request is authority-bearing because it allocates a host sequence and therefore
must pass the same single generation fence as input, resize, and stop. Request
ids never cross controller connections and never create lifecycle identity.
Unknown mode, duplicate changed request, malformed result, mismatched request
id/mode/generation, timeout, or a result that would deliver one emitted frame
twice is a typed refusal; none may be converted into a cached success.
Within one live controller connection, an exact retry of the same request id,
generation, and mode returns the first immutable result without calling the PTY
host or emitting a second frame. The bounded per-connection retry ledger is
discarded with the connection; a request id is never replay authority across a
new controller generation.

Selected version 3 retains every v1/v2 type and adds the one shim-produced type
specified byte-for-byte in `protocol/session-shim-v3.md`:

```text
HostFrame  shim -> daemon   request correlation (zero for ordinary frames)
                           + one complete encoded interactive-attach host frame
```

`HostFrame.frame_bytes` is the sole selected-v3 observation authority for each
positive-sequence Output, applied Resize, Marker, ordinary/requested Snapshot,
and Exit. It includes the attach type, canonical sequence/relative-time varints,
and exact payload. A v3 shim emits no legacy `Output`, `Snapshot`, or `Exit`
observation for the same sequence. The daemon decodes a comparison/lifecycle
view but retains and delivers the original bytes once; deriving a second event
from that view is a duplicate-delivery defect.

For selected-v3 `SnapshotRequest(mode=emit)` before Exit, the shim serializes
one `HostFrame` carrying the exact Snapshot followed immediately by a
correlation-only `SnapshotResult` whose `bytes` field is empty. The non-zero
HostFrame request id binds the pair. The controller validates both, completes
the call, and publishes the raw event once; it never produces the selected-v2
result-derived event. The request-return path exposes correlation/disposition,
not a second carrier byte send; the correlated HostFrame event is the sole
adoption/journal delivery. Inspect remains the exact screen-byte result with no host
frame. Post-Exit emit remains the exact sequence-zero direct result with no
HostFrame and no durable high-water advance. These are selected-v3 semantics;
selected v2 is unchanged and still returns the complete live frame bytes in its
result.

On a selected-v3 ring miss, `Gap` is followed by one raw recovery-Snapshot
HostFrame and then the live tail; the legacy semantic `Snapshot` observation is
not also sent. The daemon therefore preserves the exact gap-before-frame order
required by D14. The `Exit` HostFrame supplies both exact durable bytes and the
one immutable terminal view; no legacy Exit duplicate is accepted.

The daemon-side controller exposes the same read-only and emitting snapshot
semantics as the shim-owned PTY session, but it owns no VT. It may retain an
exact authoritative result at its exact `at_seq` for diagnostics or conservative
replay. It may not advance that snapshot from observed `Output`, relabel a stale
cache as current, synthesize a screen, or answer a new request without a fresh
shim result. The shim remains the sole snapshot authority.

`Welcome.extensions` is an optional, namespaced map. The OSS protocol defines
one generic `carrier_epoch` extension point for a composing carrier that needs
to fence its own connection generations. It does not name a relay, service, or
hosted endpoint, and an OSS-only daemon may omit it. Unknown optional extensions
are ignored; an extension declared required by either peer makes negotiation
fail closed when unsupported.

`carrier_epoch` is a monotonic per-session **carrier** generation. It is not the
shim `process_epoch`, PTY-host stream epoch, `controller_generation`, stable host
identity, or lifecycle identity. A controller may put it in `Welcome` only when
the composing carrier prepared and authenticated that exact value after the
verified `Hello` and before `Welcome` was serialized. The shim echoes the
accepted value in `Adopted`; the controller commits the prepared carrier handoff
only after that echo. A value allocated after `Adopted` cannot retroactively
appear in the already-sent `Welcome`: a composition that resolves its carrier
later keeps that binding daemon-side and omits this extension.

All shimwire byte fields are length-delimited opaque bytes. Implementations may
decode typed metadata where the message defines it, but must not pass `Output`,
`Input`, snapshot, or replay payloads through a Unicode string, newline
conversion, JSON normalization, or another lossy intermediate.

Protocol compatibility is based on an advertised min/max range and selected
version, never on daemon or shim binary version equality. A newer daemon must be
able to adopt an older live v1 or v2 shim. A protocol bump therefore requires an
overlap window long enough for the maximum supported session duration. Removing
that overlap requires a separate migration decision.

Version 1 remains sufficient for local adoption, replay, input, resize, stop,
heartbeat, and terminal observation. It is not sufficient for a composition
whose external attach carrier can send an on-demand `snapshot_request`: v1 has
no controller-to-shim request message, and its snapshot observation does not
carry the complete emitting-frame disposition needed to implement that request.
Such a composition adopts the v1 shim for ownership conservation but refuses the
external carrier, reports the incompatibility, and charges the session to
capacity. It never adds an optional v1 message or substitutes a daemon VT/cache.

Version 2 remains sufficient for everything version 1 provides plus the exact
authoritative snapshot proxy. It is **not** sufficient for D14 external durable
output: the released v2 observation rail has no exact applied-Resize or Marker
frame and its semantic Output/Exit/Snapshot forms are not complete encoded
attach frames. A daemon selected at v2 therefore adopts/conserves ownership and
may use snapshot inspect/emit, but reports
`durable_host_frame_unsupported`, charges the session to capacity, and refuses
external attach-v2 credential/activation. It never reconstructs the missing
frames from terminal state or sequence gaps.

Version 3 plus `full_host_frame_v3` is the first local-wire profile eligible for
D14 external durable carrier activation. The capability is comparison evidence
in the composing attestation; selected version 3 is still required and a
protocol maximum alone cannot infer it.

### D4 — Adoption is fenced and happens before readiness

On daemon start:

1. enter `recovering`; an externally composed daemon performs D12 auth-only
   typed registration/refresh for every served scope and obtains the exact
   stable-host/adoption-revision receipts;
2. keep heartbeat, capacity publication, spawner admission, poll, and claim
   unstarted;
3. scan the registry directory, validating size, ownership, mode, schema,
   duplicate session identities, socket type, and PID/start identity;
4. authenticate each compatible shim `Hello`, including the exact shim/process correlation and that
   shim's current controller generation;
5. prepare any required carrier handoff and obtain its strictly greater
   `carrier_epoch` and opaque authenticator **before** serializing `Welcome`;
6. send `Welcome` with that shim's proposed next controller generation, replay
   position, and only the already-prepared extensions;
7. let the shim atomically advance its own `controller_generation` and require
   `Adopted` to echo the exact accepted generation/extensions;
8. request replay after the carrier's persisted D14 high-water;
9. when an external carrier admits on-demand snapshots, require selected local
   shimwire version 3 with `full_host_frame_v3` and selected
   `interactive-attach-v2`; selected v2 may complete ownership/snapshot adoption
   but receives the visible carrier-ineligible outcome. Admit an eligible higher
   carrier only as a non-authoritative candidate and persist its fresh mandatory
   Snapshot receipt;
10. commit each exact per-session adoption, including server-side receipt
    resolution/consumption, and durably retain the opaque adoption receipt;
11. classify every remaining record as exited, stale, or quarantined;
12. commit one complete adoption batch for every served scope, including empty
    scans, and retain every batch receipt;
13. atomically publish the local adopted/quarantined/tombstoned set and local
    `adoptionComplete`;
14. cross D13 `OnAdoptionPublished`, obtain `carrier_active` for every exact v2
    candidate, and record `carrierActivationComplete`;
15. send the first coherent heartbeat and require the exact accepted host/
    controller/adoption-revision echo; and
16. compute capacity from live adopted **plus quarantined** shims before
    advertising `Ready` and starting poll/claim.

**Composing prepare resolution.** An optional composing callback receives the
authenticated post-`Hello` lifecycle identity, shim id, process epoch, and
current per-shim controller generation, together with the composition-resolved
stable scope-local host authority, controller id, and durable last-forwarded
sequence. The sequence is the composing carrier's resume cursor; it is not a
shim-authenticated `Hello` field. A remote authority compares it with its own
durable ingress/fence state and refuses a forward leap. Zero remains the safe
over-replay cursor when no stronger durable fact exists.

The replacement controller never supplies, guesses, or persists an external
fence id, fence revision, correlation revision, or host-adoption revision. The
composing authority resolves any such obligations from its own durable state.

Zero applicable fence correlations is valid after an unplanned controller
loss; required carrier preparation and live-shim adoption still proceed. One or
more applicable exact correlations are retained as one immutable set behind an
opaque prepared correlation returned to the daemon. A conflicting lifecycle,
host authority, shim/process/controller correlation, or durable sequence fails
startup closed. Selecting by lifecycle identity alone, choosing the newest row,
or dropping one duplicate is forbidden. The opaque prepared correlation stays
daemon-side; `Adopted` echoes only the generation and negotiated extensions that
the shim actually received in `Welcome`.

The shim is authoritative for the current generation. A daemon proposes a
strictly greater generation; the shim commits it before replying `Adopted`.
Every subsequent mutating frame carries it. Read-only inspection may omit it;
input, resize, stop, terminal acknowledgement, and tombstone disposal may not.

The old controller's socket is closed when a new generation commits. A delayed
packet from that controller is rejected even if the operating system delivers
it after the new adoption. This is the split-brain fence; a file lock alone is
not sufficient because an old daemon can retain an open fd after losing a lock.

### D5 — The shim owns output sequence and declares gaps

The existing PTY host already allocates `nextSeq` beside its ring and publishes
all host-produced frames from that one critical section
(`donmai/ptyhost/session.go:74-85,177-199,288-306`). The shim preserves that
single-producer rule.

The daemon records only the downstream carrier's acknowledged
`last_forwarded_seq`; it never allocates or renumbers host output. A composing
durable callback does not return success on socket write: for attach v2 it waits
for D14 `host_ack`, after which the carrier can reload the exact durable
disposition. Only then does the daemon advance both its cursor and the shimwire
Heartbeat acknowledgement. On adoption it asks for `last_forwarded_seq + 1`.

Under selected v3, every host-sequence member is the exact complete encoded
interactive-attach frame carried by `HostFrame`: Output bytes read from the PTY,
applied Resize, Marker, Snapshot, and Exit. The shim, daemon callback, durable
carrier handoff, and carrier ingress preserve those frame bytes byte-for-byte
and associate durability with the complete frame. UTF-8 coercion, newline
conversion, truncation, semantic reconstruction, or decode-and-reencode is a
protocol error. A carrier may produce a separately identified sanitized
viewer-bound projection when its protocol requires one, but that projection may
not overwrite the retained source frame or its sequence identity.

- Ring hit: the shim replays the exact frames and continues live.
- Ring miss: the shim emits `Gap{from_seq,to_seq,reason=ring_evicted}` and a
  snapshot whose `at_seq` is after the gap, then continues live.
- Restart during an output write: the daemon either acknowledges the complete
  frame or requests it again; frame identity is `(session identity, shim output
  sequence)`, so duplicates are discarded without changing bytes.

An external carrier may need to open a new connection generation when it sees a
gap. That is a carrier concern. The daemon must expose the gap rather than reset
the shim sequence, fabricate zero bytes, or claim contiguous replay it does not
possess.

### D6 — Discovery records contain no secrets

Each live shim has one atomic JSON discovery record, written by temporary file,
`fsync`, rename, and parent-directory `fsync`. The bounded schema contains only:

```text
schema_version
org_id, session_id
shim_id, process_epoch
pid, process_started_at
socket_path
socket_device, socket_inode
protocol_min, protocol_max
phase
created_at, orphan_deadline_at
```

It never contains an external token, provider credential, environment snapshot,
prompt, terminal output, workarea secret, or serialized adaptation plan. Runtime
credentials needed by the harness are delivered at initial spawn through an
inherited sealed fd or a mode-`0600` runner-owned file whose path is not copied
into the discovery record. After daemon restart, carrier and heartbeat
credentials are re-minted from the session identity.

Socket paths must respect the shortest supported Unix path limit. The on-disk
filename therefore uses a fixed-length digest; the unhashed lifecycle identity
lives inside the bounded record and is verified against the live shim handshake.

### D7 — Quarantine is durable, visible capacity

The daemon quarantines rather than kills when:

- no protocol version overlaps,
- a record is malformed or has unsafe ownership/mode,
- two live records claim the same lifecycle identity,
- peer authentication or identity comparison fails,
- the shim reports a phase the daemon cannot interpret, or
- adoption cannot prove a strictly newer controller generation, or
- an external durable carrier is required but the selected local wire lacks its
  exact full-host-frame observation capability.

Duplicate lifecycle identities never collapse to one quarantine item. Every
live record remains separately visible with its shim id, process epoch, last
known per-shim controller generation, and capacity charge. Reconciliation may
select one correlation for adoption, but the other correlations remain held
until each has exact terminal proof.

Quarantine means no input, resize, stop, terminal acknowledgement, or new
carrier authority is granted. It does **not** mean invisible. Every host status
and heartbeat payload includes a bounded `quarantined_sessions` projection with
session identity, shim id, protocol range, reason code, age, and
`consumes_capacity:true`. Capacity computation subtracts the shim before the
host advertises available slots. The local `host status` and `host doctor`
surfaces render the same projection.

Protocol-incompatible shims drain naturally, accept adoption by a compatible
daemon if one arrives, or execute the bounded orphan rule. A new daemon never
solves incompatibility by killing an old harness. "Drain and replace" means the
old shim serves its existing session and a current shim serves the next session;
it does not mean in-place process replacement.

Carrier incompatibility does not undo a successful ownership adoption. Selected
v1 reports `authoritative_snapshot_unsupported`; selected v2 reports
`durable_host_frame_unsupported`. Both remain visible, consume capacity, and
withhold external carrier authority until a compatible daemon/shim pair exists.

### D8 — Controller loss has a bounded orphan deadline

When the controller socket closes and no newer controller adopts, the shim
enters `orphaned` and starts its own monotonic deadline. The first implementation
uses 90 seconds. The configurable contract is stricter than a number:

```text
orphan deadline + harness termination grace + maximum clock/propagation margin
    < the smallest external stale-claim release threshold
```

Configuration that violates this inequality is rejected at daemon startup and
prevents session admission. A later reduction of an external release threshold
must fail compatibility checks before rollout; it may not silently invalidate
the inequality.

At the deadline the shim sends SIGTERM to the harness process group, waits the
bounded existing stop grace, sends SIGKILL if needed, drains the PTY to EOF,
persists `Exit`, and atomically replaces its discovery record with a terminal
tombstone. The tombstone remains until a daemon adopts it and durably reports
the terminal outcome, or an operator performs an audited disposal.

The deadline bounds double execution after an unplanned daemon crash. It is not
evidence the platform may infer: missing contact, a passed deadline, or a dead
PID without a start-identity match never releases a claim. Only the persisted
terminal observation closes the lifecycle loop.

### D9 — Planned restarts use exact, authority-scoped adoption fences

Before a planned restart the daemon takes one immutable snapshot of every
adopted and quarantined shim correlation. It deterministically sorts by
authority scope, lifecycle identity, shim id, process epoch, that shim's
controller generation, and last durably forwarded sequence; duplicate lifecycle
identities are retained as distinct rows. It then partitions the snapshot by the
credential/lifecycle authority that can durably hold it. A hosted multi-tenant
composition normally uses one organization as one authority scope; a standalone
composition may use `local`.

For every non-empty partition, the daemon asks the optional composing fence
store to persist one immutable `restart-fence-v1` request containing:

```json
{
  "fenceId": "string",
  "hostId": "stable scope-local host authority",
  "sessions": [{
    "orgId": "string",
    "sessionId": "string",
    "shimId": "optional string",
    "processEpoch": 0,
    "controllerGeneration": 0,
    "lastForwardedSeq": 0
  }],
  "issuedAt": 0,
  "holdUntil": 0,
  "state": "held"
}
```

There is deliberately no fence-level `controller_generation`. The field is
captured only inside each shim correlation. `hostId` is the durable
machine authority for that scope, never the current daemon/controller id or a
replaceable worker-registration id. Failure to resolve it is a refusal, not
permission to substitute a correlation id.

The time fields are signed Unix nanoseconds and the sequence/generation
fields are non-negative integers serialized without omission, including zero.
`shimId` is the only correlation omitted when empty, which is allowed for a
malformed quarantined record. The composing adapter transports the producer's
JSON bytes as an opaque body; it does not reconstruct this object from semantic
fields.

The exact byte slice serialized from that immutable ordered snapshot is the
request authority. The store must persist it without normalizing JSON,
reordering rows, dropping correlations, or reconstructing it through another
encoder, then echo the identical bytes with a non-empty durable revision. The
daemon allows the service manager to stop only after **every** scope returns a
byte-identical durable acknowledgement. A partial multi-scope success remains a
restart refusal; the already-created holds stay valid and the same byte requests
are idempotently retried.

Those acknowledgements authorize the old controller's stop; they are not
credentials for its replacement. A planned replacement is not required to
inherit local fence-receipt state. During post-`Hello` preparation, the
composing authority resolves every unambiguous applicable unresolved
correlation row from the exact authenticated preparation facts and binds all of
them to the adoption. Multiple exact applicable rows remain separate release
obligations even when represented by one opaque prepared correlation. One row
may not be selected while another is discarded. The same preparation with no
applicable row is the unplanned-crash case and does not fabricate a fence.

A planned service-manager action must cross one daemon-owned preflight edge.
`POST /api/daemon/restart/prepare` atomically enters `draining`, prevents new
claims, mints one server-owned preparation/fence identity, freezes the immutable
multi-scope snapshot once, obtains every required durable acknowledgement, and
returns success only while that exact prepared state remains stop-safe. Partial
failure and retry reuse the same identity and frozen per-scope request bytes;
they never resample live state or accept a caller-supplied fence id.

The only permission response is a schema-valid `2xx` body whose state is
`prepared` or `not_required`. `not_required` is valid only after the handler has
entered `draining` and proved that shim ownership/adoption is disabled with no
shim registry occupants, or that the one frozen snapshot has no correlations.
It is the idempotent default-off/zero-shim posture, not a client inference from
`404`. A caller may invoke the service manager only after one of those explicit
states. Unknown or empty success bodies, timeout, malformed acknowledgement,
missing authority scope, `409`, `5xx`, and transport failure all refuse the
action.

The daemon's own update route crosses the same internal preflight before package
swap or exit. If an external caller cannot invoke the service manager after a
successful preparation, the daemon remains `draining`. Returning to service is
an explicit reconciler/operator action, not an automatic error path: `POST
/api/daemon/resume` durably marks the local preparation abandoned, invalidates
only its stop authorization, and proves every already-persisted external hold
remains intact before it may reopen claims. A later restart takes a new snapshot
and preparation identity. A bare signal or
direct service-manager stop did not cross this edge and therefore has
unplanned-crash semantics. Signal handlers cannot substitute a late fence
because a service manager may escalate termination before remote durability
completes.

`hold_until` covers the planned restart budget, the shim orphan deadline,
termination grace, clock skew, and propagation margin. The fence is consumed by
every external path that can release a claim or terminalize a session, not just
one reaper. That includes stale pre-spawn recovery, step-heartbeat expiry,
session-duration/stuck reaping, host disappearance reconciliation, and queue
claim repair.

Fence expiry changes the state from `held` to `reconciliation_required`; it does
not release anything. Every covered correlation resolves only after the new
daemon reports either:

- a successful adoption of that exact shim/process correlation followed later
  by its ordinary terminal receipt, or
- the durable terminal tombstone for that exact shim/process correlation proving
  the shim reaped its harness group.

For duplicate lifecycle identities, one correlation's proof does not discharge
the others. The common release predicate reads the fence and all correlation
proofs in the same transaction or revision-CAS critical section that performs
release, requeue, terminalization, or fence consumption; a check followed by an
unserialized write is a time-of-check/time-of-use defect. If any correlation is
unresolved, the host and session stay visible in quarantine. This is the
required invariant: **fence expiry must never release a claim while any covered
harness may still be running.**

An OSS-only daemon has no remote reaper and therefore needs no hosted fence. It
still applies D8 locally. The fence interface is an optional composing callback,
preserving the OSS boundary.

### D10 — Crash matrix

| Failure | Required outcome |
|---|---|
| Daemon exits or is upgraded | Shim and harness continue. External attach pauses; output accumulates in the shim ring. Replacement daemon adopts before advertising capacity and resumes the carrier from the last acknowledged sequence. |
| Daemon does not return before orphan deadline | Shim terminates and reaps its harness, persists a tombstone, and stops consuming live-process capacity. External claim remains fenced/quarantined until the tombstone is reported. |
| Old daemon returns after a newer daemon adopted | Its lower controller generation is rejected for every mutation. It may inspect enough state to learn it is stale, then exits. |
| Two live shim records claim one lifecycle identity | Preserve and quarantine every shim/process correlation, charge every possibly live harness to capacity, fence every row, and refuse lifecycle release until each correlation has its own ordinary-terminal or group-reaped-tombstone proof. |
| Carrier preparation succeeds but adoption fails | The prepared carrier epoch remains unused/abandoned; it is never rebound to another session or reused. A later preparation allocates a strictly greater value. No carrier commit occurs before `Adopted` echoes the prepared value. |
| Shim exits unexpectedly | Closing the sole PTY master normally delivers terminal hangup, but the harness may ignore it. The daemon janitor verifies the recorded process-group leader's start identity, performs bounded SIGTERM -> SIGKILL if any member survives, and records a shim-failure terminal outcome only after the group is proved gone. |
| Harness exits | Shim drains PTY output, emits one immutable `Exit`, writes a terminal tombstone, and notifies the current controller. |
| Harness wedges | Existing stop/no-progress policy reaches the shim as a generation-fenced `Stop`; the shim performs group SIGTERM -> SIGKILL and owns the terminal observation. Interactive human think-time exemptions remain unchanged. |
| Socket disappears but shim PID/start identity is live | Quarantine. Do not kill, recreate the socket path, or release the claim. The orphan deadline is the shim's escape hatch. |
| Registry record survives but PID/start identity does not | Classify stale, retain a diagnostic/tombstone, and reconcile lifecycle evidence. Never signal a reused PID. |
| Protocol ranges do not overlap | Quarantine and account capacity. A compatible daemon may adopt; otherwise the shim drains or reaches its orphan deadline. |
| Cached credential is fresh by expiry but its shim receipt is absent, stale, from another scope, or names another controller/tuple | Refuse the cache and perform typed auth-only registration/refresh. If that cannot complete, remain `recovering`; do not start heartbeat, poll, claim, or adoption with guessed host authority. |
| Auth-only registration succeeds for only some served scopes | Retain no partial readiness. The successful credentials may be refreshed/retried in memory, but adoption publication and every external loop remain stopped until every scope returns its exact host/revision receipt. |
| Candidate carrier socket binds, then receipt/adoption/batch/local publication fails | The candidate remains non-active. The incumbent has no mutation authority; viewer Input/Resize/Kill are not forwarded or acknowledged. Durable completed steps retry idempotently and no earlier receipt is rebound. |
| Daemon publishes locally, then its activation exchange fails or its acknowledgement is lost | Keep `carrierActivationComplete=false` and stay `recovering`. Retry `carrier_activate` on the exact candidate; the relay returns the same `carrier_active` result only for the same authenticated epochs and stored receipt. |
| Durable host-frame append fails or is ambiguous | Do not mutate ring/cache/fan-out and do not emit `host_ack`. Donmai and the shim retain their previous acknowledged cursor and replay the exact frame. |
| Relay restarts after durable append but before host ack | Reload the persisted high-water and exact retained tail, compare replay bytes, and return the same contiguous ack. Never acknowledge from an empty in-memory ring. |
| New daemon adopts a released selected-v2 shim | Preserve ownership and the v2 snapshot proxy, report `durable_host_frame_unsupported`, charge capacity, and withhold external carrier credentials/activation. Never infer missing Marker/Resize bytes. |
| Released daemon adopts a new v3 shim | Highest overlap selects v2. The shim emits no HostFrame and behaves byte-for-byte like released v2; external v3 durability is not claimed. |
| Live v3 Snapshot HostFrame arrives without its correlation-only result, or the pair differs | Publish/acknowledge neither partial nor duplicate event; fail the controller and replay the real frame under the next adoption. |
| Selected-v3 Gap is followed by a legacy semantic Snapshot or a duplicate raw Snapshot | Refuse the duplicate. The only valid order is Gap then one exact recovery-Snapshot HostFrame then the tail. |
| Exit HostFrame is followed by any positive-sequence observation | Refuse it. Exit remains the final sequence-bearing frame; a final sequence-zero Snapshot is direct-result-only. |
| Machine reboots | Both daemon and shim processes die. Boot recovery consumes terminal/stale registry evidence before advertising capacity; external release still requires the ordinary terminal/reconciliation contract. |

### D11 — Migration is interactive-first and converges on one model

The rollout is additive:

1. Ship `session-shim-v1`, registry inspection, the D12 typed credential/cache/
   heartbeat types, selected-v3 codec/event support, and the attach-v2 client
   additions with ownership, adoption, carrier activation, and durable external
   output all disabled. Keep advertised local-wire max 2 until the v3
   discriminating corpus passes.
2. Release a max-3 shim first. Released max-2 daemons select v2 and observe the
   exact released behavior; no HostFrame can reach them.
3. Release a max-3 daemon/controller. It selects v2 with released shims,
   conserves ownership/snapshot authority, and visibly withholds durable external
   carrier. New/new selects v3 and exposes one exact raw event per sequence.
4. Deploy every composing credential authority so registration and refresh
   persist and echo the exact controller/range/capability tuple, stable host
   authority, adoption revision, max-3 range, and `full_host_frame_v3`. Keep the
   daemon flag off; verify max 3 without the capability and selected v2 both
   refuse external carrier.
5. Deploy compatible relays with the attach-v2 candidate state machine, durable
   host-frame journal/high-water reload, snapshot receipt, `host_ack`, and
   explicit activation exchange. Keep the activation selector false. An
   in-memory ring, attach-v1 host leg, or local selected-v2 shim cannot satisfy
   this step.
6. Enable shim ownership for newly launched interactive PTY sessions behind a
   local compatibility gate. Existing direct-owned sessions drain; they are not
   transplanted across process boundaries.
7. Enable startup adoption and the real service-manager survival smoke. An
   externally composed daemon performs auth-only multi-scope registration first,
   keeps heartbeat/poll/claim stopped, then adopts and publishes. This includes
   unplanned recovery with no inherited local fence receipt; composing carrier
   state is resolved from the authenticated live correlation.
8. Enable the optional composing-plane restart fence only after every authority
   scope can return an exact-byte durable acknowledgement and every release,
   requeue, terminalization, host-loss, queue-repair, and administrative path
   reaches the same serialized predicate.
9. Enable external attach-v2 takeover only after selected local v3 full-frame
   proof, per-session adoption, every per-scope batch, Donmai local publication,
   relay activation, first exact heartbeat echo, and durable ordinary-output
   acknowledgement pass together. Local v2 remains conservation-only.
10. Make shim ownership the default for interactive sessions.
11. Extend the same ownership boundary to other long-lived session modes where
   restart continuity is required.
12. Delete the direct daemon-owned session path once no served mode depends on
    it.

Rollback disables new external v2 admissions and new shim-owned claims first,
then lets already-active carriers and shims drain while retaining auth refresh,
fences, terminal evidence, durable frame journals, and release reconciliation.
It never lowers a controller/carrier generation, discards a batch receipt or
persisted carrier high-water, reactivates an incumbent, or rewrites a v3 raw
event as a legacy semantic observation. A max-3 shim behind a max-2 replacement
selects v2, remains adopted/capacity-charged, and exposes no external carrier.
Removing the new types, journal, or stores waits until no live/fenced/
quarantined/adoption reference remains.

One preflight-less legacy generation may cross into the first preflight-capable
release exactly once. This migration exception is permitted only when the old
daemon's legacy drain and status surfaces prove zero active direct-owned
sessions, the shim registry has no live or quarantined occupants, the installed
version is explicitly below the first preflight version, and the candidate
artifact is verified to contain the preflight route before the service-manager
action. The caller records an auditable legacy-cutover result. `404` is otherwise
a hard refusal; this rule is never a general compatibility fallback and is
removed after the cutover generation drains from support.

There is no permanent `legacy` versus `shim` lifecycle authority. During the
transition, ownership mode is an explicit diagnostic field; lifecycle identity,
claim semantics, and terminal receipts remain one model throughout.

### D12 — Recovery credentials use additive typed attestation seams

The daemon's public registration package gains one brand-neutral typed
attestation used by registration and refresh, plus typed server and heartbeat
receipts. The zero value remains absent and serializes byte-identically to the
pre-shim contract:

```go
type SessionShimHostAttestation struct {
    Supported     bool
    ControllerID  string
    ProtocolMin   uint32
    ProtocolMax   uint32
    Capabilities  []string
}

type SessionShimCredentialReceipt struct {
    Enabled          bool
    State            string // recovering | ready
    WorkerHostID     string // stable scope-local host authority
    AdoptionRevision string // non-empty opaque server revision; "0" is valid
    ControllerID     string
    ProtocolMin      uint32
    ProtocolMax      uint32
    Capabilities     []string
}

type SessionShimHeartbeatProjection struct {
    Enabled             bool
    AdoptionComplete    bool
    WorkerHostID        string
    ControllerID        string
    AdoptionRevision    string
    QuarantinedSessions []QuarantinedSession
}
```

The concrete public Go names may follow the daemon package's existing naming,
but these fields and equality rules are normative. `RegistrationOptions` and
`RegisterRequest` carry the optional attestation. On the JSON wire the existing
flat additive request keys are `sessionShimSupported`,
`sessionShimControllerId`, `sessionShimProtocolMin`,
`sessionShimProtocolMax`, and `sessionShimCapabilities`. `RegisterResponse` and
the refresh response carry one typed `sessionShim` receipt. `HeartbeatOptions`
accepts one coherent projection callback and `heartbeatRequestBody` carries it
under `sessionShim`; a composition must not assemble these fields from separate
samples.

For one daemon process, the attestation is constructed exactly once from the
controller id D2 resolved at daemon construction and an immutable sorted,
duplicate-free protocol/capability declaration. Initial registration and **every
refresh attempt** serialize the entire tuple. An empty `{}` refresh, omission of
one field, duplicate/unknown capability, changed ordering that is not the
canonical order, changed range under the same controller, or a controller id
equal to stable-host, worker-registration, runtime-token-jti, or a known prior
token correlation is a typed refusal. A token rotation never supplies a new
controller id; a replacement process never inherits the old one.

For D14 external durable carrier, the tuple includes protocol max at least 3 and
the exact `full_host_frame_v3` capability. The server and daemon still compare
the actually selected per-shim version at prepare/adoption time: max 3 alone does
not upgrade a released v2 shim, and selected v2 remains carrier-ineligible.

The server persists the tuple before minting the credential and echoes the
complete accepted tuple together with the stable scope-local host authority and
current adoption revision. The client compares every field exactly before it
installs, fans out, or caches the credential. A response that only returns a
bearer, worker id, or `sessionShimSupported:true` is legacy evidence, not hosted
recovery authority.

The on-disk credential cache gains the same receipt. When session-shim recovery
is requested, a cache entry is usable only when the credential is otherwise
fresh **and** its receipt contains the current process's exact tuple, non-empty
stable host authority, and non-empty adoption revision. Missing receipt, an old
controller, a changed range/capability set, or a receipt from another scope
causes a network register/refresh; it never falls back to the cached bearer. If
the authoritative request cannot succeed, the daemon remains `recovering`.
Neither raw tokens nor token jtis enter diagnostics, logs, errors, adoption
records, or the heartbeat projection.

Startup ordering changes only for an externally composed recovery:

1. resolve the controller id once, load configuration, detect the immutable
   advertised protocol/capability tuple, and enter `recovering`;
2. perform auth-only typed registration or refresh for every served authority
   scope and retain only its non-secret host/revision receipt in Donmai;
3. keep heartbeat, capacity publication, poll, claim, and the spawner's work
   admission stopped while D4 adoption, per-session commits, and every per-scope
   batch complete;
4. cross the D13 post-publication carrier activation seam;
5. start heartbeat with the exact accepted host/controller/revision projection,
   require its schema-valid exact server echo, and only then advertise `Ready`
   and start poll/claim.

The optional composing hook that acquires additional scopes returns a bounded,
deterministically ordered list of non-secret
`(scope, stable_host_authority, adoption_revision)` receipts. It retains its
bearers itself. An empty or duplicate scope, changed authority, missing receipt,
or partial multi-scope result fails recovery closed. A standalone daemon with no
external credential authority skips this hook and retains its working local
path.

### D13 — Attach v2 has an explicit post-publication activation edge

The carrier successor is normatively specified in
`protocol/interactive-attach-v2.md`. It uses the distinct WebSocket subprotocol
token `interactive-attach-v2` and `/v2/` path. Reusing
`interactive-attach-v1` negotiation while accepting v2-only claims or controls
is not versioning; it is an unannounced v1 mutation and is forbidden. The first
v2 profile is host-only, so existing v1 viewer legs may remain attached to the
same relay room while the host carrier uses v2.

That external attach-v2 host carrier is independent from the local shimwire
version and requires selected local v3 with `full_host_frame_v3`. Selected local
v2 can answer the mandatory snapshot request but cannot supply D14's complete
ordinary host sequence, so it never enters this candidate state.

A strictly higher authenticated `carrier_epoch` admits a **candidate**, not an
active room host. Admission fences the incumbent's mutation authority and
advances only through this cross-layer state machine:

```text
preparing
  -> receipt-stored
  -> adoption-committed
  -> batch-committed/local-published
  -> active
```

- `preparing`: the candidate is authenticated and epoch-fenced, but not active.
  The relay may send it exactly one mandatory `snapshot_request(reason=resync)`.
  Join, backpressure, and ordinary resync requests queue behind that request.
  Viewer `Input`, authoritative `Resize`, and `Kill` do not cross any host leg;
  input sequence/ack state does not advance, resize timers do not arm or flush,
  and a kill reports a typed not-active refusal rather than `relayed:true`.
  After the mandatory Snapshot, later host frames stay in bounded shim/client
  replay state; they do not enter the relay journal/ring/fan-out and receive no
  `host_ack` until activation.
- `receipt-stored`: the exact next authoritative Snapshot frame from the
  candidate has been appended as exact raw bytes to the D14 host-frame journal
  and its bound strict Snapshot receipt has committed. It is not yet inserted
  into the live ring/fan-out and has no host ack. A socket bind, cached Snapshot,
  best-effort lifecycle callback, or either durable write in progress is not
  this state. Donmai retains the Snapshot as a pending shim acknowledgement;
  adoption publication may use the strict stored receipt and does not wait on
  the not-yet-permitted host ack.
- `adoption-committed`: the composing authority resolved and atomically consumed
  that receipt during the exact per-session adoption commit.
- `batch-committed/local-published`: every served scope, including an empty
  scan, has returned its durable batch receipt; Donmai has atomically published
  the adopted/quarantined/tombstoned set and set local `adoptionComplete`.
- `active`: only Donmai's post-publication hook may send the v2
  `carrier_activate` control on the exact candidate leg. The relay verifies the
  authenticated PTY/carrier epochs and `receipt-stored` state, atomically makes
  that candidate authoritative, publishes the staged Snapshot into its ring,
  and returns `carrier_active` with the durable cursor. That cursor resolves the
  pending Snapshot and only then advances the shim heartbeat. Exact retry is
  idempotent; stale, changed, early, wrong-leg, v1, or receipt-less activation is
  refused without changing the room.

`SessionShimConfig` therefore gains an additive `OnAdoptionPublished` callback.
Its immutable input lists the controller id, every retained per-scope batch
receipt, and every carrier-required `(org_id, session_id, carrier_epoch)` in
deterministic order; it contains no bearer, jti, handoff nonce, snapshot bytes,
or platform receipt selector. The callback returns only after every listed
carrier has received its exact `carrier_active` acknowledgement and returns the
same complete set. Donmai verifies set equality and then records a separate
`carrierActivationComplete` local fact. `Ready`, heartbeat, poll, and claim
require both local facts.

If activation fails after durable adoption/batch commit, those commits are not
rolled back or rebound. The daemon remains `recovering`, the candidate remains
non-active, exact activation is retried, and no viewer mutation is acknowledged.
An empty carrier set completes trivially after the batch publication. A hosted
composition makes the hook mandatory; a standalone composition with no external
carrier omits it. Initial launches use the same candidate/publication/activation
ordering rather than creating a permanent recovery-only carrier model.

### D14 — Carrier durability precedes ring, fan-out, and shim acknowledgement

The local prerequisite is selected shimwire v3. Its one `HostFrame` event is the
source of exact bytes for every sequence-bearing attach frame. Selected v2
semantic events cannot enter this rail; accepting them would make applied Resize
and Marker disappear while the carrier claimed a contiguous durable sequence.

`OnSessionEventDurable` means downstream durable acknowledgement, not a
successful socket write. For every sequence-bearing host frame (`Output`,
applied `Resize`, `Marker`, live `Snapshot`, and `Exit`), the v2 relay:

1. authenticates the exact leg and validates the bounded binary frame without
   normalizing it;
2. appends the exact received frame bytes, digest, stream identity, type, and
   sequence to its durable host-frame journal;
3. commits or fsyncs that append and advances only the highest **contiguous**
   durable disposition;
4. only then applies the existing per-type in-memory ring, cache, and fan-out
   behavior;
5. returns `host_ack` for that contiguous durable high-water on the exact v2
   leg.

The journal identity is `(org_id, session_id, PTY-host epoch, host sequence)`;
`carrier_epoch` is retained as ingress correlation, never as stream identity.
An exact replay at or below the high-water is idempotent and returns the existing
ack. Different raw bytes for the same identity are a terminal typed conflict.
An out-of-order future frame cannot move the ack. A shimwire `Gap` may advance
the durable disposition only after its exact missing range/reason and the
following authoritative Snapshot are stored as one recovery transition; the
ack never claims that missing raw frames exist.

A journal timeout, refusal, disk failure, or ambiguous commit produces no ring
insertion, cache update, fan-out, or host ack. It backpressures or closes the
candidate with a typed durability error. The sanitized viewer projection remains
derived after persistence and never overwrites the retained source frame.

On relay restart, the journal loads its persisted high-water and retained replay
tail before admitting a host or viewer, sending an ack, or accepting a takeover
snapshot. Missing/corrupt state makes v2 unavailable; it never resets to zero
while claiming the same PTY epoch. A self-hosted relay supplies a compatible
durable journal through the same small interface; the relay data path imports no
hosted control-plane library and has no in-memory-success fallback.

The generic attach client treats `host_ack` as the completion of its durable
send. Only then may its `OnSessionEventDurable` call return nil. Donmai records
`last_forwarded_seq` and advances the shimwire Heartbeat acknowledgement only
after that return. Timeout, reconnect, or an unacknowledged write leaves both
cursors unchanged and replays the exact bytes. This is the single end-to-end
law: **shim acknowledgement means the external carrier can reload the exact
durable disposition after its own restart.**

The adoption-time mandatory Snapshot is the one staged exception to the
synchronous callback shape: its exact journal append and strict receipt let
adoption/batch/local publication continue, but do not advance the shim cursor.
For selected v3, its live `SnapshotResult` is correlation-only; the paired
HostFrame supplies the bytes once. A non-empty live result or a second
result-derived event is a duplicate-delivery refusal.
The pending delivery resolves from `carrier_active.ackSeq` (or the immediately
following exact `host_ack`) after activation. Waiting synchronously for that ack
before calling `OnAdoptionPublished` is a circular dependency and a contract
violation; acknowledging before activation is equally invalid.

## Acceptance and proof obligations

Architecture acceptance does not claim implementation. Delivery must satisfy:

1. **Real-binary launchd RED/GREEN smoke.** RED on the last direct-owned build:
   launch a real interactive harness through the installed launchd service,
   produce output, restart the service, and observe the PTY session terminate.
   GREEN on the candidate: perform the same restart and prove the same
   `(org_id,session_id)` and shim process continue, input/output work after
   adoption, controller generation advances, shim output sequence never resets,
   and the harness PID/start identity is unchanged.
2. **Claim conservation during upgrade.** The GREEN smoke captures the durable
   restart-fence acknowledgement, waits across the platform's shortest stale
   threshold, and asserts the claim was never released, requeued, or assigned to
   another host while the shim ran.
3. **Gap honesty.** Force output beyond the ring during the adoption gap and
   assert one explicit `Gap` plus a snapshot, not fabricated contiguous output.
4. **Quarantine visibility.** Run an incompatible shim and prove the daemon does
   not kill it, subtracts it from capacity, and reports the same quarantine code
   in host diagnostics and heartbeat payloads before readiness.
5. **Old-controller fencing.** Keep the old controller socket alive across
   adoption and prove its input, resize, stop, and acknowledgement frames are
   rejected after the generation advances.
6. **No-secret registry.** Inspect every discovery and tombstone byte while a
   credentialed session runs; fixture-known secrets and terminal bytes must be
   absent, and ownership/mode/path bounds must hold.
7. **Orphan bound.** Prevent daemon return, observe shim-owned group termination
   within the configured bound, then prove the external claim remains
   quarantined until the terminal tombstone is durably consumed.
8. **Exact multi-scope fences.** On one physical host serving at least two
   authority scopes, include adopted, quarantined, and duplicate lifecycle
   correlations, prove deterministic request bytes per scope, refuse stop on
   one missing/changed/revision-less acknowledgement, and prove the stable host
   identity never falls back to the daemon/controller or worker correlation.
9. **Prepare/commit carrier handoff.** Prove `carrier_epoch` is allocated and
   authenticated before `Welcome`, echoed by `Adopted`, and committed only
   afterward. Same/lower epochs cannot evict a live carrier; a strictly higher
   authenticated epoch can. An after-adoption allocation is kept daemon-side
   and never claimed to have appeared in the prior `Welcome`.
10. **Lossless bytes.** Exercise every byte value and split boundary through
    shim output, adoption replay, durable callback, and carrier ingress; assert
    exact payload and frame identity. Any viewer sanitization is tested as a
    separate derived projection.
11. **Duplicate terminal conservation.** Start two live correlations under one
    lifecycle identity, terminalize only one through the ordinary receipt path,
    and prove every release path remains held until the other's group-reaped
    tombstone is committed in the same serialization domain.
12. **Unplanned recovery without fence state.** Start a live shim, crash its
    controller before any restart fence exists, and prove a replacement can
    prepare and commit the required carrier from the authenticated `Hello`
    facts before the orphan deadline. It must not invent a fence or advertise
    ready before the complete adoption publication succeeds.
13. **Planned receipt-state loss.** Obtain an exact durable restart-fence
    acknowledgement, stop the old controller, and remove only its local copy of
    that receipt. Prove the replacement supplies no fence selector, the
    composing authority binds every exact applicable correlation, and ordinary
    terminal evidence later discharges all and only those obligations.
14. **Caller-side planned restart refusal.** Drive every installed restart and
    update caller through the daemon preflight, remove or corrupt one scope's
    acknowledgement, and prove no caller invokes the service manager. The green
    path proves preflight first prevents new claims and only then permits the
    planned stop. A direct signal is separately proved to take the unplanned
    recovery path rather than claim a fence it never durably obtained.
15. **Frozen preflight retry.** Fail one authority scope after another has
    acknowledged, mutate live registry state, and retry. Prove the daemon reuses
    the same server-minted identity and exact request bytes rather than
    resampling, and that no caller-selected id can enter the request. Prove
    `not_required` only for an atomically drained default-off/empty snapshot.
16. **Prepared restart cancellation.** Force the service-manager invocation to
    fail after successful preflight and prove the daemon remains draining.
    `resume` must invalidate only the local stop authorization, retain external
    holds, and reopen claims only afterward; a later preparation uses a new
    identity and snapshot. The daemon-owned update path proves the same
    preflight ordering before swap or exit.
17. **Process-scoped controller identity.** With no composing override, construct
    two daemon processes and prove each resolves one non-empty, distinct
    controller id while every adoption and diagnostic inside one process carries
    the same value. With an override, prove registration, repeated runtime-token
    refresh, carrier prepare/commit, heartbeat, and shim `Welcome` all retain the
    exact override; a replacement process rotates it. Present a stable-host id,
    worker-registration id, runtime-token jti, and the literal `daemon` as the
    controller source and prove every alias is refused rather than normalized.
18. **Authoritative v2 snapshot proxy.** Negotiate v2 against a real shim-owned
    PTY. Prove `inspect` returns exact screen bytes/`at_seq` without advancing the
    host sequence; prove live `emit` advances exactly once and delivers the exact
    encoded frame once in stream order; prove post-Exit `emit` returns the exact
    sequence-zero final frame. Exercise all byte values, concurrent ordinary
    output, duplicated requests, changed replay, mismatched correlation, timeout,
    and stale generation. Deleting the shim call must make this fixture RED; a
    daemon VT or hand-authored snapshot fixture cannot satisfy it.
19. **v1/v2 overlap and carrier refusal.** Adopt prior released v1 and v2 shims
    with the new daemon and prove their existing control/replay/terminal behavior
    remains available. V1 yields visible capacity-charged
    `authoritative_snapshot_unsupported` with no later message or cache fallback.
    V2 proves its exact authoritative snapshot proxy still works but yields
    visible `durable_host_frame_unsupported`, with no external credential or
    candidate. A selected-v3 shim under the same test must supply the one raw
    takeover Snapshot event before the carrier can progress.
20. **Typed credential attestation RED/GREEN.** Drive the real
    `RegistrationOptions -> RegisterRequest -> RegisterResponse` path and the
    real runtime-token refresh endpoint call. Initial register and every refresh
    must carry the same exact complete tuple and accept only a server echo with
    the stable host authority and adoption revision. Delete each request field,
    restore the literal `{}` refresh body, omit/change each response field, or
    rotate the controller during refresh and observe a discriminating RED; then
    restore and observe GREEN. A fake that asserts its own hand-authored struct
    cannot satisfy this proof.
21. **Stale cache and auth-only startup RED/GREEN.** Seed fresh-by-expiry caches
    with a missing receipt, prior-process controller, other-scope host,
    stale adoption revision, and changed protocol/capability tuple. Each must
    call the authoritative register/refresh path or remain `recovering`, never
    install the bearer. Against the production `Daemon.Start` composition, prove
    auth-only multi-scope credential acquisition occurs before shim `Hello`,
    while heartbeat, spawner admission, poll, and claim call counts remain zero.
    Removing the recovery phase or starting any loop early must make the fixture
    RED.
22. **Heartbeat publication boundary RED/GREEN.** After every batch and carrier
    activation, send one coherent heartbeat projection with the exact echoed
    host/controller/adoption revision and complete deterministic quarantine set.
    The first server response must echo acceptance of that exact revision before
    poll/claim starts. Omit or tear any field, replay the prior revision, or
    return an empty/changed echo and prove `Ready` and claims stay false.
23. **Pre-active carrier silence RED/GREEN.** Hold a v2 takeover independently
    at `preparing`, `receipt-stored`, `adoption-committed`, and
    `batch-committed` without local publication. At every stop point send driver
    Input, advertise a new authoritative geometry, and invoke Kill. Assert zero
    frames reach the host, zero `input_ack` advance occurs, zero resize timer or
    send occurs, and Kill does not report relayed. Removing each production state
    check must turn its named test RED. Only the one mandatory resync Snapshot
    request is permitted.
24. **Post-publication activation RED/GREEN.** Commit every per-session adoption
    and per-scope batch, then prove the candidate remains non-active until Donmai
    publishes its local complete set and calls `OnAdoptionPublished`. The exact
    v2 activation/ack exchange makes it active once. Delete the hook, call it
    before local publication, omit one carrier from its returned set, retry on a
    different leg/epoch, or negotiate v1 and prove `Ready` remains refused.
    Make publication wait synchronously for the pre-active Snapshot host ack and
    prove the deadlock/timeout fixture RED; the strict receipt must permit
    publication while the shim cursor stays held until activation.
25. **Raw-frame durability and acknowledgement RED/GREEN.** For each
    sequence-bearing host frame and every byte value/split boundary, block and
    fail the real durable append. Assert no ring/cache mutation, viewer fan-out,
    `host_ack`, Donmai `last_forwarded_seq`, or shim Heartbeat acknowledgement.
    Commit the exact raw bytes and assert those five effects occur in order.
    Deleting the append, raw-byte comparison, or ack wait must make the
    discriminating fixture RED; a semantic re-encoding or in-memory fake is not
    proof.
26. **Relay-restart high-water RED/GREEN.** Persist a contiguous frame run,
    crash after append both before and after host ack, rebuild the relay from an
    empty process heap, and prove it reloads the same high-water and exact tail.
    Exact replay returns the same ack without duplicate fan-out; changed bytes
    conflict; a future gap does not advance. Removing the reload or seeding from
    the ring must make the fixture RED.
27. **Gap durability.** Evict the shim ring across recovery and prove the exact
    `Gap` range/reason plus following shim-produced Snapshot commit as one durable
    transition before the cursor advances. The ack and viewer resync must expose
    the gap disposition without claiming the missing raw frames were stored.
28. **Non-leak and immutable-artifact proof.** Exercise every new refusal and
    diagnostic with fixture tokens, token jtis, handoff nonces, raw output, and
    raw Snapshot bytes and prove none appears in logs, errors, control snapshots,
    or host diagnostics. Installed-artifact CI must pin immutable daemon, client,
    and relay revisions; a mutable checkout or branch name cannot satisfy the
    release/activation gate.
29. **Released-v2/new-v3 overlap in both directions.** Run a new max-3 daemon
    against the immutable released max-2 shim and prove selected v2 ownership/
    snapshot adoption succeeds while `durable_host_frame_unsupported` visibly
    blocks external carrier. Run a new max-3 shim against the immutable released
    daemon and prove selected v2 emits the exact released vocabulary with no
    HostFrame. Replacing either artifact with same-source code is not proof.
30. **One complete raw event per host sequence.** Under selected v3, drive real
    PTY Output, applied Resize, Marker, ordinary Snapshot, and Exit through the
    production shim subscription. Assert one `HostFrame` per sequence with exact
    complete encoded bytes and no legacy Output/Snapshot/Exit duplicate. Delete
    each mapping or restore the released Marker/Resize drop and observe the
    discriminating fixture RED.
31. **Live SnapshotResult does not double-transmit.** Issue a real v3 emit
    request and require adjacent `HostFrame(request_id=R, exact frame)` then one
    correlation-only result with empty bytes. The controller publishes one raw
    event and completes once. Restoring v2 result bytes, producing a result-
    derived event, changing pair order/correlation, or exact-retrying a second
    HostFrame must be RED. Inspect and post-Exit direct results retain their v2
    bytes and emit no HostFrame.
32. **Gap, Exit, and final-screen ordering.** Force a v3 ring miss and assert
    `Gap -> one raw recovery Snapshot -> contiguous tail`, with no legacy
    Snapshot. Assert the raw Exit is the final positive-sequence event and drives
    terminal semantics once; the post-Exit sequence-zero Snapshot remains a
    direct result outside journal/high-water. Reorder, omit, duplicate, or send
    positive sequence after Exit and observe RED.
33. **Attestation and visible ineligibility.** Initial registration, every
    refresh, heartbeat, carrier prepare, and adoption batch must require/echo the
    max-3 tuple and `full_host_frame_v3`, then compare actual selected version 3.
    Remove the capability, advertise max 3 alone, or select v2 and prove no
    attach-v2 credential/candidate/activation exists while the exact
    `durable_host_frame_unsupported` capacity projection remains visible.

The service-manager smoke uses the installed binary and actual launchd job. A
unit test that kills a child subprocess does not exercise the failure class.

## Consequences

### Positive

- Daemon upgrades no longer terminate interactive harnesses.
- PTY, sequence, ring, and process ownership align in one small process.
- Adoption is explicit and fenced rather than inferred from a surviving PID.
- Old and new daemon generations cannot both control the same terminal.
- Reaper behavior is safe across the adoption gap; time alone never proves
  workload death.
- Incompatible shims remain observable and capacity-honest instead of becoming
  silent, unreachable load.
- Credential acquisition can precede adoption without accidentally starting
  any serving loop, and every later readiness fact names the exact accepted
  controller/host/revision tuple.
- Carrier authority and output durability now have explicit acknowledgements;
  neither a socket bind nor an in-memory ring can impersonate completion.
- The daemon receives the complete PTY host sequence as exact attach-frame bytes;
  applied Resize and Marker can no longer disappear behind semantic projection.

### Negative

- One extra process and Unix socket exist per live interactive session.
- The stable local protocol must remain backward-compatible for at least the
  maximum supported session lifetime.
- A daemon restart can temporarily pause external attach and heartbeat traffic,
  even though the harness continues.
- Terminal tombstones and registry records require bounded retention and an
  audited disposal path.
- Service-manager behavior now needs real macOS and Linux integration coverage;
  process-tree unit tests are insufficient.
- A v2 relay needs a durable host-frame journal and restart recovery in addition
  to its in-memory fan-out ring.
- Recovery may hold valid credentials and durable adoption commits while still
  remaining deliberately non-Ready until carrier activation converges.
- A third selected local-wire vocabulary and its overlap fixtures must remain
  supported for at least the maximum live-session duration.

### Risks

- **Launchd still kills descendants.** A `setsid`-only implementation may pass
  ordinary subprocess tests and fail under the installed job. The real-binary
  launchd smoke is the acceptance gate.
- **A release path forgets the restart fence.** Centralize fence evaluation in
  one transactionally serialized claim-release/terminalization predicate and
  write refusal tests at every caller; a per-reaper check or a check-then-write
  race recreates split-brain through the omitted path.
- **An identity-keyed collection drops a duplicate.** A map keyed only by
  `(org_id,session_id)` can make one live process disappear from capacity,
  fencing, and release proof. Preserve correlation rows and gate on all of them.
- **A carrier epoch is allocated after `Welcome`.** Recording that value as if
  the shim accepted it invents wire history. Prepare it before `Welcome`, or
  keep the later binding entirely daemon-side.
- **Registry ambiguity after crash.** Duplicate identities or stale PIDs can
  tempt cleanup code to kill the wrong process. Quarantine plus PID start-time
  verification is mandatory.
- **Ring miss is hidden by a carrier.** The shim emits a typed gap, but a carrier
  could still flatten it. The end-to-end gap smoke must assert the viewer-visible
  reset/snapshot outcome.
- **Protocol compatibility outlives testing.** A new daemon may compile against
  v1 while no fixture runs against the previous released shim. Release gating
  must retain at least one old-shim/new-daemon adoption fixture.
- **A daemon cache impersonates the shim VT.** Observed output is not a current
  authoritative screen, and a stale exact snapshot is exact only at its original
  `at_seq`. Every fresh attach resync crosses the v2 request to the shim; otherwise
  carrier activation refuses visibly.
- **A fresh-by-expiry cache carries stale controller authority.** Credential TTL
  does not prove the current daemon process or adoption revision. Require the
  exact typed server echo, or stay recovering.
- **A candidate leg becomes the room host too early.** Installing it at socket
  admission lets viewer input, resize, or kill cross before the receipt and
  adoption commits exist. Candidate and active bindings are distinct states;
  only the post-publication v2 exchange joins them.
- **The relay acknowledges memory rather than durability.** Ring append followed
  by a crash can lose bytes the shim was told were safe. Persist exact raw bytes,
  reload the high-water, then ack; no other ordering is accepted.
- **Selected v2 is mistaken for full-frame evidence.** It can proxy a fresh
  Snapshot but omits applied Resize/Marker and semantically projects other
  frames. Require actual selected v3 plus the exact capability, not max-version
  advertisement or snapshot success.
- **A requested Snapshot is delivered twice.** Sending the complete frame in
  both HostFrame and a v2-shaped live result creates two durable events for one
  sequence. Under v3 the result is correlation-only and the raw event is sole.

## Alternatives considered

**Drain every session before upgrade.** Rejected: it preserves the current
ownership model and makes routine upgrades wait on the longest session. It also
does not survive daemon crashes.

**Keep the PTY in the daemon and reconnect viewers only.** Rejected: reconnect
cannot recover a PTY master or child whose owning process died.

**Let the harness process survive without a shim.** Rejected: a surviving child
without its sole PTY master, output sequence, ring, and reaper is not a live
interactive session.

**Persist terminal output and reconstruct a host in the new daemon.** Rejected:
the PTY master and kernel terminal state cannot be reconstructed from bytes, and
replaying bytes would fabricate process continuity.

**Give each shim a full control-plane credential.** Rejected: it expands the
credential and network surface into every session process. The daemon rehydrates
external carriers after adoption; the registry remains secret-free.

**Kill protocol-incompatible shims during upgrade.** Rejected: this makes the
compatibility path exactly as destructive as the original daemon restart and
hides occupied capacity.

**Release claims when the restart fence expires.** Rejected: elapsed time is not
proof that a harness stopped. The safe outcome under uncertainty is visible
quarantine until a terminal receipt or adopted tombstone exists.

**Add a snapshot-request message to v1.** Rejected: the v1 type registry and
strict decoder are closed precisely so an older live shim cannot silently
downgrade or misparse a new daemon. The selected v2 overlap is the compatible
extension path.

**Add HostFrame to selected v2.** Rejected: live released v2 peers treat later
discriminators as illegal under their closed selected vocabulary. A new type is
a selected-version bump; version-range overlap makes v3 compatible without
silently changing shipped bytes.

**Reconstruct applied Resize/Marker or complete frames in the daemon.** Rejected:
released v2 intentionally never transports those frames, and semantic
Output/Exit/Snapshot messages do not retain every encoded byte. Reconstruction
would fabricate sequence history and fail byte truth.

**Send HostFrame beside every legacy observation in v3.** Rejected: two rails
deliver the same host sequence twice and make `SnapshotResult` retry ambiguous.
V3 has one observation authority and derives lifecycle views from that one raw
event.

**Serve a `/v2` URL while negotiating `interactive-attach-v1`.** Rejected: the
subprotocol token is the WSS version authority. A path and v2-shaped credential
cannot silently widen v1's frozen control registry; the successor offers and
echoes `interactive-attach-v2`.

**Make a strictly higher carrier active when its socket binds.** Rejected: the
signed generation fences stale legs but proves neither snapshot durability nor
adoption/batch/local publication. The candidate remains non-authoritative until
the explicit post-publication activation exchange.

**Treat ring insertion or a successful socket write as durable output.**
Rejected: both disappear on relay-process loss. A shim acknowledgement is
permitted only after the relay's persisted high-water can be reloaded.

**Rebuild the screen in the daemon or answer from its last snapshot cache.**
Rejected: the shim owns the PTY and headless VT. A second emulator can diverge on
queries, resize, alt-screen, or output already buffered inside the shim; a cached
snapshot is authoritative only for its recorded `at_seq`, not for a fresh relay
request.

**Use only a hard adoption-gap bound and no restart fence.** Rejected: it works
only while every restart stays faster than every external stale threshold. A
slow package manager, service-manager backoff, or incompatible daemon converts
that performance assumption into split-brain. The acknowledged fence degrades
to quarantine instead.

## Affected documents

The accepting commit carries these reference-document amendments:

- `001-layered-execution-model.md` — Layer 3 session ownership: the daemon is a
  controller of per-session shims rather than the owner of long-lived harnesses.
- `011-local-daemon-fleet.md` — drain, upgrade, crash recovery, diagnostics,
  capacity accounting, and service-manager behavior.
- `013-orchestrator-and-governor.md` — session claim ownership and restart-fence
  interaction at the host boundary.
- `ADR-2026-07-12-interactive-pty-session-host.md` — host stream epoch becomes
  the PTY-owning shim process epoch; daemon/carrier generations are separate.
- `protocol/interactive-attach-v1.md` — clarify that a daemon/carrier restart
  does not create a new PTY host epoch; any new viewer-visible gap mechanism is
  versioned rather than silently added to frozen v1.
- `protocol/interactive-attach-v2.md` — the correctly versioned host-carrier
  successor: separate negotiation/claims, candidate activation, durable host
  acknowledgement, and explicit gap disposition.
- `protocol/session-shim-v3.md` — the selected local-wire successor carrying one
  exact complete raw host-frame observation for every positive-sequence frame,
  with v2 overlap and non-duplicating SnapshotResult semantics.

The platform mirror names its own reaper, relay, and host-heartbeat amendments.

## Affected work items

The platform mirror carries the private tracker mapping. Architecture acceptance
unblocks implementation sequencing; delivery remains gated by the proof
obligations and activation gates in this ADR and its platform mirror.

## Implementation notes

- Planned OSS packages: `shimwire` (codec and versioned closed message types),
  `sessionshim` (process/registry/adoption implementation), and a hidden
  `session-shim` binary mode. The exact package layout may change; the ownership
  and protocol boundaries above may not.
- `daemon.WorkerSpawner` becomes the composing point for a shim-backed proxy
  handle. It must not retain a second direct reference to PTY state.
- The shim reuses `ptyhost`, `provider/harness/ptycli`, `attachwire`, and the
  existing process-group stop semantics; it does not fork a second PTY stack.
- `daemon.SessionShimConfig` carries an additive controller-id override. The
  effective value is resolved/generated once when the daemon is constructed;
  it is not a callback and is never read from mutable worker/token state.
- Registration, refresh, cache, and heartbeat gain the D12 additive public
  types. With the session-shim attestation absent, their request/response/cache
  bytes and startup order remain the existing standalone contract.
- The composing `Daemon.Start` hook may obtain auth-only per-scope credentials
  before adoption, but it must not start heartbeat, spawner admission, poll, or
  claim. `OnAdoptionPublished` is the later, separate carrier-activation edge.
- The v2 controller proxy delegates both snapshot modes to the shim and preserves
  exact frame bytes. A cache may accelerate display of a known checkpoint but is
  not an implementation of either request mode.
- Selected local v3 adds `HostFrame` without changing selected v2. The daemon's
  raw controller event is the only durable callback for a host sequence;
  type-specific lifecycle handling derives from it rather than firing a second
  event.
- A selected-v3 live emitting Snapshot result is correlation-only and empty of
  frame bytes; inspect and post-Exit direct results retain v2 semantics. The
  paired HostFrame/result write is serialized and exact retries never emit a
  second frame.
- The v2 attach client returns durable event success only after the matching
  `host_ack`; a successful WSS write is not the `OnSessionEventDurable` contract.
- Registry writes use the injected state-directory seam. No brand-specific path
  is compiled into OSS.
- Release sequencing is OSS protocol/library first, composing binary second,
  platform fence/relay integration third, followed by the real installed-service
  smoke before default-on.

## Amended 2026-08-22 — adoption binds one session-owned workarea root

`ADR-2026-08-22-session-owned-multi-repository-workarea.md` (Accepted
architecture; implementation and migration pending) makes a session's filesystem
state a single session-owned directory, `workareaRoot`, at
`<worktree-root>/<session-id>/`, with one repository per leaf inside it. Three
consequences for this ADR, none of which touches the synchronized region above:

- **D2 is unchanged.** `(org_id, session_id)` remains the sole lifecycle
  identity. `workareaRoot` is a correlation value of exactly the same class as
  `shim_id`, `process_epoch`, PID, and socket path: it can never create, release,
  terminalize, or re-key a session.
- **D3's discovery record gains one optional field.** A record MAY carry
  `workarea_root`. Because the root is derived from the session identity the
  adopting controller can compute it, so the field is a convenience and an
  integrity cross-check, never a requirement — an old record without it is
  adopted normally, and the additive-only rule of the local wire holds.
- **D6 stays true, and this is the constraint that shapes the field.** A
  repository URL may carry embedded auth (`ADR-2026-07-07`), which makes it a
  bearer secret. The discovery record therefore persists a **path** and never a
  repository URL; the same rule binds the workarea's own declaration record.
  Persisting the more convenient thing would have written credentials into a
  registry this ADR proved secret-free.

Adoption is correspondingly simpler rather than harder: a replacement controller
adopting a shim under D4 computes one root from the identity it already has,
performs no filesystem walk to discover what the session held, and reads the
root's declaration record — never a directory listing — for the repository set.
