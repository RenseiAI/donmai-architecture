# 001 — Layered Execution Model

**Status:** Canonical
**Last updated:** 2026-08-07
**Boundary:** shared (OSS-canonical; platform extensions live at `rensei-architecture/001-layered-execution-model-platform-extensions.md`)

This is the canonical mental model for the Donmai OSS execution layer. Every other doc in this corpus elaborates one slice of what's described here. If a contributor reads only one doc, it should be this one.

## Goal of the platform

Donmai orchestrates fleets of coding agents — and increasingly, non-coding agents — to do real work against real customer codebases and content. The platform spans two products that share architecture but have different audiences:

- **The OSS execution layer** (`donmai`) — the open-source primitive set. One CLI, one bootstrap, you can work. Ships *one* batteries-included implementation per concept.
- **The SaaS / enterprise control plane** (`Donmai Platform`) — premium product. TUI install, signup, register workers, default workflow within minutes. Ships alternative implementations and the centralized control plane.

The single most important architectural commitment binding the two: **the OSS layer never ships an interface whose only working implementation lives downstream in the SaaS product.** Every contract in this corpus must have a usable OSS-shipped implementation.

The single most important *user* commitment: **using Donmai across LLM providers, substrate providers, and issue trackers must produce a strictly better result than using any of those providers alone.** If we fail at that, we are an integration vendor, not a platform. The Intelligence Services layer (§4 below) is where this commitment is honored.

The single most important *quality* commitment: **project quality must compound, not decay.** Today's agent fleets show a Day-1-vs-Day-40 gap — sessions feel like magic on day one, like a slog on day forty. Conversational quality with the same models stays consistent. The architectural answer is in the Memory layer (`007`) — active context injection at session start, with this corpus and per-project CLAUDE.md as high-priority retrieval sources, plus session-end writes that compound knowledge across runs. If we don't close this gap, the platform fails its own scale story.

## Three orchestration principles

These resolve the sub-issue / coordination friction the legacy system has accumulated, and govern every workflow and template decision below.

### Principle 1 — Issues are human intent. Sessions are agent work. Child delegation is session-graph work. Linear sub-issues are reserved for human use.

The system MUST NOT create Linear sub-issues for cost-efficiency decomposition. When a coordinator delegates a sub-task, it may use a harness-native child primitive or launch an independently admitted child through the orchestrator, A2A, or the host CLI. Both forms are represented by a typed parent/child edge and a child `SessionRef`; native child support is an optimization, not the eligibility gate. Linear sub-issues exist only when a human (or an agent at a human's explicit instruction during refinement) decides the work merits separate intent tracking.

### Principle 2 — Decomposition is a session-graph concern, not a workflow-level fork.

The legacy `-coordination` work types (`development-coordination`, `inflight-coordination`, `qa-coordination`, `acceptance-coordination`) are deprecated. Coordinators are agents using child delegation heavily; they are not a different work type. A native child may share a process; an orchestrated/A2A/host-CLI child may run in its own session and execution cell. Both remain under the parent session graph rather than becoming a hidden workflow fork. Work types collapse from eight to five: `development`, `qa`, `acceptance`, `refinement`, `research`. Backlog-writer is elevated to a first-class agent (separate from work types) in `012`; it is the linchpin agent that determines downstream parallelism by writing issues with clear dependencies and haiku-executable scope.

The other side of this principle is that *control flow* across sessions — transitions between stages, success/failure routing, conditional dispatch — is a **workflow-canvas** concern, never platform-internal. The platform ships composable nodes (triggers, conditions, actions); the user wires them. Anything that hides chaining behavior behind auto-generated workflows, required schema fields, or closed runtime registries violates this. See `016-workflow-engine.md` § "Locus of definition — user-visible nodes only" for the binding rule, and `ADR-2026-05-03-locus-of-workflow-definition.md` for the decision record.

### Principle 3 — Quality must compound across sessions, projects, and tenants.

See the Day-1-vs-Day-40 commitment above. Architecturally enforced by: Memory writes that survive session end, retrieval that injects relevant prior context at session start, Kit-shippable intelligence extractors that enrich domain-specific knowledge, and the architecture corpus itself as a versioned canonical retrieval source.

## The distribution and runtime model

Above the typed capability layers below, three concepts govern what gets installed, what it exposes, and how it executes:

```mermaid
graph TB
    P[Plugin<br/>artifact, single install]
    F[Provider Family interfaces<br/>typed capability contracts<br/>Sandbox · Workarea · VCS · IssueTracker · Deployment ·<br/>AgentRegistry · AgentRuntime · ModelEndpoint · Kit · RequesterProvider]
    V[Workflow Verbs<br/>actions · conditions · triggers · gates<br/>plugin.verb namespace]
    D[Workflow Definition<br/>YAML graph, apiVersion: workflow/v2]
    E[Workflow Engine<br/>compilation · validation · durable execution]

    P -->|implements| F
    P -->|exposes| V
    V -->|referenced by| D
    F -->|consumed by| D
    D -->|executed by| E
    E -->|invokes| V
```

**Plugin** is the unit of distribution — one installable artifact, one OAuth grant, atomic lifecycle. A plugin declares zero, one, or many implementations of typed Provider Family interfaces, AND zero, one, or many named Workflow Verbs. Examples: a "Donmai Vercel Integration" plugin implements `DeploymentProvider` + `SandboxProvider` + `ObservabilityProvider`, and exposes verbs `vercel.deploy`, `vercel.list_deployments`, `vercel.get_logs`. Single OAuth flow grants the full scope set; multiple capabilities ride the same install.

**Provider Family** is the typed contract the platform reasons about. A scheduler picks providers by capability flags, not by plugin identity. Ten families today; see "The ten plugin families" below.

**Workflow Verb** is the operational vocabulary — named entry points the workflow engine can invoke. Namespacing is `<plugin>.<verb>` or `<plugin>.<resource>.<verb>`, enforced at registry validation to prevent collisions. Verbs declare typed input/output schemas so the engine validates wiring at compile time.

**Workflow Definition** is a graph of typed nodes (`trigger | condition | action | gate`) referencing verbs by id and major version (`vercel@1:vercel.deploy`). Versioned grammar (`apiVersion: workflow/v1`); details in `016`.

**Workflow Engine** is the runtime substrate. Compiles definitions, validates verb resolution, executes durably (signal events, gate timeouts), inherits from WEFT's typed-graph model. The orchestrator embeds the engine; it does not duplicate it.

The detail for these concepts lives in `015-plugin-spec.md` and `016-workflow-engine.md`.

## The layered model

Six layers, each with a clear purpose. Lower layers don't know about higher ones; higher layers compose lower ones.

```mermaid
graph TB
    P[Policy · Security · Observability<br/>cross-cutting hooks]
    I[Intelligence Services<br/>Memory · Code Intelligence · context injection]
    C[Composition<br/>Kits · Skills · MCP Tools · Agents · Toolchains]
    E[Execution<br/>Sandbox · Workarea · AgentRuntime · Worker]
    N[Integration<br/>IssueTracker · VersionControl · Deployment · AgentRegistry]
    B[Provider Base Contract<br/>discovery · capability flags · scope · signing]

    I -->|enriches| C
    C -->|contributes to| E
    E -->|drives| N
    B -.implemented by.-> C
    B -.implemented by.-> E
    B -.implemented by.-> N
    P -.intercepts.-> B
    P -.intercepts.-> I
```

### Layer 1 — Provider Base Contract

The ground floor. A unified `Provider` interface that all seven plugin families extend. It defines:

- **Discovery** — how a plugin advertises itself (npm package + manifest, or registry pull).
- **Capability declaration** — what this implementation actually supports, expressed as a typed capability struct. Schedulers and consumers reason about capability, not provider identity.
- **Scope resolution** — `project → org → tenant → global`, with explicit conflict semantics.
- **Signing and trust** — third-party plugins are signed; enterprise tenants may require sigstore-equivalent verification.
- **Lifecycle hooks** — pre/post/around extension points that the Policy layer attaches to.

Without this layer, the seven plugin families below would each invent their own discovery, their own capability vocabulary, and their own trust model. This layer exists to stop that drift.

Detail: **`002-provider-base-contract.md`**.

### Layer 2 — Integration

External-system adapters. Things that map external concepts (Linear issues, GitHub PRs, Vercel deployments) into the platform's internal model.

Four families today:

- **IssueTrackerProvider** — Linear (OSS default), Jira, Asana, Monday, sheets/Notion, "platform proxy mode."
- **VersionControlProvider** — git hosts (GitHub/GitLab/Bitbucket), Atomic, S3 with/without versioning, structured-content backends.
- **DeploymentProvider** — Vercel, Cloudflare Pages, custom CI hooks.
- **AgentRegistry** — local YAML, git-ref, langchain, openai-assistant, A2A remote agents.

These are the most "shaped" plugin families because external systems already have their own protocols; we adapt rather than invent. The base contract gives them shared vocabulary so a tenant can consistently say "use Jira for issues, Atomic for VCS, A2A for these agents" without each setting being a different config namespace.

Detail: **`008-version-control-providers.md`** for VCS specifically. IssueTracker, Deployment, and AgentRegistry are described inline in `002`.

### Layer 3 — Execution

Where work physically happens. Four sub-concepts that compose:

- **SandboxProvider** — *where* compute runs. Local Mac Studio fleet, Vercel Sandbox, E2B, Modal, Daytona, Docker, Kubernetes. Owns capacity, billing, network topology.
- **WorkareaProvider** — *what filesystem state* the worker sees. Acquire-deterministic-state / release-with-disposition lifecycle. Local impl uses a warm **workarea cache** with scoped clean; snapshot-capable providers (E2B, Vercel) accelerate via filesystem or memory snapshots.
- **AgentRuntimeProvider** — *which model + agentic protocol* dispatches the LLM process. Claude (Anthropic), Codex (OpenAI), Amp, Spring AI, OpenCode, Ollama, Gemini, plus A2A as a transport flavor for federated work. Each declares capabilities like `supportsMessageInjection`, `supportsSessionResume`, `supportsToolPlugins`, `canSpawnNativeChildren`, `canRunHeadlessly`, `emitsSubagentEvents` (drives operator-surface child visibility), `streamingTransport` (sse / ndjson / websocket / none), and `humanLabel` companions for capability flags so TUI surfaces don't re-encode semantics. Each also declares a **stability tier** (`stable | beta | unstable | registration-only`); the orchestrator (`013`) consults the tier when placing work, warning on `unstable` and refusing `registration-only` unless the session is explicitly a probe.
- **Worker** — the agent process itself. Registers with the orchestrator (dial-in or dial-out per `SandboxProvider.capabilities.transportModel`) and consumes work.

#### The building blocks: execution context, sandbox, pool, capacity profile

Those four sub-concepts are *contracts*. These four are the **nouns** — the
things an operator provisions, an author names, and the resolver places work
into. They are defined here because using any of them loosely makes the other
three read wrong. Canonical:
`ADR-2026-08-07-execution-context-pool-and-placement-vocabulary.md` (R1/D1/D2).

```
capacity profile   named policy: an ordered list of pools + how to choose among them
      │                                                  (org-authored, project-granted)
      ├── pool      a SOURCE of execution contexts from ONE provider
      │   ├── pool  another source, possibly a different provider
      │   └── …     ordering and fallback live in the profile, never inside a pool
      │
      └── each pool yields ▸ execution context   the unit — one concrete place one session runs
                              ├── kind: persistent host slot   (long-lived, enrolled)
                              └── kind: sandbox                (ephemeral, provider-minted)
```

- **Execution context — the unit.** One concrete place one session runs. It is
  the only thing that can actually realise a capability, and it is the exact
  placement a resolved execution cell carries. On the operator wire and in the
  CLI the noun is **`instance`**.
- **Sandbox — one *kind* of execution context**, the ephemeral, provider-minted
  kind. **Not** the generic word for the unit. The other kind is a slot on a
  persistently enrolled host; the shipped discrimination is
  `instanceKind: persistent_host | on_demand_sandbox`. The `SandboxProvider`
  family above keeps its name deliberately — it provides execution contexts of
  every kind, and its contract is Accepted and in motion.
- **Pool — a single-provider *source* of execution contexts.** One substrate
  provider plus its credential and configuration, owned by the org and named by
  a human; it enrolls persistent hosts, or mints ephemeral sandboxes on demand.
  A pool is **not** a bag of heterogeneous sandboxes, **not** a kind of
  execution context (nothing runs "on a pool"), **not** sized (capacity
  accounting lives on enrolled machines, so a provider-configured pool has no
  ceiling at all), and **not** a host or a set of named hosts.
- **Capacity profile — a named policy over pools.** An ordered list of pools
  plus the rules for choosing among them. Org-authored, granted to projects,
  reusable across them. **This is the one place unlike capacity composes** — a
  pool that carried its own fallback would be a second truth source for the same
  decision.

Two consequences worth stating once, here, rather than rediscovering them per
doc: **authors name pools, never hosts** (pool naming *is* the placement
mechanism — machine-specific pools today, geographic pools at scale), and the
difference between naming a pool and naming a context is a difference of *time*,
not of kind — a pool is a placement resolved at claim, a context is a placement
resolved exactly.

##### How the nouns compose: the placement composition law

The nouns say what exists. The **composition law** says who decides, in what
order, and with what power. Canonical:
[`ADR-2026-08-12-placement-composition-law-and-single-fallback-rule.md`](ADR-2026-08-12-placement-composition-law-and-single-fallback-rule.md).
Six stages, each holding exactly one kind of power:

```
0 INTENT      what the author asked for       refs + preference posture
1 PERMISSION  may this run there?             hard gate      fail-CLOSED
2 VIABILITY   can this run there?             hard filter    loud, typed, on ∅
3 PREFERENCE  where would we like it to run?  ordering only  never widens
4 RANKING     which survivor is best?         ordering only  never gates
5 BIND        make it so                      intersection   receipts
```

Power is monotone down the list: no stage may add a candidate an earlier stage
removed, and no stage may substitute a target that was never a candidate. The
order is an **authority** order, not an evaluation order — stages 1 and 2 are
both hard filters and compose as an intersection, so an implementation may
evaluate them in either order (`004` does capability before policy). What the
order fixes is attribution: a candidate excluded by more than one stage is
reported at the earliest stage that excludes it.

Three rules fall out of the law and are stated here because every other doc
depends on them:

- **One fallback rule.** Fallback is *the next candidate in the ordered
  surviving set* — already permitted, already viable. Out-of-set substitution
  never happens, and an exhausted set is a typed failure carrying the
  per-candidate exclusion trace, never a silent queue.
- **A pin is hard within the law and only within it.** An explicit pin narrows
  the candidate set; a pinned target that fails permission or viability fails the
  decision loudly with the pin named. There is no non-strict pin.
- **Every decision emits one record shape** — candidates considered,
  per-candidate exclusion stage and named rule, chosen target, ordering policy
  and scores, ruleset revision with exposed staleness, and the admission→claim
  receipts chain. A decision that cannot be explained from its own record is a
  defect.

**Vocabulary, one noun per referent.** **Placement** decides where a *new
execution context* lands; **selection** decides *which live peer* receives
delegated work; **steering** is session-to-session communication between *live*
sessions (a transport, not a decision); **routing** is the umbrella noun for
placement plus selection; and the workflow DAG's gates and edges are **control
flow**, not routing. Selection is the same law with `remote_peer` candidates.

The executable unit is a **resolved execution cell**, not a fused provider id. A versioned `DispatchIntent` keeps harness, model identity, serving endpoint, auth binding, placement, session mode, and requested capabilities independent. Admission intersects declared compatibility with live inventory, auth/placement proof, and evidence tier, then persists an immutable receipt before enqueue. Autonomous and human-controlled sessions return the same `SessionRef`; human control is a capability/lease. Every child is admitted through the same contract, while its delegation transport (`native_harness`, `platform_dispatch`, `a2a`, or `host_cli`) belongs on the graph edge. Full contract: `ADR-2026-08-05-versioned-execution-cell-and-session-reference.md`.

**The harness reference's version identifies the adapter, not the family contract.** Per [`ADR-2026-08-08-harness-as-versioned-deliverable.md`](ADR-2026-08-08-harness-as-versioned-deliverable.md) D1, four version namespaces are kept distinct and each has exactly one producer: the **family ABI** (the contract between the agent package and any harness implementation, which moves rarely and whose move is lock-step by definition), the **adapter version** (the exact integration about to run, for one harness, moving independently of every other harness), the **binary pin** (which releases of the third-party program the adapter is built and verified against), and the **conformance rung** (what has been proven, computed from gate outcomes and never authored). The cell's harness reference carries the *adapter version*, because what must not change across the admission→spawn boundary is the exact integration, not the family contract. A requested version absent from the generated set is refused; there is no downgrade path, and a latest-compatible choice is a resolution-time decision recorded before admission, never a spawn-time substitution.

A **Worker** may run two kinds of work over the same poll/claim loop: **agent work** (a `SessionSpec` that drives an `AgentRuntimeProvider`) or **batch work** (a `BatchJobSpec` discriminated by `workType`, executed by a registered batch handler that does **NOT** invoke an `AgentRuntimeProvider`). Batch work still composes `SandboxProvider`/`WorkareaProvider` as its handler needs, and may even invoke an LLM under a resolved auth mode (`host-session`/`local`) as a single non-interactive turn — but it is not an agent session (no tracker issue, no `activeSessions`/quota entry). See `ADR-2026-06-03-batch-work-type-category.md` (first instance: code-survival scans, `ADR-2026-06-01`; second: KG extraction).

For a long-lived interactive agent session, the worker's replaceable controller
process is not the process-lifetime owner. Per
[`ADR-2026-08-17-session-shim-adoption.md`](ADR-2026-08-17-session-shim-adoption.md),
one stable per-session shim owns the harness process group, PTY master, output
sequence, replay ring, snapshot/recording state, and terminal observation. The
daemon creates or adopts that shim and may restart without creating a new
session or PTY-host epoch. `(org_id, session_id)` remains the sole lifecycle
identity; shim ids, process epochs, controller generations, PIDs, sockets, and
carrier generations are correlation or fencing values only. Adoption and
quarantine accounting finish before the host advertises capacity.

The split between SandboxProvider and WorkareaProvider is critical. They are not the same concern — even on a perfectly fresh K8s pod, if you reuse it for a second session without resetting filesystem state, you get the false-positive QA bug that motivated this entire architecture. SandboxProvider gives you *compute*; WorkareaProvider guarantees *filesystem determinism inside that compute*; AgentRuntimeProvider says *which LLM speaks the protocol the orchestrator expects*.

The codebase's existing `AgentProvider` (`packages/core/src/providers/types.ts`) is the OSS reference implementation of `AgentRuntimeProvider`. The renaming is corpus-only; the type stays the same.

Details:
- **`003-workarea-provider.md`** — Workarea contract and workarea-cache semantics.
- **`004-sandbox-capability-matrix.md`** — Sandbox capability flags and capability-filtered routing over capacity profiles.
- **`013-orchestrator-and-governor.md`** — Worker, AgentRuntime, governor, dispatch loop.

### Layer 4 — Composition

What gets *into* a session. Buildpacks-shaped: third parties contribute language, framework, or domain support via a manifest with detect rules and contribution types.

A **Kit** declares:
- **Detect** — what makes this Kit applicable to a given workload (file presence, config patterns, repo metadata).
- **Provide** — contributions to the session: build/test/validate commands, prompt fragments, tool permissions, MCP servers, skills (SKILL.md), agent templates, A2A skill exports, *toolchain demands* (e.g., `java = "17"`).
- **Composition rules** — ordering, scope, conflict resolution when multiple Kits apply.

The killer architectural mechanic: **a Kit's toolchain demand is a signal to the SandboxProvider+WorkareaProvider scheduler.** Declaring `provide.toolchain = { java = "17" }` causes the scheduler to route to a warm workarea-cache entry, image, or snapshot that satisfies the demand. Kits never know about sandbox providers; sandbox providers never know about Kits. The toolchain spec is the contract between them.

**The seam that signal arrives through** is stage 2 (viability) of the placement composition law — see Layer 3 § "How the nouns compose". Demands compile into the dispatch intent at composition time and occupy their own slot in the viability tuple alongside model, harness, auth binding, execution-host capabilities, lane, serving endpoint, and health. A demand is therefore a **hard filter**, not a scoring hint: a workload whose Kit declares an operating-system-locked command lane can only survive on candidates that declare that operating system, and if none does, the decision fails loud and typed naming the demand. This preserves the mutual ignorance above — the demand is still expressed in toolchain terms and still resolved by the scheduler — while giving it a defined evaluation point instead of an unspecified influence.

**A capability's realization demand occupies the same slot and behaves the same way.** Per [`ADR-2026-08-13-capability-realization-registry-and-viability-of-absence.md`](ADR-2026-08-13-capability-realization-registry-and-viability-of-absence.md), a capability a session demands must be *realized* on the candidate's harness adapter version; where no realization is registered, the candidate is excluded at the same stage 2, with the same hard-filter treatment and the same loud, typed empty set. Kit toolchain demands and capability realization demands are two signals of one shape — both compile into the intent at composition time, both are resolved by a scheduler that knows nothing about their subject matter, and neither is ever traded away by a ranker.

This layer is where the strategic timing call lives: the AI ecosystem is converging on a buildpacks-shaped pattern (MCP Registry, Anthropic Skills, AgentStack, nori-skillsets), but no system today bundles all four required dimensions (manifest + detect + registry + composition) with host-driven introspection. Landing this layer with a real spec is a chance to set the standard rather than adopt one.

Detail: **`005-kit-manifest-spec.md`**.

### Layer 5 — Intelligence Services

The differentiator. Memory and Code Intelligence accumulate value across sessions, providers, and tenants. They are not optional — every session reads from and writes to them, regardless of which sandbox hosted it or which Kit configured it.

- **Memory** — knowledge graph (Postgres + pgvector), in-session observation capture, AST-driven file-op extraction, cross-session injection, proactive context-aware suggestions.
- **Code Intelligence** — BM25 + vector hybrid search, repo map (PageRank), symbol search, dedup detection, cross-package dependency validation, type usage finding. The existing `@donmai/code-intelligence` package (formerly `@renseiai/agentfactory-code-intelligence`, being deprecated) is the OSS-shipped implementation; functionality migrates to the Go `donmai` binary over time.

These services are **provider-orthogonal**: an agent running on Vercel Sandbox with an E2B-paused workarea using a Spring Java Kit still benefits from the same memory graph and same code index. Routing across providers is what makes the platform composable; *enriching across providers* is what makes it differentiated.

These services are what a user actually selects, and they are selected **by capability, never by mechanism**. A user asks for Memory; whether that arrives as a prompt partial plus an MCP server, as tools registered by an operator-injected extension, or as an entry in a harness's own config file is compiled by the platform from the resolved execution cell, per [`ADR-2026-08-13-capability-realization-registry-and-viability-of-absence.md`](ADR-2026-08-13-capability-realization-registry-and-viability-of-absence.md). The per-harness realization never appears in an authoring surface — changing the harness reference must not change the capability picker's option set.

Detail: **`007-intelligence-services.md`**.

### Layer 6 — Policy, Security, and Observability (cross-cutting)

Not a layer in the strict sense — a set of hooks that attach to the lifecycle events of every other layer. Pre/post/around for: provider acquire, session start, command exec, commit, push, merge, deploy, memory write, kit detect, prompt construction, model dispatch, etc.

This is where regulated-enterprise concerns live (banking, defense, healthcare). Three intertwined concerns share this layer because they all attach to the same hook surface, but they are distinct:

- **Policy** — *what is allowed*. Tenant-defined rules: which models can run on which data, which kits can deploy to which environments, which agents can write to which paths. Policy is **almost entirely a SaaS control-plane concern** — the OSS layer ships only the hook surface, not opinionated implementations.
- **Security** — *defense in depth across every layer*. Plugin signing and trust verification (Layer 1), tenant isolation and network policy (Layer 3), provenance and attestation (Layer 2 VCS), secret management (cross-cutting), prompt-injection and code-injection defense (Layer 4 Kit ingestion + Layer 5 memory writes), audit chains. Security is **shared between OSS and SaaS** — the OSS layer must ship secure defaults; the SaaS layer adds central administration and pluggable security providers (vulnerability scanners, code signers, identity providers, SIEM exporters).
- **Observability** — *what happened*. Structured event emission from every provider lifecycle hook. Workarea ID, session ID, model dispatch decisions, cost accumulation, tool calls, agent attribution. The basis for routing intelligence, agentic DORA metrics, cost-per-issue attribution, and post-hoc forensics.

Defense in depth is the architectural principle that makes this layer load-bearing for enterprise sales: **each lower layer enforces a security property locally, and the policy hooks compose them into tenant-defined enforcement chains.** A failure at any single layer is contained by the layers around it. See "Security as defense in depth" below for the per-layer responsibilities.

Detail: **`010-security-architecture.md`** (deferred — depends on every other contract being stable). The OSS execution layer needs to land first; security providers compose against stable interfaces, not moving targets.

## The ten plugin families

Bringing the layers together, here are the ten typed Provider Family contracts. Each is a typed interface; plugins implement zero, one, or many. The Provider base contract from Layer 1 is the common shape every family extends.

| Family | Layer | OSS-shipped impl | Platform-shipped alternates |
|---|---|---|---|
| **SandboxProvider** | Execution | Local (Mac Studio fleet) | Vercel Sandbox · E2B · Modal · Daytona · Docker · K8s |
| **WorkareaProvider** | Execution | Local workarea cache (scoped clean) | Snapshot-aware variants per sandbox |
| **AgentRuntimeProvider** | Execution | Claude (Anthropic) | Codex · Gemini · Amp · Spring AI · OpenCode · Ollama · A2A |
| **VersionControlProvider** | Integration | Git (GitHub) | Atomic · S3 · structured-content backends |
| **IssueTrackerProvider** | Integration | Linear | Jira · Asana · Monday · Sheets/Notion · proxy mode |
| **DeploymentProvider** | Integration | (none — opt-in) | Vercel · Cloudflare · custom |
| **AgentRegistry** | Integration | Local YAML + git-ref | LangChain · OpenAI Assistant · A2A · third-party |
| **KitProvider** | Composition | TS/Next.js Kit (default codebase shape) | Rust · Go · Ruby · iOS · Spring Java · marketing/non-code |
| **ModelEndpoint** | Execution | Anthropic (Claude) | OpenAI · Google · Local (Ollama) — thin family per ADR-2026-06-06, sole verb `Resolve` |
| **RequesterProvider** | Integration (inbound) | HTTP/MCP/A2A listener (request → workflow dispatch) | Platform-governed receipt generation · scoped-principal onboarding |

The OSS layer ships a working implementation of every column-2 entry. The SaaS platform extends column 3. Tenants pick which providers they want; the orchestrator's scheduler reasons about capabilities, not provider identity.

The table above describes each family's **typed-internal contract surface** — the cross-provider plumbing the platform reasons about. The **user-visible surface** (workflow nodes, verbs, CLI subcommands, templates, UI palettes) stays *native-rich per provider* — the platform never collapses provider-specific affordances into a lowest-common-denominator shape. See `ADR-2026-05-10-native-rich-providers.md`.

A **Plugin** is an artifact that ships one or more rows above. The "Donmai Vercel Integration" plugin ships a `SandboxProvider` row (Vercel Sandbox), a `DeploymentProvider` row, an observability row, and a verb registry — one install, multiple family implementations.

**The harness family ships in two tiers**, per [`ADR-2026-08-08-harness-as-versioned-deliverable.md`](ADR-2026-08-08-harness-as-versioned-deliverable.md) D2. A **native adapter** (the rich tier) is an in-tree package implementing the provider contract for one harness; it earns the right to declare real capability integration — hooks, tool registration, native permission grammar, MCP delivery, PTY spawn, delivery into a live session, native children, structured replay — and pays for it with code, a smoke lane, and the harness-addition checklist. A **declared harness** (the breadth tier) is a manifest and no code, bound to one **shared driver** — an in-tree package implementing the event contract for a whole class of harnesses rather than for one (today: the shared CLI-JSONL execution driver and the shared interactive PTY spawn-mode driver; `acp-generic` is the third and the first built to be one). A declared harness may select and parameterize what its driver already implements and may never introduce a delivery channel, transport, or capability the driver lacks — its declared capabilities are a strict subset of the driver's, the same narrow-only, fail-closed rule `ADR-2026-06-06` applies to per-cell capability narrowing and to per-machine narrowing. **The tier is derived, never declared:** a harness is rich iff it ships an adapter package and breadth iff it is a manifest bound to a driver, because a self-declared tier is a capability claim by another name. Out-of-process and wasm plugin ABIs are **deferred by ADR** (D5) — the deferral keeps untrusted code out of the execution path entirely, and it has a stated revisit trigger rather than a date.

## Security as defense in depth

Security is not a layer; it is a property each layer must contribute to. The architectural rule: **every layer enforces a security property locally, and the Layer 6 hooks compose them.** A breach or bypass at one layer is contained by the layers around it. The pluggable shape (a `SecurityProvider` plugin family is *not* added to the seven — security is a hook taxonomy, not a thing) means tenants can layer in scanners, signers, IDPs, and audit sinks without each subsystem reinventing them.

Per-layer responsibilities at a glance:

| Layer | Local security property |
|---|---|
| **Provider Base Contract** | Plugin signature verification, scope-resolution authority, capability declarations are tamper-evident. The base contract is what makes "this Kit was published by Spring Framework Org" provable. |
| **Integration** | VCS attestation (Atomic-style native, git-via-trailers), IssueTracker access tokens scoped to the minimum required, DeploymentProvider gate hooks (no deploy without policy approval). |
| **Execution** | Sandbox process isolation, network egress allowlists per session, secret injection at acquire time (not in code), worker dial-in/dial-out auth (one-time tokens, JWT rotation), workarea snapshot encryption at rest. |
| **Composition** | Kit signature verification before detect runs, untrusted-code execution policy (declarative kits run in-orchestrator, executable kits run in the workarea sandbox), MCP server permission scoping per kit, prompt-injection sanitization on ingested external content (kit docs, fetched URLs, memory queries). |
| **Intelligence Services** | Memory row-level security per tenant/project/scope (Cedar policies), code-index access controls, audit trail for every read/write, encryption of sensitive observations at rest. |
| **Policy/Security/Observability hooks** | Composable enforcement chains, audit log emission, breach detection, attestation aggregation (proving the full chain of custody for a change). |

Two non-obvious points worth flagging because they shape the design before doc 010 lands:

1. **Prompt-injection defense is a Layer 4 + Layer 5 concern, not a Layer 6 add-on.** When a Kit ingests external docs, when memory recalls past observations into a session prompt, when a research agent WebFetches a URL — those are all places where attacker-controlled content reaches the model. The ingestion path is where defense lives, not the policy hooks. Hooks observe; ingestion sanitizes.

2. **Provenance and audit are Layer 2 + Layer 6 cooperation.** Atomic VCS gives us native per-change attestation (Ed25519 + session metadata); git fakes it via commit trailers; the SaaS control plane aggregates both into a tenant-visible audit chain. The attestation primitive lives in VCS; the chain lives in observability. Don't put either in the wrong place.

Detail: **`010-security-architecture.md`** (deferred). The architecture above is intentionally schematic — concrete enforcement chains, threat model, and security-provider plugin shape land once the lower layers are stable.

## Capability flags as the abstraction technique

Throughout the corpus, you'll see one technique applied repeatedly: **expose capabilities as typed flags rather than encoding them in provider identity.** Example:

```ts
interface SandboxProviderCapabilities {
  transportModel: 'dial-in' | 'dial-out' | 'either'
  supportsFsSnapshot: boolean
  supportsPauseResume: boolean
  supportsCapacityQuery: boolean
  idleCostModel: 'zero' | 'storage-only' | 'metered'
  billingModel: 'wall-clock' | 'active-cpu' | 'invocation'
  regions: string[]
  maxConcurrent: number | null
  maxSessionDurationSeconds: number | null
}
```

This unlocks two things: (1) a scheduler that routes by capability (`acquire(spec)` picks the cheapest/fastest provider satisfying the demand), and (2) graceful introduction of new providers — adding `BlaxelSandbox` doesn't require teaching the scheduler about Blaxel; it just declares its capabilities. Every reference doc in this corpus follows the same pattern: the contract is a capability struct + a small set of lifecycle methods.

**The limit of the technique — a flag only the admitting side reads is not a capability.** The technique works because the declaring side and the executing side are the same side: a provider declares what it can do, and that same provider is then asked to do it. The moment a *separate* admitting layer grants a capability, the technique breaks unless the grant is computed against what the executor has attested. Per [`ADR-2026-08-08-harness-authority-admission-plane-parked.md`](ADR-2026-08-08-harness-authority-admission-plane-parked.md) D3, a granted capability set MUST be the intersection of the requested set with an executor-attested inventory for the exact harness and version being admitted, and that attestation MUST derive from the same generated artifact the executor itself reads — not a second, hand-maintained list on the admitting side. An admission plane that can grant a capability its executor will refuse is worse than no admission plane: it converts a fast, local, free failure into a late, remote, post-commit, post-quota-charge one. The corresponding test is written on the **input** — assert that admission refuses a capability the executor's declared surface omits — because a test asserting that admission returns a receipt proves only that admission returns a receipt.

**The same limit applies one layer down, at delivery time.** A capability that survives admission still has to be *realized* on the exact harness that will run it, and the realization differs per harness: a prompt partial plus an MCP server on one, operator-injected extension-pack tools on another, an entry in the harness's own config file on a third. Per [`ADR-2026-08-13-capability-realization-registry-and-viability-of-absence.md`](ADR-2026-08-13-capability-realization-registry-and-viability-of-absence.md), the **realization** — the binding of one capability to one harness *adapter version* — is the object the flag is ultimately about; it lives in a registry keyed on capability × adapter version, and the receipt attests the **delivered surface** rather than the runner's delivery action. Absence of a realization is a typed viability exclusion consumed by the placement resolver, never a silent downgrade and never satisfied by prompt guidance. A flag whose realization the executing side cannot attest is not a capability either, for exactly the reason a flag only the admitting side reads is not one.

## The donmai ↔ Rensei Platform contract

<!-- BOUNDARY-SYNC-START: 001-donmai-rensei-platform-contract -->
<!-- This section is mirrored verbatim across
     donmai-architecture/001-layered-execution-model.md and
     rensei-architecture/001-layered-execution-model-platform-extensions.md.
     Any change MUST land simultaneously in both corpora via paired commits.
     See BOUNDARY.md § "Mechanism 3: synchronized verbatim mirror" and
     § "BOUNDARY-SYNC inline marker syntax". -->

The boundary stated as a discipline:

1. The OSS layer defines all interfaces in this corpus.
2. The OSS layer ships a working implementation of every interface — never *only* the type.
3. The SaaS control plane extends with alternate implementations and centralized administration (registries, signing, policy enforcement, multi-tenant management, the SaaS dashboard, the routing-intelligence panel).
4. The OSS layer never depends on the SaaS plane to function. Removing the platform leaves a usable single-machine product.
5. The boundary between them is a small set of pluggable function callbacks (`setAgentLauncher`-shaped), not subprocess or RPC. The platform composes the OSS layer as a library; both ship as one binary to end users.

<!-- BOUNDARY-SYNC-END: 001-donmai-rensei-platform-contract -->

**Canonical realization.** The cleanest demonstration of this discipline lives in the closed-source TUI consumer's main entry point, which calls `afcli.RegisterCommands(rootCmd, afcli.Config{...})` to import the OSS TUI's full command surface and extends with platform-specific commands on top. Public packages (`afclient`, `afcli`, `worker` in `donmai`) carry the OSS interfaces; `internal/views` stays internal. The two-binary boundary works because the OSS layer never reaches up; the SaaS layer reaches down through public APIs only.

**Where this principle has tension: webhooks.** The OSS Linear integration today requires a public URL. Long-term answer: a localtunnel-style ephemeral URL spun up by the OSS CLI. Short-term: OSS users deploy a small webhook target on Railway or equivalent. SaaS users get the platform's webhook proxy (see platform extensions). Neither violates the principle — the OSS layer remains usable; webhooks are an integration concern, not a core dependency.

**See also:** the platform extensions to this contract — dual-surface discipline, the "premium = react-flow online + TUI parity" commitment, and the SaaS-side extensions to the contract — live at [`rensei-architecture/001-layered-execution-model-platform-extensions.md`](https://github.com/RenseiAI/rensei-architecture/blob/main/001-layered-execution-model-platform-extensions.md).

## What this corpus is not

- **Not implementation reference.** Concrete code lives in source repos (`donmai`, future Kit repos). This corpus is *contracts*. Where this corpus and code diverge, the corpus is right and the code needs to align (or an ADR amends the corpus).
- **Not a roadmap.** Sequencing belongs in Linear; OSS readers can ignore Linear-realignment specifics — those live in `rensei-architecture/009-linear-realignment.md` and operate against the platform team's backlog.
- **Not the brand book.** Naming decisions (the completed `agentfactory`→`donmai` rename, the Kit-or-Ofuda question) are tracked in the rebrand runbook; this corpus reflects approved final names.

## Reading order for new contributors

Humans and fleet agents alike should consume in this order:

1. This doc (you're here).
2. **`002-provider-base-contract.md`** — without the base contract, the rest looks like a list of unrelated provider types.
3. **`015-plugin-spec.md`** — Plugin manifest, single-artifact distribution, atomic auth, verb registry. Read second; it formalizes how Provider Families and Workflow Verbs come together in one shippable artifact.
4. **`016-workflow-engine.md`** — Workflow grammar, node taxonomy, durable execution, versioning. Read third; it's the runtime substrate that consumes everything below.
5. The reference doc for whichever layer you are working on: `003` (workarea), `004` (sandbox), `005` (kit), `007` (intelligence + context injection), `008` (VCS).
6. **`013-orchestrator-and-governor.md`** — orchestrator, governor, worker, AgentRuntime dispatch. The runtime that embeds the workflow engine. (Topology view + donmai merge-queue specifics live in `rensei-architecture`.)
7. **`014-tui-operator-surfaces.md`** — TUI display primitives + capability-chip pattern; read if you're building TUI features. (Live capacity contract + dual-surface discipline live in `rensei-architecture`.)
8. **`006-cross-provider-interactions.md`** — the seams. Read once you understand the individual layers; this is where most subtle bugs live. (Seam 4 platform implementation block + Seam 6 audit-chain extension live in `rensei-architecture`.)
9. **`010-security-architecture.md`** — once landed. Until then, the "Security as defense in depth" section above is the source of truth.

## How to disagree with this doc

This doc is the canonical synthesis of an architectural conversation, not a final answer. To disagree:

1. Open an ADR proposing the change (copy `ADR-template.md`).
2. State the affected sections of this doc and the reference docs.
3. Declare the ADR's `boundary:` field in frontmatter — `OSS-only`, `platform-only`, or `shared`. See `BOUNDARY.md` for the verdict definitions.
4. Commit the ADR; if the discussion converges, update this doc and the affected references in the same commit that flips the ADR to `Accepted`.

Direct edits without an ADR are fine for clarifications, examples, and typo fixes. Anything that changes a contract, a layer's responsibility, or a discipline statement requires an ADR.

**Edits to the BOUNDARY-SYNC section** ("The donmai ↔ Rensei Platform contract" five-point discipline above) require paired commits to both `donmai-architecture/001-layered-execution-model.md` and `rensei-architecture/001-layered-execution-model-platform-extensions.md`. See `BOUNDARY.md` § "Mechanism 3: synchronized verbatim mirror".
