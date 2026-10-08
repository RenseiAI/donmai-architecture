---
status: Accepted
date: 2026-10-07
boundary: shared
split: sibling-extensions
---

# ADR-2026-10-07 — Session-shim adoption for headless dispatched sessions

**Status:** Accepted 2026-10-08 (founder acceptance as drafted, including D8;
the six rulings are under "Decisions (founder, 2026-10-08)"). Architecture
only: implementation is pending. D8's gate, the acceptance of ADR-2026-08-31
D1 and D2, cleared on 2026-10-08 (see "Affected documents"). The corpus
edits listed under "Affected documents" landed in the accepting commit, with
two clarifications recorded under "Clarified at acceptance".
**Date:** 2026-10-07
**Boundary:** shared. OSS-canonical here: the headless workload profile of the
session shim, how a headless runner's dependencies on the live daemon behave
across a restart, the terminal-status outbox rule, the change to the restart
preflight, the composition with seat budgets, priority and confinement, the
test plan and the rollout. A hosted control plane's side (claim and lease
continuity when the daemon's worker registration changes, idempotency at its
terminal-status receiver, and fence consumption for headless rows) is described
here only generically. The concrete control-plane delta lands in the platform
corpus's mirrored stub when this ADR is accepted.
**Authors:** architecture lane, filed by the coordinator session.
**Extends:** [`ADR-2026-08-17-session-shim-adoption.md`](ADR-2026-08-17-session-shim-adoption.md)
D11 step 11 ("extend the same ownership boundary to other long-lived session
modes where restart continuity is required").

## Terms

- **Seat:** one headless dispatched session on a host: one `donmai agent run`
  worker process and the harness it drives over stdio pipes (claude with
  stream JSON, codex with its app-server JSON-RPC, pi with `--mode rpc`
  line-delimited JSON). None of them uses a terminal.
- **Direct-owned:** the daemon is the seat's parent. It holds the `exec.Cmd`,
  the stdio pipes and the reaper. This is how every headless seat runs today.
- **Shim-owned:** the seat was launched detached under the session-shim launch
  contract, publishes a discovery record and socket, and can be adopted by a
  replacement daemon. This is how interactive sessions run when ownership is
  enabled.
- **Adoption:** a replacement daemon finds a live shim, authenticates it,
  advances its controller generation, and takes over as its controller. In the
  recovery taxonomy of
  [`ADR-2026-08-31-session-recovery-taxonomy-and-state-vocabulary.md`](ADR-2026-08-31-session-recovery-taxonomy-and-state-vocabulary.md)
  D1 this is a **rebind**: the same process and the same incarnation regain a
  lost binding.

Code citations are to the `donmai` repository's main branch as of
2026-10-08 (after release v0.72.67 and the seat-budget, Linux confinement and
session-detail authentication changes that merged that night), in the form
`path:Symbol`, unless the text names an open pull request.

## Context

### What the corpus already decided

1. **One ownership model for every session class.** ADR-2026-08-17 makes the
   shim own the workload so that the daemon becomes a replaceable controller.
   Its Decision section says the first delivery is interactive-only and that
   the architecture "converges on this same ownership model for every session
   class that needs daemon-restart survival; it does not preserve a permanent
   second ownership model." Its D11 step 11 extends the same boundary to
   "other long-lived session modes", and step 12 deletes the direct
   daemon-owned path.
2. **Headless work is a session like any other.**
   [`ADR-2026-08-16-one-session-substrate-and-typed-event-spine.md`](ADR-2026-08-16-one-session-substrate-and-typed-event-spine.md)
   admits headless work as one kind in its closed admission union, with
   `(org_id, session_id)` as the only lifecycle identity and every process,
   shim or transport id an alias that can never create or end a session.
3. **Confinement belongs to the harness process.**
   [`ADR-2026-10-03-executor-os-confinement.md`](ADR-2026-10-03-executor-os-confinement.md)
   D4 rule 1 wraps the harness spawn, not the worker or the shim, and D4
   rule 5 states that "a confined process stays confined across a daemon
   restart and shim adoption, because the boundary belongs to the process."
4. **A running session keeps what it was admitted with.**
   [`ADR-2026-10-05-set-broad-enforce-the-minimum.md`](ADR-2026-10-05-set-broad-enforce-the-minimum.md)
   D1 (R1) rule 3 computes effective limits at admission and never
   re-evaluates them for a running session.

### What the code does today

**Interactive sessions survive a restart; headless seats do not.**

- The shim is not a separate binary. `daemon/session_shim_spawn.go:startShimProcess`
  runs the ordinary worker command (`daemon/session_shim_spawn.go:shimCommand`,
  which defaults to `<self> agent run`) with the launch contract in its
  environment (`sessionshim/launch.go:Launch.Env`), detaches it into its own
  session (`daemon/session_shim_process_unix.go:configureShimProcess` sets
  `Setsid`), points stdout and stderr at a per-session log file rather than a
  daemon pipe, pins the child's PID and start time, and releases the process.
  Inside that worker the PTY driver reads the contract and becomes the shim in
  process (`provider/harness/ptycli/handle.go:spawnSessionOwned` calls
  `sessionshim.LaunchFromEnv` and `sessionshim.StartOwnedFromEnvWithRoot`). The
  runner loop runs in the same process. **The worker process is the shim.**
- Selection is interactive-only. `daemon/session_shim_spawn.go:shimOwnsSession`
  requires `spec.Mode == "interactive"`, and its comment records the reason:
  "A headless worker that dies with its daemon is re-dispatched; a human's
  terminal is not."
- A headless seat takes the direct path, `daemon/worker_spawner.go:(*WorkerSpawner).spawn`.
  The daemon puts the worker in its own process group only
  (`daemon/process_group_unix.go:configureSessionProcessGroup` sets `Setpgid`),
  reads its stdout and stderr through `os.Pipe` pairs it owns, and is the
  worker's reaper. That is enough to kill the seat on any restart, by one of
  three routes:
  - *graceful stop:* `Daemon.Stop` drains, and on timeout
    `daemon/worker_spawner.go:(*WorkerSpawner).DrainContext` sends SIGTERM to
    every remaining seat's process group;
  - *systemd:* the unit's default control-group kill reaches the seat, because
    a process group does not leave the unit's cgroup;
  - *launchd:* the job's `AbandonProcessGroup` leaves the seat running, but its
    stdout and stderr pipes lose their reader. The runner logs to stderr, and a
    Go program that writes to a broken pipe on file descriptor 1 or 2 is killed
    by SIGPIPE. The in-repo comment on
    `daemon/session_shim_spawn.go:runShimChildLogGuard` records that hazard
    and is why the shim path uses a log file instead.
- In hosted mode nothing finds a surviving seat afterwards. Startup adopts
  shims only, a seat that did survive is absent from the session list and from
  capacity, and its next session-detail read gets a 404.
- The shim itself is PTY-shaped. `sessionshim/shim.go:Start` listens on the
  socket, then calls `ptyhost.Spawn`, then publishes the record and arms the
  orphan deadline. `Shim.sess` is a concrete `*ptyhost.Session`, and every
  observation frame from wire version 3 onward is an interactive-attach frame
  (`shimwire/payloads.go:validateHostFrame` accepts Output, Resize, Marker,
  Snapshot and Exit only). The parts that are not PTY-shaped are identity, the
  registry, the generation fence, the orphan policy, the tombstone and
  quarantine.

**The planned-restart preflight refuses while any headless seat runs.**
`daemon/restart_preflight.go:(*Daemon).prepareRestartWithLease` enters
`draining`, settles spawn reservations, and then refuses with "%d direct-owned
session(s) remain outside session-shim coverage" whenever
`spawner.ActiveSessionCounts()` is non-zero. Shim-owned sessions never enter
the spawner's session map (`daemon/worker_spawner.go:(*WorkerSpawner).spawnThroughShim`),
so that count is exactly the direct-owned sessions: every headless seat, plus
legacy interview sessions.

**Recovery holds surviving headless work; it never adopts it.** In the
standalone local runtime, `daemon/local_runtime_recovery.go:(*localRuntime).recover`
passes every session that needs recovery to `hold`, which records it as
`SessionUnknown` ("a local observation of unresolved execution ownership"),
upgraded to `SessionRunning` only when the recorded PID and start identity
still match, with the reason "execution ownership requires reconciliation".
Nothing reattaches to the process. The local runtime also refuses to run with
the session shim at all: `daemon/daemon.go` rejects that combination because
"local file runtime supports direct headless execution only".

**What a running headless runner needs from the live daemon.** The runner
reads its whole `SessionDetail` once at start from `GET /api/daemon/sessions/<id>`
on the daemon's loopback control port (`afcli/agent_run.go:fetchSessionDetail`,
served by `daemon/server.go:handleSessionDetail`;
`daemon/session_detail.go:SessionDetail`). After that:

- *Credential refresh.* Every credential use re-reads the detail
  (`afcli/agent_run.go:(*agentRunCredentialCache).current`), and the daemon
  stamps refreshed tokens into its store with
  `daemon/session_detail.go:(*sessionDetailStore).UpdateRuntimeCredentials`.
  The read is authenticated by a per-session read token that the store mints
  at acceptance and the spawner passes in `DONMAI_SESSION_READ_TOKEN`
  (`daemon/session_detail.go`, `verifySessionReadToken`); without it the route
  returns the detail with every credential cleared. The store and its read
  tokens are in memory and are written only at acceptance (`StoreIfAbsent`,
  called from `daemon/daemon.go`); no adoption path repopulates them. After a
  restart the re-read therefore gets a 404 or a redacted detail, never a new
  bearer. The heartbeat, activity and
  result posters fall back to the last bearer they hold
  (`runtime/heartbeat/pulser.go`, `runtime/activity/poster.go`,
  `result/poster.go`); the execution-event uploader returns an error instead
  (`runtime/executionevent/uploader.go`). The runtime bearer is refreshed
  roughly hourly, so a seat that survived a restart would run on its last
  bearer until that expires. This gap already applies to adopted interactive
  sessions, because their runner uses the same cache.
- *Other refresh rails.* A private token file that a provisioning daemon may
  rewrite (`runner/mcp_gateway_token_file.go`; the OSS daemon does not rewrite
  it today) and, for interactive sessions, the attach token file
  (`runner/interactive_loop.go:attachTokenSource`). The `credentials-client`
  socket protocol is not on the seat path: `agent run` never constructs a
  loader, and its only importer is the pi confinement code, which denies the
  socket as a model endpoint.
- *Session lease heartbeat and memory inject.* The runner's heartbeat pulser
  posts the lock refresh itself every 30 seconds (`runtime/heartbeat/pulser.go`;
  wired in `runner/loop.go` step 9), and runtime memory-inject blocks arrive on
  that lock-refresh response (`runner/loop.go` step 8b). Three failed ticks, a
  `refreshed:false` answer or `stop:true` fire `LostOwnership`, and a headless
  run then ends with the `lost-ownership` failure mode (`runner/failure.go`);
  interactive sessions are exempt from that fuse. A separate 15-second step
  heartbeat also goes straight to the control plane. In the hosted case none of
  this passes through the daemon. In the standalone local runtime the same
  routes land on the daemon's local receiver (`daemon/local_runtime_http.go`,
  route `lock-refresh`), which grants no inject authority.
- *Operator stop.* Besides the lease's `stop` field, the daemon can stop a seat
  through `POST /api/daemon/sessions/<id>/stop` or a `session.kill` mutation
  (`daemon/mutation_apply.go`, `ForceKillSession`). Both need the daemon that
  owns the child.
- *Terminal status.* The runner posts its terminal status itself
  (`result/poster.go:(*Poster).PostWithOptionsOutcome`), with three attempts and
  no idempotency key. Only for a completed run whose dispatch carries a
  terminal workarea lease does it capture an immutable body first
  (`result/poster.go:(*Poster).PrepareTerminalStatusBody`), record delivery
  (`runner/runner.go`, `MarkTerminalStatusDelivered`), and leave undelivered
  bytes for the daemon's replayer (`afcli/daemon_run.go` starts
  `runtime/workarea/lease.go:(*LeaseStore).RunTerminalResultReplayer`). That is
  the `donmai.terminal-status-outbox.v1` record of
  [`ADR-2026-07-18-bounded-terminal-workarea-leases.md`](ADR-2026-07-18-bounded-terminal-workarea-leases.md)
  D6. A failed or cancelled run gets no outbox record, so a post that fails
  until the runner exits is lost. The standalone receiver is already
  idempotent: `internal/localqueue/transactions.go:(*Store).CommitTerminal`
  returns the original receipt for an exact replay and a conflict for a changed
  body.

**Spawn-time credentials are frozen in the environment.** The daemon composes
the worker environment (`daemon/worker_spawner.go:sessionEnv`) and layers
per-session credentials through the `OnPreSpawn` rail; the standalone runtime
adds a per-attempt bearer that it persists durably
(`internal/localruntimeauth/credentials.go:(*Store).CreateAttempt`, checked by
`VerifyAttempt`). Two merged changes tightened this: donmai pull request 806
moved the last argv-borne token (the fleet child's provisioning token) into the
environment and the claude MCP header helper's bearer into an owner-only file,
and pull request 812 moved pi's model credentials out of the harness child's
environment into an owner-only per-session file
(`provider/harness/pi/credential_file.go`), removed at session end. The worker
also unsets its read token after the first detail read. Once a process has
started, its environment cannot be changed from outside.

**Service-manager kill scope.** The generated launchd job sets
`AbandonProcessGroup` (`installer/launchd/installer.go`). The generated
systemd unit sets no `KillMode` and no `Delegate` (`installer/systemd/installer.go`,
`[Service]` block), so systemd's default control-group kill reaches every
process in the unit's cgroup on stop, whether or not it called `setsid`.
ADR-2026-08-17 D1 already requires that "the equivalent unit posture must kill
the daemon process, not the adopted shim cgroup"; the generated unit does not
meet that yet.

### Why this matters now

A seat runs for tens of minutes to hours. Because the preflight refuses while
any seat runs, a planned upgrade of a seat host must first drain it: stop
claiming, then wait for the longest seat to finish. On 2026-10-07 one seat-host
upgrade waited about two hours in a soft drain for exactly this reason. An
unplanned daemon crash is worse: the seats die with the daemon and their work
is re-dispatched from the start. The cost of a restart grows with seat length.

## Decision summary

Headless seats become shim-owned through the same mechanism interactive
sessions already use: the worker process is launched detached under the
launch contract and hosts the shim in process. A new **headless workload
profile** of the shim wire carries ownership, the generation fence, liveness,
stop, credential refresh and the terminal observation, and nothing
terminal-shaped. The runner keeps its direct control-plane legs; the
daemon-local legs move onto the fenced shim connection or reconnect to the same
local address. Every shim-owned seat writes its terminal status to the durable
outbox before the first send. The restart preflight counts shim-owned seats as
covered. A seat that cannot be adopted is stopped and later resumed as a new
incarnation when its harness has a verified resume artifact; only the seats
that can be neither adopted nor resumed still need the soft drain.

| # | Decision | Chosen option |
|---|---|---|
| 1 | Process ownership | The worker process hosts the shim in process, as interactive does; no PTY, no byte proxy (D1, Option C) |
| 2 | Runner dependencies on the live daemon | Control-plane legs stay direct; credential refresh is pushed over the fenced shim connection; local callbacks reconnect to the same address; no proxy in the shim (D2) |
| 3 | Exactly-once terminal result | Outbox before first send, exact-byte replay, receiver dedupe by session attempt plus body digest, release only on durable terminal evidence (D3) |
| 4 | Adoption identity and lineage | ADR-2026-08-17 D1 to D10 unchanged; a new selected wire version that headless shims advertise exclusively; one closed `workload` field in the record (D4) |
| 5 | Composition with budgets, priority and confinement | On systemd every shim-owned seat starts in its own transient scope, which is both the survival boundary and the budget cgroup; priority and budget are fixed at launch; confinement stays at the harness spawn (D5) |
| 6 | Test plan | Real-binary upgrade of a live seat in a Linux container, a launchd smoke on macOS, and a failure matrix (D6) |
| 7 | Rollout and fallback | Adopt-capable daemon first, consumer side second, per-host launch gate third; preflight refuses only for seats that can be neither adopted nor resumed, with a drain mode for exactly those (D7) |
| 8 | Seats that cannot be adopted (founder decision 6) | Cooperative stop for resume, a parked fence row, and a new incarnation seeded from a verified harness artifact; one session terminal across incarnations; the stop is uncharged; adoption always wins where it applies (D8) |

## D1 — Process ownership

### Options

**Option A — a non-PTY shim around the harness.** A small shim owns the
harness process and its stdio pipes, sequences the harness's stdout into a
ring, and lets a replacement runner replay the ring to rebuild its state.

- For: it mirrors the interactive design most literally (the shim owns the
  workload's byte stream).
- Against: the runner holds most of a seat's state in memory: the turn loop,
  the request and response correlation on the harness channel, cost and usage totals, the
  completion contract, the stall and idle timers, the pull-request delivery
  backstop, the WIP checkpoint. Rebuilding that from a replayed byte log is a
  second implementation of the runner that must agree with the first. The pi
  and codex channels are bidirectional, so the shim would also have to proxy
  writes.
  This is the "persist bytes and reconstruct in the new process" design that
  ADR-2026-08-17 rejected for terminals, for the same reason: it fabricates
  continuity.

**Option B — a separate supervisor process that parents the runner.** A new
small binary is launched detached, writes the record, speaks the shim wire,
and runs `agent run` as its child.

- For: the supervisor can be tiny and change rarely.
- Against: it adds a third process per seat and a second launch path that the
  interactive design does not use. Every daemon-local dependency of the runner
  (credentials, callbacks) would either cross the supervisor, making it a
  credential-handling proxy, or bypass it, which removes the reason it exists.
  The supervisor also cannot observe the runner's terminal outcome without a
  new runner-to-supervisor protocol.

**Option C — the worker process hosts the shim in process (recommended).** The
daemon launches the headless worker exactly as it launches an interactive one
(`startShimProcess`: detached session, log file, pinned start identity,
released process). The headless driver reads the launch contract and starts a
headless shim in process: socket, registry record, generation fence, orphan
deadline, tombstone. The runner loop and the harness's stdio stay where they
are today, inside that process.

- For: it is the mechanism already built for interactive sessions, so
  launch, discovery, peer authentication, fencing, quarantine, orphaning,
  tombstones and the restart fence are reused rather than re-specified. The
  harness stdio needs no proxy. The runner's terminal outcome is local to the
  process that writes the tombstone.
- Against: the shim lives in a large binary, not a small one. ADR-2026-08-17 D1
  describes the shim as "deliberately small and version-stable". In practice
  version stability comes from the process never changing once started and from
  the wire range negotiated in D3 of that ADR, not from the binary size; the
  interactive shim already runs the whole runner. This ADR states that
  explicitly so the two documents agree. The cost is that the shim process
  holds the runner's control-plane bearer, as an interactive shim already does
  today; the discovery record still holds none.

### Chosen: Option C

The headless driver gains the same "launched with the contract, so become the
shim" branch that `provider/harness/ptycli/handle.go:spawnSessionOwned` has for
PTY sessions, with three differences:

1. **No PTY host.** The headless shim owns the runner's process group and,
   through it, the harness process group the driver already creates (for
   example `provider/harness/pi/process_unix.go` sets `Setpgid` on the pi
   child). Its terminal observation is the runner's own exit, after the harness
   group is proved gone.
2. **No host output stream.** The runner's events, activity and spans go to the
   control plane directly, as today. Nothing is sequenced through the daemon,
   so there is no ring, no replay, no Gap and no Snapshot.
3. **Same detached launch.** stdout and stderr go to the per-session log file
   `startShimProcess` already opens, so the replacement daemon can keep showing
   the seat's log by reading the file.

`shimOwnsSession` selects headless seats only when the per-host gate in D7 is
on and the host passes the kill-scope requirement for its service manager (D5).
Everything else keeps the direct path until D7's last step deletes it.

## D2 — Runner dependencies on the live daemon

### Options

**Option A — the shim proxies every daemon connection.** The runner talks only
to its shim; the shim forwards to whichever daemon is current. Under Option C of
D1 the shim and the runner are one process, so this reduces to "the runner
talks to the daemon through the shim socket". It would move the credential
re-read and the local callbacks onto the shim wire.

**Option B — the runner reconnects to the replacement daemon.** Every
dependency stays where it is; the runner retries against the same local address
until the new daemon answers, and the new daemon rebuilds whatever per-seat
state it needs to answer.

**Option C — split by what each dependency is (recommended).** Legs that talk
to the control plane stay direct. The one daemon-to-runner push that carries
authority, credential refresh, moves onto the fenced shim connection. Local
callbacks that carry no authority reconnect.

### Chosen: Option C

| Dependency | Today | During the restart gap | After adoption |
|---|---|---|---|
| Session detail at start | Read once at spawn | Not needed | Not needed; the runner already holds it |
| Credential refresh (hosted bearer and worker id) | Re-read from the daemon's in-memory store on every use | Runner keeps its current bearer | Pushed by the new controller over the shim connection (below) |
| Standalone per-attempt bearer | Durable on disk (`localruntimeauth`) | Unchanged | The new daemon verifies the same bearer from disk; nothing to re-deliver |
| Session lease refresh, step heartbeat and memory inject (hosted) | Runner to control plane directly | Continue while the bearer is valid | Continue; present the new registration once pushed |
| Session lease and status routes (standalone) | Runner to the daemon's local receiver | Fail and are retried with bounded backoff | The new daemon serves them from its durable queue |
| Terminal status | Runner to receiver directly | Runner sends directly; on failure the outbox holds it | Daemon replays from the outbox (D3) |
| Token file a provisioner rewrites | Path in the seat's environment | File keeps its last content | Whoever rewrites it resumes on the same path, derived from session identity |
| Operator stop | Lease `stop` field, the daemon's per-session stop route, or a `session.kill` mutation | Lease `stop` still arrives | The daemon routes become a generation-fenced `Stop` over the shim connection |

**Credential refresh moves onto the shim connection.** The headless profile
adds one daemon-to-shim message, `CredentialUpdate`, carrying the controller
generation and the new worker id, bearer and expiry. It is a mutating frame:
the shim rejects it unless its generation matches the adopted controller's, so
an old daemon that comes back can never overwrite a newer credential. The
controller sends it after every routine refresh and once immediately after
adoption, before the host reports ready. A shim-owned runner's credential
provider reads the last pushed value and no longer re-reads the HTTP detail.

Two alternatives were weighed and rejected. Rehydrating the HTTP detail store
on adoption would need the daemon to persist or re-derive the full
`SessionDetail` (issue context, prompt material, bearers) for every live seat,
which is the kind of state ADR-2026-08-17 D6 keeps out of every on-disk shim
record. Proxying everything through the shim (Option A) adds nothing for legs
that do not involve the daemon at all. The shim connection is a Unix socket
restricted to the daemon's user, checked by peer credentials and process start
identity (ADR-2026-08-17 D3) and fenced by generation (D4 of that ADR). Those
are the properties a bearer push needs. The loopback detail route
authenticates a bearer, not a peer process, and its read tokens die with the
daemon that minted them.

**What freezing credentials in the environment implies for adoption.** The
environment is fixed when the worker execs. Adoption therefore cannot, and must
not try to, re-deliver anything through the environment. The spawn-time value
is the floor credential the seat starts with; anything that must outlive a
restart needs one of the refresh rails above. The record and the tombstone
never copy an environment value. The environment stays readable by processes of
the same user, which is the local trust boundary ADR-2026-08-17 D3 already
accepts for the shim socket.

**The runner treats a missing daemon as degraded, not fatal.** A failed
re-read or a refused local callback is retried with bounded backoff and logged.
It never ends the seat on its own. Every poster falls back to its last bearer,
including the execution-event uploader, which today returns an error instead.
The seat's bound on running without a controller is the orphan deadline in D4.
The lease fuse is unchanged: a hosted seat whose bearer expires before a
replacement daemon pushes a new one loses its lease after three failed ticks
and ends as `lost-ownership`, writing its outbox record and tombstone on the
way out (D3). With an hourly bearer that only bites when the daemon stays away
for most of an hour. The founder kept the lease with the runner (decision 2);
D8 covers a restart that is expected to take longer.

**This also closes a gap for interactive sessions.** Adopted interactive
sessions use the same credential cache and have the same empty-store problem.
`CredentialUpdate` is added to the interactive profile in the same release
(decision 5), as a new selected version of that profile.

## D3 — Exactly-once terminal result delivery

### Options

**Option A — keep today's split.** Retain an immutable body only for a
completed run with a terminal workarea lease, and post without retention
otherwise.

**Option B — the daemon owns terminal reporting for shim-owned seats.** The
runner writes its result locally; only the daemon reports it.

**Option C — outbox before first send for every shim-owned seat
(recommended).** The runner always prepares the immutable terminal-status body,
persists it in the existing terminal-status outbox, and only then sends it.
Whoever holds the record later replays the exact bytes.

Option A loses a terminal status whenever the post fails and the process exits
before a retry, which is precisely the window a restart opens. Option B makes a
seat's completion depend on a daemon that may be mid-upgrade, and throws away
the runner's working direct leg.

### Chosen: Option C

1. **Persist, then send.** A shim-owned runner calls
   `PrepareTerminalStatusBody` for every terminal status (completed, failed or
   cancelled), writes the body into the `donmai.terminal-status-outbox.v1`
   record whether or not a terminal workarea lease applies, and only then sends
   it. The record is keyed by the session's lifecycle identity and attempt, and
   carries the body digest (the runner's existing `stableTerminalResultID`
   already digests the session id and result). Adoption is a rebind, so it
   never creates a second attempt.
2. **Record delivery in the tombstone.** When the runner exits, the shim's
   terminal observation names the outbox record and its state (`delivered` or
   `pending`). The headless tombstone carries the same two fields beside the
   existing exit code, signal and `groupReaped`.
3. **Replay exact bytes.** A replacement daemon that adopts a tombstone with a
   pending record hands it to the existing replayer
   (`RunTerminalResultReplayer`), which sends the identical bytes with fresh
   header credentials. Body fields, including the worker id, are never
   rewritten.
4. **Receivers deduplicate.** A receiver that has durably accepted a terminal
   status for a session attempt returns the original receipt for an exact
   replay of the same bytes and a conflict for different bytes. The standalone
   receiver already does this (`CommitTerminal`). The runner sends no
   idempotency key today, so a hosted receiver must define the same exact-replay
   contract before any hosted seat is shim-owned (D7 step 2).
5. **One fallback writer.** If the shim process dies without writing a terminal
   record, the replacement daemon follows ADR-2026-08-17 D10 ("Shim exits
   unexpectedly"): it proves the harness group gone, then creates one failure
   record (cause `worker_exited_without_result`) in the same outbox. Creating
   the record is first-writer-wins on the outbox key, so a runner record that
   lands first is never overwritten.
6. **Release only on durable terminal evidence.** Claim release, requeue and
   workarea release follow ADR-2026-08-17 core contract rule 10 unchanged: an
   ordinary terminal receipt or a group-reaped tombstone. A missing process, an
   elapsed deadline or a shim-absent attestation never releases.

**Claim and lease continuity across an upgrade.** The claim belongs to the
session, not to the daemon process.

- During the gap, a hosted runner keeps refreshing its session lease directly,
  so a stale-claim reaper that reads the session lease sees a live seat. A
  planned restart also fences the seat (D7), so no reaper may release it even
  if the lease lapses. A control plane whose stale-claim reaping keys on the
  daemon's worker heartbeat instead, which stops during the gap, must consult
  the session lease or the fence before releasing; that belongs to the
  platform delta.
- A replacement daemon may come back with a new worker registration; the
  registration id is a replaceable correlation (ADR-2026-08-17 D2). The adopting
  daemon pushes the new worker id and bearer to the runner (D2), so later lease
  refreshes present the new registration.
- The hosted control plane must accept a lease refresh and a terminal status for
  an adopted lineage from the replacement registration of the same stable host,
  keyed on `(org_id, session_id)` and the adoption batch, not on equality with
  the worker id that claimed the work. That is a control-plane delta and lives
  in the mirrored stub.

## D4 — Adoption identity and lineage

ADR-2026-08-17 D1 to D10 apply to headless shims unchanged, with the
adjustments below. Nothing here touches its identity, fencing or release rules.

- **Identity (that ADR's D2).** `(org_id, session_id)` is the only lifecycle
  identity. `shim_id`, `process_epoch`, PID and start identity, and the per-shim
  `controller_generation` are correlation and fencing values only. Two live
  records for one identity quarantine every record. Adoption keeps the same
  incarnation; `process_epoch` does not advance on adoption.
- **Wire (that ADR's D3).** Same socket location and modes, same peer-credential
  and start-identity checks, same `session-shim-v1` family token. The headless
  profile is a new selected version, called H here; acceptance fixes H = 6
  (`protocol/session-shim-v6.md`). It keeps the v1 control messages (Hello, Welcome, Adopted,
  Stop, Heartbeat, Exit, Error), adds `CredentialUpdate`, and refuses every
  PTY-shaped message (Output, Input, Resize, Snapshot, SnapshotRequest,
  HostFrame, AttributedInput, Checkpoint) with a typed error. **A headless shim
  advertises the range `[H, H]`.** A daemon that predates H has no overlap,
  so it quarantines the shim as `protocol_mismatch`, never treats it as a PTY
  session, and never kills it. Interactive shims keep their existing range.
  ADR-2026-08-17 D3 says raising the minimum above 1 is a later migration
  decision for the family; that concern is about keeping released interactive
  peers adoptable, and a new workload class has no released peers to keep.
- **Adoption order (that ADR's D4).** Steps 1 to 16 apply. The carrier, proof,
  replay and activation steps (5, 8, 9 and 14) are no-ops for a headless shim.
  Headless lineages appear in every adoption batch and every heartbeat
  projection, with `workload: headless`.
- **Sequence (that ADR's D5).** No host output stream exists, so there is
  nothing to sequence, replay or declare missing. Exit is the only terminal
  observation; it is immutable, delivered once per controller, and
  acknowledged by a generation-fenced acknowledgement before the shim stops
  waiting, as an interactive Exit is. `protocol/session-shim-v6.md` fixes the
  exact form (`HeadlessExit`). A headless
  shim is never offered to an external attach carrier; it is not quarantined
  for lacking one either.
- **Registry (that ADR's D6).** A headless record gains one closed field,
  `workload: headless`, and schema version 2; an interactive record is
  unchanged (absence means `pty`) so that older daemons still decode it. The
  record's strict decoder (`sessionshim/record.go`, `DisallowUnknownFields`)
  makes an older daemon classify a headless record as malformed and
  quarantine it (`record_malformed`), which is the safe outcome. The record
  stays secret-free.
- **Quarantine (that ADR's D7).** Unchanged. Quarantined headless shims charge
  capacity and appear in host status and the heartbeat.
- **Orphan deadline (that ADR's D8).** Unchanged contract and defaults
  (`sessionshim/orphan.go`: 15-minute deadline, 5-second termination grace,
  30-second margin, and the startup inequality against the external release
  threshold). At expiry the headless runner stops the harness group, finalizes
  its outbox record with cause `orphaned`, tries one direct delivery if its
  bearer is still valid, writes the tombstone and exits. A headless seat can
  report its own terminal status with no daemon at all, which an interactive
  shim cannot.
- **Restart fence (that ADR's D9).** Headless rows join the same frozen snapshot
  with `lastForwardedSeq` zero.
- **Gate versus adoption.** The per-host gate in D7 controls launching new
  headless shims only. Any daemon that understands H adopts every compatible
  headless shim it finds, with the gate on or off.

## D5 — Composition with seat budgets, priority modes and confinement

**The kill scope comes first.** A shim-owned seat survives only if stopping the
daemon's service does not kill it.

- launchd: the generated job already sets `AbandonProcessGroup`, and the shim
  calls `setsid`. ADR-2026-08-17 D1 still requires a real launchd smoke before
  adoption is enabled on macOS.
- systemd: `setsid` does not leave a cgroup, and the generated unit uses the
  default control-group kill. **Every shim-owned seat on systemd therefore
  starts in its own transient scope**, created at launch under the same systemd
  manager that runs the daemon unit (the user manager for a user install, the
  system manager for a system install). The scope is outside the daemon unit's
  cgroup, so stopping the unit does not reach it.
- Other service managers and other operating systems keep headless shim launch
  off until a process-survival fixture exists for them (that ADR's D1).

**The per-seat budget uses the same scope.** The merged seat-budget change
(donmai pull request 804) already prefixes the worker command with
`systemd-run [--user] --scope --collect` and the budget's limits
(`daemon/seatbudget/cgroup.go:SystemdScopeArgsForBus`), on the direct path
(`daemon/worker_spawner.go:(*WorkerSpawner).spawn`) and on the shim path
(`daemon/session_shim_spawn.go:startShimProcess`). It picks `--user` from a
live bus probe (`SystemdUserScopeForEUID`), needs systemd 252 or later
(`MinScopeSystemd`), and names the unit from the session id
(`ScopeName`, `donmai-seat-<id>.scope`, cut to 64 characters). Three things in
it do not yet meet this ADR:

- the scope exists only when an operator configured a seat budget
  (`daemon/seat_budget.go:resolveSeatBudget` returns nothing otherwise), so a
  shim-owned seat with no budget stays in the daemon unit's cgroup;
- a host that cannot create the scope runs the seat unwrapped and reports
  `none`, rather than refusing; and
- the reported budget is derived from configuration and the placement probe,
  not read back from the seat, and adopted shim handles report the daemon's
  current budget (`daemon/session_shim_spawn.go:sessionShimHandles`), not the
  one the seat got.

Under this ADR:

1. Every shim-owned seat on systemd starts in its own scope, budget or not.
   With a budget the scope carries the limits; without one it carries none but
   still takes the seat out of the daemon unit's cgroup. This applies to
   interactive shims too (founder decision 5).
2. A host that cannot create the scope does not launch headless shims; the
   gate in D7 stays off there. A seat is never launched as an unscoped shim on
   systemd.
3. The scope name is derived from a fixed-length digest of the session
   identity and the incarnation number, like the registry file names
   (ADR-2026-08-17 D6), so two sessions can never collide on a truncated id and
   a resumed incarnation (D8) never meets its predecessor's scope.
4. The launching daemon records the limits the seat got in a secret-free
   launch record beside the discovery record. An adopting daemon reports the
   limits it reads back from the seat's cgroup, falling back to that launch
   record, and never its own current configuration.
5. Adoption never changes a running seat's limits, in line with ADR-2026-10-05
   D1 rule 3. A budget change applies to new seats only.
6. The scope is collected by systemd when its last process exits. No daemon
   ever stops a scope to make an upgrade fit.

On hosts without a usable systemd, the worker-cap environment values
(`GOMAXPROCS` and the build-job counts,
`daemon/seatbudget/budget.go:WorkerCapEnv`) are set at launch and stay with the
process; off Linux an enforced budget degrades to best-effort, as the merged
code already reports.

**Priority modes are fixed at launch.** The daemon's service priority mode
(`installer/servicepriority`, merged in donmai pull request 800) is applied to
the daemon service and inherited by children at fork. A shim-owned seat
inherits the mode current at its launch. A later mode change applies to seats
launched afterwards; adoption does not renice a running seat. Host status
reports each seat's observed priority. Inheritance through a transient scope
and through an abandoned launchd process group is to be shown by the D6
fixtures, not assumed.

**Confinement stays at the harness spawn.** The merged Linux backend (donmai
pull request 807) launches the harness through bubblewrap with
`--unshare-user --unshare-pid --die-with-parent` and a tmpfs root, then a
Landlock stage that re-executes the donmai binary before the harness
(`runtime/confinement/backend_linux.go:mountNamespaceFlags`,
`runtime/confinement/stage_linux.go`). It shares the network namespace, is
applied by the pi adapter only when confinement is requested
(`provider/harness/pi/pi.go:confinerForSession`), and refuses the spawn when
the backend, its self-test or the nested-sandbox check fails. The macOS
profile wraps the same spawn. Both sit inside the runner, as ADR-2026-10-03 D4
rule 1 requires, so the headless shim, which is the runner process, stays
outside the boundary and keeps writing its record, tombstone and outbox under
the host state home. The boundary belongs to the harness process and survives
adoption (that ADR's D4 rule 5). `--die-with-parent` ties the launcher to the
runner, and killing the launcher ends the PID namespace and everything in it,
which is the right lifetime: if the shim process dies, the harness dies, and
the D10 janitor proves the group gone. A resumed incarnation (D8) is a new
process, so it re-renders and re-applies confinement, with the self-test
re-run if the harness binary changed. The transient scope must not add
namespace hardening of its own, or the backend's nested-sandbox check refuses
the seat.

So the seat process is the right boundary for the budget, because a cgroup has
to contain every process the seat starts, and the wrong boundary for
confinement: a confined shim could not write its record, tombstone and outbox
outside the workarea, and ADR-2026-10-03 D4 rule 2 forbids a profile around the
worker on macOS because it would make the harness's own profile impossible.

**Per-session scratch directories.** The open per-session scratch-directory
change (donmai pull request 797) creates the directory on both launch paths and
records it on disk. After adoption the claim must be rebuilt from that record;
in that change an adopted shim's claim is empty after a restart, so the
directory would be reclaimed only by the next startup sweep. The headless work
closes that gap for both workload profiles.

**Stalled-request retry.** The merged stalled-request retry (donmai pull
request 803; off by default) watches the harness event stream inside the
runner and has no relation to daemon liveness. It composes with adoption
unchanged. Its recovery step, `runner/steering.go:resumeWithDirective`, which
resumes the provider-native session with a directive, is the primitive D8's
resumed incarnation reuses for its first turn.

## D6 — Test plan

Each test below counts as evidence only after it has been watched failing,
against the direct-owned path or with the behaviour it guards removed
(`agents/PROTOCOL.md` § V).

**The acceptance test: a live seat across a daemon upgrade, in a container.**

1. Build two daemon artifacts, N and N+1, where N+1 differs in version string
   and in one harmless behaviour the test can observe.
2. Start a Linux container that runs systemd with a delegated cgroup v2
   hierarchy. Install N as a user service with the generated unit. Configure
   the standalone local runtime, so no control plane is involved. This needs
   the local runtime's refusal to run with the shim lifted for headless seats
   (D7 step 1); the OSS layer must ship a working implementation without a
   control plane, and the local runtime is that implementation.
3. Dispatch one headless seat whose harness is a scripted fake that speaks the
   pi `--mode rpc` line protocol on stdio, emits events, and waits on a
   trigger file.
   Give the seat a budget and enable confinement.
4. Call `POST /api/daemon/restart/prepare`; expect `prepared`. Replace the
   binary with N+1 and restart the unit through systemd.
5. Assert: the worker's PID and start identity are unchanged; the seat's scope
   still exists with the same limits; a write outside the workarea is still
   denied; N+1 reports the seat adopted with the controller generation advanced
   by exactly one; capacity was charged throughout; N+1 pushed a
   `CredentialUpdate` that the runner applied; the runner's standalone lease
   refresh succeeds against N+1.
6. Touch the trigger. Assert exactly one terminal commit in the standalone
   queue (`CommitTerminal` revision unchanged on replay), the outbox record is
   `delivered`, the tombstone was consumed, and the scope was collected.

A second run of the same flow replaces the local runtime with a stub hosted
receiver in the container: a small HTTP server that implements lease refresh,
step heartbeat and terminal status with exact-replay semantics, and rotates the
worker id on re-registration. It checks the hosted shape: the lease refresh
keeps succeeding across the gap, `CredentialUpdate` delivers the rotated worker
id, and an outbox replay carries the original body with fresh headers.

**macOS.** The same flow against a real launchd job, as ADR-2026-08-17 D1
requires. Headless shim launch stays off on macOS until it passes.

**Failure modes.** Each runs in the same container.

| Case | Expected |
|---|---|
| Worker (shim) killed with SIGKILL mid-run | Daemon janitor proves the harness group gone, then writes one `worker_exited_without_result` record; no second record if the runner had written one |
| Harness finishes while the daemon is down; direct post succeeds | Outbox `delivered`; the new daemon adopts the tombstone and sends nothing |
| Harness finishes while the daemon is down; direct post fails | Outbox `pending`; the new daemon replays the exact bytes once; a forced second replay returns the original receipt |
| Old daemon (no H) started against a live headless shim | `protocol_mismatch` quarantine; capacity charged; the seat is not killed; it reaches the orphan deadline, writes its outbox record and tombstone |
| New daemon meets a headless shim from an earlier profile revision | Highest overlap selected, or quarantine when none; never a kill |
| Adoption refused (identity mismatch, duplicate identity, peer-credential failure) | Quarantine; the runner keeps refreshing its lease; orphan deadline ends it |
| Replacement daemon crashes between `Welcome` and the batch commit | The next daemon adopts at the next generation; frames from the crashed controller are rejected |
| Old daemon process resurfaces after adoption | Its `Stop` and `CredentialUpdate` are rejected as stale |
| Daemon killed without the preflight | Seat survives; adoption proceeds with no fence (the unplanned case) |
| Hosted bearer expires while no daemon runs (fake receiver) | The lease fuse ends the seat as `lost-ownership`; it writes its outbox record and tombstone; nothing is released without terminal evidence |
| Daemon returns before the bearer expires | The pushed `CredentialUpdate` arrives before the old bearer lapses; the lease never misses a tick |
| Host reboot | Every process dies; boot recovery classifies stale records and tombstones before advertising capacity |
| One direct-owned and one shim-owned seat | Preflight refuses with the direct-owned count; after the direct-owned seat ends it returns `prepared` |
| User install where scope creation is refused | The seat is refused before spawn with a typed reason; it never falls back to an unscoped shim |

**Wire tests.** A discriminating corpus for version H: every PTY-shaped message
on a headless connection is refused; `CredentialUpdate` with a stale
generation is refused; a headless shim never advertises a version an
interactive-only daemon could select; the new record field fails closed in an
older decoder.

## D7 — Rollout, the mixed fleet and the restart preflight

### Restart preflight

1. Shim-owned headless seats are covered by the same snapshot and fence as
   interactive shims (`sessionShimFenceSnapshot`,
   `verifyRestartRegistryCoverage`).
2. A direct-owned seat whose harness is resume-qualified and whose resume
   artifact verifies is stopped for resume and fenced as a parked session
   (D8). Every other direct-owned seat still refuses a planned restart. The
   refusal gains a closed cause, `direct_owned_sessions`, with the count of
   seats that can be neither adopted nor resumed, so a caller can tell it apart
   from a fence failure.
3. `POST /api/daemon/drain` gains a mode that drains only the seats that can
   be neither adopted nor resumed. The host stops launching new direct-owned
   seats, keeps launching shim-owned ones, and the call returns when no such
   seat remains. The planned restart then proceeds without stopping new work.
4. A direct-owned seat is never converted to shim ownership. Apart from D8's
   stop-for-resume, which is cooperative and fenced, no option kills a seat to
   let a planned restart through. A bare signal or a service-manager stop that
   skips the preflight keeps its unplanned-crash meaning (ADR-2026-08-17 D9).

### Rollout order

1. **Adopt-capable daemon, launch off.** Ship version H, the record field,
   `CredentialUpdate`, outbox-before-send, the preflight change, and a local
   runtime that accepts shim-owned headless seats and adopts, rather than
   holds, a recovering session whose shim it adopted. Headless shim launch stays
   disabled everywhere. This release can adopt headless shims but never creates
   one. It must be on every host before step 3, so a rollback to it is always
   safe.
2. **Consumer first.** A composing control plane deploys terminal-status
   idempotency, lease and terminal acceptance from a replacement registration
   of the same stable host, and fence consumption over headless rows, before
   any of its hosts launches a headless shim. This repeats the "deploy the
   consumer first, the daemon second" rule of ADR-2026-08-17 rule 11.
3. **Per-host launch gate.** Enable headless shim launch for new seats, per host,
   only where the host passes its kill-scope requirement (D5) and the D6
   fixture for its service manager. Registration advertises the capability, so
   a control plane can tell which hosts adopt headless seats.
4. **Transition, once.** On each host, existing direct-owned seats are stopped
   for resume where D8 allows it; the rest finish under the drain mode of the
   preflight's item 3 while new seats start shim-owned. That is the last soft
   drain the host needs for an upgrade.
5. **Default on**, then delete the direct-owned headless path once nothing
   depends on it (ADR-2026-08-17 D11 step 12).

### Fallback

- Turning the gate off makes new seats direct-owned again. Existing headless
  shims keep running and are adopted by any adopt-capable daemon.
- Installing an artifact older than step 1 while headless shim records exist
  would leave them quarantined until their orphan deadlines reap them: safe,
  but every such seat is lost. The update path refuses that downgrade while the
  registry holds a live headless record, extending the artifact check
  ADR-2026-08-17 D11 already requires for the preflight route.
- Hosts that cannot run headless shims (Windows today; macOS until the launchd
  smoke passes) keep the direct path. Their resume-qualified seats use
  stop-and-resume (D8); the rest keep the soft drain.
- Stop-and-resume has its own rollout and fallback, in D8.

## D8 — Stop and resume for seats that cannot be adopted

Founder decision 6 puts this here. It is a fallback beside adoption, never a
replacement for it.

### Where it applies

At a planned restart each seat takes the first path that applies:

1. **Adopt.** A shim-owned seat is fenced and adopted (D1 to D7). Nothing is
   interrupted.
2. **Stop for resume.** A seat that cannot be adopted, whose harness is
   resume-qualified and whose resume artifact verifies, is stopped
   cooperatively, parked under the restart fence, and resumed by the
   replacement daemon as a new incarnation.
3. **Drain.** Every other seat keeps today's behaviour: the preflight refuses
   until it finishes (D7).

"Cannot be adopted" means one of three things: the host does not launch
headless shims (no survival fixture for its service manager, or the gate is
off); the seat was launched direct-owned before the gate was turned on; or a
shim-owned seat was quarantined and is about to reach its orphan deadline. In
the third case the shim takes the stop-for-resume exit instead of the terminal
exit when its harness qualifies, so the next compatible daemon can resume what
the quarantine would otherwise have ended.

A live process that can be adopted is always adopted. In the vocabulary of
ADR-2026-08-31 D1 a live process is a rebind case; resume applies only after
the previous incarnation is gone and its end is recorded.

Resume needs no surviving process, so the same path also covers a planned host
reboot. It does not cover an unplanned crash: a crashed seat left no
cooperative stop, no flushed artifact and no recorded end, which is the
"classify further" case of ADR-2026-08-31 D1. Resume after a crash is outside
this ADR.

### Which harnesses qualify, and what a verified resume artifact is

**Qualification is computed, never declared.** A harness adapter version is
resume-qualified only when its resume fixture passes at that version: the
fixture stops a scripted session mid-run through the stop-for-resume path,
starts a new process from the artifact, and observes the harness reporting the
earlier conversation as loaded. This is the same rule
`ADR-2026-08-13-capability-realization-registry-and-viability-of-absence.md`
D6 applies to capability bits, and an adapter-version bump re-runs the fixture
(its D1.6). A harness without a passing fixture is not resume-qualified, and its
seats keep the soft drain.

**Where the harnesses stand today: none qualifies.** The generated capability
matrix declares session resume for three production harnesses, codex, opencode
and pi (`matrix/capability-matrix.json`, field `resume`, from
`agent.Capabilities.SupportsSessionResume`), and not for claude, whose adapter
returns `ErrUnsupported` from `Resume` (`provider/harness/claude/claude.go`).
But every production use of `Resume` today is inside one live runner process:
the only caller is `runner/steering.go:resumeWithDirective` (steering, turn
continuation and the stalled-request retry), and the dispatch field meant to
name a session to resume, `prompt/queued_work.go:ProviderSessionID`, is
copied through and never read. No path starts a new process from a previous
process's conversation. Per harness:

- *codex* resumes a thread through its app-server from a rollout under
  `CODEX_HOME`. For a headless seat that home is a randomly named directory
  under the provider's temporary directory, the system one by default, created
  per provider instance (`provider/harness/codex/config_boundary.go`), and no
  record maps it to the session; a new process creates a fresh home and cannot
  see the old thread. The interactive path already records home and thread id
  with the shim
  (`sessionshim/record.go:ResumeKey`) and keeps the home through teardown.
- *opencode* reopens its on-disk session store through a fresh serve child
  (`provider/harness/opencode/opencode.go`, `Resume`), but donmai does not
  isolate that store, so it is not a session-owned location.
- *pi* relaunches against its session storage (`provider/harness/pi/pi.go`,
  `Resume`), which sits inside the repository checkout behind the checkout's
  exclude file (`provider/harness/pi/confinement.go:sessionStateRoot`). Its
  resume sends no prompt, so a directive would be dropped, and the adapter marks
  the path untested.
- *claude* already renders `--resume <id>` in its arguments
  (`provider/harness/claude/cli_args.go`) but does not implement `Resume`, and
  its conversation store is the CLI's own, outside anything donmai declares.

ADR-2026-08-31 D2 rules out two of those placements by name, the checkout and
the system temporary directory, and requires the others to be declared. So
qualification needs adapter work first: each harness keeps its conversation
state at a declared, session-owned location under the workarea root, keyed by
the session, and its resume accepts a directive. The shared conformance check
(`agent/conformance/checks.go:checkResumeContinues`) is not enough either: it
proves that a resumed session starts and keeps the event contract, not that it
loaded its history. Until a harness passes the D8 fixture, its seats keep the
soft drain.

**The artifact.** A resume artifact is the harness's own conversation state,
identified by a closed set of facts the stopping runner records:

- the harness key and adapter version, and the harness binary pin;
- the harness's native session or thread identifier;
- the path of the state, relative to the session-owned harness state directory
  that the workarea root declares (never inside a repository checkout and never
  in a system temporary directory, per ADR-2026-08-31 D2);
- a content digest of that state, taken after the harness has flushed it; and
- the model endpoint route the harness was started with.

**Verification happens three times.**

1. *At stop.* The preflight checks qualification before it asks for the stop.
   The runner then stops the harness the way its adapter declares flushes the
   conversation, confirms the state exists and records its digest. A harness
   that fails to leave readable state is the rare case; the seat then ends as
   `host-restart` with its WIP checkpoint, as described under "Terminal
   delivery" below.
2. *Before spawn.* The replacement daemon re-checks every recorded fact: the
   state exists and its digest matches, the adapter version and binary pin
   are the same or the new adapter version's fixture proves it reads the old
   state, and the endpoint route is unchanged (the codex adapter already
   refuses an in-process resume on a different gateway route). It also checks that the
   upgraded host can still realize the seat's admitted execution cell: same
   harness, same execution-security levels, same confinement. A failed check
   is a typed refusal that names what was missing (ADR-2026-08-31 D1).
3. *After spawn.* The harness must show that the conversation was loaded, for
   example by reporting the resumed native identifier and a non-zero history.
   A resume that starts blank is a **failed resume**: the incarnation is
   recorded as `seeded_fresh` and briefed as a fresh start, as ADR-2026-08-31
   D1 requires, instead of running on a conversation it does not have.

### Incarnations and lineage

The lineage rules of ADR-2026-08-17 D1 to D10 apply, with one addition: an
incarnation counter.

- **Identity.** `(org_id, session_id)` stays the only lifecycle identity. A
  resume is not a new session, not a new dispatch and not a new attempt. The
  standalone queue refuses a second attempt by design
  (`internal/localqueue/types.go:AttemptRef`, minted once by `Claim`), so it
  gains an incarnation counter inside the existing attempt instead.
- **Incarnation number.** Each incarnation carries `process_epoch`, the existing
  "monotonic per-session value for one shim incarnation", now used for every
  incarnation whether or not it is shim-owned. The first is 1; a resume
  writes the previous value plus one. A resumed incarnation that is shim-owned
  gets a new `shim_id` and starts its own `controller_generation`.
- **One live incarnation.** Incarnation N+1 may start only after incarnation
  N's end is recorded and its process group is proved gone. Two live
  incarnations of one session are the D2 duplicate case of ADR-2026-08-17 and
  quarantine both.
- **Provenance.** Each resumed incarnation records how it started (`resume` or
  `seeded_fresh`), the incarnation it continues, and the artifact digest it was
  seeded from.
- **Resume record.** The stopping runner writes one record per parked session,
  atomically and with the same modes as a discovery record (ADR-2026-08-17 D6),
  in the same registry directory. It holds the identity, the stopped
  incarnation number, the artifact facts above, the workarea root, the stop
  reason, the stage counters and budget meter readings (turns, continuations,
  sub-agents started, tokens, running time), and the list of work lost at the
  stop. It holds no bearer, prompt or terminal output. Credentials for the new
  incarnation are minted from the session identity, as for any spawn. Credential
  files written for one incarnation, such as pi's owner-only credentials file
  (`provider/harness/pi/credential_file.go`), belong to that incarnation and are
  removed when it stops; they are never resume state.
- **Admission is reused, not repeated.** The new incarnation runs under the
  session's original admission receipt and effective cell. A running session
  keeps what it was admitted with (ADR-2026-10-05 D1 rule 3), and a resume is
  the same session. If the upgraded host cannot realize that cell, the seat is
  not resumed.

### The stop

1. The preflight records the stop reason `host_restart` for the seat, then asks
   the runner to stop for resume. This is not the daemon's per-session stop:
   `StopSession` follows SIGTERM with SIGKILL after 250 ms
   (`daemon/process_group_unix.go:sessionTerminationGrace`), and a SIGTERM'd
   run today ends as `timeout` and posts a session terminal status
   (`runner/loop.go`, `classifyStreamStop`; `runner/runner.go:terminalResultPostContext`).
   A stop for resume must do neither. On the direct path the request is a
   signal sent after the reason is recorded, the runner reads the reason back
   before it chooses its exit path, and the daemon waits for the bound below
   before it escalates; a signal with no recorded reason keeps today's meaning.
   A quarantined shim at its orphan deadline takes the same path internally.
2. The runner starts no new turn and waits for a safe point: the current tool
   call finishes, bounded by the restart budget (ADR-2026-08-17 D9). A tool
   call still running at the bound is interrupted and listed as lost.
3. The runner stops the harness so that it flushes its conversation, verifies
   the artifact, writes the resume record, and pushes a WIP checkpoint of the
   workarea where the work owes a commit. That reuses the provider-error
   checkpoint (`runner/provider_error_checkpoint.go:checkpointProviderError`,
   which pushes `wip/<session>` within 20 seconds and sets `Resumable` and
   `ResumeCheckpoint` on the result), extended from `provider-error` to
   `host-restart`. The checkpoint is insurance for the case where no resume
   happens. The workarea itself stays on disk: failed runs already keep their
   workarea by default (`afcli/agent_run.go`, `--preserve-worktree`), and the
   worker's exit path must not release it for `host-restart`.
4. The runner exits with a new local failure mode, `host-restart`, and posts
   **no** session terminal status. It stops refreshing its lease; the parked
   session is held by the restart fence instead.
5. Only after the runner has exited and its process group is proved gone does
   the preflight add the session to its frozen snapshot, as a **parked row**:
   identity, stopped incarnation number, the WIP checkpoint if one was pushed,
   and no `shim_id`. A parked row is therefore evidence that no incarnation of
   the session is running, which a shim row is not. A composing fence store
   holds it like any other row. It needs a new version of the fence request,
   because `restart-fence-v1` allows an empty `shimId` only for a malformed
   quarantined record.

### The resume

The replacement daemon resumes parked sessions in the same startup phase in
which it adopts shims: after auth-only registration and before it advertises
capacity or claims new work (ADR-2026-08-17 D4). For each resume record it
runs the before-spawn verification and puts the session in its adoption batch
as a resume. The composing authority consumes the parked row in the same
transaction that commits the batch, so a resume and an end decided elsewhere
can never both win. Only after that commit does the daemon launch the new
incarnation (shim-owned if the host now launches headless shims, direct-owned
otherwise) and charge it to capacity. In the standalone runtime the local queue
plays the authority's part.

The new incarnation's runner starts the harness with `Resume` and the native
identifier from the record, and its first turn is a directive delivered through
the existing `runner/steering.go:resumeWithDirective` path. The directive names
the work lost at the stop, so the agent does not assume an interrupted tool
call completed. The workarea, its branch, its commits and its uncommitted
changes are where the previous incarnation left them, under the same lease.

### Terminal delivery across stop and resume

- **A stop for resume is not a session end.** The stopped incarnation writes no
  terminal status and no outbox record. Its end is recorded locally, in the
  resume record and, for a shim, in its tombstone with cause
  `stopped_for_resume`.
- **One session terminal across all incarnations.** The incarnation that
  finishes the work writes the session's terminal status through the D3 outbox.
  The outbox key is the session and its attempt, which a resume does not
  change, so a second terminal from any incarnation is a conflict, never a
  second delivery.
- **When no resume happens.** If the before-spawn check fails or the cell can
  no longer be realized, the replacement daemon writes one terminal status for
  the session with failure mode `host-restart`, carrying the WIP checkpoint as
  its resume checkpoint. The record is first-writer-wins on the outbox key
  (D3). If no daemon returns before the fence hold expires, the composing
  authority may end the session as `host-restart` itself, on the evidence of
  the parked row; that consumes the row, so a late resume is refused.
- **A failed resume is not an end.** A harness that starts blank downgrades to
  `seeded_fresh` and keeps running; nothing is delivered.
- **Release still needs terminal evidence.** The claim, the workarea lease and
  the fence rows are released only on the session's terminal status
  (ADR-2026-08-17 rule 10). A parked row is the one fence row that may lead to
  an end without its host returning, and only because it was written after the
  process group was proved gone; elapsed time alone still releases nothing.

### Budget charging

- **The stop is uncharged.** A stop for resume is not a session end, so it
  neither charges nor refunds a per-work-item dispatch budget. The session was
  charged once, at dispatch, and stays charged once however many incarnations
  it takes.
- **A `host-restart` end is uncharged and may be dispatched again.** A
  composing control plane that charges a per-work-item budget classifies it
  with operator and upgrade stops: no charge and no failure backoff. Unlike
  `operator-cancelled`, which is never dispatched again
  (`ADR-2026-06-22-daemon-per-session-cancel-wire.md`), a `host-restart` end
  may be dispatched again, from its WIP checkpoint, because nobody cancelled
  the work.
- **Spent cost stays spent.** Tokens and time used by every incarnation, including
  a model request lost at the stop, roll up to the session. Nothing is refunded
  because a stop happened.
- **Caps continue.** The stage budget meter (tokens, duration, sub-agents) is
  process-local today (`runner/budget.go:BudgetEnforcer`), as are the turn and
  continuation counters, so a new process would start from zero. The resume
  record carries their readings and the new incarnation's enforcer starts from
  them. A resume never resets a cap, so a restart is never a way around one.

### What is lost at a stop

- A tool call still running at the safe-point bound. It is interrupted, listed
  in the resume record, and named to the resumed agent.
- A model request in flight: its tokens are spent and its output is discarded.
- Anything the harness held only in process: background shells and servers it
  started, local tool servers and their state, and any state its conversation
  artifact does not record.
- Wall-clock time between the stop and the resume.
- A memory-inject block the runner has acknowledged but not yet handed to the
  harness. A headless runner acknowledges on buffer
  (`runner/loop.go:newInjectAcceptor`), so the control plane will not send it
  again. The runner delivers buffered blocks at the safe point where it can;
  any it cannot are listed by delivery id in the resume record, never by
  content, and named to the resumed agent.

Not lost: the conversation (in the artifact), the workarea with its committed
and uncommitted changes, the branch and pull request, the session's counters
and cost, and memory-inject deliveries not yet acknowledged, which the control
plane delivers again and the runner deduplicates by delivery id.

### Test plan

The stop-and-resume tests need no service-manager survival, so they run on
every operating system the daemon supports, with the standalone local runtime
and with the stub hosted receiver of D6. The harness is a scripted fake that
keeps its conversation in the session-owned state directory and, when resumed,
reports how much history it loaded.

1. **Acceptance.** Dispatch a seat on a host with headless shim launch off.
   Call `POST /api/daemon/restart/prepare`. Expect `prepared`, a resume record,
   a WIP checkpoint where the work owes a commit, a parked fence row, no
   terminal status at the receiver, and no budget movement. Upgrade from N to
   N+1. Expect N+1 to resume the seat before it reports ready, with incarnation
   2, provenance `resume`, the fake reporting the full history, and the lost-work
   directive delivered. Finish the work; expect exactly one terminal status and
   one dispatch charge in total.
2. **Failure matrix.**

| Case | Expected |
|---|---|
| Artifact missing or digest mismatch at resume | Typed refusal naming the fact; session ends `host-restart` with its WIP checkpoint, uncharged |
| Harness binary pin changed by the upgrade, no fixture proving compatibility | Same as above; never a resume against an unproven version |
| Endpoint route changed | Typed refusal; the codex adapter's existing route check also refuses |
| Harness starts blank after a verified artifact | Failed resume recorded; incarnation continues as `seeded_fresh` with a full briefing |
| Tool call still running at the safe-point bound | Interrupted; listed as lost; named in the resume directive |
| Previous incarnation's process group still alive | The new incarnation never starts; duplicate rule quarantines |
| Daemon crashes during the stop, before the preflight returns | The preflight never returned `prepared`, so this is the unplanned case: no parked row, no resume, today's crash behaviour |
| Host does not return before the fence hold expires | The authority ends the session as `host-restart` from the parked row; a late resume by the returning host is refused |
| Resume and an authority-side end race | Exactly one consumes the parked row; the loser is refused before any process starts |
| Host reboots between stop and resume | Resume proceeds from the on-disk record and artifact |
| Older daemon (rollback) finds a resume record | The update path refuses the downgrade while a resume record exists |
| Quarantined shim reaches its orphan deadline, harness qualified | Parks instead of ending; the next compatible daemon resumes it |
| Two resumes in a row | Incarnation 3; caps keep counting from the record |
| Composing plane receives the `host-restart` end | Classified uncharged, no backoff, dispatchable again from the checkpoint |

3. **Fixture per harness.** The resume fixture that qualifies an adapter
   version (above) is part of that harness's conformance suite and runs on
   every adapter-version change.

### Rollout relative to shim adoption

Where both paths apply, adoption wins. Stop-and-resume ships alongside it:

1. **With the adopt-capable release (D7 step 1).** Ship the resume record, the
   resume-before-ready scan, the `host-restart` failure mode and the parked
   fence row, with stop-for-resume disabled.
2. **With the consumer step (D7 step 2).** The composing control plane holds
   parked rows, classifies `host-restart` as uncharged and dispatchable again,
   and accepts the session terminal from any incarnation of the session.
3. **Per harness.** Move the harness's conversation state to a declared,
   session-owned location (codex's headless home first, since its interactive
   path already records one; then pi out of the checkout, opencode's store, and
   claude's `Resume`), make its resume carry a directive, and add the fixture.
   A harness becomes resume-qualified when that fixture passes at its adapter
   version.
4. **Per host, independent of the shim gate.** Enable stop-for-resume in the
   preflight. It needs no service-manager fixture, so a host that cannot run
   shims yet (macOS before the launchd smoke) gets it first, and loses its
   soft drain for every qualified harness. On a host where shims are on, it
   applies only to seats that cannot be adopted, which shrinks the one-time
   transition of D7 step 4 to the seats whose harness is not qualified.

**Fallback.** Turning stop-for-resume off returns those seats to the soft
drain. A daemon that predates step 1 must not be installed while resume
records exist; the update path refuses that downgrade, as it does for headless
shim records (D7).

## Decisions (founder, 2026-10-08)

1. **Orphan deadline.** Headless seats reuse the interactive orphan deadline
   and readoption policy unchanged (D4).
2. **Lease after adoption.** The runner keeps refreshing its session lease
   directly; the daemon does not take it over for adopted seats (D2, D3).
3. **Credential channel.** Credential refresh is pushed as `CredentialUpdate`
   over the shim connection; the daemon's HTTP session-detail store is not
   rehydrated on adoption (D2).
4. **systemd posture.** Every shim-owned seat starts in its own transient
   systemd scope, which is also the per-seat budget cgroup (D5).
   `KillMode=process` on the daemon unit is not used.
5. **Interactive gaps.** The empty credential store after adoption and the
   systemd kill scope are fixed for interactive shims in the same release as
   headless adoption (D2, D5, D7).
6. **Seats that cannot be adopted.** Against the recommendation, stop-and-resume
   is designed here rather than in a separate ADR. On a host that cannot run
   shims, or for a seat that cannot be adopted, a planned restart stops the seat
   and resumes it as a new incarnation seeded from retained harness state, for
   harnesses with a verified resume artifact. Soft drain remains the fallback
   for harnesses without one. D8 is that design.
7. **Acceptance.** The founder accepted the ADR as drafted on 2026-10-08,
   including D8, and asked for the unblocking work to be scheduled.

## What this ADR does not decide

- Children across a parent restart, which
  [`ADR-2026-10-03-sub-agents-for-dispatched-sessions-and-non-native-harnesses.md`](ADR-2026-10-03-sub-agents-for-dispatched-sessions-and-non-native-harnesses.md)
  leaves open. Each child is its own session and its own seat; adopting a
  parent says nothing about its children.
- Multiplexed hosting of several sessions in one harness process, still
  deferred by
  [`ADR-2026-08-12-pi-extension-delivery-seam-and-capability-pack-boundary.md`](ADR-2026-08-12-pi-extension-delivery-seam-and-capability-pack-boundary.md)
  D7.
- Restart survival on Windows.
- The interactive profile's wire versions beyond adding `CredentialUpdate`
  (founder decision 5).
- Resume after an unplanned crash, and resume on a different host. D8 resumes
  only a seat its own host stopped cooperatively, from state on that host.

## Consequences

### Positive

- A planned upgrade of a seat host no longer waits for its seats. After the
  one transition drain, it takes as long as a daemon restart.
- An unplanned daemon crash no longer re-dispatches running seats from the
  start; they are adopted if the daemon returns before the orphan deadline.
- One ownership model for both session classes, as ADR-2026-08-17 intended,
  and a path to deleting the direct-owned code.
- A terminal status survives any single process failure on the host.
- Seat budgets and the kill-scope fix share one cgroup per seat on Linux.
- Hosts that cannot run shims, seats launched before the gate, quarantined
  shims and planned reboots stop costing whole seats for every harness that
  qualifies for resume (D8). Only unqualified harnesses still drain.

### Negative

- Every shim-owned seat holds a socket, a registry record and, on systemd, a
  transient scope. Hosts accumulate more per-session state to classify on boot.
- The wire family gains a version whose message set is not a superset of the
  previous one. The selection rule stays "highest common version", but the
  headless range never overlaps an interactive-only daemon.
- The control plane must accept a lease refresh and a terminal status from a
  replaced registration. That is a real change to claim bookkeeping.
- A seat now outlives a daemon restart by design. An intentional stop still
  ends it, because the daemon's own stop path sends a generation-fenced `Stop`
  to every adopted shim (`011` § "Drain and restart semantics"). A
  service-manager stop that bypasses that path leaves seats running until they
  finish or reach their orphan deadline.
- A resumed seat loses what was in flight at the stop (D8) and pays again for
  the context it reloads. Resume is a cheaper failure than a re-dispatch, not a
  free one.
- Each harness needs a resume fixture per adapter version before it qualifies,
  and the qualification can be lost on any harness upgrade.

### Risks

- **The survival claim is only as good as the kill-scope fixture.** systemd and
  launchd details differ by version. Mitigation: the per-host gate requires the
  fixture to pass for that host's posture.
- **Hosted bearer lifetime versus restart length.** If a daemon stays down
  longer than the bearer's remaining life, the runner's lease fuse ends the
  seat as `lost-ownership`. The outbox and tombstone keep that outcome exact,
  but the seat's work stops. Mitigation: the push immediately after adoption
  (D2). A planned outage long enough to matter is usually a reboot, which ends
  every process anyway and is covered by D8.
- **Duplicate terminal writers.** The runner and the daemon's fallback could
  both try to write. Mitigation: first-writer-wins on the outbox key and exact
  replay at the receiver.
- **Scope creation fails on some installs.** Mitigation: refuse the seat before
  spawn with a typed reason; never launch an unscoped shim on systemd.
- **Interrupted side effects.** A tool call cut off at the safe-point bound may
  have half-applied an external effect (a push, a migration, an API write). The
  resumed agent is told which call was cut off, but it cannot know how far the
  call got. Mitigation: the safe-point wait lets most calls finish; the lost
  list is explicit; harness tool idempotency stays the harness's concern.
- **Resume fidelity drifts with harness releases.** A harness can change its
  conversation format between versions. Mitigation: qualification is computed
  per adapter version (D8), and an upgrade that changes the binary pin without
  a passing compatibility fixture ends the seat as `host-restart` rather than
  resuming on an unreadable artifact.
- **The parked row is new authority.** It is the one fence row that can lead to
  an end without its host returning. Mitigation: it is written only after the
  process group is proved gone, and resume and authority-side ends consume it
  in one transaction.

## Alternatives considered

- **Keep draining before every upgrade.** Rejected for the reasons ADR-2026-08-17
  already gives: upgrades wait on the longest session, and crashes are not
  covered.
- **Stop and resume on every restart.** Kill the seat and start a new
  incarnation from retained harness state. Rejected as the primary mechanism:
  not every harness has a verified resume artifact, a resume is a new
  incarnation with its own cost, and work in flight at the moment of the stop
  is lost. Adopted instead as the fallback for seats that cannot be adopted
  (founder decision 6, D8), never in place of adoption.
- **A non-PTY byte-stream shim around the harness** (D1 Option A) and **a
  separate supervisor process** (D1 Option B). Rejected in D1.
- **Give the daemon every control-plane leg of an adopted seat.** It would make
  the seat depend on the daemon being up for the whole gap, which is the
  dependency this ADR removes.

## Affected documents

These edits landed in the commit that flipped this ADR to Accepted:

- `ADR-2026-08-17-session-shim-adoption.md` — core contract rule 1 names the
  headless profile's ownership (runner and harness process groups, no PTY, VT
  or output sequence); rules 9 and 10 name the parked row of D8 as a fenced
  correlation whose resolution is a successor incarnation's terminal or an
  authority-side `host-restart` end. These rules sit inside the
  `adr-2026-08-17-session-shim-core-contract` synchronized region, so this needs
  paired PRs in both corpora and a green `scripts/check-boundary-sync.sh`. A
  non-synchronized note in D1 states that the shim's version stability comes
  from the negotiated wire, not from binary size; D11 step 11 points here.
- `011-local-daemon-fleet.md` — § "Session-shim adoption", § "Drain and restart
  semantics" (the direct-owned-only drain mode and the typed preflight cause),
  § "Recovery from crash" (headless seats are adopted, not re-dispatched).
- `013-orchestrator-and-governor.md` — worker lifecycle: a headless seat may
  outlive its daemon and is released only on terminal evidence; the
  `host-restart` failure mode and its re-dispatch rule (D8).
- `ADR-2026-08-31-session-recovery-taxonomy-and-state-vocabulary.md` — D8
  relies on its D1 (resume creates an incarnation, verified at the layer that
  performs it, downgrading to seeded-fresh) and D2 (session state outlives the
  process, at a declared session-owned location). D8 was accepted as
  architecture with no D8 behaviour allowed to ship before those two were
  accepted; they were accepted on 2026-10-08, so that gate is clear. Its D3
  and D4 moved to `ADR-2026-10-08-session-state-vocabulary-and-recovery-migration.md`,
  which is Proposed; D8 does not depend on them.
- `ADR-2026-08-17-session-shim-adoption.md` D9 — the restart fence request gains
  a version that carries parked rows (D8). The schema lives in D9, outside the
  synchronized region; the platform mirror records the fence store's side.
- `protocol/session-shim-v6.md` (new) — the selected-v6 delta: the headless
  workload profile, `CredentialUpdate`/`CredentialResult` for both profiles,
  and `HeadlessExit`.

### Clarified at acceptance

1. **H is 6.** The headless profile and the credential push share selected
   version 6. Interactive v6 shims advertise `[1, 6]`, headless shims `[6, 6]`,
   and the profile is declared in the existing optional `Hello` extension map,
   because a new top-level `Hello` member would break older strict decoders
   before selection.
2. **Only headless records change.** D4's registry bullet said the record's
   schema version moves; read literally that would make every older daemon
   quarantine new interactive shims too. The schema version and the
   `workload` member apply to headless records only, and interactive records
   stay byte-identical.

## Affected work items

Tracked in the platform corpus's mirrored stub; no tracker identifiers are
recorded here.

## Implementation notes

- Selection: `daemon/session_shim_spawn.go:shimOwnsSession` gains the headless
  case behind the per-host gate.
- Launch: `daemon/session_shim_spawn.go:startShimProcess` gains the systemd
  scope wrap; the seat-budget wrap moves here from
  `daemon/worker_spawner.go:(*WorkerSpawner).spawn`.
- Shim start: `sessionshim/shim.go:Start` splits into a transport-neutral core
  (socket, record, fence, orphan, tombstone) and the PTY host; the headless
  driver calls the core directly.
- Credentials: `afcli/agent_run.go:agentRunCredentialCache` reads the last
  `CredentialUpdate` for shim-owned seats; the daemon's credential refresher
  sends one per adopted lineage.
- Terminal: `runner/runner.go` always prepares and persists the status body for
  shim-owned seats; the daemon's existing replayer drains it.
- Preflight: `daemon/restart_preflight.go:(*Daemon).prepareRestartWithLease`
  gains the closed `direct_owned_sessions` cause (today the refusal falls back
  to the generic `restart_preflight_refused`); the drain route gains the
  direct-owned-only mode.
- Local runtime: the refusal in `daemon/daemon.go` is lifted for headless shim
  seats, and `daemon/local_runtime_recovery.go:(*localRuntime).recover` adopts
  a session whose shim was adopted instead of holding it as `unknown`.
- Startup sweeps: anything that reclaims per-session state at boot (the codex
  orphan sweep, the per-session scratch-directory sweep) treats an adopted
  headless lineage as a live owner.
- Posters: `runtime/executionevent/uploader.go` falls back to the last bearer
  on a failed credential read, like the other posters.
- Stop for resume (D8): a `host-restart` failure mode in `runner/failure.go`; a
  stop request distinct from `StopSession`, with a bound long enough for the
  safe point and the checkpoint push; `checkpointProviderError` extended to
  `host-restart`; the worker exit path keeps the workarea for `host-restart`.
- Resume (D8): a secret-free resume record beside the discovery record; a
  resume scan in the startup adoption phase; `process_epoch` written from the
  record instead of the constant 1 in `daemon/session_shim_spawn.go`; the
  runner's first turn through `resumeWithDirective`; the stage budget meter
  seeded from the record.
- Harness adapters (D8): session-owned conversation state for codex, opencode
  and pi, a directive-carrying resume for pi, `Resume` for claude, and a
  history-loaded resume fixture beside `checkResumeContinues`.
