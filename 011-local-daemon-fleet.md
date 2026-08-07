# 011 — Local Daemon Fleet (Operations & UX)

**Status:** Reference (initial draft)
**Last updated:** 2026-07-22
**Boundary:** shared (OSS-canonical; platform extensions live at `rensei-architecture/011-local-daemon-fleet-platform-extensions.md`)
**Related:** `004-sandbox-capability-matrix.md` (architectural shape lives there), `ADR-2026-05-06-tui-noun-consolidation.md` (superseded in part), `ADR-2026-05-07-daemon-http-control-api.md`, `ADR-2026-06-03-injectable-state-dir.md` (on-disk daemon state dir + log dir are now embedder-injected; OSS default `donmai`), `ADR-2026-07-18-bounded-terminal-workarea-leases.md`, `ADR-2026-08-03-cli-noun-tree-fleet-retirement.md`.

> **Command surface note (2026-08-03):** `ADR-2026-05-06-tui-noun-consolidation.md` called for the daemon CLI lifecycle commands (install, status, doctor, drain, update) to be invoked as `<binary> host *` on both binaries via a shared `afcli.RegisterCommands` tree. That never shipped in the OSS binary: as verified against the code on 2026-08-03, `donmai` still exposes these under `daemon *` (`donmai daemon install`, `donmai daemon status`, …), with no exported `host` command. The example fences below use this shipped OSS form. `ADR-2026-08-03-cli-noun-tree-fleet-retirement.md` D2 commits `afcli` to exporting a real `host` parent with `daemon` demoted to a hidden deprecated alias — once that OSS release ships, `donmai host install` etc. become correct and `daemon *` becomes the alias. Until then, treat `host *` forms as the target, not the current command. (The platform binary already exposes its own hand-assembled `host` tree today; see that ADR's Finding 3.)

## Why this exists

The architectural shape of the local daemon is in `004` — `SandboxProvider` running in persistent mode, registered once, serving multiple projects. This doc is the operations and UX manual for the **single-machine OSS deployment**: how a user installs it, configures it, recovers from problems. Multi-machine fleets (SaaS aggregation across machines) are a platform extension; see the platform-extensions doc.

The motivating user pain (called out during architectural review):

> I have 8 different VSCode workspaces currently open, and routinely have more than 20 open, each with their own auto-start of a worker fleet. This means I'm constantly switching windows and tabs just to update my fleet when a release ships.

The architectural answer is the daemon model from `004`. This doc makes it real for users.

## The user model

> "I have a Mac. I want to install Donmai once, configure it once, and have any project's work execute on this Mac as long as the project is allowed and credentials are wired up. I never want to think about the worker fleet again."

Concretely, the user's day:

1. **Once at install:** `brew install donmai && donmai daemon install` (or equivalent on Linux). Daemon starts; registers as a system service.
2. **Once per project:** `donmai project allow github.com/foo/bar`. Daemon now accepts work for that project. Credentials are picked up from system keychain or per-project config.
3. **Day-to-day:** open VSCode for any allowed project, or don't. Linear webhooks → orchestrator → daemon. The daemon clones the repo on first session, warms its workarea cache, and runs sessions. No window-switching, no per-workspace fleet management.
4. **On release:** daemon auto-updates on configured channel. Drains in-flight work, restarts cleanly. User sees a single notification or nothing at all.

## Installation paths

### macOS (launchd, primary target)

```bash
# One-line install
brew install donmai
donmai daemon install          # writes ~/Library/LaunchAgents/dev.donmai.daemon.plist
                                # loads agent; survives reboots and re-logins

# Verify
donmai daemon status
# donmai-daemon: running   pid 12345   uptime 2h13m   sessions 3 / 8
```

The launchd plist is generated from a template; the user doesn't edit it directly. The daemon binary lives at `/usr/local/bin/donmai` (or `~/.donmai/bin/` for user-scoped install). Logs at `~/Library/Logs/donmai/daemon.log` per macOS convention.

### Linux (systemd)

```bash
# Distro-agnostic via the Donmai installer
curl -fsSL https://get.donmai.dev | sh

# User-scoped systemd unit (recommended)
donmai daemon install --user
systemctl --user status af-daemon

# System-scoped unit (multi-user shared machine)
sudo donmai daemon install --system
sudo systemctl status af-daemon
```

Logs to `journalctl --user -u af-daemon`. The OSS execution layer ships only the user-scoped variant by default; system-scoped is opt-in.

### Windows (service)

**OSS shipping order: deferred. Architecture: in scope.**

Initial OSS support is deferred — we don't have the user demand or the test coverage today, and the user has stated a preference against Windows-as-primary. But the architecture (`004` capability flags, `005` per-OS kit contributions) admits Windows as a first-class OS. When regulated banking customers eventually require it (and they will), the daemon port is a 4-week scoped piece of work, not an architectural rewrite.

Concretely, the Windows port consists of: a Windows Service host (replacing launchd plist / systemd unit), Windows-flavored credential helpers (Windows Credential Manager), workarea-cache directory in `%LOCALAPPDATA%\rensei`, NDJSON logs to ETW or file. Kits already declare per-OS install scripts and command overrides per `005`; the Spring kit, the TS kit, and the Rust kit all work as long as their `[provide.toolchain_install.windows]` and `[provide.commands_override.windows]` sections are populated.

### Linux ARM64

Explicitly in scope alongside x86_64. Mac Studio M-series is arm64; Graviton/Ampere on cloud is arm64; Raspberry Pi-class cloud lab boxes are arm64. The daemon binary ships in both x86_64 and arm64 builds; auto-update picks the correct one based on `uname -m` at install time.

### Docker (for self-hosted dev/test fleets)

```bash
docker run -d --name donmai-daemon \
  -v ~/.donmai:/etc/donmai \
  -v ~/.ssh:/root/.ssh:ro \
  -v /var/run/docker.sock:/var/run/docker.sock \
  donmai/daemon:latest
```

Useful for CI, ephemeral dev environments, or machines where the user doesn't want a long-running native daemon. Inherits the same config file format.

## First-run setup

On first install, an interactive wizard captures the minimum config.

```
$ donmai daemon setup

Welcome to Donmai. Let's get your machine working.

[1/5] Machine identity
  Machine ID (minted once, opaque): hst_01J9Z4T7Q2K8V3RB
  Display name (yours to change):   Mac Studio — office
  Region (helps the scheduler with latency): home-network
  Continue? [Y/n]

[2/5] Capacity
  Detected: 16 cores, 64 GB RAM
  Reserve for system (won't be used by sessions):
    cores [4]:
    memory MB [16384]:
  Max concurrent sessions [8]:
  Continue? [Y/n]

[3/5] Orchestrator
  Where do work assignments come from?
  > 1. Self-hosted (OSS only)        — point at your own webhook target
    2. Local file queue (single-user) — for solo dev, no network
    3. Donmai Platform (SaaS)        — register with donmai.dev/dashboard (see platform extensions doc)
  Choice [1]:

[4/5] Project allowlist
  Allow which projects? (You can add more later with `donmai project allow`.)
  > Detected: github.com/myorg/myrepo  [add? Y/n]
  > Add another? [n]

  For each project, where are git credentials?
    github.com/myorg/myrepo:
      > 1. macOS Keychain (osxkeychain helper)
        2. SSH key  (~/.ssh/id_ed25519)
        3. Personal access token  (paste / env var)
        4. GitHub CLI (gh auth)
      Choice [1]:

[5/5] Auto-update
  Channel: [stable] / beta / main
  Schedule: [nightly] / on-release / manual
  Drain timeout (max wait for in-flight work before restart): [600] seconds

✔ Setup complete. Daemon is running.
  Status: donmai daemon status
  Logs:   donmai daemon logs
  Stop:   donmai daemon stop
```

The wizard writes `~/.donmai/daemon.yaml` matching the schema in `004`. Idempotent: re-running re-prompts for changed values without resetting unchanged ones.

The Step 3 "Donmai Platform (SaaS)" choice walks through registration with `donmai.dev/dashboard`; that branch is documented in the platform-extensions doc.

### Machine identity is minted once and referenced, never derived

Per `ADR-2026-08-07-onboarding-is-the-only-user-action.md` D1, the identity Step 1 captures is **opaque, minted once at onboarding, and held in exactly one record**. It is never derived from mutable environment state — `os.Hostname()`, the DHCP-assigned name, the network the machine happens to be on — and it is never re-derived per config file or per served scope. A machine that keeps several per-scope configs reads the same identity from all of them; a host carrying two identities for two scopes is a defect, not a supported layout. The human-readable display name is separate, freely mutable, and carries no keying weight.

Rotation is an explicit, deliberately-initiated operation, never a side effect of the environment changing. Every piece of state keyed on the identity — operator pins, deletion tombstones, host↔scope bindings — survives a rotation, or the identity is not durable and D1 is not met. The record itself is a state-dir-resident artifact; see `ADR-2026-06-03-injectable-state-dir.md`.

### "Setup complete" is a post-condition, not a step count

Per the same ADR's D6, the wizard may print a readiness claim only when the end state it claims is verified: the identity record exists, a credential for every consented scope exists *and authenticates*, and the host is present in the orchestrator's admission set. "The step ran" is not "the step's post-condition holds", and a daemon that answers its own local control API while holding no registration is not ready.

The corollary matters more than the rule, because it is the common path: a step **skipped because its post-condition already holds** is complete, not incomplete. Recording a satisfied-and-skipped step as not-done drops a fully working install back into the wizard on the next bare invocation. Readiness is derived from live state, never from a persisted journal of which prompts were answered.

## Config file walkthrough

The full schema is in `004`. Key knobs and when to use them:

### `capacity.maxConcurrentSessions`

How many sessions the daemon will run in parallel. Default: 8 on a Mac Studio, 4 on a MacBook Pro. Hard ceiling enforced by the scheduler.

If sessions are heavy (Cargo builds, large test suites), drop this. If sessions are light (TS typecheck only), raise it. Watch `donmai daemon stats` for per-session resource usage.

### `capacity.reservedForSystem`

Cores and memory the daemon will *not* touch. The user is still using their machine; sessions can't starve macOS or VSCode. Default is conservative (4 cores, 16 GB RAM); tune down if you want more session throughput.

### `projects[].cloneStrategy`

- `shallow` (default) — `git clone --depth 1`. Fast for short-lived sessions; loses history.
- `full` — full clone. Slower first-time, supports `git log`-heavy operations.
- `reference-clone` — clone-from-existing-local-mirror. Fast and full history if you already have a clone elsewhere on disk.

The workarea provider's local cache composes with this — first acquire pays the clone cost; subsequent acquires reuse the cache entry.

### `projects[].git.credentialHelper`

Per-project credential source. Common options:

- `osxkeychain` — macOS Keychain. Set via `git credential-osxkeychain store`.
- `manager` — Git Credential Manager (cross-platform).
- `cache` — in-memory cache (short-lived).
- File path to a custom helper script.

For SSH-based remotes, set `sshKey` instead of `credentialHelper`.

### `autoUpdate.channel`

- `stable` (default) — production-grade releases only.
- `beta` — release candidates.
- `main` — every commit on `main`. Don't use unless you're a contributor or running a dev fleet.

### `autoUpdate.schedule`

- `nightly` — check for updates at 03:00 local time. Drains and restarts if an update is available. Recommended.
- `on-release` — checks immediately when a release notification arrives (requires SaaS or webhook). Lower latency for fixes.
- `manual` — never auto-updates; you run `donmai daemon update` when ready.

### `orchestrator.url`

Where the daemon receives work assignments.

- `file:///$HOME/.rensei/queue` — local file queue. Solo dev, no network. The OSS layer ships a minimal queue runner that delivers work from local Linear webhooks or CLI dispatch.
- `https://your-deployed-orchestrator.example.com` — self-hosted orchestrator endpoint.
- `donmai.dev/dashboard` — the SaaS control plane (platform-extension; see the platform-extensions doc for setup).

### Which keys are hot-reloadable

This is contract, not commentary. Per `ADR-2026-08-07-onboarding-is-the-only-user-action.md` D3, anything captured at process start that can legitimately change during the process lifetime is a defect. Registration claims, the served-scope set, project→scope routing maps, per-project allowlists, and per-scope credential contexts are all **runtime-mutable**: editing them takes effect on the running daemon with no restart, no re-pairing, and no re-authentication.

Two constraints bind the watcher that implements this:

- **Watch the directory, not one basename.** A multi-scope host keeps one config file per served scope. A watcher bound to the primary file leaves every other scope frozen at boot — which is the frozen-state defect wearing a hot-reload badge.
- **Merge per scope; never replace globally.** The reload composes each scope's project set into the shared spawner. A replace-shaped reload evicts the other scopes' projects and trades a frozen-state bug for a destructive one.

`capacity.*`, `autoUpdate.*`, and `orchestrator.url` are the deliberate exceptions: they describe the process itself rather than what it serves, so a change to them may require a drain-aware restart. Everything describing *what the host serves* may not.

## Drain semantics

When the daemon needs to restart (auto-update, manual stop, system reboot scheduled), it drains:

1. **Stop accepting new work.** Daemon updates its registered status to `draining` and reports it on the next heartbeat; a compliant orchestrator reads it and stops routing new sessions to the host. This depends on the heartbeat request actually carrying the status field on the wire, not just computing it internally — see `ADR-2026-08-03-daemon-host-status-signal-completion.md`, which closes a prior gap where the daemon computed this status every beat and silently dropped it before serialization. Until a daemon build including that fix is in use, treat "the orchestrator routes new sessions elsewhere" as aspirational rather than guaranteed.
2. **Wait for in-flight sessions.** Up to `drainTimeoutSeconds` (default 600). Sessions get a SIGTERM at the timeout. Unleased workareas follow the configured post-mortem release policy. Under the accepted, implementation-pending terminal-lease architecture, every `active` or `release-pending` workarea remains unavailable until provider disposition is complete and `released` is durably saved; acknowledgement and expiry only select a release path.
3. **Release eligible workarea-cache entries.** Cache entries in `ready` or `warming` state are torn down; `acquired` entries follow the policy above. Drain never overrides a non-released terminal workarea lease or acquisition-quarantine guard.
4. **Restart.** New process boots, re-registers, status returns to `ready`.

For graceful planned restarts (e.g., a reboot), `donmai daemon drain` returns when drain completes. CI scripts or shutdown hooks can wait on it.

**A scope change is not on this list.** Per `ADR-2026-08-07-onboarding-is-the-only-user-action.md` D3, adding or removing a project or an organization on a host is a runtime operation, so no user-facing instruction is ever "restart the service." The restarts that remain — auto-update, an operator stop, a reboot — always drain first, because a configuration change must never cost in-flight work.

## Recovery from crash

If the daemon process dies unexpectedly:

1. **System service auto-restart.** launchd / systemd brings it back. Default backoff: immediate, then 30s, 5m for repeated crashes.
2. **In-flight sessions become orphans.** Their workareas remain on disk. Under the accepted, implementation-pending terminal-lease architecture, the new daemon loads the separate acquisition-quarantine journal first, then every durable `active` and `release-pending` lease, before classifying orphan workareas. Any guarded, quarantined, non-released, or unreconciled exact workarea remains unavailable under its originating session identity; only an unleased, unguarded orphan follows the ordinary post-mortem policy.
3. **Workarea-cache state survives.** Cache entries are filesystem state; they are rediscovered only after quarantine, lease, session, and cache-catalog reconciliation. An entry with a quarantine record or non-released lease cannot be admitted to an available state.
4. **Logs preserve crash context.** macOS: `~/Library/Logs/donmai/daemon.log`; Linux: `journalctl --user -u donmai-daemon`. The daemon emits a final crash dump to the same path before exiting (when possible).

If the daemon refuses to start, common causes:

- **Bad credentials** for a configured project. Daemon logs the project ID and exits. Fix via `donmai project credentials github.com/foo/bar`.
- **Port collision** for the local exec endpoint. Daemon picks a free port by default; explicit `localExecPort` in config can hit collisions. Run `donmai daemon doctor` to detect.
- **Disk full** in the workarea-cache directory. Cache entries are scratch FS; running out of disk halts acquires. Default cleanup: warn at 80%, refuse new cache entries at 90%. The configured envelope is `capacity.workareaMaxDiskGb`.

`donmai daemon doctor` runs a scripted health check (config valid, credentials work, orchestrator reachable, disk available, workarea cache sane) and prints the failing condition.

Every remediation string above is an admission that the daemon could not heal itself. Per `ADR-2026-08-07-onboarding-is-the-only-user-action.md` D4 each one is therefore a work item rather than a UX affordance: a hint may not name an action whose inputs the daemon or its orchestrator already holds. Two rules follow, and both are cheap to enforce.

- **A hint naming a command the binary does not register is a gate failure, not a typo.** Assert every user-facing remediation string against the registered command set.
- **A condition that stops the host from serving does not live only in this log file.** It rides the host-status signal outward so it is visible wherever the user actually is — D7, on the signal completed by `ADR-2026-08-03-daemon-host-status-signal-completion.md`.

## Terminal workarea lease recovery and reaping (Accepted architecture; implementation and release pending)

`ADR-2026-07-18-bounded-terminal-workarea-leases.md` accepts the target daemon
contract below as architecture only. Implementation and release remain pending:
the daemon must not advertise a consumer capability that depends on it until the
lease, quarantine, outbox, recovery, and provider-release fixtures pass against
the exact approved released artifacts.

Before attempting to persist a terminal lease, the daemon writes and fsyncs a
record in a separate acquisition-quarantine journal. A durable lease supersedes
the guard only after it is re-read and associated with the cache entry. If lease
persistence fails, the guard remains: terminal success is not posted, the exact
workarea is excluded at boot, and automatic cleanup may only destroy it. If the
quarantine authority is unavailable, the affected provider root remains
unready; absence of a record after an I/O failure is never evidence of safety.

The lease keeps the exact workarea under the originating session's exclusive
ownership through the final durable `released` state. Before verification
access, one durable local execution claim binds the invocation and claim to the
lease, session, terminal result, and workarea. That Donmai transaction is the
sole claim-clock origin: its canonical claim bytes, returned `claimNowMs`, and
canonical `claimedAt` form one immutable tuple that byte-identical replay returns
without resampling after restart or ambiguous transport. The downstream consumer
must durably retain the exact successful claim-acknowledgement receipt before
any command starts or result is accepted. A byte-exact semantic acknowledgement
for the local claim moves `active -> release-pending`. Expiry is a separate path:
it only makes `active` eligible, after which the reaper records the expiry reason
and moves it to `release-pending`. Worker exit, drain, restart, acknowledgement,
and expiry do not themselves make the workarea reusable. Only a successful
provider disposition followed by durable `released` does so.

Recovery order is quarantine journal, leases and local claims, terminal-status
outbox, downstream receipt/result outbox state when configured,
session/catalog reconciliation, actionable indexes, then workarea-cache admission.
Duplicate terminal submissions reuse a record only for the same terminal-result
identity and canonical-byte-equivalent Donmai invariants. A configured privileged
consumer remains disabled unless the running released-artifact set and, when Kit
commands are selected, the active package identity and command-composition
digest exactly match their approved values. Package publication, architecture
acceptance, and source conformance do not by themselves authorize capability
advertisement, claim enablement, or workflow/CI activation.

Lease time uses signed integer Unix milliseconds. Acquisition samples the
persisted nondecreasing clock once and sets
`expiresAtMs = acquiredAtMs + leaseDurationMs`; the immutable maximum is
`acquiredAtMs + maxLeaseDurationMs`. Enqueue and claim each sample once and use
signed `remainingMs = expiresAtMs - nowMs`, with no second rounding step. The
accepted architecture sets `settlementBudgetMs` to `977000 ms`; its separate
`60000 ms` safety margin makes claim require `remainingMs > 1037000`, and the
optional separate `60000 ms` pre-claim queue makes enqueue require
`remainingMs > 1097000`.
Rollback is clamped to the persisted high-water mark and cannot increase
remaining time; a forward jump may make the lease immediately reapable. Renewal
may extend the same active lease only up to the acquisition-fixed `7200000 ms`
maximum and only before the terminal-status body carrying `expiresAt` is durably
saved. Before that save, renewal atomically updates both the durable lease and
full descriptor; afterward it is forbidden.

For a scan snapshot of actionable count `N`, exact batch capacity `B`, provider
concurrency `K`, maximum initial/inter-batch delay `I`, and provider-attempt
timeout `R`, every non-final serial batch contains exactly `B` records and the
final batch contains the remainder. Each admitted batch is work-conserving up to
`K`: it fills available attempt slots while an unstarted record remains. Each
snapshot record receives exactly one attempt before a failed attempt moves to a
later scan. Subject to continuous host, process, durable-authority, attempt-slot,
and provider-call-path availability, every attempt responds or times out within:

```text
ceil(N / B) * (I + ceil(B / K) * R)
```

Downtime has no bounded wall-clock duration. After restart or restored
availability, reconciliation creates a new recovery snapshot with a new `N` and
a new first-admission deadline no later than `I`; the exact partition,
work-conserving rule, and bound then apply anew.

Every durable `release-pending` record MUST cause at least one provider release
attempt. The callback MUST be idempotent for the same workarea and equivalent
disposition and MAY be invoked more than once. Failure keeps the record
`release-pending`, retains the workarea, retries with capped backoff and the same
timeout, and emits an operator-visible error. Expiry never counts as a
successful terminal acknowledgement.

## Per-session cancel-wire

Beyond drain (whole-daemon) and crash recovery, the daemon can stop **one**
in-flight session via the per-session cancel-wire. `WorkerSpawner.StopSession`
is the single in-process choke point; the localhost-only
`POST /api/daemon/sessions/<id>/stop` edge and the idle/no-progress watchdog both
drive it. A cancel rides the existing lock-refresh heartbeat (the refresh response
gains a `stop` field) for a fast cooperative in-band stop, escalating to
SIGTERM→SIGKILL only if the child does not exit. An unleased workarea follows the
post-mortem release policy. Under the accepted, implementation-pending
terminal-lease architecture, a non-released lease retains the exact workarea
through `release-pending` until
provider disposition is durably `released`; acknowledgement and expiry are only
separate eligibility reasons.

Two new terminal classifications carry distinct re-dispatch postures:

- **`FailureOperatorCancelled`** — an operator/orchestrator asked to stop. The
  orchestrator backstop MUST NOT re-dispatch it. The classification is set *before*
  the child's exit is observed, so an intentional cancel is never laundered into a
  crash (the bug this fixes: a killed child read as a crash and re-dispatched).
- **`FailureNoProgress`** — the no-progress watchdog self-cancelled a session that
  emitted no observable progress (tokens/turns/session-handle updates per
  `ADR-2026-06-13-daemon-sessionhandle-enrichment.md`) for a configured idle
  window. Its own mode (not folded into crash or operator-cancel) so the backstop
  can apply a bounded-retry policy specific to hangs.

The deferred-exit-trigger path is excluded from the multi-root case: a deferred
exit is scoped to the single root that armed it and never cascades to sibling
roots, and the no-progress watchdog does not count a sibling root's still-running
work as the deferred root's "no progress." Full contract:
`ADR-2026-06-22-daemon-per-session-cancel-wire.md`.

## Logs and observability

Three observability surfaces:

- **`donmai daemon logs`** — tail the daemon log. NDJSON by default. Pretty-printed when stdout is a TTY.
- **`donmai daemon stats`** — current capacity, sessions in flight, workarea-cache state per (repo, toolchain), recent acquire/release latencies.
- **Prometheus metrics** at `http://localhost:9101/metrics` (configurable). Scrape into your own monitoring if running multi-machine.

Key NDJSON fields the daemon emits (consumed by Layer 6 observability per `006`):

```
{ "time": "...", "level": "info", "event": "session-accepted",   "session_id": "...", "project": "...", "kit_set": [...], "estimated_duration_s": 600 }
{ "time": "...", "level": "info", "event": "workarea-acquired",  "session_id": "...", "workarea_id": "...", "acquire_path": "pool-warm", "duration_ms": 4200 }
{ "time": "...", "level": "info", "event": "session-completed",  "session_id": "...", "result": "delivered", "wall_clock_s": 580, "active_cpu_s": 312 }
{ "time": "...", "level": "warn", "event": "pool-invalidated",   "repo": "...", "reason": "lockfile-changed" }
{ "time": "...", "level": "info", "event": "auto-update-applied","from_version": "0.8.59", "to_version": "0.8.60", "drain_duration_s": 47 }
```

## HTTP Control API

The daemon binds to `127.0.0.1:7734` (configurable) and exposes a JSON HTTP
control API used by the `donmai daemon *` CLI surface (the platform binary's
already-shipped `host *` tree drives the same API downstream; see
`ADR-2026-08-03-cli-noun-tree-fleet-retirement.md`), by per-session
worker children, and by integration tooling. The contract is locked in
`ADR-2026-05-07-daemon-http-control-api.md`; this section is the
operations-facing reference.

**Auth model.** Localhost-only. The daemon binds to the loopback interface
exclusively and silently ignores any `Authorization: Bearer …` header.
Sending a platform user-JWT to this service expands the trust boundary for
no gain and the daemon's command-side clients (`afclient.Client`'s
daemon-targeted methods) MUST NOT attach one.

**Endpoint inventory.** Lifecycle (pre-existing seven, shipped before Wave 9):

```
GET    /api/daemon/status
GET    /api/daemon/stats
POST   /api/daemon/pause
POST   /api/daemon/resume
POST   /api/daemon/stop
POST   /api/daemon/drain
POST   /api/daemon/update
POST   /api/daemon/capacity
GET    /api/daemon/workarea/stats
POST   /api/daemon/workarea/evict
GET    /api/daemon/sessions
GET    /api/daemon/sessions/<id>
POST   /api/daemon/sessions/<id>/stop
GET    /api/daemon/heartbeat
GET    /api/daemon/doctor
GET    /healthz
```

`POST /api/daemon/sessions/<id>/stop` is the **per-session** cancel edge (distinct
from the daemon-wide `POST /api/daemon/stop`, which drains and stops the whole
process). It stops one in-flight session and leaves the rest of the fleet running.
It is localhost-only / no-bearer like the rest of the API, and drives the
in-process `WorkerSpawner.StopSession` primitive. Full contract — the in-band stop
signal, the `FailureOperatorCancelled` / `FailureNoProgress` terminal modes, and
the no-progress watchdog — is in
`ADR-2026-06-22-daemon-per-session-cancel-wire.md`.

#### Workarea-cache surface rename (2026-08-07) and its aliases

`GET /api/daemon/workarea/stats` and `POST /api/daemon/workarea/evict` were
`GET /api/daemon/pool/stats` and `POST /api/daemon/pool/evict` until 2026-08-07.
They report on and evict from the machine-local **workarea cache**
(`003-workarea-provider.md` § "The workarea cache") — never from an org capacity
pool, which the daemon has no authority over. `ADR-2026-08-07-execution-context-pool-and-placement-vocabulary.md`
D2.3 renamed them under `ADR-2026-08-03` D5.4's alias discipline:

| Surface | Superseded spelling (alias) | Removed in |
|---|---|---|
| `GET /api/daemon/workarea/stats` | `GET /api/daemon/pool/stats` | **v0.59.0** |
| `POST /api/daemon/workarea/evict` | `POST /api/daemon/pool/evict` | **v0.59.0** |
| `GET /api/daemon/stats?workarea=true` | `GET /api/daemon/stats?pool=true` | **v0.59.0** |
| `DaemonStatsResponse.workarea` | `DaemonStatsResponse.pool` | **v0.59.0** |
| `<binary> host stats --workarea` | `--pool` | **v0.59.0** |
| `capacity.workareaMaxDiskGb` | `capacity.poolMaxDiskGb` | **v0.59.0** |

Rules this rename is bound by, each of which is a defect if skipped:

- **Every alias declares a concrete removal version at creation.** `v0.59.0` —
  one minor after the release that creates them, matching the cadence the
  `daemon`→`host` aliases set. An alias with no removal version is a defect
  (`ADR-2026-08-03` D5.4).
- **The `?pool=true` query parameter and the `pool` response field must be
  aliased too.** An unrecognised query parameter is *ignored*, not rejected — so
  an un-aliased rename degrades silently (an older client asks for cache stats
  and gets a response with the section missing) rather than failing cleanly.
  Silent degradation is the worse failure and the one the alias exists to
  prevent.
- **`capacity.poolMaxDiskGb` needs a read alias on the config struct, not just
  in the CLI key allowlist.** The daemon's YAML load is non-strict, so an
  unrecognised key is dropped silently; the field's `0` means **no limit**; and
  the config writer replaces the whole `capacity` mapping, so an unmodelled key
  inside it is erased by the next unrelated `set`. A CLI-only alias would
  therefore turn an operator's existing disk cap into "no limit" and then delete
  it from disk — LRU eviction off, disk fills.

**Do not confuse `/api/daemon/workarea/*` (singular — the cache) with
`/api/daemon/workareas/*` (plural — individual workareas and their archives,
listed below).** They are one character apart and address different things. That
is an uncomfortable adjacency for a rename whose whole subject is one noun per
referent; it is recorded in `ADR-2026-08-07` § "One risk carried forward" along
with the unambiguous spelling (`/api/daemon/workarea-cache/*`) a follow-up
should take if it proves confusing in practice.

Provider/Kit/Workarea/Routing operator surfaces (Wave 9):

```
GET    /api/daemon/providers
GET    /api/daemon/providers/<id>

GET    /api/daemon/kits
GET    /api/daemon/kits/<id>
GET    /api/daemon/kits/<id>/verify-signature
POST   /api/daemon/kits/<id>/install
POST   /api/daemon/kits/<id>/enable
POST   /api/daemon/kits/<id>/disable
GET    /api/daemon/kit-sources
POST   /api/daemon/kit-sources/<name>/enable
POST   /api/daemon/kit-sources/<name>/disable

GET    /api/daemon/workareas
GET    /api/daemon/workareas/<id>
POST   /api/daemon/workareas/<archiveID>/restore
GET    /api/daemon/workareas/<archiveIDA>/diff/<archiveIDB>

GET    /api/daemon/routing/config
GET    /api/daemon/routing/explain/<sessionID>
```

The Workarea diff endpoint switches between a single JSON envelope and
NDJSON streaming based on entry count; the cutover threshold is configurable
via `daemon.yaml` key `workarea.diffStreamingThreshold` (default 1000).
Consumers MUST handle both shapes via `Content-Type` discrimination
(`application/json` vs `application/x-ndjson`). Full protocol detail in
`ADR-2026-05-07-daemon-http-control-api.md` § D4a.

The `/api/daemon/providers` response in the Wave 9 ship includes a
top-level `partialCoverage: true` flag and a `coveredFamilies:
["agent-runtime"]` array — the runner.Registry currently exposes only
AgentRuntime providers. The remaining seven Provider Families (Sandbox,
Workarea, VCS, IssueTracker, Deployment, AgentRegistry, Kit) return as
empty until per-family registries land in a future wave; consumers render
the caveat from the flag rather than sniffing for emptiness.

## Common operational patterns

### "I want to test a beta release on one machine"

```bash
donmai daemon set autoUpdate.channel beta
donmai daemon update                 # force-pull now
donmai daemon status                 # confirm new version
# revert later:
donmai daemon set autoUpdate.channel stable
```

### "I want to pause work for an hour without uninstalling"

```bash
donmai daemon pause                  # stops accepting new work; existing finishes
# ... do something ...
donmai daemon resume
```

### "I want to add a project I haven't wired credentials for yet"

```bash
donmai project allow github.com/newco/newrepo --no-credentials
# Daemon will refuse work for this project until credentials configured.
# Add credentials when ready:
donmai project credentials github.com/newco/newrepo
```

### "The workarea cache is getting big, disk is filling"

```bash
donmai daemon stats --workarea       # see usage by (repo, toolchain)
donmai daemon evict --repo github.com/old/project --older-than 7d
# or
donmai daemon set capacity.workareaMaxDiskGb 100
# the daemon will LRU-evict to fit
```

`--pool` and `capacity.poolMaxDiskGb` still work as deprecated aliases and are
removed in **v0.59.0** — see § "Workarea-cache surface rename (2026-08-07) and
its aliases". Setting the disk envelope to `0` means *no limit*, which disables
LRU eviction entirely.

### "I need to inspect a workarea after a session failed"

```bash
donmai session list --status failed --limit 10
donmai session inspect <session-id>
# Workarea was archived on failure (default); restore for inspection:
donmai session restore-workarea <session-id> --to ~/debug/sess-XYZ
```

## Open questions

1. **Per-machine vs per-user install on shared machines.** A workstation shared by two users: do they share one daemon (system-scoped) or each get their own (user-scoped)? Default user-scoped because credentials/policy diverge per user; system-scoped for hosted-team-machine scenarios. Tenant config selects.
2. ~~**GUI status surface.**~~ **Resolved.** The TUI's `daemon status` view (rendered via Bubble Tea v2) IS the GUI surface — `host status` once `ADR-2026-08-03-cli-noun-tree-fleet-retirement.md` D2 ships. A separate menu-bar / system-tray app would duplicate the same data and create a third surface to keep in sync.
3. **Self-update verification.** The daemon must verify its own update binary before swapping. Sigstore verification on the binary; reject if signature fails. Concrete impl ties to provider signing & trust verification.
4. **Daemon-to-daemon delegation.** Two daemons on the same LAN: should one delegate work to the other when overloaded? Or always go through the orchestrator? Default: through the orchestrator (preserves audit chain, scope resolution, cost attribution). Direct delegation is a P3 optimization.

These are intentional gaps for ADRs after operational experience.
