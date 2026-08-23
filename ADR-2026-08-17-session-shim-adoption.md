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
quarantine contract, and migration law are OSS-canonical here; hosted relay,
restart-fence persistence, and control-plane reaper integration live in the
platform mirror)
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

### D3 — The stable local adoption wire has a v1/v2 overlap

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
message vocabulary. A v2-capable shim advertises `[1,2]`, a v2-capable daemon
selects the highest overlap, and both speak only the selected vocabulary. A new
daemon therefore still adopts a live v1 shim, and a new shim selected at v1
emits no v2 message. Renaming the family token or raising the minimum above 1 is
a later migration decision, not part of this correction.

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
able to adopt an older live v1 shim. A protocol bump therefore requires an
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

### D4 — Adoption is fenced and happens before readiness

On daemon start, for each compatible shim:

1. enter `recovering`; do not advertise ready capacity and do not poll/claim;
2. scan the registry directory, validating size, ownership, mode, schema,
   duplicate session identities, socket type, and PID/start identity;
3. authenticate `Hello`, including the exact shim/process correlation and that
   shim's current controller generation;
4. prepare any required carrier handoff and obtain its strictly greater
   `carrier_epoch` and opaque authenticator **before** serializing `Welcome`;
5. send `Welcome` with that shim's proposed next controller generation, replay
   position, and only the already-prepared extensions;
6. let the shim atomically advance its own `controller_generation` and require
   `Adopted` to echo the exact accepted generation/extensions;
7. request replay after the daemon's last durably forwarded sequence;
8. when the required external carrier admits on-demand snapshots, require
   selected protocol version 2 and prove one fresh authoritative inspect/emit
   round trip before presenting the controller as an attach host;
9. rehydrate external carrier credentials by `(org_id, session_id)`, authenticate
   and commit the prepared higher-epoch carrier handoff, then durably retain the
   adoption receipt;
10. resume external heartbeats only after carrier and controller ownership are
   established;
11. classify every remaining record as exited, stale, or quarantined; and
12. compute capacity from live adopted **plus quarantined** shims before
   advertising ready and resuming claims.

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

The daemon durably records only `last_forwarded_seq`; it never allocates or
renumbers host output. On adoption it asks for `last_forwarded_seq + 1`.

`Output.data` is the exact length-delimited byte slice read from the PTY master.
The shim, daemon callback, durable carrier handoff, and carrier ingress preserve
those bytes byte-for-byte and associate durability with the complete frame;
UTF-8 coercion, newline conversion, truncation, or decode-and-reencode is a
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
- adoption cannot prove a strictly newer controller generation.

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
| Machine reboots | Both daemon and shim processes die. Boot recovery consumes terminal/stale registry evidence before advertising capacity; external release still requires the ordinary terminal/reconciliation contract. |

### D11 — Migration is interactive-first and converges on one model

The rollout is additive:

1. Ship `session-shim-v1`, registry inspection, and adoption disabled.
2. Enable shim ownership for newly launched interactive PTY sessions behind a
   local compatibility gate. Existing direct-owned sessions drain; they are not
   transplanted across process boundaries.
3. Enable startup adoption and the real service-manager survival smoke. This
   includes unplanned recovery with no inherited local fence receipt; composing
   carrier state is resolved from the authenticated live correlation.
4. Enable the optional composing-plane restart fence only after every authority
   scope can return an exact-byte durable acknowledgement and every release,
   requeue, terminalization, host-loss, queue-repair, and administrative path
   reaches the same serialized predicate.
5. Make shim ownership the default for interactive sessions.
6. Extend the same ownership boundary to other long-lived session modes where
   restart continuity is required.
7. Delete the direct daemon-owned session path once no served mode depends on
   it.

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
19. **v1 overlap and carrier refusal.** Adopt a prior released v1 shim with the
    new daemon and prove its existing control/replay/terminal behavior remains
    available. Then require an external attach carrier with on-demand snapshots
    and prove the same v1 selection yields a visible capacity-charged carrier
    refusal, with no v2 message sent and no cache/fabricated snapshot fallback.
    A v2 shim under the same test must answer the carrier's takeover resync before
    the carrier is reported complete.

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
- The v2 controller proxy delegates both snapshot modes to the shim and preserves
  exact frame bytes. A cache may accelerate display of a known checkpoint but is
  not an implementation of either request mode.
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
