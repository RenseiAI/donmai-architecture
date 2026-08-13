# 004 — Sandbox Capability Matrix

**Status:** Reference
**Last updated:** 2026-08-07
**Related:** `001-layered-execution-model.md`, `002-provider-base-contract.md`, `003-workarea-provider.md`, `006-cross-provider-interactions.md`, `014-tui-operator-surfaces.md`, `ADR-2026-05-06-tui-noun-consolidation.md`, `ADR-2026-08-07-execution-context-pool-and-placement-vocabulary.md`.

> **Vocabulary note (2026-08-07).** This doc predates
> `ADR-2026-08-07-execution-context-pool-and-placement-vocabulary.md`, which
> narrows several nouns it uses loosely. Read it with that ADR's R1 building
> blocks in hand: the **unit** is an *execution context* (wire noun `instance`);
> a **sandbox** is one *kind* of execution context — the ephemeral,
> provider-minted kind — not a synonym for the unit; a **pool** is a
> single-provider *source* of execution contexts; and a **capacity profile** is
> a named policy over an ordered list of pools. The `SandboxProvider` family
> name is deliberately unchanged (that ADR's D1/D10.5).

## Why this exists

Donmai needs to scale from ~10 concurrent agents (a single Mac Studio's local capacity) to ~1000+ without the user or the agent caring where compute physically runs. We have six platform-shipped sandbox implementations today (`Local`, `Docker`, `K8s`, `Daytona`, `E2B`, `Modal`) plus a Vercel implementation in scope for SaaS turnkey, and a likely seventh (`Atomic` or other agent-native VCS-bundled compute) on the horizon.

That scale comes from **an org running many pools and granting capacity profiles over them** — not from bursting. There is no burst mechanism: no accepted overflow policy, no exhaustion trigger, and no schema for one. An earlier revision of this doc opened by promising `cloud-burst across multiple providers`; that promise was never implemented and the routing column that carried the intent was subsequently deleted. `ADR-2026-08-07` D7 records the absence as fact and names **failure-triggered routing-around** — honouring the capacity profile's existing order when a dispatch *fails* — as the first iteration. Predictive burst remains undesigned and needs its own ADR.

Each provider has different lifecycle primitives, different cost shapes, different network topologies, and different snapshot/pause-resume support. A router that knows about each by name doesn't scale: every new provider would force router edits. The fix is **capability declaration**: each provider declares typed flags; the router reasons about flags; new providers slot in by declaring their shape.

This doc defines the capability struct, profiles each shipped provider against it, and specifies how capability declarations feed the routing decision.

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
   * Optional: query current capacity. Feeds routing's health-and-headroom
   * filter (see "Routing: capability filtering, then the capacity profile").
   * It does NOT trigger an overflow to another provider: there is no burst
   * mechanism (ADR-2026-08-07 D7).
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

  // Cost shape — the reference data an operator weighs when authoring a
  // capacity profile's pool order; not a per-session scoring input
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

The seventh row — A2A as transport flavor — is its own provider implementation in code (`A2ASandboxProvider`), declaring `isA2ARemote: true` and `transportModel: 'dial-in'` (the orchestrator dials into the remote A2A peer). Treating remote A2A agents as a substrate provider unifies "where does work execute" reasoning regardless of whether the work lives on our infra or someone else's. *(Substrate provider, not "sandbox provider": an A2A peer is a `remote_peer` placement, never the ephemeral kind — `ADR-2026-08-07` D1/D10.1. The code identifier `A2ASandboxProvider` and the `Sandbox` Provider Family name are unchanged, per D10.5.)*

The capability flags above are the *declared* shape — what a provider/host advertises at registration time. The corresponding *runtime view* is `LiveCapacityInstance.capabilities` in the live execution capacity contract (`014-tui-operator-surfaces.md` § "Live capacity contract" and `ADR-2026-05-06-tui-noun-consolidation.md` Addendum 2026-05-06). Each live row carries the capability tags currently in force on that specific instance — the operator-facing reflection of what this doc specifies as the provider's capability schema.

## Regime fit — when to choose what

The matrix above tells the router what's *possible*; the table below tells operators what's *appropriate* when authoring a capacity profile's pool order. Operators pick the regime; routing filters and falls through within the order they authored.

**The Primary/Fallback cells name providers, not pools.** A pool is a source over exactly one provider (`ADR-2026-08-07` D6.1), so picking a regime is picking which provider the profile's next pool should carry — the pool itself is named by its author (D9). The cells read as bare provider names for that reason; a cell reading `Local pool` here until 2026-08-07 was the only one that did not, and it invited the pool-vs-provider conflation this table exists to avoid.

| Workload regime | Primary | Fallback | Why |
|---|---|---|---|
| **OSS local dev** | Local | — | Mac Studio fleet, no cloud spend, no auth ceremony |
| **SaaS turnkey, NA, active-burst** | Vercel | E2B | Same Vercel account/auth/billing as the SaaS app, active-CPU billing wins for I/O-heavy agent work |
| **Cross-region, long-idle, paused sandboxes** | E2B | Modal | $0 paused tier, multi-region, mid-process pause/resume the killer feature for bursty queues |
| **Enterprise self-hosted** | K8s | Docker | Already production-grade in the platform's existing impl, fits VPC/private-network requirements |
| **Devcontainer-style long-lived workspaces** | Daytona | Local | Days-long workspaces, FS archive, dev-environment ergonomics |
| **GPU-bound agent work (rare today)** | Modal | E2B+GPU | Modal is the only one with first-class GPU billing |
| **Federated work via A2A (someone else's agent)** | A2A | — | Routes to a remote agent over the A2A protocol; we orchestrate, they execute |
| **Fast small-task FaaS (sub-agents)** | Modal | Vercel | `min_containers` warmth, sub-second invocation, snapshot resume |

Tenant-level regime selection lives in `.rensei/config.yaml` or platform config. Per-session override is allowed for forensics or special cases.

## Routing: capability filtering, then the capacity profile

> **Reconciled 2026-08-07** per `ADR-2026-08-07-execution-context-pool-and-placement-vocabulary.md`
> D6. This section previously specified a `SandboxScheduler.schedule(spec, hints)`
> that scored every provider per session and picked the cheapest — i.e.
> per-session routing *across* providers. The accepted model rejects that. The
> reasoning behind the rejection is preserved below in § "Why routing does not
> pick a provider per session", deliberately, so it is not re-proposed.

Routing decides which **execution context** a session runs in. That decision is
made at two levels, and keeping them apart is the whole of the design:

- **A pool is a single-provider source of execution contexts.** Exactly one
  substrate provider plus its credential and configuration, owned by the org and
  named by a human. It enrolls persistent hosts, or mints ephemeral sandboxes on
  demand. It carries no ordering and no fallback of its own.
- **A capacity profile is a named policy over an ordered list of pools.** Org
  authored, granted to projects. **This is the only place unlike capacity
  composes.** Ordering, fallback, and constraints live here.

So capability declarations — the subject of this doc — do not feed a
provider-scoring function. They feed an **eligibility filter over the pools a
profile already names**. What the profile names is authored by a human who
weighed cost and latency once, at authoring time, with a name attached; it is not
re-derived per session from a scoring heuristic nobody can see.

> **Amended 2026-08-13** by
> `ADR-2026-08-13-capability-realization-registry-and-viability-of-absence.md`.
> The eligibility filter admits a second class of demand alongside the substrate
> capability declarations this doc specifies: a **capability realization** demand
> — whether the capability a session asked for is realized on the candidate's
> harness adapter version. It filters with the same authority, at the same stage,
> and carries the same consequence: a candidate with no registered realization is
> excluded, never silently downgraded, and never rescued by prompt guidance. The
> exclusion reason is a **closed named type plus a stable rule id**, with any
> human-readable detail display-only and no consumer branching on it. This doc
> stays sandbox-scoped and gains the *shape* of the rule, not a harness table; the
> registry itself is specified in that ADR.

> **Operator surface forward-reference.** The routing decision for a session is
> surfaced through the local daemon's HTTP control API at
> `GET /api/daemon/routing/explain/<sessionID>` (and the rolling-config
> view at `GET /api/daemon/routing/config`). See `011-local-daemon-fleet.md`
> § "HTTP Control API" and `ADR-2026-05-07-daemon-http-control-api.md` §§
> D1, D4 for endpoint contracts. The wire shape of the explain response
> mirrors the `RoutingDecision` + `RoutingTraceStep` types defined for the
> hosted dashboard so the same renderer composes both surfaces.

### The routing algorithm

> **Amended 2026-08-12** by
> `ADR-2026-08-12-placement-composition-law-and-single-fallback-rule.md`. The
> five steps below are this layer's projection of that ADR's six-stage
> composition law: step 1 and step 3 are **viability** (stage 2), step 2 is
> **permission** (stage 1), step 4 is **preference + ranking** (stages 3 and 4),
> and step 5 is **bind** (stage 5) together with the single fallback rule. The
> law fixes an *authority* order, not an evaluation order — permission and
> viability are both hard filters, so evaluating capability before policy (as
> below) is correct. What the authority order fixes is **attribution**: a
> candidate excluded by more than one step is reported at the earliest
> *stage* that excludes it, so a pool that is both forbidden and unviable reads
> as forbidden in the decision record.

The candidate set is **the pools named by the capacity profile the project is
granted**, in the order the profile declares. Candidates are eliminated, never
re-ranked by a hidden score.

1. **Filter by capability constraints from `spec`.** This is where every flag in
   this doc earns its place. A pool is eligible only if its provider's declared
   capabilities satisfy:
   - `region` matches `capabilities.regions`.
   - `os` and `arch` match `capabilities.os` / `capabilities.arch` (both required).
   - `resources.vCpu/memoryMb` ≤ provider ceilings.
   - `resources.gpu` requires `supportsGpu: true`.
   - `maxDurationSeconds` ≤ `maxSessionDurationSeconds`.
   - Workarea pairing: the provider supports the requested workarea provider's snapshot/pause-resume needs (e.g., a session asking for `release(pause)` requires `supportsPauseResume: true`).
   - Session mode: an interactive or otherwise persistent-lane session is eligible only for pools whose provider can host persistently-enrolled hosts (see § "Persistent and on-demand are lanes").

2. **Filter by policy.** Layer 6 policy hooks may reject a candidate (e.g., "this
   project may only run on `EnterpriseK8s`"). Note that a per-pool project grant
   exists in the platform schema but is **advisory, not enforced** today, by
   deliberate decision — `ADR-2026-08-07` D8, which records the exit condition
   that would end that deferral.

3. **Filter by health and capacity** (best-effort; not all providers expose
   `capacity()`).
   - Drop pools whose provider reports `unhealthy` health.
   - Drop pools above 90% of `maxConcurrent` where a ceiling is known. **A pool whose configured membership is a provider configuration rather than enrolled machines has no ceiling at all** — capacity accounting exists only on the enrolled-host face (`ADR-2026-08-07` D4). Absence of a ceiling is not evidence of available capacity.

4. **Order the survivors by the capacity profile's ordering policy, and take the
   first.** The **default** ordering policy — and the only one the OSS layer
   implements — is `declared`: the survivors in the order the profile's author
   wrote, unscored. Determinism comes from that order, which a human authored and
   can read back. Until 2026-08-12 this step read
   `There is no cost/latency score and no cross-provider tie-break` as a property
   of routing itself; per
   `ADR-2026-08-12-placement-composition-law-and-single-fallback-rule.md` D3 that
   is now the property of the **default policy**, not of the algorithm. Two
   constraints bind any richer policy, and they are not waived:

   - **Ordering never gates.** An ordering policy is a *permutation* of the
     surviving set. A policy that can drop a candidate is a filter mis-declared
     as an order, and is refused at the contract level — filtering is steps 1–3.
   - **The load-ratio inversion must be fixed first.** Because pool capacity is
     derived by summing over enrolled machines, a provider-configured pool with
     no enrolled machines scores as maximally idle and would rank **first,
     always** (`ADR-2026-08-07` D7). Any load-ordering policy must fix that
     before it is offered, or step 5's fallback becomes unconditional routing to
     metered capacity.

   Ordering policies beyond `declared` are a hosted extension point: a capacity
   profile is hosted-owned (see § "OSS vs SaaS responsibilities"), and its
   ordering policy inherits that verdict. The OSS layer defines the seam and
   ships a working implementation of the default. The reasoning about which
   provider belongs where in a profile still lives in **authoring**, exactly
   where the rest of this section puts it; a policy declares *how* to traverse
   what a human named, never *what* to name.

5. **Acquire an execution context from that pool; on failure, take the next
   candidate in the ordered surviving set.** This is the **single fallback rule**
   (`ADR-2026-08-12` D2), and it is `ADR-2026-08-07` D7's failure-triggered
   routing-around made normative: reactive, bounded by the set the profile
   already produced, and requiring no telemetry that does not exist. The next
   candidate is *already* permitted and *already* viable, because it survived
   steps 1–3 — which is what makes continuing down the list safe without
   re-asking. **Out-of-set substitution never happens:** no ambient default, no
   implicit primary, and no separately authored list consulted after the set is
   exhausted. An exhausted set is a typed failure carrying the full per-candidate
   exclusion trace. Reaching capacity the profile does not name is a
   **permission** question that re-enters at stage 1 as an entitlement grant
   before ordering runs — never a router improvisation — and predictive
   escalation remains undesigned.

Cost and latency have not disappeared; they moved to where a human can see them.
The reasoning that used to live in the scoring function — that agent workloads
are I/O-heavy, so an `active-cpu` billing model often beats a `wall-clock` one
despite a higher headline rate; that `expectedAcquireMs` differs sharply between
a warm cache hit and a cold provision; that `idleCostModel` decides whether idle
capacity is free or expensive — is exactly the reasoning that belongs in the
**authoring** of a profile's pool order. The capability matrix below is the
reference data for making that call.

### Why routing does not pick a provider per session

Preserved in full, because it is the kind of decision that gets re-proposed
every six months by someone who has read the capability matrix and noticed it
would make a lovely scoring input. Three reasons, in increasing order of cost.

1. **It would be a second truth source for one decision.** The profile's ordered
   pool list already *is* the substrate-priority statement. A per-session scorer
   that can override that order is a second lever pointed at the same outcome,
   and the two can disagree silently — the operator reads the profile, the
   resolver obeys the score, and nobody can explain the placement afterwards.
   This is the same objection that killed a proposed global
   substrate-priority setting, and a per-session scorer re-creates it one level
   further down. (The corresponding rejection *inside* a pool is the same
   argument again: a pool that mixed providers would re-create the conflict
   within a single named object.)
2. **It assumes a fungibility the lanes do not have.** The provider a pool
   carries decides whether that pool can host persistently-enrolled hosts at
   all. The persistent and on-demand paths are disjoint because of it. A scorer
   ranking an ephemeral cloud provider against a pool of enrolled machines is
   comparing candidates that cannot substitute for one another for a whole class
   of sessions; making them substitutable is a resolver rewrite, not a scoring
   tweak.
3. **Its cheapest-wins default is the wrong default under a real load metric.**
   Any ranking that reads capacity as "how idle is it" inverts the moment a pool
   has no enrolled machines: with pool load derived by summing over enrolled
   hosts, an empty provider-configured pool scores as maximally idle and ranks
   **first, always** — not on exhaustion. A scoring router would send work to
   metered capacity unconditionally, and it would look like a routing preference
   rather than a bug. Any future load-ordering policy on a profile has to fix
   this before it is offered.

**How the 2026-08-12 ordering policy stays inside these three reasons.** A
profile-declared ordering policy is not the per-session cross-provider scorer
rejected above, and the difference is worth stating where the objection lives.
Reason 1 objects to a *second* truth source that can override an authored order;
an ordering policy is declared **on the profile itself**, so an operator reads
the list and the traversal rule in the same object and the decision record names
which policy ran. Reason 2 objects to ranking candidates that cannot substitute
for one another; the lane split is a **filter** input (step 1 and § "Persistent
and on-demand are lanes"), so every candidate reaching the ordering step can
already serve the request. Reason 3 is accepted outright and is why `declared`
stays the default and why the load-ratio inversion is a precondition on any
alternative. What remains rejected, unchanged, is a scorer that picks a provider
per session *across* what the profile named.

What legitimately survives from the old design is the *shape* of the hint
vocabulary — preferred and forbidden providers, region preference, budgets —
but as **profile-level, human-authored, named policy**, not as per-session hints
threaded into a scorer. A budget that lives in a profile is a statement an
operator made; a budget that lives in a hint is a statement nobody can attribute.

### Capacity snapshots

For providers that support it, `CapacitySnapshot` lets the router reason about
real-time load and lets an operator read a pool's observed membership:

```ts
interface CapacitySnapshot {
  provisionedActive: number          // currently running
  provisionedPaused: number          // not running, can resume cheaply
  maxConcurrent: number | null       // ceiling, or null when the pool has none
  estimatedAvailable: number         // safe to provision now
  warmCacheReady: number             // sessions that can start in <Xs
  capturedAt: Date
}
```

Local: trivially computable. K8s: `kubectl top` + `ResourceQuotas`. Docker:
`/info` and host cgroups. Daytona: workspace counts via API. E2B / Modal /
Vercel: opaque (return `null` from `capacity()`); the router falls back to
optimistic provisioning + retry-on-rejection. `warmCacheReady` reads the
workarea cache described in `003-workarea-provider.md` § "The workarea cache".

Read `maxConcurrent: null` as *unknown*, never as *unlimited* — see step 3 above.

### Persistent and on-demand are lanes, not a scheduler bias

An earlier revision of this section called the `persistent | on_demand`
distinction "a scheduler bias, not a provider type". That is now the wrong way
round, and the correction matters: **the pool's provider decides which lane the
pool can serve.** Only providers that can host persistently-enrolled hosts can
back the persistent lane; the two resolution paths are disjoint (see reason 2
above).

- **Persistent** — the pool holds enrolled hosts that stay registered and offer
  execution-context slots. Acquisition is fast because the host is already there.
  Capacity accounting is real, because it sums over enrolled machines.
- **On-demand** — the pool holds a provider configuration and mints an ephemeral
  execution context per session, tearing it down at session end. Cheaper at rest,
  slower per session, and **no pool-level ceiling exists** (`ADR-2026-08-07` D4).

Capability flag interaction: a provider with `idleCostModel: 'zero'` (E2B
paused) narrows the *economic* gap between the lanes — paused contexts cost
storage only — but it does not merge them. The lane split is structural, not a
cost trade-off, and treating an `idleCostModel: 'zero'` on-demand pool as a
drop-in for a persistent one is the mistake reason 2 exists to prevent.

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

The Local substrate provider has two operational modes. Tenants pick one per machine. *(Substrate provider, not "sandbox provider": daemon mode below enrolls a persistent host, which is an execution context of the **other** kind — `ADR-2026-08-07` D10.1. The `SandboxProvider` family name is unchanged, per D10.5.)*

### Foreground mode (legacy default, pre-daemon)

A worker fleet is spawned alongside the user's editor session — typically by a VSCode/Cursor SessionStart hook or `pnpm orchestrator` invocation. The fleet's lifetime is tied to that editor process; closing the editor stops the fleet. Each project's workspace runs its own fleet, scoped to that project.

This works for solo dev with one project open. It breaks down at the scale a real user actually operates: 8–20+ open workspaces, each spinning its own fleet, each requiring manual updates on every release. The user-friction cost is real and quickly dominates the OSS experience.

### Daemon mode (recommended for any user with >1 project)

A single long-running daemon registers with the orchestrator **as a host**, offering execution contexts to the org. One per machine, not per project. Work for any allowed project routes to whichever host has a free execution-context slot; the workarea provider handles the per-session clone/checkout/toolchain setup.

Concretely:

```
┌─────────────────────────────────────────────────────────────────┐
│                       Mac Studio (one machine)                   │
│                                                                  │
│  ┌────────────────────────────────────────────────────────┐    │
│  │  donmai daemon (system service)                        │    │
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
│  │  WorkareaProvider workarea cache                      │    │
│  │  - warm cache entries per (repo, toolchain) key      │    │
│  │  - cold-path: clone + install on first project use   │    │
│  └────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────┘
```

> **Renamed 2026-08-07** — the bottom box read `WorkareaProvider local pool` /
> `warm pool members` until this ADR. It is the machine-local **workarea cache**,
> not a pool: `pool` names the org-owned capacity pool and nothing else
> (`ADR-2026-08-07` D2.3). `003-workarea-provider.md` § "The workarea cache" is
> the contract; its state names (`warming` / `ready` / `acquired` / `invalid` /
> `retired`) are the canonical labels for the entries drawn here.

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
  - id: donmai
    repository: github.com/RenseiAI/donmai-libraries
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
  // Host model — the machine registers as a host with the orchestrator at
  // daemon start, and offers execution-context slots from then on
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

> **`Local daemon mode for the OSS execution layer`** — One per-machine daemon registers as a multi-project **host**, replaces the per-VSCode-workspace fleet model, supports auto-update, project allowlist, and workarea-on-demand bootstrapping. Closes the friction described by users running 8–20+ workspaces.

## OSS vs SaaS responsibilities

| Concern | OSS | SaaS |
|---|---|---|
| `SandboxProvider` interface | ✅ owns | consumes |
| Capability struct | ✅ owns | consumes |
| `Local` impl | ✅ ships | inherits |
| `Docker` / `K8s` impls | optional contrib | ✅ ships |
| `Vercel` / `E2B` / `Modal` / `Daytona` impls | ❌ (cloud creds) | ✅ ships |
| Capability-filtered routing | ✅ owns interface | ✅ ships hosted impl |
| Capacity profiles (named policy over pools) | ❌ (single-tenant; no grant edge) | ✅ owns |
| Ordering policies beyond the authored order | ❌ (ships `declared` only) | ✅ owns |
| Placement decision record (shape) | ✅ owns contract + local emission | aggregates + extends |
| Per-tenant regime config | ❌ (single-tenant) | ✅ owns |
| Fleet observability dashboard | ❌ (basic logs) | ✅ owns |

A `Capacity-aware burst routing | ✅ ships local-only | ✅ ships hybrid (local + cloud)` row stood here until 2026-08-07. It was removed rather than re-scoped: **neither side ships burst routing, and neither ever did.** See § "Why this exists" and `ADR-2026-08-07` D7.

The OSS layer can run a multi-Mac-Studio fleet on a LAN with the local provider plus optional Docker. The hosted control plane adds capacity profiles with a project grant edge, the multi-tenant control plane, and the cloud substrate implementations the OSS layer does not ship credentials for.

## Open questions

1. **Workarea provider pairing.** Should a `SandboxSpec` always carry a `workareaSpec`, or are there sandbox uses without workareas (e.g., GPU eval runs that don't touch a repo)? Default: yes-always for coding-agent flows; admit "no-workarea" mode for benchmarks/eval. Concrete in `006-cross-provider-interactions.md`.
2. ~~**Scheduler bias function.**~~ **Closed 2026-08-07** by `ADR-2026-08-07` D6. There is no cost/latency scoring function to tune, because routing does not score providers per session — it filters, then honours the order a human authored in a capacity profile. The cost-sensitive-vs-latency-sensitive choice is expressed by *which* profile a project is granted and *how* its pools are ordered. What remains genuinely open is the shape of the profile object itself (its fields and verbs), which is D6.2 accepting-work, not a question about this doc. **Refined 2026-08-12** by `ADR-2026-08-12-placement-composition-law-and-single-fallback-rule.md` D3: the traversal rule is now a named field of the profile — its **ordering policy**, defaulting to the authored order — so the cost/latency posture is expressed by which profile a project is granted, how its pools are ordered, *and* which ordering policy it declares. The OSS layer implements only the default; a scorer that picks a provider per session across what the profile named stays rejected, and no policy may drop a candidate.
3. **Health check semantics.** Do we treat a single failed `health()` as unhealthy, or require N consecutive? Default: fail-fast on `unhealthy`, two-strike on `degraded`. Tenants may override.
4. **A2A capability shape.** A remote A2A agent doesn't expose VCpu/Memory ceilings — those are the remote's concern. Capabilities for A2A providers may need a `delegatedCapacity: true` flag and a fallback contract that the remote will refuse if it can't satisfy. Not yet specified; revisit when A2A becomes load-bearing.

These are intentional gaps to be locked by ADR after implementation experience.
