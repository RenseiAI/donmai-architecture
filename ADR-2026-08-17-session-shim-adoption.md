---
status: Proposed
date: 2026-08-17
boundary: shared
split: synchronized-mirror
---

# ADR-2026-08-17 — Per-session shim ownership and daemon adoption

**Status:** Proposed
**Date:** 2026-08-17
**Boundary:** shared (the per-session process boundary, local shim wire,
adoption protocol, sequence ownership, crash semantics, registry safety,
quarantine contract, and migration law are OSS-canonical here; hosted relay,
restart-fence persistence, and control-plane reaper integration live in the
platform mirror)
**Authors:** session-continuity design lane

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
   or re-key a session.
3. **Adoption before advertisement:** a starting daemon discovers and classifies
   every registry entry, adopts every compatible live shim, rehydrates its
   external carriers by session identity, and accounts for every quarantined
   shim before it advertises ready capacity or claims new work.
4. **Single controller:** every successful adoption advances a monotonic
   `controller_generation`. Every mutating controller frame carries that
   generation. The shim rejects stale generations, so an old daemon can never
   regain the input, resize, stop, or acknowledgement authority after a newer
   daemon adopts.
5. **Sequence truth:** the shim is the sole allocator of host output sequence.
   Adoption resumes from an acknowledged sequence. If the requested position
   has fallen out of the ring, the shim emits an explicit `Gap` followed by a
   snapshot; no daemon or carrier may invent missing output or reset sequence
   while claiming continuity.
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
9. **Fence before restart:** a planned daemon restart obtains a durable,
   acknowledged fence covering the exact adoptable session identities before
   stopping. While fenced, heartbeat, stale-claim, and session reapers may
   observe but may not release, requeue, or terminalize those sessions.
10. **Expiry is not proof of death:** fence expiry never releases a claim merely
    because time elapsed. Release requires an adopted live owner to report a
    terminal receipt, or a durable shim terminal tombstone proving the harness
    process group was reaped. Without either, the session and claim enter visible
    reconciliation quarantine.
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
- `controller_generation`: a monotonic fencing number advanced on adoption,
- PID and process start identity: diagnostic/janitor correlation,
- socket path and protocol range: discovery and negotiation.

None is a lifecycle identity. A new `shim_id` under the same session is not a new
session; two live shim ids claiming the same `(org_id, session_id)` are an
ambiguity that quarantines both until reconciled. A PID is never trusted without
its process-start identity because PID reuse is normal.

### D3 — `session-shim-v1` is a stable local adoption wire

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
                            generation, resume sequence, optional extensions
Adopted    shim -> daemon   accepted generation and exact replay disposition
Output     shim -> daemon   shim-owned sequence + raw bytes
Gap        shim -> daemon   missing inclusive range + closed reason
Snapshot   shim -> daemon   state after the gap or on request
Input      daemon -> shim   generation + attributed input bytes
Resize     daemon -> shim   generation + authoritative geometry
Stop       daemon -> shim   generation + typed reason
Heartbeat  both ways       liveness and acknowledged sequence
Exit       shim -> daemon   immutable terminal observation
Error      either way      closed code + display-only detail
```

`Welcome.extensions` is an optional, namespaced map. The OSS protocol defines
one generic `carrier_epoch` extension point for a composing carrier that needs
to fence its own connection generations. It does not name a relay, service, or
hosted endpoint, and an OSS-only daemon may omit it. Unknown optional extensions
are ignored; an extension declared required by either peer makes negotiation
fail closed when unsupported.

Protocol compatibility is based on an advertised min/max range and selected
version, never on daemon or shim binary version equality. A newer daemon must be
able to adopt an older live v1 shim. A protocol bump therefore requires an
overlap window long enough for the maximum supported session duration. Removing
that overlap requires a separate migration decision.

### D4 — Adoption is fenced and happens before readiness

On daemon start:

1. enter `recovering`; do not advertise ready capacity and do not poll/claim;
2. scan the registry directory, validating size, ownership, mode, schema,
   duplicate session identities, socket type, and PID/start identity;
3. connect and complete `Hello`/`Welcome` with every compatible live shim;
4. atomically advance `controller_generation` at the shim;
5. request replay after the daemon's last durably forwarded sequence;
6. rehydrate external carrier credentials by `(org_id, session_id)` and attach;
7. resume external heartbeats only after carrier and controller ownership are
   established;
8. classify every remaining record as exited, stale, or quarantined; and
9. compute capacity from live adopted **plus quarantined** shims before
   advertising ready and resuming claims.

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

### D9 — Planned restarts use a durable host-level adoption fence

Before a planned restart the daemon enumerates every adopted and quarantined
session and asks its composing control plane, when present, to persist a restart
fence. The request names the host, a fence id, the exact session identities and
shim correlation ids, issue time, and `hold_until`. The daemon waits for a
durable acknowledgement containing the same set before allowing the service
manager to stop it. If the acknowledgement does not arrive, the update is
refused and the old daemon keeps serving.

`hold_until` covers the planned restart budget, the shim orphan deadline,
termination grace, clock skew, and propagation margin. The fence is consumed by
every external path that can release a claim or terminalize a session, not just
one reaper. That includes stale pre-spawn recovery, step-heartbeat expiry,
session-duration/stuck reaping, host disappearance reconciliation, and queue
claim repair.

Fence expiry changes the state from `held` to `reconciliation_required`; it does
not release anything. A claim can be released only after the new daemon reports
either:

- a successful adoption followed later by an ordinary terminal receipt, or
- an adopted terminal tombstone proving the shim reaped the harness group.

If neither proof arrives, the host and session stay visible in quarantine. This
is the required invariant: **fence expiry must never release a claim while the
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
3. Enable startup adoption and the real service-manager survival smoke.
4. Enable the optional composing-plane restart fence only after every release
   path consults the same predicate.
5. Make shim ownership the default for interactive sessions.
6. Extend the same ownership boundary to other long-lived session modes where
   restart continuity is required.
7. Delete the direct daemon-owned session path once no served mode depends on
   it.

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
  one claim-release/terminalization predicate and write refusal tests at every
  caller; a per-reaper check recreates split-brain through the omitted path.
- **Registry ambiguity after crash.** Duplicate identities or stale PIDs can
  tempt cleanup code to kill the wrong process. Quarantine plus PID start-time
  verification is mandatory.
- **Ring miss is hidden by a carrier.** The shim emits a typed gap, but a carrier
  could still flatten it. The end-to-end gap smoke must assert the viewer-visible
  reset/snapshot outcome.
- **Protocol compatibility outlives testing.** A new daemon may compile against
  v1 while no fixture runs against the previous released shim. Release gating
  must retain at least one old-shim/new-daemon adoption fixture.

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

**Use only a hard adoption-gap bound and no restart fence.** Rejected: it works
only while every restart stays faster than every external stale threshold. A
slow package manager, service-manager backoff, or incompatible daemon converts
that performance assumption into split-brain. The acknowledged fence degrades
to quarantine instead.

## Affected documents

The following edits land only in the commit that flips this ADR to `Accepted`:

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
No affected reference document is edited while this ADR remains Proposed.

## Affected work items

The platform mirror carries the private tracker mapping. The delivery remains
blocked on this ADR's acceptance.

## Implementation notes

- Proposed OSS packages: `shimwire` (codec and closed message types),
  `sessionshim` (process/registry/adoption implementation), and a hidden
  `session-shim` binary mode. The exact package layout may change; the ownership
  and protocol boundaries above may not.
- `daemon.WorkerSpawner` becomes the composing point for a shim-backed proxy
  handle. It must not retain a second direct reference to PTY state.
- The shim reuses `ptyhost`, `provider/harness/ptycli`, `attachwire`, and the
  existing process-group stop semantics; it does not fork a second PTY stack.
- Registry writes use the injected state-directory seam. No brand-specific path
  is compiled into OSS.
- Release sequencing is OSS protocol/library first, composing binary second,
  platform fence/relay integration third, followed by the real installed-service
  smoke before default-on.
