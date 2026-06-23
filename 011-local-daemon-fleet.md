# 011 — Local Daemon Fleet (Operations & UX)

**Status:** Reference (initial draft)
**Last updated:** 2026-05-06
**Boundary:** shared (OSS-canonical; platform extensions live at `rensei-architecture/011-local-daemon-fleet-platform-extensions.md`)
**Related:** `004-sandbox-capability-matrix.md` (architectural shape lives there), `ADR-2026-05-06-tui-noun-consolidation.md`, `ADR-2026-05-07-daemon-http-control-api.md`, `ADR-2026-06-03-injectable-state-dir.md` (on-disk daemon state dir + log dir are now embedder-injected; OSS default `donmai`).

> **Command surface note (2026-05-06):** Per `ADR-2026-05-06-tui-noun-consolidation.md`, the daemon CLI lifecycle commands (install, status, doctor, drain, update) are now invoked as `<binary> host *` (e.g., `donmai host install` for the OSS binary; the platform binary's equivalent on the platform). Both binaries share the same noun model via `afcli.RegisterCommands`. The `<binary> daemon *` form shown in the example fences below remains as a hidden deprecated alias for one release.

## Why this exists

The architectural shape of the local daemon is in `004` — `SandboxProvider` running in persistent mode, registered once, serving multiple projects. This doc is the operations and UX manual for the **single-machine OSS deployment**: how a user installs it, configures it, recovers from problems. Multi-machine fleets (SaaS aggregation across machines) are a platform extension; see the platform-extensions doc.

The motivating user pain (called out during architectural review):

> I have 8 different VSCode workspaces currently open, and routinely have more than 20 open, each with their own auto-start of a worker fleet. This means I'm constantly switching windows and tabs just to update my fleet when a release ships.

The architectural answer is the daemon model from `004`. This doc makes it real for users.

## The user model

> "I have a Mac. I want to install Donmai once, configure it once, and have any project's work execute on this Mac as long as the project is allowed and credentials are wired up. I never want to think about the worker fleet again."

Concretely, the user's day:

1. **Once at install:** `brew install donmai && donmai host install` (or equivalent on Linux). Daemon starts; registers as a system service.
2. **Once per project:** `donmai project allow github.com/foo/bar`. Daemon now accepts work for that project. Credentials are picked up from system keychain or per-project config.
3. **Day-to-day:** open VSCode for any allowed project, or don't. Linear webhooks → orchestrator → daemon. The daemon clones the repo on first session, warms a workarea pool, and runs sessions. No window-switching, no per-workspace fleet management.
4. **On release:** daemon auto-updates on configured channel. Drains in-flight work, restarts cleanly. User sees a single notification or nothing at all.

## Installation paths

### macOS (launchd, primary target)

```bash
# One-line install
brew install donmai
donmai host install            # writes ~/Library/LaunchAgents/dev.donmai.daemon.plist
                           # loads agent; survives reboots and re-logins

# Verify
donmai host status
# donmai-daemon: running   pid 12345   uptime 2h13m   sessions 3 / 8
```

The launchd plist is generated from a template; the user doesn't edit it directly. The daemon binary lives at `/usr/local/bin/donmai` (or `~/.donmai/bin/` for user-scoped install). Logs at `~/Library/Logs/donmai/daemon.log` per macOS convention.

### Linux (systemd)

```bash
# Distro-agnostic via the Donmai installer
curl -fsSL https://get.donmai.dev | sh

# User-scoped systemd unit (recommended)
donmai host install --user
systemctl --user status af-daemon

# System-scoped unit (multi-user shared machine)
sudo donmai host install --system
sudo systemctl status af-daemon
```

Logs to `journalctl --user -u af-daemon`. The OSS execution layer ships only the user-scoped variant by default; system-scoped is opt-in.

### Windows (service)

**OSS shipping order: deferred. Architecture: in scope.**

Initial OSS support is deferred — we don't have the user demand or the test coverage today, and the user has stated a preference against Windows-as-primary. But the architecture (`004` capability flags, `005` per-OS kit contributions) admits Windows as a first-class OS. When regulated banking customers eventually require it (and they will), the daemon port is a 4-week scoped piece of work, not an architectural rewrite.

Concretely, the Windows port consists of: a Windows Service host (replacing launchd plist / systemd unit), Windows-flavored credential helpers (Windows Credential Manager), pool directory in `%LOCALAPPDATA%\rensei`, NDJSON logs to ETW or file. Kits already declare per-OS install scripts and command overrides per `005`; the Spring kit, the TS kit, and the Rust kit all work as long as their `[provide.toolchain_install.windows]` and `[provide.commands_override.windows]` sections are populated.

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
$ donmai host setup

Welcome to Donmai. Let's get your machine working.

[1/5] Machine identity
  Machine ID (auto-generated): mac-studio-marks-office
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
  Status: donmai host status
  Logs:   donmai host logs
  Stop:   donmai host stop
```

The wizard writes `~/.donmai/daemon.yaml` matching the schema in `004`. Idempotent: re-running re-prompts for changed values without resetting unchanged ones.

The Step 3 "Donmai Platform (SaaS)" choice walks through registration with `donmai.dev/dashboard`; that branch is documented in the platform-extensions doc.

## Config file walkthrough

The full schema is in `004`. Key knobs and when to use them:

### `capacity.maxConcurrentSessions`

How many sessions the daemon will run in parallel. Default: 8 on a Mac Studio, 4 on a MacBook Pro. Hard ceiling enforced by the scheduler.

If sessions are heavy (Cargo builds, large test suites), drop this. If sessions are light (TS typecheck only), raise it. Watch `donmai host stats` for per-session resource usage.

### `capacity.reservedForSystem`

Cores and memory the daemon will *not* touch. The user is still using their machine; sessions can't starve macOS or VSCode. Default is conservative (4 cores, 16 GB RAM); tune down if you want more session throughput.

### `projects[].cloneStrategy`

- `shallow` (default) — `git clone --depth 1`. Fast for short-lived sessions; loses history.
- `full` — full clone. Slower first-time, supports `git log`-heavy operations.
- `reference-clone` — clone-from-existing-local-mirror. Fast and full history if you already have a clone elsewhere on disk.

The workarea provider's local pool composes with this — first acquire pays the clone cost; subsequent acquires reuse the pool member.

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
- `manual` — never auto-updates; you run `donmai host update` when ready.

### `orchestrator.url`

Where the daemon receives work assignments.

- `file:///$HOME/.rensei/queue` — local file queue. Solo dev, no network. The OSS layer ships a minimal queue runner that delivers work from local Linear webhooks or CLI dispatch.
- `https://your-deployed-orchestrator.example.com` — self-hosted orchestrator endpoint.
- `donmai.dev/dashboard` — the SaaS control plane (platform-extension; see the platform-extensions doc for setup).

## Drain semantics

When the daemon needs to restart (auto-update, manual stop, system reboot scheduled), it drains:

1. **Stop accepting new work.** Daemon updates its registered status to `draining`; the orchestrator routes new sessions elsewhere.
2. **Wait for in-flight sessions.** Up to `drainTimeoutSeconds` (default 600). Sessions get a SIGTERM at the timeout; their workareas are released with `mode: archive` so they can be inspected post-mortem.
3. **Release pool members cleanly.** Pool members in `ready` or `warming` state are torn down; `acquired` members are forced-released as above.
4. **Restart.** New process boots, re-registers, status returns to `ready`.

For graceful planned restarts (e.g., a reboot), `donmai host drain` returns when drain completes. CI scripts or shutdown hooks can wait on it.

## Recovery from crash

If the daemon process dies unexpectedly:

1. **System service auto-restart.** launchd / systemd brings it back. Default backoff: immediate, then 30s, 5m for repeated crashes.
2. **In-flight sessions become orphans.** Their workareas remain on disk. The new daemon process scans on boot, marks orphan workareas as `archive`, and notifies the orchestrator. The orchestrator may re-dispatch the corresponding session work (idempotency depends on the work type — backstop logic in `packages/core/src/orchestrator/session-backstop.ts` handles much of this).
3. **Pool state survives.** Pool members are filesystem state; they're rediscovered on daemon boot via a lightweight pool-scan that re-validates each member's `cleanStateChecksum`.
4. **Logs preserve crash context.** macOS: `~/Library/Logs/donmai/daemon.log`; Linux: `journalctl --user -u donmai-daemon`. The daemon emits a final crash dump to the same path before exiting (when possible).

If the daemon refuses to start, common causes:

- **Bad credentials** for a configured project. Daemon logs the project ID and exits. Fix via `donmai project credentials github.com/foo/bar`.
- **Port collision** for the local exec endpoint. Daemon picks a free port by default; explicit `localExecPort` in config can hit collisions. Run `donmai host doctor` to detect.
- **Disk full** in the pool directory. Pool members are scratch FS; running out of disk halts acquires. Default cleanup: warn at 80%, refuse new pool members at 90%.

`donmai host doctor` runs a scripted health check (config valid, credentials work, orchestrator reachable, disk available, pool sane) and prints the failing condition.

## Per-session cancel-wire

Beyond drain (whole-daemon) and crash recovery, the daemon can stop **one**
in-flight session via the per-session cancel-wire. `WorkerSpawner.StopSession`
is the single in-process choke point; the localhost-only
`POST /api/daemon/sessions/<id>/stop` edge and the idle/no-progress watchdog both
drive it. A cancel rides the existing lock-refresh heartbeat (the refresh response
gains a `stop` field) for a fast cooperative in-band stop, escalating to
SIGTERM→SIGKILL only if the child does not exit; the session's workarea is released
with `mode: archive` for post-mortem inspection.

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

- **`donmai host logs`** — tail the daemon log. NDJSON by default. Pretty-printed when stdout is a TTY.
- **`donmai host stats`** — current capacity, sessions in flight, pool state per (repo, toolchain), recent acquire/release latencies.
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
control API used by the `donmai`/platform-binary `host *` CLI surface, by per-session
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
GET    /api/daemon/pool/stats
POST   /api/daemon/pool/evict
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
donmai host set autoUpdate.channel beta
donmai host update                 # force-pull now
donmai host status                 # confirm new version
# revert later:
donmai host set autoUpdate.channel stable
```

### "I want to pause work for an hour without uninstalling"

```bash
donmai host pause                  # stops accepting new work; existing finishes
# ... do something ...
donmai host resume
```

### "I want to add a project I haven't wired credentials for yet"

```bash
donmai project allow github.com/newco/newrepo --no-credentials
# Daemon will refuse work for this project until credentials configured.
# Add credentials when ready:
donmai project credentials github.com/newco/newrepo
```

### "Pool's getting big, disk is filling"

```bash
donmai host stats --pool           # see usage by (repo, toolchain)
donmai host evict --repo github.com/old/project --older-than 7d
# or
donmai host set capacity.poolMaxDiskGb 100
# the daemon will LRU-evict to fit
```

### "I need to inspect a workarea after a session failed"

```bash
donmai session list --status failed --limit 10
donmai session inspect <session-id>
# Workarea was archived on failure (default); restore for inspection:
donmai session restore-workarea <session-id> --to ~/debug/sess-XYZ
```

## Open questions

1. **Per-machine vs per-user install on shared machines.** A workstation shared by two users: do they share one daemon (system-scoped) or each get their own (user-scoped)? Default user-scoped because credentials/policy diverge per user; system-scoped for hosted-team-machine scenarios. Tenant config selects.
2. ~~**GUI status surface.**~~ **Resolved.** The TUI's `host status` view (rendered via Bubble Tea v2) IS the GUI surface. A separate menu-bar / system-tray app would duplicate the same data and create a third surface to keep in sync.
3. **Self-update verification.** The daemon must verify its own update binary before swapping. Sigstore verification on the binary; reject if signature fails. Concrete impl ties to provider signing & trust verification.
4. **Daemon-to-daemon delegation.** Two daemons on the same LAN: should one delegate work to the other when overloaded? Or always go through the orchestrator? Default: through the orchestrator (preserves audit chain, scope resolution, cost attribution). Direct delegation is a P3 optimization.

These are intentional gaps for ADRs after operational experience.
