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

> **Durable carrier-boundary proof correction 2026-08-23.** Unplanned recovery
> exposed a cursor-authority gap: a selected-v3 shim can have an fsync-backed
> acknowledgement floor ahead of a composing authority's prior adoption, while
> the external carrier alone owns the durable journal high-water. Neither cursor
> may be inferred from the other, and replaying ordinary frames through a
> non-authoritative candidate would violate D13. The correction below adds one
> generic control-authenticated, content-addressed durable-carrier proof and
> reservation, binds it through preparation, attach credential, admission,
> Snapshot receipt, and adoption consume, and lets `PreparedAdoption` raise but
> never regress the shim's local resume floor. The one mandatory pre-active
> Snapshot remains the only candidate host frame. This correction is normative;
> implementation, release, migration, and activation remain pending.

> **Retained-candidate abandonment correction 2026-08-23.** The first durable
> `receipt_stored` candidate may have no prior active carrier. Abandoning that
> candidate must preserve its staged Gap/Snapshot and positive journal high-water
> while clearing both current carrier bindings, a state the closed proof-v1
> disposition union cannot represent. The same hole exists one phase earlier
> when an admitted `preparing` candidate dies after fencing an incumbent whose
> existing high-water may be zero or positive. Proof schema v1 is therefore frozen for
> exact same-handoff replay and drain only. Proof schema v2 adds a typed
> `abandoned` disposition, the all-time carrier-epoch floor, and exact predecessor-
> abandonment lineage. A separate control-authenticated abandonment operation
> burns either admitted pre-active state without reactivating its incumbent; only then may a
> changed controller reserve a strictly higher candidate. This correction is
> normative. After proof/receipt consume, abandonment is forbidden and a
> replacement rehydrates the exact original candidate/bearer with no new proof,
> Snapshot, or cursor. Implementation, release, migration, and activation remain
> pending.

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
14. **Proof-bound recovery cursor:** a selected-v3 shim persists every exact
    externally acknowledged cursor before confirming its Heartbeat, while the
    external carrier exposes its independent durable high-water only through a
    generic control-authenticated proof/reservation. The proof binds stable
    store authority, lifecycle/PTY incarnation, active and pending carrier
    epochs, closed disposition, boundary, and monotonic content-addressed
    revision without token, jti, or raw-frame bytes. It is resolved after
    authenticated `Hello`, whose selected-v3 `LastSeq` is held as an adoption
    boundary, and before `Welcome`; `PreparedAdoption.ResumeFrom` may raise but
    never regress the local sidecar floor. When `LastSeq` exceeds proof boundary,
    the carrier records one proof-bound `controller_unforwarded` Gap before
    the mandatory Snapshot. The signed carrier credential, atomic admission
    recheck, Gap/Snapshot receipt, and adoption consume bind the exact proof and
    resolved boundary. Drift refuses and reprepares. No prior control-plane
    cursor, daemon assertion, or pre-active ordinary-frame replay can substitute
    for that chain. An exact same-controller receipt-stored handoff may replay;
    an admitted preparing candidate, or a receipt-stored handoff under a changed
    controller, first durably abandons by exact request/result. The transition
    preserves existing high-water and any staged Snapshot while clearing current
    active/pending authority. The successor proof names that abandonment and an
    all-time epoch floor, so no old candidate or incumbent is rebound and the next
    reservation is strictly higher. Any proof-v1 replay/drain eligibility comes
    only from one fsync-backed store-authority-bound immutable manifest frozen
    after v1 writers close; append-only tombstones make the set shrink-only across
    restart and rollback, and unlisted or changed rows reconcile rather than open.
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
5. prepare any required carrier handoff, resolve/reserve its exact D15 durable-
   carrier proof, and obtain its strictly greater `carrier_epoch`, proof-bound
   authenticator, and resolved resume cursor **before** serializing `Welcome`;
6. send `Welcome` with that shim's proposed next controller generation, replay
   position, and only the already-prepared extensions;
7. let the shim atomically advance its own `controller_generation` and require
   `Adopted` to echo the exact accepted generation/extensions;
8. request replay from the exact proof-resolved `PreparedAdoption.ResumeFrom`,
   which may raise but never regress the shim's fsync-backed local floor;
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
stable scope-local host authority, controller id, validated local sidecar
resume floor, and authenticated `Hello.LastSeq`. The sidecar floor is local
comparison evidence, while `Hello.LastSeq` is the shim-authenticated live tail;
neither is the external carrier cursor. For proof-bound external
activation, the composing authority obtains the D15 carrier-owned proof rather
than accepting a daemon `last_forwarded_seq` assertion or its own prior adoption
cursor. Its prepared response carries exact
`resolved_boundary = Hello.LastSeq` and
`resolved_resume_from = Hello.LastSeq + 1`; Donmai returns the latter as
`PreparedAdoption.ResumeFrom`, and the adopter refuses any regression below the
sidecar floor. If Hello LastSeq exceeds proof boundary, the proof-bound prepared
correlation also carries the exact `controller_unforwarded` Gap required by D15.

The replacement controller never supplies, guesses, or persists an external
fence id, fence revision, correlation revision, or host-adoption revision. The
composing authority resolves any such obligations from its own durable state.

Zero applicable fence correlations is valid after an unplanned controller
loss; required carrier preparation and live-shim adoption still proceed. One or
more applicable exact correlations are retained as one immutable set behind an
opaque prepared correlation returned to the daemon. A conflicting lifecycle,
host authority, shim/process/controller correlation, sidecar floor, proof store/
revision/digest/boundary, or durable sequence fails
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
Heartbeat acknowledgement. Under selected v3 the shim fsyncs D15's
incarnation-bound ACK sidecar before confirming that Heartbeat. On adoption the
sidecar successor is the local floor; a proof-bound external composition uses
the carrier-owned resolved boundary to return an exact
`PreparedAdoption.ResumeFrom` at or above it. Neither the composing authority's
prior adoption cursor nor a daemon cache may lower or advance this chain by
inference.

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
| Controller crashes after proof/receipt adoption consume but before activation | Abandonment is forbidden. Server-resolve the consumed adoption, return the exact original still-valid bearer and same candidate epoch to the authenticated replacement, require old transport absent/closed, resume after staged H without duplicate, exact-replay adoption/batches, and activate the original candidate. |
| Daemon publishes locally, then its activation exchange fails or its acknowledgement is lost | Keep `carrierActivationComplete=false` and stay `recovering`. Retry `carrier_activate` on the exact candidate; the relay returns the same `carrier_active` result only for the same authenticated epochs and stored receipt. |
| Durable host-frame append fails or is ambiguous | Do not mutate ring/cache/fan-out and do not emit `host_ack`. Donmai and the shim retain their previous acknowledged cursor and replay the exact frame. |
| Relay restarts after durable append but before host ack | Reload the persisted high-water and exact retained tail, compare replay bytes, and return the same contiguous ack. Never acknowledge from an empty in-memory ring. |
| V1 cutover crashes before manifest/write-closed commit | V2 readiness remains false; no partial allowset authorizes a legacy row. Exact request retries under the exclusive store lock. |
| V1 cutover commits but response is lost | Exact request replay returns the first store-bound cutover receipt and never resnapshots surviving v1 rows. |
| V1 cutover runs on an initialized zero-row store | Relay resolves/returns its own non-empty store authority under lock and freezes an empty manifest/count zero; no prior proof response or caller-supplied authority exists. |
| Unlisted/changed/new proof-v1 row appears after cutover | Refuse into reconciliation and clear v2 readiness; never add it to the immutable base manifest. |
| Listed v1 entry drains | Commit its shrink-only tombstone before row/secret deletion. Restart and rollback retain permanent ineligibility. |
| Replacement shim sidecar ack is N and carrier proof boundary is N, both ahead of prior composing adoption M | Keep M unchanged during preparation, set proof-resolved ResumeFrom to N+1, send only the mandatory Snapshot N+1/atSeq N, then advance M to N only in the transaction consuming exact proof plus receipt. |
| Carrier proof boundary is below the local sidecar floor | Refuse before Welcome. Never regress the shim, substitute M, or replay ordinary frames through a candidate. |
| Carrier journal advances after proof reservation but before candidate admission | Atomic admission recheck detects revision/digest/boundary drift in the same lock that would fence/install; mutate no room state and reprepare at a strictly greater carrier epoch. |
| Prior candidate has a durable receipt-stored Snapshot under the same controller and exact handoff | Resume only that retained proof/handoff/receipt/Snapshot. A second mandatory Snapshot or replacement proof is forbidden. |
| A changed controller finds a durable receipt-stored candidate | Freeze and durably commit the exact abandonment request/result before allocating a successor. Preserve the staged Gap/Snapshot and high-water, clear active/pending authority, burn the old candidate and incumbent, then reserve above the all-time carrier-epoch floor. |
| Carrier commits abandonment but the response or composing commit is lost | Exact request replay returns the first abandonment revision/digest and bytes. No successor is allocated until the composing authority durably records that result. |
| Socket dies before proof reservation/admission | Apply the existing non-durable socket fence; no carrier state or receipt is fabricated. |
| Admitted candidate dies in `preparing` before receipt storage | Its reservation, pending epoch, floor, incumbent fence, and existing high-water are durable. Commit the exact abandonment with null receipt evidence, clear active/pending without rebind, and reprepare through the predecessor above the floor. |
| Proof is terminal, unavailable, corrupt, timed out, replay-changed, revision-regressed, or from another store authority | Refuse external carrier while conserving shim ownership/capacity. No zero/in-memory/prior-adoption fallback. |
| New daemon adopts a released selected-v2 shim | Preserve ownership and the v2 snapshot proxy, report `durable_host_frame_unsupported`, charge capacity, and withhold external carrier credentials/activation. Never infer missing Marker/Resize bytes. |
| Released daemon adopts a new v3 shim | Highest overlap selects v2. The shim emits no HostFrame and behaves byte-for-byte like released v2; external v3 durability is not claimed. |
| Live v3 Snapshot HostFrame arrives without its correlation-only result, or the pair differs | Publish/acknowledge neither partial nor duplicate event; fail the controller and replay the real frame under the next adoption. |
| Selected-v3 Gap is followed by a legacy semantic Snapshot or a duplicate raw Snapshot | Refuse the duplicate. The only valid order is Gap then one exact recovery-Snapshot HostFrame then the tail. |
| Exit HostFrame is followed by any positive-sequence observation | Refuse it. Exit remains the final sequence-bearing frame; a final sequence-zero Snapshot is direct-result-only. |
| Machine reboots | Both daemon and shim processes die. Boot recovery consumes terminal/stale registry evidence before advertising capacity; external release still requires the ordinary terminal/reconciliation contract. |

### D11 — Migration is interactive-first and converges on one model

The rollout is additive:

1. Ship `session-shim-v1`, registry inspection, the D12 typed credential/cache/
   heartbeat types, selected-v3 codec/event and ACK-sidecar support,
   `PreparedAdoption.ResumeFrom`, and the attach-v2 client additions with
   ownership, adoption, carrier activation, and durable external output all
   disabled. Keep advertised local-wire max 2 until the v3 discriminating corpus
   passes.
2. Release a max-3 shim first. Released max-2 daemons select v2 and observe the
   exact released behavior; no HostFrame can reach them.
3. Release a max-3 daemon/controller. It selects v2 with released shims,
   conserves ownership/snapshot authority, and visibly withholds durable external
   carrier. New/new selects v3 and exposes one exact raw event per sequence.
4. Deploy every composing credential authority so registration and refresh
   persist and echo the exact controller/range/capability tuple, stable host
   authority, adoption revision, max-3 range, and the lexically ordered five-
   token set including `durable_carrier_proof_v2` and `full_host_frame_v3`.
   Keep the daemon flag off; verify max 3 with the earlier four tokens and
   selected v2 both refuse external carrier.
5. Deploy compatible relays with frozen proof-v1 journal and exact legacy-claim
   readers, the one store-bound v1 eligibility manifest/shrink-only tombstone
   codec/control edge, proof-v2 request/proof
   codecs, the exact schema-v1 abandonment ledger/route, all-time carrier-epoch
   floor, single-use predecessor lineage, the attach-v2 candidate state machine,
   durable host-frame journal/high-water reload, stable store authority,
   monotonic proof reservation/recheck, snapshot receipt, `host_ack`, and
   explicit activation exchange. Keep the activation selector false. A
   four-disposition proof writer, an in-memory ring, attach-v1 host leg,
   four-token attestation, or local selected-v2 shim cannot satisfy this step.
   Carrier health exposes the exact boolean
   `durable_carrier_proof_v2_ready:true` only after all v2 proof/abandonment state
   plus the manifest/write-closed flag/tombstones/every referenced v1 row and
   credential reload and verify. Before that freeze, both composing and Relay v1
   writers close durably, the store header raises its mandatory minimum writer
   schema so unaware rollback binaries fail before write-open, and the composing
   side retains the exact cutover receipt.
   Missing/false, v1-only, or the old unversioned
   `durable_carrier_proof_ready:true` is ineligible.
   The composing store also retains the original encrypted attach credential
   through activation and ships typed consumed-adoption recovery, the remaining-
   validity consume gate, absent/closed old-transport check, and exact
   `ResumeFrom=H+1` handling before any candidate may reach adoption consume.
6. Enable shim ownership for newly launched interactive PTY sessions behind a
   local compatibility gate. Existing direct-owned sessions drain; they are not
   transplanted across process boundaries.
7. Enable startup adoption and the real service-manager survival smoke. An
   externally composed daemon performs auth-only multi-scope registration first,
   keeps heartbeat/poll/claim stopped, then adopts and publishes. This includes
   unplanned recovery with no inherited local fence receipt; composing carrier
   state is resolved from its control-authenticated D15 proof after `Hello` and
   returns the exact non-regressing prepared resume cursor before `Welcome`.
8. Enable the optional composing-plane restart fence only after every authority
   scope can return an exact-byte durable acknowledgement and every release,
   requeue, terminalization, host-loss, queue-repair, and administrative path
   reaches the same serialized predicate.
9. Enable external attach-v2 takeover only after selected local v3 full-frame
   proof, ACK-sidecar crash recovery, proof-reservation/admission drift checks,
   proof-bound receipt/adoption consume, per-session adoption, every per-scope
   batch, Donmai local publication, relay activation, first exact heartbeat
   echo, and durable ordinary-output acknowledgement pass together. Local v2
   remains conservation-only.
10. Make shim ownership the default for interactive sessions.
11. Extend the same ownership boundary to other long-lived session modes where
   restart continuity is required.
12. Delete the direct daemon-owned session path once no served mode depends on
    it.

Rollback disables new external v2 admissions and new shim-owned claims first,
then lets already-active carriers and shims drain while retaining auth refresh,
fences, terminal evidence, durable frame journals, store authority, proof-v1/v2
bytes/revisions/reservations, abandonment request/results and predecessor-consume
state, carrier-epoch floors, and release reconciliation. Once any abandonment
exists, a four-disposition reader is not a valid rollback artifact; it may drain
exact retained v1 handoffs but cannot mint or admit a new carrier.
The v1 base manifest, write-closed flag, tombstones, cutover receipt, and retained
rows/secrets survive rollback; no artifact may regenerate/enlarge/clear the set or
reopen a v1 writer. An unaware artifact is rollback-ineligible.
Consumed-adoption recovery envelopes/correlations remain readable until their
candidate activates or enters reconciliation; rollback never remints an expired,
lost, or corrupt bearer.
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

For D14/D15 external durable carrier, the tuple includes protocol max at least 3
and the exact lexically sorted, duplicate-free capability set
`authoritative_snapshot_v2`, `carrier_epoch_prepare_commit`,
`durable_carrier_proof_v2`, `full_host_frame_v3`,
`interactive_attach_v2`. The server and daemon still compare the actually
selected per-shim version at prepare/adoption time: max 3 alone, or max 3 with
the earlier four-token set, does not upgrade a released v2 shim or prove a
carrier reservation, and selected v2 remains carrier-ineligible.

`durable_carrier_proof_v2` **replaces** `durable_carrier_proof_v1` in that exact
five-token advertised set. A controller never advertises both. V2 advertisement
requires the frozen v1 decoder and exact retained same-handoff replay/drain path
for migration, each gated by one live untombstoned exact entry in the durable
store-bound v1 cutover manifest. Those abilities are not a v1 advertisement and
cannot mint, reserve, or admit a new proof-v1 candidate.

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

A strictly higher authenticated `carrier_epoch` with an exact D15 proof
reservation admits a **candidate**, not an active room host. Admission first
authenticates the signed proof binding and, in the same journal lock that would
fence/install, compares current store authority, proof revision/digest,
reservation request id/digest, reserved candidate epoch, and boundary. Drift
refuses before any incumbent fence or room mutation. Exact match atomically
consumes/replays the reservation and fences the incumbent's mutation authority.
The candidate then
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
  When Hello LastSeq K exceeds proof boundary N, one exact proof-bound
  `controller_unforwarded` Gap N+1..K precedes the mandatory Snapshot. The Snapshot is
  exactly sequence K+1 with `at_seq == K` (K=N means no gap); no ordinary replay
  from an older composing cursor is permitted. After that Snapshot, later host frames stay in bounded shim/client
  replay state; they do not enter the relay journal/ring/fan-out and receive no
  `host_ack` until activation.
- `receipt-stored`: the exact next authoritative Snapshot frame from the
  candidate has been appended as exact raw bytes to the D14 host-frame journal
  and its bound strict Snapshot receipt has committed. It is not yet inserted
  into the live ring/fan-out and has no host ack. A socket bind, cached Snapshot,
  best-effort lifecycle callback, or either durable write in progress is not
  this state. The receipt echoes the exact store authority, proof revision/
  digest, reservation request id/digest, reserved candidate epoch, proof
  boundary N, resolved boundary K, and the nullable exact gap.
  Donmai retains the Snapshot as a pending shim acknowledgement;
  adoption publication may use the strict stored receipt and does not wait on
  the not-yet-permitted host ack.
- `adoption-committed`: the composing authority resolved and atomically consumed
  that receipt and its exact reserved proof during the per-session adoption
  commit. Only this transaction may advance an older composing adoption cursor
  through resolved boundary K.
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

On relay restart, the journal loads its stable store authority, per-stream proof
ordinal, frozen reservation requests/proofs, pending candidate proof/receipt,
persisted high-water, and retained replay tail before resolving proof, admitting
a host or viewer, sending an ack, or accepting a takeover Snapshot. Missing/
corrupt state makes v2 unavailable; it never resets a proof or sequence to zero
while claiming the same PTY epoch/store authority. A self-hosted relay supplies
a compatible durable journal through the same small interface; the relay data
path imports no hosted control-plane library and has no in-memory-success
fallback.

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

### D15 — Durable carrier proof resolves the recovery cursor before `Welcome`

There are three cursor authorities and none may impersonate another:

- the shim's local fsync-backed externally acknowledged floor;
- the external carrier journal's durable high-water; and
- a composing authority's last committed adoption cursor.

After a crash these can legitimately be `N`, `N`, and `M` with `M < N`, while
the authenticated Hello reports a live host tail `K >= N`. The
shim cannot regress to `M`; the composing authority cannot accept `N` merely
because the replacement daemon reported it; and the candidate cannot replay
ordinary frames `M+1..N` before activation. Recovery therefore resolves the
carrier's own proof rather than choosing among inferred cursors.

#### D15.1 — Selected-v3 acknowledgement sidecar is a local floor

For selected local v3, the shim persists each exact externally covered
Heartbeat acknowledgement in an incarnation-bound sidecar before it confirms
that Heartbeat to the controller. The sidecar is a strict bounded JSON body in
an exact mode-`0600` `.ack` file under the exact mode-`0700` registry directory,
atomically replaced with file and parent-directory
fsync. It binds exact `(org_id, session_id, shim_id, process_epoch,
controller_generation, acked_seq)`. It contains no bearer, jti, stable host or
controller id, raw frame, frame digest, prompt, or terminal bytes. Released
registry scanners enumerate only their frozen `.json` discovery records and
ignore the `.ack` suffix, so selected-v2 overlap remains unchanged.

The sidecar says only that some previously authenticated carrier durably covered
`acked_seq`; it is not a carrier-store proof and cannot mint or select a handoff.
Selected v3 validates exact correlation, `controller_generation <=
Hello.Generation`, and `acked_seq <= Hello.LastSeq`. On cold adoption, its
successor sequence is `LocalResumeFrom`, normalized to start at 1 when no
sidecar exists. A malformed, unsafe-mode, identity-mismatched, ahead, regressed,
or overflowed sidecar refuses selected-v3 carrier recovery. Selected v2 ignores
the `.ack` file entirely, including corrupt bytes, preserving released overlap.
The shim independently retains its in-memory acknowledged floor and refuses a
later `Welcome.resume_from` below it even if a controller failed to validate the
file. The shim never lowers a valid floor.

After authenticated `Hello`, `AdoptionPreparation` exposes exact
`LocalResumeFrom uint64` (normalized start 1) and `LastHostSeq uint64` from that
Hello. The old ambiguous `LastForwardedSeq` spelling is not the proof authority.
`PreparedAdoption` gains one exact additive field:

```go
type PreparedAdoption struct {
    ControllerGeneration Generation
    Extensions           Extensions
    Correlation          []byte
    ResumeFrom           *uint64
}
```

`nil` preserves the standalone/local-floor behavior. A non-nil pointer may
equal or advance the local floor and becomes the exact `Welcome.resume_from`.
It may not regress the floor; a lower value is a typed preparation refusal, not
a silent `max`, and `LastHostSeq == math.MaxUint64` cannot produce a successor.
The older free-standing `ResumeFrom` composition callback may still describe a
standalone durable sink, but it cannot be configured simultaneously with a
proof-resolving prepare hook; that ambiguity is a typed startup refusal.
Proof-bound hosted/external preparation requires non-nil `ResumeFrom`.

Adding the field changes Go unkeyed external composite literals even though the
zero value and keyed literals remain source-compatible. This is an explicit
pre-release source-compatibility exception: the migration gate compiles known
consumers, converts them to keyed literals, and releases the field before the
proof capability can advertise. Introducing a parallel unbound cursor callback
would preserve compilation by weakening the authority contract and is rejected.

For selected-v3 proof preparation, sending `Hello` establishes a bounded
adoption output barrier at `LastHostSeq=K`: no later positive host sequence is
allocated ahead of the proof-bound mandatory Snapshot. PTY bytes may remain
kernel-backpressured or in the shim's existing bounded raw staging area; timeout
or staging exhaustion aborts preparation and releases the barrier without
inventing sequence/output. This selected-v3 behavior changes no v1/v2 wire byte.

#### D15.2 — Generic durable-carrier proof and reservation

A compatible external carrier exposes a small control-authenticated interface
over its durable journal. The public semantic interface is brand-neutral:

```go
type DurableCarrierProofResolver interface {
    FreezeV1Eligibility(context.Context, DurableCarrierV1CutoverRequest) (DurableCarrierV1Cutover, error)
    Reserve(context.Context, DurableCarrierProofRequest) (DurableCarrierProof, error)
    Abandon(context.Context, DurableCarrierAbandonmentRequest) (DurableCarrierAbandonment, error)
    RecheckAndFence(context.Context, DurableCarrierProof, DurableCarrierCandidate) (DurableCarrierProof, error)
}
```

An implementation may combine the operations inside its control API and WSS
admission transaction. `Reserve` runs after authenticated shim `Hello` and
before `Welcome`; `RecheckAndFence` runs under the same carrier-journal lock or
revision-CAS critical section that admits/fences the exact candidate. The
candidate argument is the strict verified non-secret projection of the signed
carrier claims: lifecycle/PTY/carrier epoch, store/proof/request bindings,
carrier boundary N, resolved boundary/last host K, and reserved candidate epoch.
The raw JWT, jti, handoff nonce, and bearer do not enter the durable interface;
the relay's authentication/room layer verifies those separately before this
call. The control credential authenticates the reserve caller but never enters
either request, proof, digest, diagnostics, or logs. An OSS/self-hosted relay
ships a working local-journal implementation; no hosted dependency is required
by the interface.

The request binds the exact lifecycle/PTY incarnation and comparison evidence:

```text
org_id, session_id
pty_epoch
local_resume_from
last_host_seq
expected_active_carrier_epoch
expected_pending_carrier_epoch
reserved_candidate_carrier_epoch
reservation_request_id
reservation_request_digest
```

That exact shape is proof-request schema v1. Proof-request schema v2 retains
every member and adds exactly:

```text
schema_version = 2
expected_carrier_epoch_floor
predecessor_abandonment = null | {
  target_reservation_request_id
  target_reservation_request_digest
  source_candidate_state
  abandonment_request_id
  abandonment_request_digest
  abandonment_revision
  abandonment_digest
  abandoned_candidate_carrier_epoch
}
```

The member is always present. It is null unless this reservation immediately
follows the exact durable abandonment below. A non-null object must equal the
retained abandonment result byte-for-byte and can be consumed by exactly one new
reservation request; exact replay of that request returns its first proof, while
another request using the same predecessor conflicts. New external admission
uses request/proof schema v2 only. Schema v1 remains decodable for exact retained
same-handoff replay and drain; it cannot express or follow abandonment and never
authorizes a new changed-controller candidate.

`reservation_request_id` is a server/composer-minted non-zero UUID frozen once
for one preparation attempt. `reservation_request_digest` is lowercase SHA-256
over the exact canonical request bytes excluding the digest field. Both are
persisted before the carrier call. An exact post-crash retry uses the same id
and bytes; changed bytes at that id conflict. A daemon callback may transport
them opaquely but never mint, resample, or reconstruct them.
`reserved_candidate_carrier_epoch` is the newly allocated strictly greater
epoch for this exact preparation. It must exceed both expected and carrier-
observed active/pending epochs. Under schema v2 it must also exceed
`expected_carrier_epoch_floor`, the journal's durable all-time maximum observed
or reserved carrier epoch, and becomes the new floor when the reservation
commits. Reserving proof before allocating that value, resetting the floor when
active/pending clear, or leaving the value out so one proof could sign two
candidate epochs is forbidden.

At a JSON control boundary, every epoch, cursor, and revision above is a
canonical uint64 decimal string (`"0"` or a non-zero digit followed by digits),
the request id is a canonical UUID string, and the digest is exactly 64
lowercase hexadecimal characters. Canonical request/proof bytes use RFC 8785
JSON Canonicalization Scheme after omitting their own digest member. A JSON
number, unknown/duplicate member, overflow, non-canonical spelling, or changed
canonical byte is a refusal rather than an equivalent representation.

Shim id, shim process epoch, and controller generation remain in the prepared
adoption correlation outside the carrier proof because the carrier does not
authenticate those local facts. The composing authority binds both sets in one
preparation transaction; neither can select or rewrite the other.

The returned immutable proof-v1 has exactly these semantic fields:

```text
schema_version = 1
store_authority_id
proof_revision
reservation_request_id
reservation_request_digest
disposition = empty | active | receipt_stored | terminal
org_id, session_id
pty_epoch
local_resume_from
last_host_seq
active_carrier_epoch
pending_carrier_epoch
reserved_candidate_carrier_epoch
high_water
boundary
proof_digest
```

Proof schema v2 retains those fields, sets `schema_version = 2`, replaces the
closed disposition union with
`empty | active | receipt_stored | abandoned | terminal`, and adds the always-
present `carrier_epoch_floor` plus the same nullable exact
`predecessor_abandonment` object from the request. On every successful v2
reservation, `carrier_epoch_floor == reserved_candidate_carrier_epoch` and the
value is strictly greater than the pre-reservation floor and every active,
pending, or abandoned candidate epoch retained by the store.

`store_authority_id` is a stable, non-secret authority for one initialized
journal store, not a host/session/controller id. It is non-empty and bounded;
explicit store reinitialization rotates it and invalidates every earlier proof.
`proof_revision` is the proof ordinal: a positive canonical uint64 decimal
persisted monotonically for the exact
`(store_authority_id, org_id, session_id, pty_epoch)` stream. It advances on
every durable disposition or reservation for that stream; it is deliberately
not a store-global counter or global fsync bottleneck. Rollback or reuse under
changed bytes is corruption. `proof_digest` is lowercase SHA-256 over the exact
canonical proof bytes excluding the digest field, including the frozen
reservation request id/digest. The store durably retains those bytes and the
reservation state, so exact request replay returns the first proof revision/
digest while changed replay conflicts.

`high_water` is the highest contiguous durable disposition (raw frame or
explicit gap transition). `boundary` is the carrier proof boundary before the
new mandatory Snapshot; proof schemas v1 and v2 require equality with high-water. Both
are present so the journal fact and its handoff role cannot be confused with the
separately resolved Hello boundary later. `empty` requires
zero prior active/pending carrier epochs and zero high-water/boundary; its newly
reserved candidate epoch remains non-zero and strictly greater. `active` names
the current active carrier and no pending one. `receipt_stored` also names the exact prior pending carrier whose staged
Snapshot is already included in the high-water. `terminal` is durable evidence
that no live takeover may be prepared. Unknown disposition or impossible epoch/
cursor combination is corruption, never a display-only warning.

In schema v2, `abandoned` requires zero active and pending carrier epochs, a
retained high-water/boundary that may be zero, a non-null predecessor abandonment
naming `preparing` or `receipt_stored`, and a
new reserved candidate strictly above its carrier-epoch floor. It grants no
authority to the abandoned candidate or the prior active carrier. `empty` is
unchanged and still requires zero high-water; `abandoned` is never normalized to
it because `empty` has no predecessor. Schema v1's four-value union is frozen: a v1 decoder continues to reject
`abandoned`, and a four-value implementation cannot advertise
`durable_carrier_proof_v2`.

A prior `receipt_stored` candidate is not silently rebound. Exact same-handoff
recovery may replay its retained proof, frozen receipt, and staged Snapshot; a
new handoff first durably abandons/burns the old prepared authority while
preserving its staged frame as a journal disposition, then reserves a strictly
higher carrier at that high-water. A merely `preparing` prior candidate has no
durable receipt, but after in-lock admission its reservation, pending epoch,
floor, incumbent fence, and existing high-water are durable; it uses the same
content-addressed abandonment with null receipt fields before reprepare. Only a
socket that dies before proof reservation/admission uses the non-durable fence.
Terminal, unavailable, corrupt, timeout, stale
store, revision rollback, or conflicting active/pending state refuses before
`Welcome`.

##### Exact retained-candidate abandonment

Durable abandonment is available for an exact current admitted candidate in
`preparing` or `receipt_stored`. A socket that dies before proof reservation and
in-lock admission continues to use the existing non-durable socket/generation
fence and can never be promoted into this operation. A same-controller
`receipt_stored` handoff with changed bytes is a changed-replay conflict, not
permission to abandon and resample; an admitted preparing handoff has no retained
Snapshot replay and must abandon before reprepare. The
control-authenticated caller freezes and persists one strict schema-v1 request
before calling the carrier:

```text
schema_version = 1
abandonment_request_id
abandonment_request_digest
reason = superseded_before_activation
cause = controller_changed | preparing_reprepare | credential_lifetime_insufficient
expected_candidate_state = preparing | receipt_stored
store_authority_id
org_id, session_id, pty_epoch
admitted_proof_schema_version
admitted_proof_revision, admitted_proof_digest
reservation_request_id, reservation_request_digest
prepared_correlation_digest
snapshot_receipt_request_digest = null | digest
snapshot_receipt_revision = null | non-empty opaque string
expected_active_carrier_epoch
expected_pending_carrier_epoch
reserved_candidate_carrier_epoch
expected_carrier_epoch_floor
expected_high_water
```

The request id is a non-zero UUID. Its digest is lowercase SHA-256 over RFC 8785
canonical request JSON excluding the digest member. Every epoch, revision,
cursor, and high-water is a canonical uint64 decimal string; the admitted
revision, pending/reserved candidate epoch, and epoch floor are positive.
`expected_pending_carrier_epoch == reserved_candidate_carrier_epoch`.
`admitted_proof_schema_version` is canonical `"1"` or `"2"` and permits the
bounded proof-v1-to-v2 migration bridge; it is never inferred from a digest.
`expected_carrier_epoch_floor` is positive, at least every expected active/
pending/reserved epoch, and must equal the locked source state.
`expected_high_water` may be zero. The two Snapshot-receipt fields are both null
exactly for `preparing` and both non-null exactly for `receipt_stored`; partial
nullability conflicts. `preparing_reprepare` requires source `preparing` and may
keep or change controller. `controller_changed` requires source `receipt_stored`
and distinct source/current controllers. `credential_lifetime_insufficient`
requires source `receipt_stored` and server proof that the original credential's
remaining validity is below the post-consume orphan/recovery minimum; it is the
only same-controller receipt-stored abandonment. Every other combination
conflicts. The caller cannot know or supply the carrier-private current state root. Under
the same journal lock that commits abandonment, the carrier resolves the unique
current admitted `preparing` or `receipt_stored` state matching every request binding, computes its
`source_state_revision`/`source_state_digest`, and returns them. That digest
commits the admitted proof/reservation, exact prepared-correlation digest, nullable
Snapshot-receipt request digest/revision, nullable Gap/staged Snapshot identity,
active/pending epochs, epoch floor, and high-water. No match or more than one
match conflicts; resolving first and writing later is a TOCTOU defect.

On first success the carrier returns and freezes exactly:

```text
schema_version = 1
state = abandoned
cause = same closed value
abandonment_request_id, abandonment_request_digest
store_authority_id
org_id, session_id, pty_epoch
admitted_proof_schema_version
admitted_proof_revision, admitted_proof_digest
source_candidate_state = preparing | receipt_stored
source_state_revision, source_state_digest
reservation_request_id, reservation_request_digest
prepared_correlation_digest
snapshot_receipt_request_digest, snapshot_receipt_revision = same nullable pair
abandonment_revision, abandonment_digest
abandoned_candidate_carrier_epoch
prior_active_carrier_epoch
active_carrier_epoch = 0
pending_carrier_epoch = 0
carrier_epoch_floor
high_water, boundary
```

`abandonment_revision` is the next positive ordinal in the same per-stream proof
revision domain; it advances exactly once from the locked current source state.
`abandonment_digest` is lowercase SHA-256 over the RFC 8785 canonical result
excluding that member. The abandoned candidate equals the request's pending and
reserved candidate, and `source_candidate_state` echoes the locked exact state.
`prior_active_carrier_epoch` echoes the exact source active
binding, including zero for a first carrier, but current active/pending both
become zero: abandonment never reactivates or rebinds the fenced incumbent.
`carrier_epoch_floor == expected_carrier_epoch_floor` and never decreases.
`high_water == boundary == expected_high_water` and remains
unchanged, including zero. For `receipt_stored`, the exact staged Gap/Snapshot
bytes remain durable but permanently non-publishable by the abandoned leg; for
`preparing`, no staged Snapshot or receipt is invented. The same atomic journal transaction marks
the exact target proof reservation `abandoned`; its proof, receipt, or candidate
can never be admitted, activated, or consumed afterward.

The store keys the frozen request/result by stream plus abandonment request id
and also uniquely by the abandoned candidate epoch. Exact id/body replay after
either process crashes returns the first result bytes without another revision.
The same id with changed bytes, a different id for the same candidate, changed
source/proof/reservation/receipt/epoch/high-water evidence, activation or
adoption racing the request, or result-digest mismatch is a typed conflict with
no state mutation. Lost or corrupt possibly committed result bytes make external
v2 unavailable and enter reconciliation; they are never reconstructed from a
room snapshot or replaced by clearing state.

When `admitted_proof_schema_version="1"`, the source reservation must match one
live untombstoned cutover-manifest entry. The same serialized transition appends
its `abandoned_to_v2` drain tombstone before the v1 row/credential can be removed
or the proof-v2 successor enabled. An unlisted/changed/tombstoned v1 source
refuses into reconciliation.

Only after the composing authority durably records that exact result may it
allocate a successor candidate. Its schema-v2 Reserve request names the exact
predecessor object, uses `expected_carrier_epoch_floor` from the result, and
chooses a new candidate strictly above it. The carrier atomically consumes the
predecessor into that one reservation and returns a proof-v2 with
`disposition=abandoned`, zero active/pending, the preserved high-water/boundary,
the same predecessor object, and the newly advanced floor. The signed credential,
WSS in-lock recheck, strict Snapshot receipt, and adoption consume all bind the
exact proof-v2 bytes. No additional proof field for the old active binding is
needed: it is named by the content-addressed abandonment result, while the proof's
typed predecessor and floor carry precisely the lineage and monotonic authority
later admission consumes.

The proof's reserved candidate epoch must equal the request, the signed attach
credential's `carrier_epoch`, the epoch rechecked at WSS admission, and both the
receipt's `carrier_epoch` and explicit reserved-candidate field. Any mismatch is
changed replay/proof conflict. A proof revision can authorize exactly one
candidate epoch.

The proof contains no token, token jti, handoff nonce, prepared-correlation
selector, raw frame, frame digest, screen bytes, or receipt secret. A room
snapshot, in-memory ring, callback, daemon cursor, or composing adoption row is
not this proof.

#### D15.3 — Preparation, admission, receipt, and consume share one proof

After `Hello`, let carrier proof boundary/high-water be `N` and the
Hello-frozen `LastHostSeq` be `K`. The composing preparation transaction obtains
the carrier proof, compares its lifecycle/PTY correlation and epochs, and
requires `N + 1 >= LocalResumeFrom` and `K >= N`. A proof whose successor is
below `LocalResumeFrom`, `K < N`, or overflow of `K + 1` refuses
`carrier_cursor_regression`. The
prepared response returns exact `resolved_boundary=K` and
`resolved_resume_from=K+1`; Donmai sets `PreparedAdoption.ResumeFrom` to that
value. A composing authority whose prior adoption is only `M` retains `M`;
proof resolution is provisional and does not advance adoption.

For a changed-controller successor, the abandoned candidate's staged Snapshot
sequence is the preserved high-water `H`, and the new proof boundary `N` is
exactly `H`. The replacement Hello boundary `K` must be at least `H`. `K==H`
therefore stages only the new Snapshot `H+1/at_seq=H`; `K>H` stages exactly Gap
`H+1..K` plus Snapshot `K+1/at_seq=K`; `K<H` or `K==MaxUint64` refuses. The old
staged Snapshot remains durable history but is never published, fanned out,
acknowledged on its abandoned leg, or replayed as the successor's mandatory
Snapshot. Exact same-handoff replay does the opposite: it retains the old staged
Snapshot and emits no new one.

When `K == N`, no recovery gap exists. When `K > N`, the prepared correlation
and signed credential bind one exact optional
`Gap{from_seq=N+1,to_seq=K,reason=controller_unforwarded}`. This reason says the frames
were emitted while the externally durable carrier was unavailable and are
being truthfully superseded by the authoritative Snapshot; it is not
`ring_evicted`. The existing source-compatible host-client helper continues to
default ordinary gaps to `ring_evicted`; an additive
`DeclareHostGapWithReason` is required for this proof-bound recovery reason.

Hosted/external eligibility requires the attested capability token
`durable_carrier_proof_v2` in addition to selected local v3 and
`full_host_frame_v3`. Capability arrays are lexically sorted and duplicate-free;
max 3 with only the earlier four tokens is ineligible. A standalone composition
with no external carrier omits the proof and keeps its local-floor path.

`protocol/interactive-attach-v2.md` also freezes the exact draft-2 proof-v1 host
claim profile. It has no proof-schema/floor/predecessor claims and is accepted
only when every original claim, including jti/nonce/prepared correlation and
proof/reservation, matches one live untombstoned entry in the exact store-bound
`proof_v1_retained_eligibility_v1` manifest and the original credential remains
valid. No authority mints or refreshes
that profile after v2 cutover. Mixed/changed/fresh/expired evidence refuses; a
receipt-stored v1 handoff that cannot exact-replay uses the explicit abandonment
bridge, while an active leg drains its existing connection without fallback.

The carrier journal produces that manifest exactly once per initialized store
authority through `FreezeV1Eligibility`, after both composing and carrier v1
writers durably close and under the exclusive store lock. The same commit raises
the required writer schema to 2, which every previously released v1 store opener
must already fail closed on before write-open. Its immutable sorted
entries bind stream, reservation id/digest, proof revision/digest, candidate
epoch/state, and nullable exact credential/JTI digests/expiry; a store-bound
revision/digest and fsync/transaction barrier make the snapshot durable. An
append-only content-addressed tombstone removes an entry after drain/abandon/
terminal/reconciliation. The base set never grows, tombstones never disappear,
and an unlisted/changed/new v1 row refuses into reconciliation. Manifest,
write-closed flag, tombstones, and referenced rows reload before
`durable_carrier_proof_v2_ready`; rollback preserves and enforces them rather than
resampling or reopening v1.

The signed attach-v2 credential binds exact non-secret claim fields
`proof_schema_version="2"`, `store_authority_id`, `proof_revision`, `proof_digest`,
`carrier_epoch_floor`, and the always-present nullable
`predecessor_abandonment` object,
`carrier_boundary=N`, `resolved_boundary=K`, `last_host_seq=K`,
`reservation_request_id`, `reservation_request_digest`, and
`reserved_candidate_carrier_epoch` beside
the existing lifecycle/PTY/carrier/handoff claims. The carrier authenticates the
credential, requires the proof schema and every floor/predecessor claim to equal
the retained proof-v2 bytes exactly, and atomically rechecks all proof fields and
the current journal high-water before any incumbent fence,
room mutation, callback, or mandatory Snapshot request. Exact match consumes or
replays that reservation and establishes proof boundary N plus resolved boundary
K and the optional proof-bound gap. Drift returns
`carrier-proof-drift`, leaves the incumbent/candidate state unchanged, burns the
prepared handoff according to its existing law, and requires a fresh proof and
strictly higher carrier epoch. A check followed by an unlocked mutation is a
TOCTOU defect.

Once the recheck/fence commits, the only permitted candidate host disposition
is the optional exact `controller_unforwarded` Gap N+1..K followed immediately by the
one mandatory Snapshot `frame_seq=K+1`, `at_seq=K`. For `K==N`, only the
Snapshot exists. There is no ordinary `M+1..K` candidate replay, no host
acknowledgement before activation, and no inference from a cached Snapshot. The
Gap and Snapshot commit as one durable transition. The strict receipt
additionally binds store authority, proof revision/digest/boundary N,
resolved boundary/last host sequence K, nullable exact gap fields/reason, reservation request id/
digest, and reserved candidate carrier epoch. The composing adoption
transaction re-resolves and locks the prepared proof, unique receipt, handoff,
and adoption row; only that transaction may advance a prior adoption cursor
from `M` through `K` while consuming both proof and Gap/Snapshot receipt.
Changed/replayed-cross-handoff evidence cannot advance it. The staged Snapshot
remains pending until `carrier_active` resolves its own sequence K+1 as already
specified by D13/D14.

The Gap/Snapshot append may advance the journal's current proof ordinal after
the admission-time recheck. That expected successor does not rewrite the frozen
reservation proof carried by the credential/receipt or make it stale for
adoption consume. The journal retains both: the admitted proof at boundary N and
the exact proof-descended pending transition through Snapshot K+1. Adoption
verifies that ancestry and receipt atomically; only a disposition not descended
from the reserved proof is drift/conflict.

After activation, ordinary frames may legitimately advance the carrier journal
to `L >= K+1`. An equal-active reconnect therefore validates its resume
`AckSeq=L` only for the same controller and same token against current persisted high-water and the retained activated
proof binding; it does **not** require L to equal the original proof boundary N
or resolved boundary K. A `receipt_stored` reconnect retains pre-stage
`AckSeq=N`, optional gap N+1..K, and candidate Snapshot K+1, then activation
acknowledges K+1. Neither resume state requests or emits a second mandatory
Snapshot.

A changed controller or fresh jti cannot equal-active at A. It follows the normal
proof-v2 `active` disposition, reserves B above A and the all-time floor, and
completes the full candidate pipeline. Equal/lower evidence never rebinds.

#### D15.4 — Consumed adoption rehydrates the exact pending candidate

Abandonment is pre-consume only. Once the composing adoption transaction has
consumed the proof and Snapshot receipt, a controller crash at
`adoption-committed` or `batch-committed/local-published` cannot abandon or mint
a replacement candidate. The consumed adoption is now the authority for the
same pending carrier epoch and staged Snapshot.

The replacement calls the existing authenticated prepare seam with only its
current controller/host/lifecycle and post-`Hello` facts; it supplies no adoption,
proof, receipt, token, nonce, jti, carrier, or recovery selector. The composing
authority locks and server-resolves the exact consumed adoption, handoff,
proof-reservation, receipt, current controller/host/lifecycle, retained secret
envelope, and expected pending-carrier binding. It returns one typed immutable
outcome; the carrier separately verifies the pending state under its own journal
lock at reconnect:

```text
state = adopted_candidate_recovery
controller_id = exact current controller
carrier_epoch = original candidate C
pre_stage_ack_seq = original proof boundary N
staged_high_water = original Snapshot sequence H
resume_from = H + 1
credential = exact original still-valid attach-v2 bearer bytes
correlation = opaque server-minted recovery correlation
credential_expires_at = original exp
```

The credential is never re-signed, refreshed, or reconstructed: its original jti,
nonce, prepared-correlation digest, proof/reservation claims, epoch, and every byte
remain unchanged. The bounded encrypted authority-scoped envelope retains it
through activation and returns it only to the authenticated replacement
controller after the server-side resolution above. Exact recovery retry under the
same controller returns the first outcome bytes; a changed request conflicts.
Loss, corruption, expiry, or authority mismatch enters reconciliation and never
remints equivalent claims.

Before adoption consume, the composing authority requires the original
credential's remaining validity to cover the configured shim orphan deadline,
maximum recovery startup/activation retry budget, clock skew, and propagation
margin. A receipt-stored candidate below that bound remains unconsumed and uses
the exact abandonment cause `credential_lifetime_insufficient`, even under the
same controller, then reserves a higher proof-v2 candidate. Configuration that
cannot make this inequality true keeps activation disabled. `staged_high_water ==
MaxUint64` likewise refuses consume into explicit reconciliation because
`resume_from` cannot be represented.

Donmai uses exact `PreparedAdoption.ResumeFrom=H+1`; it never requests or emits H
again. Later shim frames H+1 onward may enter bounded local staging but remain
outside Relay until activation. The generic attach client reconnects with the
unchanged bearer and carrier epoch C. Relay accepts it only when every token/
retained-candidate binding matches and the prior candidate transport is already
absent or closed. A still-live same-jti transport returns a typed retryable
refusal; bearer replay never evicts it. On success Relay replaces only the absent
transport, returns the original `receipt_stored` resume disposition with
`AckSeq=N` and the already-retained optional Gap/Snapshot through H, and sends no
mandatory Snapshot request or journal append.

The composing adoption callback uses only the opaque recovery correlation and
returns the first adoption result without another proof/receipt consume or cursor
advance. The replacement then finishes any missing batch/local publication and
uses the ordinary same-epoch `carrier_activate` on C. `carrier_active.ackSeq=H`
resolves the original pending Snapshot; only then does shim acknowledgement move
and staged H+1 onward flow. This is recovery of an already-adopted authority, not
arbitrary cross-controller rebind.

#### D15.5 — State and failure matrix

| State/failure | Required outcome |
|---|---|
| Sidecar ack and carrier boundary are N, so the local floor is N+1; Hello LastHostSeq K=N and prior adoption is M&lt;N | Prepare provisionally from proof N, set exact `ResumeFrom=N+1`, send only Snapshot N+1/atSeq N, and advance M through N only while consuming proof plus receipt. |
| Carrier proof boundary N is below Hello LastHostSeq K | Set `ResumeFrom=K+1`; send exact `controller_unforwarded` Gap N+1..K then Snapshot K+1/atSeq K; receipt binds both and adoption may advance M only through K. |
| Hello LastHostSeq K is below proof boundary N, or K is max uint64 | Refuse before Welcome; no cursor clamp, candidate, gap, or Snapshot. |
| Carrier boundary successor N+1 is below `LocalResumeFrom` | Refuse preparation as regression; do not lower the floor, send `Welcome`, or replay ordinary frames pre-active. |
| Carrier boundary successor N+1 is at or above `LocalResumeFrom` | Exact proof may raise `ResumeFrom`; the carrier remains the authority for those already-durable dispositions. |
| Journal advances after proof reservation but before WSS admission | Atomic recheck returns drift before room/fence mutation; burn/reprepare with a greater carrier epoch and new proof. |
| Exact proof/prepare/admission retry | Return the first retained revision/digest/reservation and first candidate disposition; never allocate a second mandatory Snapshot. |
| Changed proof bytes, revision rollback, or store-authority rotation | Typed conflict/corruption; no fallback to cursor inference or zero under the same PTY epoch. |
| Prior durable `receipt_stored` candidate, same controller and exact handoff | Resume only its exact retained proof, frozen receipt, optional Gap, and Snapshot. Never abandon it, allocate a replacement proof, or request a second Snapshot. |
| Prior durable `receipt_stored` candidate, changed controller | Commit the exact authenticated abandonment result first. Preserve its staged high-water H, clear active/pending, retain the all-time epoch floor and single-use predecessor, then reserve a proof-v2 candidate strictly above that floor. Never rebind the old handoff or incumbent. |
| Abandoned high-water is H and replacement Hello tail is K | K&lt;H or K=max refuses. K=H sends only Snapshot H+1/atSeq H; K&gt;H sends exact `controller_unforwarded` Gap H+1..K then Snapshot K+1/atSeq K. The abandoned Snapshot remains non-publishable history. |
| Abandonment response is lost after carrier commit | Exact request replay returns the first abandonment revision/digest/result without advancing again. Changed bytes, another request id for the candidate, or another successor use conflict. |
| Abandonment result is missing or corrupt after possible commit | Keep external v2 unavailable in reconciliation. Do not reconstruct lineage, clear state, lower high-water/floor, or fall back to proof v1. |
| Controller changes after exact adoption consume but before candidate activation | Server-resolve the consumed adoption and return the exact original still-valid bearer/epoch plus `ResumeFrom=H+1`; exact same-token reconnect reuses the retained Gap/Snapshot and adoption result, then finishes batch/local/activation with no abandon, proof, receipt, Snapshot, or cursor advance. |
| Old same-jti candidate transport is still live during adopted recovery | Return retryable transport-live refusal; do not evict it with bearer replay. Retry only after it is absent/closed. |
| Original credential lacks the recovery-validity margin before adoption consume | Keep proof/receipt unconsumed and durably abandon with cause `credential_lifetime_insufficient`, then allocate above the floor. |
| Original credential is expired/lost/corrupt after adoption consume | Enter reconciliation. Never abandon the consumed evidence or mint equivalent claims. |
| Same-controller, same-token active carrier resumes after ordinary frames advanced to L | Validate AckSeq L against current journal high-water and retained activated proof; do not require equality with original N/K. |
| Changed controller or fresh JTI encounters active carrier A | Equal-active reconnect at A is forbidden. Use normal proof-v2 `active` disposition, allocate B above A and the all-time floor, and complete candidate -> receipt -> adoption -> batch/local -> activation. Same/lower A cannot rebind. |
| Socket dies before reservation/in-lock admission | Apply the non-durable socket fence; create no carrier abandonment or receipt evidence. |
| Admitted candidate remains `preparing` | Commit exact abandonment with null receipt fields, preserve existing high-water/floor, clear active/pending without incumbent rebind, mark the target reservation abandoned, and reserve the successor through its predecessor. |
| Proof disposition is terminal | Refuse carrier preparation and enter terminal reconciliation; no candidate is created. |
| Proof resolver timeout, loss, or corruption | Remain recovering with external carrier ineligible; local shim ownership/capacity conservation remains. |
| Relay restarts | Reload store id, monotonic revision, proof-v1/v2 reservations, abandonment requests/results and consume state, carrier-epoch floor, high-water, pending proof/receipt, and active binding before proof or WSS readiness. |
| Four-token/max-3 attestation, proof-v1-only reader, or older relay/controller rollback | Withhold new external carrier proof/credential/admission; preserve existing journal/proof/abandonment/adoption evidence and let already-active carriers drain. |

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
    max-3 tuple and exact lexical five-token set including
    `durable_carrier_proof_v2` and `full_host_frame_v3`, then compare actual
    selected version 3. Remove `durable_carrier_proof_v2`, retain the prior four
    tokens, or advertise max 3 alone and prove typed auth refusal with no hosted
    heartbeat/credential/candidate/activation. Remove `full_host_frame_v3` or
    select v2 and prove no attach-v2 candidate exists while the exact
    `durable_host_frame_unsupported` capacity projection remains visible.
34. **Sidecar/proof cursor divergence RED/GREEN.** Persist shim ACK sidecar N,
    retain composing adoption M&lt;N, crash the controller, and cold-adopt from the
    production registry. With `Hello.LastHostSeq K=N`, preparation must resolve
    carrier proof boundary N, return exact `resolved_boundary=N` and
    `resolved_resume_from=N+1`, and set `PreparedAdoption.ResumeFrom` without
    pre-active replay. With K&gt;N, the selected-v3 Hello output barrier must hold
    K, return `ResumeFrom=K+1`, and produce exact
    `controller_unforwarded` Gap N+1..K then Snapshot K+1/atSeq K. K&lt;N,
    sidecar/Hello generation mismatch, ack beyond LastHostSeq, unsafe sidecar
    modes, or overflow refuses. Selected v2 ignores even a corrupt `.ack` file.
    Replacing proof resolution with M, N from the daemon, zero, or a silent
    `max` must make the fixture RED. A carrier boundary successor below
    `LocalResumeFrom` refuses; one at or above it may raise the cursor exactly.
35. **Frozen proof reservation and admission recheck RED/GREEN.** Persist one
    immutable reservation request id/body/digest, reserved candidate epoch, proof
    ordinal/body/digest, store authority, and boundary. Crash before/after the
    resolver response and prove exact retry returns the first values while a
    changed request conflicts. Advance the journal between proof and WSS, then
    prove the same lock that would fence/install detects drift and performs zero
    incumbent/candidate/room mutation. Removing the signed proof binding,
    reserved-epoch equality, or in-lock recheck must be RED.
36. **Proof-bound receipt and adoption consume RED/GREEN.** For K=N the
    mandatory Snapshot is N+1/atSeq N with no gap. For K&gt;N, exact Gap N+1..K
    and Snapshot K+1/atSeq K commit together. The frozen receipt echoes store
    authority, proof ordinal/digest/boundary N, last-host/resolved boundary K,
    nullable gap range/reason, reservation request id/digest, and reserved
    candidate epoch. Atomically consume proof plus receipt while advancing prior
    adoption M only through K. Mutate/omit each
    binding, reuse one proof for a second carrier epoch/handoff, or check then
    consume outside the lock and observe RED. No matching proof/receipt leaves M
    unchanged and the candidate non-active.
37. **Proof restart/pending/rollback matrix.** Fresh-process reload preserves
    store authority, per-stream ordinal, proof-v1/v2 reservations, abandonment
    request/results and predecessor-consume state, carrier-epoch floor, pending
    proof/receipt, active binding, and high-water. Exact `receipt_stored` recovery retains
    pre-stage AckSeq N, optional Gap N+1..K, and Snapshot K+1 and emits no
    second mandatory Snapshot; admitted preparing recovery uses durable
    abandonment with null receipt evidence before reprepare;
    terminal/loss/corruption/timeout/revision rollback refuses. Registration and
    every refresh must carry the exact lexically ordered five-token set with
    `durable_carrier_proof_v2`. Delete it while keeping max 3/four earlier tokens
    and prove external carrier stays ineligible; an older rollback drains but
    cannot mint/admit new proof-bound carriers. After activation advances to L,
    equal-active resume accepts current AckSeq L without requiring equality to
    original N/K.
38. **Retained-candidate abandonment real-binary RED/GREEN.** Through immutable
    installed daemon, selected-v3 shim/client, composing authority, and relay
    binaries, create the first carrier with active epoch zero, stage its real
    optional Gap plus Snapshot so `receipt_stored` has positive high-water H, and
    replace the daemon so controller id changes. With the abandonment writer or
    proof-v2 `abandoned` decoder disabled, observe the installed recovery remain
    non-Ready for the exact typed reason; no test-only store or same-source fake
    qualifies. Restore GREEN and prove one authenticated frozen request/result
    preserves H and the exact staged bytes, records prior active zero, clears
    current active/pending, advances one abandonment revision/digest, preserves
    the all-time epoch floor, and never publishes/acks the old leg. Lose the
    response across independent carrier/composer crashes and prove exact replay
    returns the first bytes while every changed id/body/binding conflicts. Reserve
    one successor through its single-use predecessor at B above the floor; K=H
    sends only Snapshot H+1, K&gt;H sends exact Gap H+1..K plus Snapshot K+1, and
    K&lt;H/overflow refuses. Separately keep the controller/handoff identical and
    prove retained replay uses the old Snapshot with no abandonment or second
    request. Repeat with active A, H&gt;0, admitted C killed in `preparing`: both
    receipt members are null, H/floor remain, A/C clear without rebind, the target
    proof reservation becomes abandoned, and only a higher successor admits;
    repeat H=0 and keep a pre-admission socket death as the non-durable control.
    Remove independently the auth gate, source-state binding, durable
    abandonment write, active/pending clear, high-water preservation, epoch-floor
    comparison, predecessor single-use, candidate-state/nullability gate, target
    reservation transition, or proof-v2 WSS/
    receipt/adoption binding and observe its named fixture RED before restoring
    the exact production seam and observing GREEN.
39. **Consumed-adoption and active-controller recovery RED/GREEN.** With immutable
    installed binaries, crash independently at `adoption-committed` and
    `batch-committed/local-published`. The authenticated replacement must receive
    the first server-resolved typed outcome containing exact original still-valid
    bearer/epoch C, N, H, and ResumeFrom H+1 from encrypted authority-scoped
    storage. With old transport absent, same-jti Relay reconnect sends no new
    Snapshot/append, adoption/batches exact-replay, C activates, ack H advances
    the shim, and H+1 onward resumes. Keep old transport live and require retryable
    refusal without eviction. Removing server-side consumed-adoption/current-
    controller/host/lifecycle/envelope locking, changing/reminting JWT/JTI,
    abandoning, replaying H, allocating proof/receipt/Snapshot, or advancing the
    adoption cursor is RED. Before consume, reduce token validity below orphan +
    recovery margin and prove exact `credential_lifetime_insufficient`
    abandonment; delete the margin gate and observe RED. After consume, expire/
    lose/corrupt the envelope and prove reconciliation without remint/leak. For
    already-active A, same-controller same-token reconnect at L remains GREEN;
    changed controller or fresh JTI at A/equal/lower is RED, while normal proof-v2
    higher B full-pipeline takeover is GREEN.
40. **Durable v1 eligibility cutover RED/GREEN.** Through the real persistent
    carrier store and composing credential writer, create exact v1 rows across
    every nonterminal state, close both v1 writers durably, and invoke the
    authenticated cutover. Crash before commit and prove readiness false with no
    partial eligibility; crash after commit before response and prove exact retry
    returns the first store authority, cutover id/revision, manifest digest/count,
    and write-closed fact without resnapshot. Verify deterministic per-row
    reservation/proof/credential digests and byte-identical draft-2 auth only for
    live untombstoned entries. Add/mutate an unlisted v1 row and prove refusal,
    reconciliation, and readiness false. Drain/abandon/terminalize rows and prove
    fsync-backed tombstones precede deletion and eligibility only shrinks across
    restart. Roll back to a manifest-unaware artifact and prove writers/readiness
    stay disabled because minimum-writer-schema store-open fails before a write;
    restore compatible code and observe the same smaller allowset.
    Disable independently writer-close ordering, exclusive lock, store-authority
    binding, canonical digest, fsync/transaction, minimum-writer-schema refusal,
    reload, exact entry lookup,
    tombstone monotonicity, or rollback enforcement and observe its fixture RED
    before restoring GREEN.
    Repeat with a freshly initialized zero-v1-row store and no proof response:
    Relay must resolve/return its own non-empty store authority and empty-manifest
    count zero; requiring caller authority or accepting empty/guessed authority is
    RED.

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
- Proof-v1 readers remain necessary for exact retained same-handoff replay while
  every new external reservation, abandonment successor, and admission uses v2.
- The relay journal retains an additional exact abandonment ledger, monotonic
  carrier-epoch floor, and single-use predecessor-consume index per stream.
- The composing secret store must retain one original candidate bearer through
  activation and enforce a minimum remaining-validity budget before adoption
  consume.
- The carrier store retains one immutable proof-v1 cutover manifest plus
  shrink-only tombstones and a mandatory minimum-writer schema until every listed
  reference drains.

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
- **An abandonment clears the only allocation watermark.** Active and pending
  legitimately become zero, so choosing the next epoch from those fields can
  reuse a burned value. The all-time carrier-epoch floor is durable, monotonic,
  bound into proof v2, and exercised across fresh-process reload.
- **An old candidate is rebound under a replacement controller.** Lifecycle and
  PTY equality do not transfer its handoff. Same-controller exact replay is the
  only retained path; changed-controller recovery first consumes one exact
  abandonment predecessor and allocates above its floor.
- **Bearer replay evicts a live pending transport.** Adopted-candidate recovery
  reuses the original token, so accepting it while the prior same-jti socket is
  live would let a stolen bearer displace the legitimate leg. Relay waits for the
  transport to be absent/closed; the opaque Platform correlation never widens
  bearer authority.
- **The retained bearer expires after consume.** Recovery may not remint equivalent
  claims. Enforce the orphan/recovery/activation validity margin before consume;
  below it, abandon while evidence is still unconsumed. After consume, loss or
  expiry is explicit reconciliation.
- **Rollback resnapshots surviving v1 rows.** That would reopen eligibility for a
  row already drained or introduced after cutover. The base manifest is one-time
  and store-bound, tombstones are append-only, and minimum-writer-schema refusal
  keeps unaware binaries out of the writer path.

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

**Add `abandoned` to proof schema v1.** Rejected: v1 declares a closed
four-disposition union and treats an unknown disposition as corruption. A merged
contract is a compatibility boundary even before activation. V1 remains the
decoder for exact retained same-handoff evidence; request/proof schema v2 is the
first schema that can carry abandonment and gates every new admission.

**Define retained v1 by timestamp, deploy generation, or an in-memory cutover
marker.** Rejected: none identifies the exact reservation/proof/credential bytes,
and restart or rollback can reopen the set. The fsync-backed store-bound manifest
is the authority; its tombstone ledger can only subtract.

**Represent abandonment as `empty` or erase the staged high-water.** Rejected:
`empty` means no durable stream history. The staged Snapshot is an exact journal
disposition and sequence allocation; zeroing or relabeling it fabricates a fresh
stream inside the same PTY epoch.

**Keep abandoned lineage only in carrier-private state.** Rejected: the signed
proof, WSS admission recheck, strict receipt, and adoption consume could not name
which burned candidate authorized the successor. Proof v2 carries the exact
single-use predecessor object and carrier-epoch floor; the content-addressed
abandonment result holds the old active binding without widening the proof.

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
- The durable proof resolver adds `Abandon`; a compatible carrier exposes the
  exact strict control-authenticated abandonment route beside Reserve. The
  composing authority persists request bytes before I/O and result bytes before
  allocating the successor. Diagnostics expose only a closed outcome/reason and
  bounded numeric revision/high-water: no control bearer, exact request/result
  bytes, request UUID/digest, proof/state/receipt/prepared-correlation digest,
  receipt revision, token/jti/nonce, store authority, or raw frame enters logs,
  traces, errors, room snapshots, heartbeat, status, or doctor output.
- The resolver also adds `FreezeV1Eligibility`; the store, not the daemon,
  produces the one manifest under its exclusive lock. A v1 row lookup takes the
  exact manifest entry/tombstone path and never tests wall clock or process build.
- The composing prepare hook adds a typed `adopted_candidate_recovery` result.
  It returns the exact retained bearer and H+1 cursor only after server-side
  consumed-adoption/current-authority resolution; the daemon never supplies a
  selector and the Relay never sees the opaque recovery correlation.
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
