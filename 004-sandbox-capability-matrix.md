# 004 — Sandbox Capability Matrix

**Status:** Reference (initial draft)
**Last updated:** 2026-05-06
**Related:** `001-layered-execution-model.md`, `002-provider-base-contract.md`, `003-workarea-provider.md`, `006-cross-provider-interactions.md`, `014-tui-operator-surfaces.md`, `ADR-2026-05-06-tui-noun-consolidation.md`

## Why this exists

Donmai needs to scale from ~10 concurrent agents (a single Mac Studio's local capacity) to ~1000+ (cloud-burst across multiple providers) without the user or the agent caring where compute physically runs. We have six platform-shipped sandbox implementations today (`Local`, `Docker`, `K8s`, `Daytona`, `E2B`, `Modal`) plus a Vercel implementation in scope for SaaS turnkey, and a likely seventh (`Atomic` or other agent-native VCS-bundled compute) on the horizon.

Each provider has different lifecycle primitives, different cost shapes, different network topologies, and different snapshot/pause-resume support. A scheduler that knows about each by name doesn't scale: every new provider would force scheduler edits. The fix is **capability declaration**: each provider declares typed flags; the scheduler reasons about flags; new providers slot in by declaring their shape.

This doc defines the capability struct, profiles each shipped provider against it, and specifies the cross-provider scheduling algorithm that routes work to capacity.

## Reference implementation: donmai worker dial-out

The architecture's worker registration model is grounded in a working OSS implementation. From `donmai/worker/types.go`:

```go
type RegisterRequest struct {
    Hostname         string
    Version          string
    MaxAgents        int
    Capabilities     []string         // ["claude", "codex"] — to migrate to typed
    ActiveAgentCount int
    Status           string           // "idle" | "busy" | "draining"
}

type RegisterResponse struct {
    WorkerID                    string
    RuntimeJWT                  string
    HeartbeatIntervalSeconds    int
    PollIntervalSeconds         int
}
```

This is the dial-out flow described in §"Worker registration model" below. Workers boot with a one-time `rsp_live_…` registration token, exchange it for a scoped JWT, then poll/heartbeat. The orchestrator never initiates connections to workers — they come to it. This is the right shape for K8s pods, Docker containers, and the local daemon model in `011`.

The capability tag list (`["claude", "codex"]`) is a lightweight precedent for the typed `SandboxProviderCapabilities` struct in this doc. Migration path: both fields ship simultaneously, typed preferred when present, tag list deprecated over one major-version window. See `002` §"Capability-tag-to-typed-struct migration path."

## The interface

```ts
interface SandboxProvider extends Provider<'sandbox'> {
  /**
   * Provision compute for a worker session. Returns a handle the
   * orchestrator uses to talk to (or wait for) the worker process.
   */
  provision(spec: SandboxSpec): Promise<SandboxHandle>

  /**
   * Current state of a provisioned sandbox. Hosts may poll.
   */
  status(handle: SandboxHandle): Promise<SandboxStatus>

  /**
   * Tear down a sandbox. Idempotent.
   */
  terminate(handle: SandboxHandle): Promise<void>

  /**
   * Optional: pause a running sandbox to a $0-compute (storage-only) state.
   * Only valid when capabilities.supportsPauseResume is true.
   */
  pause?(handle: SandboxHandle): Promise<void>

  /**
   * Optional: resume a paused sandbox. ~1s on E2B, slower on others.
   */
  resume?(handle: SandboxHandle): Promise<void>

  /**
   * Optional: stream logs from the worker. Convention: NDJSON over stream.
   */
  streamLogs?(handle: SandboxHandle): AsyncIterable<LogEvent>

  /**
   * Optional: query current capacity. Used by the scheduler to decide
   * whether to dispatch locally or burst to cloud.
   */
  capacity?(): Promise<CapacitySnapshot>
}

interface SandboxSpec {
  // Identity
  sessionId: string
  scope: ProviderScope

  // Resources requested
  resources?: { vCpu?: number; memoryMb?: number; diskMb?: number; gpu?: GpuRequest }

  // Worker bootstrap
  registrationToken: string         // dial-out: injected as env var
                                    // dial-in: presented at exec time
  workerImage?: string              // override; otherwise provider default
  envVars?: Record<string, string>
  networkPolicy?: NetworkPolicy

  // Lifecycle
  maxDurationSeconds?: number
  idleTimeoutSeconds?: number

  // Workarea coupling — see 003 + 006
  workareaProviderId?: string       // which workarea provider is paired
  workareaSpec?: WorkareaSpec       // for providers that bundle compute+fs

  // Region preference
  region?: string                   // checked against capabilities.regions
}

interface SandboxHandle {
  readonly providerId: string
  readonly externalId: string       // provider-native identifier
  readonly transport: TransportEndpoint
  readonly provisionedAt: Date
}

interface TransportEndpoint {
  // For dial-in providers (orchestrator → sandbox)
  execUrl?: string                  // RPC endpoint to invoke commands
  authToken?: string                // ephemeral, scoped to this sandbox

  // For dial-out providers (worker → orchestrator)
  registrationUrl?: string          // where the worker dials home
  // (registrationToken on Spec is used; nothing extra here)
}

type SandboxStatus =
  | { state: 'provisioning' }
  | { state: 'ready' }
  | { state: 'running'; workerSessionId?: string }
  | { state: 'paused'; pausedAt: Date }
  | { state: 'terminated'; reason: string; terminatedAt: Date }
  | { state: 'failed'; error: string }
```

## Capabilities

```ts
interface SandboxProviderCapabilities {
  // Transport — how does the orchestrator talk to the worker?
  transportModel: 'dial-in' | 'dial-out' | 'either'

  // Snapshot/pause primitives — informs WorkareaProvider scheduling
  supportsFsSnapshot: boolean       // FS-only snapshot (Vercel, Daytona)
  supportsPauseResume: boolean      // memory + FS preserved (E2B, Modal preview)

  // Capacity & scheduling
  supportsCapacityQuery: boolean    // can answer "how much can I take right now"
  maxConcurrent: number | null      // hard ceiling; null = unbounded
  maxSessionDurationSeconds: number | null

  // Geography
  regions: string[]                 // ISO region codes; ['*'] for any

  // Platform (OS + CPU architecture)
  // Sessions request these via SandboxSpec; scheduler matches.
  // Critical for kit toolchain demands — a Rust toolchain installed
  // for darwin/arm64 is not the same as one for linux/x86_64.
  os: ('linux' | 'macos' | 'windows')[]
  arch: ('x86_64' | 'arm64' | 'wasm32')[]

  // Cost shape — drives scheduler economic routing
  idleCostModel: 'zero' | 'storage-only' | 'metered'
  billingModel: 'wall-clock' | 'active-cpu' | 'invocation' | 'fixed'
  // wall-clock: charged for every second running (E2B)
  // active-cpu: charged only for CPU not in I/O wait (Vercel)
  // invocation: per-call (Lambda-style)
  // fixed: bring-your-own-hardware (local, self-hosted K8s)

  // Resource ceilings
  maxVCpu: number | null
  maxMemoryMb: number | null
  supportsGpu: boolean

  // Network
  supportsCustomNetworkPolicy: boolean
  egressDefault: 'allow-all' | 'deny-all' | 'allowlist'

  // A2A / federated work
  // A2A is "execute work in someone else's workarea+sandbox"
  // — modeled here as a transport flavor, not a separate plugin family
  isA2ARemote: boolean              // when true, this provider represents
                                    // a remote agent over the A2A protocol
}
```

## Capability profile by provider

The platform ships against multiple cloud providers (Blaxel, Cloudflare, Daytona, E2B, Modal, Runloop, Vercel and others). The OSS execution layer ships only `Local`. Profiles below are first-cut declarations; each implementation owns its declared values and the host verifies via discrepancy detection (see `002`).

| Capability | Local | Vercel | E2B | Modal | Daytona | Docker | K8s |
|---|---|---|---|---|---|---|---|
| `transportModel` | either | dial-in | dial-in | dial-in | dial-in | either | either (dial-out conv. for fleets) |
| `supportsFsSnapshot` | ❌ | ✅ (p75 <1s) | ✅ | ✅ (preview) | ✅ (FS archive) | ❌ | ❌ (volume snap optional) |
| `supportsPauseResume` | ❌ | ❌ | ✅ (~1s) | ✅ (preview) | ❌ | ❌ | ❌ |
| `supportsCapacityQuery` | ✅ (host-local) | ❌ | ❌ | ❌ (FaaS opaque) | ❌ | ✅ | ✅ (kubectl top + quotas) |
| `maxConcurrent` | host RAM | 2000 (Ent default) | tier-gated | tier-gated | tier-gated | host CPU | cluster |
| `maxSessionDurationSeconds` | unlimited | 18000 (5h Pro) | 86400+ | tier | days (long-lived) | unlimited | unlimited |
| `regions` | local | iad1 only | multi | multi | multi | local | cluster |
| `os` | host OS | linux | linux | linux | linux | host OS | linux (typical) |
| `arch` | host arch | x86_64 | x86_64 | x86_64, arm64 | x86_64 | host arch | x86_64, arm64 |
| `idleCostModel` | zero | metered (no idle tier) | zero (paused) | metered (idle warm billed) | storage-only (archived) | zero | metered (reserved nodes) |
| `billingModel` | fixed | active-cpu | wall-clock | wall-clock | wall-clock | fixed | fixed |
| `maxVCpu` | host | 8 (Pro) / 32 (Ent) | tier | tier | tier | host | cluster |
| `maxMemoryMb` | host | 16384 / 65536 | tier | tier | tier | host | cluster |
| `supportsGpu` | ❌ (typically) | ❌ | ❌ | ✅ | ❌ | host-dep | cluster |
| `egressDefault` | allow-all | allow-all (configurable) | allow-all | allow-all | allow-all | allow-all | cluster-policy |
| `isA2ARemote` | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ |

The seventh row — A2A as transport flavor — is its own provider implementation in code (`A2ASandboxProvider`), declaring `isA2ARemote: true` and `transportModel: 'dial-in'` (the orchestrator dials into the remote A2A peer). Treating remote A2A agents as a sandbox provider unifies "where does work execute" reasoning regardless of whether the work lives on our infra or someone else's.

The capability flags above are the *declared* shape — what a provider/host advertises at registration time. The corresponding *runtime view* is `LiveCapacityInstance.capabilities` in the live execution capacity contract (`014-tui-operator-surfaces.md` § "Live capacity contract" and `ADR-2026-05-06-tui-noun-consolidation.md` Addendum 2026-05-06). Each live row carries the capability tags currently in force on that specific instance — the operator-facing reflection of what this doc specifies as the provider's capability schema.

## Regime fit — when to choose what

The matrix above tells the scheduler what's *possible*; the table below tells operators what's *appropriate*. Tenants pick the regime; the scheduler routes within it.

| Workload regime | Primary | Fallback | Why |
|---|---|---|---|
| **OSS local dev** | Local pool | — | Mac Studio fleet, no cloud spend, no auth ceremony |
| **SaaS turnkey, NA, active-burst** | Vercel | E2B | Same Vercel account/auth/billing as the SaaS app, active-CPU billing wins for I/O-heavy agent work |
| **Cross-region, long-idle, paused pools** | E2B | Modal | $0 paused tier, multi-region, mid-process pause/resume the killer feature for bursty queues |
| **Enterprise self-hosted** | K8s | Docker | Already production-grade in the platform's existing impl, fits VPC/private-network requirements |
| **Devcontainer-style long-lived workspaces** | Daytona | Local | Days-long workspaces, FS archive, dev-environment ergonomics |
| **GPU-bound agent work (rare today)** | Modal | E2B+GPU | Modal is the only one with first-class GPU billing |
| **Federated work via A2A (someone else's agent)** | A2A | — | Routes to a remote agent over the A2A protocol; we orchestrate, they execute |
| **Fast small-task FaaS (sub-agents)** | Modal | Vercel | `min_containers` warmth, sub-second invocation, snapshot resume |

Tenant-level regime selection lives in `.rensei/config.yaml` or platform config. Per-session override is allowed for forensics or special cases.

## The cross-provider scheduler

The scheduler decides which `SandboxProvider` (and which `WorkareaProvider`) handles a session. The interface is small:

> **Operator surface forward-reference.** The scheduler's per-session
> decisions are surfaced through the local daemon's HTTP control API at
> `GET /api/daemon/routing/explain/<sessionID>` (and the rolling-config
> view at `GET /api/daemon/routing/config`). See `011-local-daemon-fleet.md`
> § "HTTP Control API" and `ADR-2026-05-07-daemon-http-control-api.md` §§
> D1, D4 for endpoint contracts. The wire shape of the explain response
> mirrors the `RoutingDecision` + `RoutingTraceStep` types defined for the
> SaaS dashboard so the same renderer composes both surfaces.


```ts
interface SandboxScheduler {
  schedule(spec: SandboxSpec, hints?: ScheduleHints): Promise<SandboxHandle>
}

interface ScheduleHints {
  preferredProviders?: string[]     // tenant config
  forbiddenProviders?: string[]
  preferredRegions?: string[]
  costBudgetCents?: number          // session-level cap
  latencyBudgetMs?: number          // willingness to wait for warm path
  workareaProviderHint?: string     // bias toward a paired workarea provider
}
```

### Scheduling algorithm

1. **Filter by capability constraints from `spec`.**
   - `region` matches `capabilities.regions`.
   - `os` and `arch` match `capabilities.os` / `capabilities.arch` (both required).
   - `resources.vCpu/memoryMb` ≤ provider ceilings.
   - `resources.gpu` requires `supportsGpu: true`.
   - `maxDurationSeconds` ≤ `maxSessionDurationSeconds`.
   - Workarea pairing: provider supports the requested workarea provider's snapshot/pause-resume needs (e.g., a session asking for `release(pause)` requires `supportsPauseResume: true`).

2. **Filter by tenant policy.**
   - Hints (`preferredProviders` / `forbiddenProviders`).
   - Layer 6 policy hooks may reject candidates (e.g., "this project may only run on `EnterpriseK8s`").

3. **Filter by capacity** (best-effort; not all providers expose `capacity()`).
   - Drop providers reporting `unhealthy` health.
   - Drop providers above 90% of `maxConcurrent` if known.

4. **Score remaining candidates by cost + latency.**
   - Cost: normalize `billingModel` to expected-cents-per-session for the workload shape (active-CPU vs wall-clock matters here — agent workloads are I/O-heavy, so Vercel's `active-cpu` often beats E2B's `wall-clock` despite higher headline rate).
   - Latency: sample-based estimate of `expectedAcquireMs` for paired workarea provider (warm pool / paused sandbox available?).
   - Linger penalty: add expected idle cost over typical session length.

5. **Pick the lowest-scored provider.** Ties broken by tenant `preferredProviders` order; final tie broken by lowest `providerId` for determinism.

6. **Provision and return.** On provision failure, blacklist for a back-off window and retry next-best.

### Capacity snapshots

For providers that support it, `CapacitySnapshot` lets the scheduler reason about real-time load:

```ts
interface CapacitySnapshot {
  provisionedActive: number          // currently running
  provisionedPaused: number          // not running, can resume cheaply
  maxConcurrent: number | null       // ceiling
  estimatedAvailable: number         // safe to provision now
  warmPoolReady: number              // sessions that can start in <Xs
  capturedAt: Date
}
```

Local pool: trivially computable. K8s: `kubectl top` + `ResourceQuotas`. Docker: `/info` and host cgroups. Daytona: workspace counts via API. E2B / Modal / Vercel: opaque (return `null` from `capacity()`); scheduler falls back to optimistic provisioning + retry-on-rejection.

### Persistent vs on-demand modes

The platform's existing `projects.sandboxMode: 'persistent' | 'on_demand'` distinction is **a scheduler bias, not a provider type**. Both modes use the same provider implementations.

- **Persistent** — scheduler keeps `provisionedActive` ≥ baseline regardless of demand. Workers stay registered. Acquire-acquire-acquire is fast.
- **On-demand** — scheduler provisions on demand and tears down when sessions end. `provisionedActive` tracks demand directly. Cheaper but slower per-session.

Capability flag interaction: a provider with `idleCostModel: 'zero'` (E2B paused) collapses the persistent/on-demand distinction economically — paused workers cost storage only, so you can run "persistent" mode without paying for idle compute.

## Worker registration model

Two transport flavors, declared per provider:

### Dial-in (managed sandboxes — Daytona, E2B, Modal, Vercel)

The orchestrator holds a connection to the sandbox's hosted control plane. Provisioning returns a handle with an `execUrl` and `authToken`. To dispatch work: call the provider's `exec` API. The worker process inside the sandbox is essentially anonymous — the orchestrator drives it.

This is the dominant model in research findings (E2B's `envd`, Modal's direct connection, Daytona's hosted control plane). It's how `agent.runCommand({...})` actually works.

### Dial-out (substrate platforms — K8s, Docker fleet, on-demand cloud)

The orchestrator provisions compute and waits. A worker process inside the compute boots, reads `DONMAI_REGISTRATION_TOKEN` from env, dials the orchestrator's registration endpoint, presents the token, and receives a scoped JWT. From then on, the worker pulls work from a queue (Redis/Valkey/etc.).

This is the platform's existing model (`maybeProvisionWorker` flow). Works perfectly for K8s and Docker.

### Either (host-shared kernel — Local, sometimes Docker)

Both transports are valid. Local Mac Studio: dial-in via Unix-domain socket (loopback) is simplest. K8s pod on the same VPC: dial-in is fine. K8s pod across VPC: dial-out queue-pull avoids firewall pain. Provider declares `'either'`; scheduler picks based on network topology.

### A2A as transport flavor

A remote A2A agent registers as a `SandboxProvider` with `isA2ARemote: true`. Provisioning is a no-op (the remote already exists). `provision` returns a handle whose `execUrl` is the A2A peer's endpoint. The orchestrator dispatches work via the A2A protocol, treating the response as session output. A2A doesn't reshape the architecture, it slots into a specific extension point.

## Local daemon mode (the central machine pattern)

The Local sandbox provider has two operational modes. Tenants pick one per machine.

### Foreground mode (legacy default, pre-daemon)

A worker fleet is spawned alongside the user's editor session — typically by a VSCode/Cursor SessionStart hook or `pnpm orchestrator` invocation. The fleet's lifetime is tied to that editor process; closing the editor stops the fleet. Each project's workspace runs its own fleet, scoped to that project.

This works for solo dev with one project open. It breaks down at the scale a real user actually operates: 8–20+ open workspaces, each spinning its own fleet, each requiring manual updates on every release. The user-friction cost is real and quickly dominates the OSS experience.

### Daemon mode (recommended for any user with >1 project)

A single long-running daemon registers with the orchestrator as a worker pool. One per machine, not per project. Work for any allowed project routes to whichever daemon worker has capacity; the workarea provider handles the per-session clone/checkout/toolchain setup.

Concretely:

```
┌─────────────────────────────────────────────────────────────────┐
│                       Mac Studio (one machine)                   │
│                                                                  │
│  ┌────────────────────────────────────────────────────────┐    │
│  │  rensei-daemon (system service)                        │    │
│  │                                                        │    │
│  │  - registers capacity: 16 vCPU, 64GB, projects: [*]   │    │
│  │  - subscribes to work queue                           │    │
│  │  - spawns N worker processes on demand                │    │
│  │  - self-updates on release                            │    │
│  └────────────────────────────────────────────────────────┘    │
│                          ↓ spawns                               │
│  ┌────────────────────────────────────────────────────────┐    │
│  │  worker-1, worker-2, … worker-N (per session)         │    │
│  │  each operates on a workarea acquired per session     │    │
│  └────────────────────────────────────────────────────────┘    │
│                          ↓ acquires                             │
│  ┌────────────────────────────────────────────────────────┐    │
│  │  WorkareaProvider local pool                          │    │
│  │  - warm pool members per (repo, toolchain) key       │    │
│  │  - cold-path: clone + install on first project use   │    │
│  └────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────┘
```

### Daemon lifecycle

The daemon implements the `SandboxProvider` interface but with extended lifecycle hooks beyond the per-session ones:

- **`daemon.start()`** — invoked once at boot. Reads config (`~/.rensei/daemon.yaml`), validates git credentials per allowed project, registers with the orchestrator (dial-in or dial-out per `transportModel`), reports capacity.
- **`daemon.refreshCapacity()`** — periodic (default 60s). Re-reports current load, available memory, healthy worker count.
- **`daemon.acceptWork(spec)`** — orchestrator dispatches work; daemon validates allowed-project, spawns a worker, returns a `SandboxHandle`.
- **`daemon.update()`** — checks for new OSS release; downloads, verifies signature, restarts cleanly with in-flight work draining first.
- **`daemon.stop()`** — graceful shutdown; outstanding sessions get a configurable grace period to finish, then SIGTERM.

### Configuration shape

```yaml
# ~/.rensei/daemon.yaml
apiVersion: rensei.dev/v1
kind: LocalDaemon

machine:
  id: mac-studio-marks-office
  region: home-network         # informs the scheduler about latency

capacity:
  maxConcurrentSessions: 8
  maxVCpuPerSession: 4
  maxMemoryMbPerSession: 8192
  reservedForSystem:
    vCpu: 4                    # don't starve macOS / VSCode
    memoryMb: 16384

projects:
  # Allowed projects, with credentials and clone strategy
  - id: renseiai
    repository: github.com/renseiai/renseiai
    cloneStrategy: shallow     # or 'full' | 'reference-clone'
    git:
      credentialHelper: osxkeychain
      sshKey: ~/.ssh/id_ed25519_renseiai
  - id: agentfactory
    repository: github.com/renseiai/agentfactory
    cloneStrategy: full
    git:
      credentialHelper: osxkeychain

orchestrator:
  url: https://platform.rensei.dev      # SaaS — or ssh://localhost:NNNN for OSS-only
  authToken: ${DONMAI_DAEMON_TOKEN}

autoUpdate:
  channel: stable              # 'stable' | 'beta' | 'main'
  schedule: nightly            # 'nightly' | 'on-release' | 'manual'
  drainTimeoutSeconds: 600     # max wait for in-flight work before restart

observability:
  logFormat: ndjson
  logPath: ~/.rensei/daemon.log
  metricsPort: 9101            # Prometheus scrape, optional
```

### Capability declarations for daemon mode

Local daemon mode shifts a few declared capabilities relative to foreground mode:

```ts
{
  // Worker pool model — workers register with orchestrator at daemon start
  transportModel: 'either',   // dial-in via Unix socket or dial-out via queue
                              // — orchestrator picks per network topology

  // Capacity is queryable in real time (the daemon owns the host)
  supportsCapacityQuery: true,
  maxConcurrent: <from config>,

  // Cost is fixed (it's the user's hardware)
  idleCostModel: 'zero',
  billingModel: 'fixed',

  // Toolchain provisioning happens in the workarea provider, not sandbox
  // (daemon doesn't bake toolchains into worker images — it's the host machine)
}
```

### Why this matters for OSS

The "one CLI, one bootstrap, voila you can work" promise from `001` is *almost* true today, but the per-VSCode worker fleet bleeds it. A user with 20 open workspaces is updating 20 fleets every time an OSS release ships. Daemon mode collapses that to one daemon, one update, all projects served.

The discipline this preserves: daemon mode is shipped in the OSS execution layer; it does not require the SaaS plane. An OSS-only user with no SaaS subscription can still run `rensei daemon start`, register their machine with their *own* orchestrator instance (or local file-queue-backed orchestrator for solo work), and get the central-fleet experience. SaaS adds multi-machine fleet aggregation, dashboards, and remote dispatch.

### Linear realignment hook

This pattern is currently absent from the platform's icebox parse — there's no issue covering "local daemon" as an explicit mode. Net-new issue to author (see [`rensei-architecture/009-linear-realignment.md`](https://github.com/RenseiAI/rensei-architecture/blob/main/009-linear-realignment.md)):

> **`Local daemon mode for the OSS execution layer`** — One per-machine daemon registers as a multi-project worker pool, replaces per-VSCode-workspace fleet model, supports auto-update, project allowlist, and workarea-on-demand bootstrapping. Closes the friction described by users running 8–20+ workspaces.

## OSS vs SaaS responsibilities

| Concern | OSS | SaaS |
|---|---|---|
| `SandboxProvider` interface | ✅ owns | consumes |
| Capability struct | ✅ owns | consumes |
| `Local` impl | ✅ ships | inherits |
| `Docker` / `K8s` impls | optional contrib | ✅ ships |
| `Vercel` / `E2B` / `Modal` / `Daytona` impls | ❌ (cloud creds) | ✅ ships |
| Cross-provider scheduler | ✅ owns interface | ✅ ships hosted impl |
| Capacity-aware burst routing | ✅ ships local-only | ✅ ships hybrid (local + cloud) |
| Per-tenant regime config | ❌ (single-tenant) | ✅ owns |
| Fleet observability dashboard | ❌ (basic logs) | ✅ owns |

The OSS layer can run a multi-Mac-Studio fleet on a LAN with the local provider plus optional Docker. SaaS adds the cloud burst story and the multi-tenant control plane.

## Open questions

1. **Workarea provider pairing.** Should a `SandboxSpec` always carry a `workareaSpec`, or are there sandbox uses without workareas (e.g., GPU eval runs that don't touch a repo)? Default: yes-always for coding-agent flows; admit "no-workarea" mode for benchmarks/eval. Concrete in `006-cross-provider-interactions.md`.
2. **Scheduler bias function.** The cost/latency score weighting needs tenant-level config (cost-sensitive customers vs latency-sensitive). Default: 70/30 cost/latency. Real customers will want this tunable.
3. **Health check semantics.** Do we treat a single failed `health()` as unhealthy, or require N consecutive? Default: fail-fast on `unhealthy`, two-strike on `degraded`. Tenants may override.
4. **A2A capability shape.** A remote A2A agent doesn't expose VCpu/Memory ceilings — those are the remote's concern. Capabilities for A2A providers may need a `delegatedCapacity: true` flag and a fallback contract that the remote will refuse if it can't satisfy. Not yet specified; revisit when A2A becomes load-bearing.

These are intentional gaps to be locked by ADR after implementation experience.
