# 002 — Provider Base Contract

**Status:** Reference. v2 enrichments **Accepted (2026-05-06)**.
**Last updated:** 2026-05-06
**Related:** `001-layered-execution-model.md`, `005-kit-manifest-spec.md`, `013-orchestrator-and-governor.md`

## Why this exists

The platform has ten plugin families: `Sandbox`, `Workarea`, `AgentRuntime`, `VersionControl`, `IssueTracker`, `Deployment`, `AgentRegistry`, `Kit`, `ModelEndpoint`, `RequesterProvider`. Without a unified base contract, each family invents its own discovery, capability vocabulary, scope resolution, and trust model.

`ModelEndpoint` (added per ADR-2026-06-06) names the model-serving company (Anthropic / OpenAI / Google / Local) and is consumed by the `AgentRuntime`/Harness providers (or called directly by the one-shot lane); it is a deliberately thin family — its sole verb is `Resolve` — and an accepted exception to the "families have user-facing verbs" norm.

This doc defines the single base contract every plugin family extends. Land it once, the policy/security layer (cross-cutting in `001`) has consistent extension points, the SaaS control plane has consistent administration, and tenants can configure providers in one mental model rather than eight.

**Plugin vs Provider — disambiguation.** A **Plugin** (`015`) is the artifact of distribution — one installable unit. A **Provider** is a typed implementation of one of the eight family interfaces. A single Plugin may register zero, one, or many providers. The base contract here governs the *typed interface* every Provider implements; `015` governs the *artifact* that bundles them. Both are necessary; neither subsumes the other.

## The base interface

```ts
/**
 * Every plugin family extends this contract.
 * Family-specific verbs live on the family-typed sub-interfaces
 * (SandboxProvider, WorkareaProvider, KitProvider, etc.) declared
 * in their own reference docs (003–008).
 */
interface Provider<F extends ProviderFamily = ProviderFamily> {
  readonly manifest: ProviderManifest<F>
  readonly capabilities: ProviderCapabilities<F>
  readonly scope: ProviderScope
  readonly signature: ProviderSignature | null

  /**
   * Called by the host once at activation. Idempotent.
   * Use to validate environment, open long-lived clients, etc.
   * Throwing here aborts activation; the host will not invoke any
   * family-specific verb before activate() returns.
   */
  activate(host: ProviderHost): Promise<void>

  /**
   * Called by the host at deactivation. Idempotent.
   * Releases long-lived resources. Must not throw on second call.
   */
  deactivate(): Promise<void>

  /**
   * Optional health check. Hosts may poll periodically to drop
   * unhealthy providers from rotation without restarting them.
   */
  health?(): Promise<ProviderHealth>
}

type ProviderFamily =
  | 'sandbox'
  | 'workarea'
  | 'agent-runtime'                    // 8th family per ADR-2026-04-27
  | 'vcs'
  | 'issue-tracker'
  | 'deployment'
  | 'agent-registry'
  | 'kit'
  | 'model-endpoint'  // 9th family per ADR-2026-06-06
  | 'requester-provider'  // 10th family per ADR-2026-06-19

type ProviderHealth =
  | { status: 'ready' }
  | { status: 'degraded'; reason: string; recoverableAt?: Date }
  | { status: 'unhealthy'; reason: string }
```

The base contract is deliberately small. Anything family-specific (`provision`, `acquire`, `clone`, `record`, `detect`) lives on the family interface, not here. The base is what every Provider must do *to be administrable*: declare itself, advertise capabilities, prove its identity, attach to lifecycle hooks.

### Go-native realization (2026-06-14)

The TypeScript shape above is the canonical contract; it is now **landed Go-native** in the OSS execution layer (`donmai/agent/base.go`) so a third-party **Go** provider SDK has a base to build on. The mapping is 1:1: `ProviderManifest<F>` → the generic `agent.ProviderManifest[F]` embedding `agent.ProviderBase` (the family-agnostic discovery + trust header); `ProviderScope`/`ScopeSelector` with `ValidateScope` enforcing the non-global-needs-a-selector rule; `ProviderSignature`/`ProviderHealth` as Go structs (signature is shape-only today — manifests carry a `nil` signature under the OSS permissive default, signing deferred per ADR-2026-06-06); `activate`/`deactivate`/`health` → the `agent.BaseProvider` interface, with an embeddable `agent.NoopLifecycle` giving a new provider an idempotent stub lifecycle for free. The ten-value `ProviderFamily` enum (the `requester-provider` inbound family per ADR-2026-06-19 is the tenth) is realized as `agent.ProviderFamily` (a type alias of `agent.Family`; `FamilyHarness == "agent-runtime"`, byte-identical) with `KnownProviderFamilies()`/`IsKnownProviderFamily()`. The two LLM-layer freezing axes — **harness** (`HarnessManifest`) and **model-endpoint** (`ModelEndpointManifest`) — formally extend the base via an additive `Base()` manifest projection (compile-time asserted to satisfy `agent.BaseManifest`) plus a lifecycle bridge (`BaseProviderFromHarness`/`BaseProviderFromEndpoint`), with **no wire or read-site change**. A load-bearing parity gate (`donmai/matrix/base_parity_test.go`, run `GOWORK=off`) asserts every shipped manifest embeds the base. Per Decision 3 below the realization stays on `apiVersion: 'rensei.dev/v1'`. Decision record: **ADR-2026-06-14-provider-base-contract-go-native** (OSS-only); axis-freeze sequencing (which axes are READY vs deferred): **ADR-2026-06-14-sdk-axis-readiness-and-freeze-sequencing** (shared).

## RequesterProvider — inbound contract

`RequesterProvider` (added per ADR-2026-06-19) is the one **inbound** family: every other family is outbound (the engine calls out) or engine-initiated. It accepts an authenticated, structured request from a *registered external requester*, maps it onto a workflow dispatch (an `agent.request` trigger — `requester` is a deprecated read alias, see `016-workflow-engine.md`), and returns a structured response. It is the inbound dual of A2A and reuses the AgentRegistry `remote` protocol vocabulary (`'a2a' | 'mcp' | 'http'`) and the base contract's identity model (`authorIdentity` + signature).

**Registration as attribution and authorization anchor (ADR-2026-06-20).** Every inbound requester registers once per org as a durable scoped principal — a *registration record* carrying: an actor handle (the `<agent>` segment of the stable identity `external:<org>:<handle>`), an allowed-projects whitelist, an allowed-workflow-template-slugs whitelist, a governance posture, and an optional public key for the signed-request handshake. The `rsk_*` bearer credential is **bound to** that registration at mint time; it is a rotatable bearer, while the registration is the durable principal. On every `agent.request` dispatch the family resolves the registration from the credential's binding and checks the dispatch target against the registration's whitelist — not the credential's coarser scopes. A credential bound to no active registration carries no inbound authorization (fail-closed). The resolved identity `external:<org>:<handle>` is what stamps the audit record, independent of which credential carried the request. Storage, resolution query, mint internals, and posture-to-policy mapping are platform-only; see the mirrored stub in `rensei-architecture`.

Its capability struct and response envelope:

```ts
interface RequesterProviderCapabilities {
  acceptedProtocols: ('a2a' | 'mcp' | 'http')[];
  maxConcurrentRequests: number | null;  // null = unbounded; platform quotas per principal
  supportsStreamingResponse: boolean;     // poll/stream for long-running work
  requiresSignedRequests: boolean;        // per-requester signature enforcement
}

interface RequesterResponse {
  result: unknown;
  receipt?: unknown;  // platform-populated: model, cost, eval verdict, audit reference
}
```

The `receipt` is defined here as an optional opaque field; its generation (signing, evaluation grading, cost/provenance binding) is **platform-only** and out of scope for the OSS contract — see the mirrored stub in `rensei-architecture`.

## Manifest

Every provider declares itself via a manifest. The manifest is the discovery primitive — the host reads manifests *before* loading any code, which is what makes signature verification work (sign the manifest hash, not the runtime).

```ts
interface ProviderManifest<F extends ProviderFamily> {
  apiVersion: 'rensei.dev/v1'
  family: F
  id: string                          // globally unique within family
  version: string                     // semver
  name: string
  description?: string

  // Origin metadata — used for discovery and trust
  author?: string                     // human-readable
  authorIdentity?: string             // keypair identity for signing
  homepage?: string
  license?: string                    // SPDX identifier
  repository?: string                 // git URL or other VCS handle

  // Compatibility — host checks these before activation
  requires: {
    rensei: string                    // semver range of host runtime
    capabilities?: string[]           // host-side capabilities required
                                      // (e.g., 'workarea:snapshot', 'memory:graph')
  }

  // Family-typed entries
  entry: ProviderEntry<F>             // how to load the implementation
  capabilitiesDeclared: ProviderCapabilities<F>
                                      // declared up-front so the scheduler
                                      // can reason about candidates without
                                      // loading the implementation

  // Tooling/observability
  metricsPrefix?: string
  logScope?: string
}

type ProviderEntry<F> =
  | { kind: 'static'; modulePath: string }     // bundled with rensei
  | { kind: 'npm'; package: string; export?: string }
  | { kind: 'binary'; command: string; args?: string[] }
                                                // out-of-process providers
  | { kind: 'remote'; url: string; protocol: 'a2a' | 'mcp' | 'http+rensei' }
                                                // network-attached providers
```

Three properties matter for the architecture:

- **Capabilities are declared in the manifest, not at runtime.** The scheduler reads capability declarations during discovery, decides candidates, *then* activates only the chosen provider. This avoids the "load all six sandbox impls to ask which one supports pause-resume" anti-pattern.
- **Entry kinds are open.** Static (bundled), npm (third-party), binary (out-of-process), and remote (network-attached) all share the same manifest schema. A remote A2A agent registers as a `Provider` with `entry.kind = 'remote'` and is administered identically to a local Kit.
- **Manifest is signable as a unit.** Hash the manifest (canonical JSON), sign that, attach the signature. Trust verification is one hash check, regardless of entry kind.

## Discovery

Hosts find providers through four sources, resolved in order:

1. **Static bundled providers** — shipped with the OSS execution layer or SaaS control plane binary. Manifest is compiled in.
2. **Project-local providers** — `.rensei/providers/*.manifest.{json,yaml}` files in the workarea. Used for tenant-specific Kits or custom adapters checked into the repo.
3. **Configured registries** — declared in tenant config. Examples: `registry.rensei.dev`, `registry.tessl.io` (treated as a Kit-source registry per the Tessl finding), enterprise self-hosted registries. Pull happens at activation; cached locally with manifest signatures.
4. **Programmatic registration** — for embedding scenarios where the host is composed in code (e.g., the SaaS control plane composing the OSS runtime via `setAgentLauncher`). Adds Providers via API; manifest still required.

Conflict semantics: if the same provider `id` appears in multiple sources, the most-specific scope wins (project > org > tenant > global). Exact precedence in the Scope section below.

## Capabilities — the abstraction technique applied

Every family defines its own `Capabilities` struct. The base contract provides only the *shape*: a flat object of typed flags, with optional ranges and string unions. No nested objects in the canonical form (kept flat for serialization, comparison, and scheduler queries).

**Each capability flag SHOULD declare a `humanLabel` companion** so TUI surfaces (`014`) and dashboards don't re-encode semantics. Pattern:

```ts
// Capabilities are declared, but each ships a companion human-label registry:
const SandboxCapabilityLabels = {
  transportModel: {
    'dial-in': 'Orchestrator dials in (managed sandbox)',
    'dial-out': 'Worker dials out (substrate)',
    'either': 'Either supported',
  },
  billingModel: {
    'wall-clock': 'Billed continuously while running',
    'active-cpu': 'Billed only for active CPU; I/O wait is free',
    'invocation': 'Per-invocation pricing',
    'fixed': 'Bring-your-own-hardware (no per-use cost)',
  },
  // ... etc
}
```

Capability flags are typed enums; humanLabel registries are co-located plain-language strings. Consumers (TUIs, dashboards, audit logs) render the labels; schedulers and policy hooks reason about the typed values. This prevents the legacy pathology where "billing model" gets translated three different ways across three different surfaces.

```ts
// Family-specific capabilities are declared in the family's reference doc.
// Examples for the scheduler's mental model:

interface SandboxProviderCapabilities {
  transportModel: 'dial-in' | 'dial-out' | 'either'
  supportsFsSnapshot: boolean
  supportsPauseResume: boolean
  idleCostModel: 'zero' | 'storage-only' | 'metered'
  billingModel: 'wall-clock' | 'active-cpu' | 'invocation'
  regions: string[]
  maxConcurrent: number | null
  maxSessionDurationSeconds: number | null
}

interface VersionControlProviderCapabilities {
  mergeStrategy: 'three-way-text' | 'patch-theory' | 'crdt' | 'last-write-wins' | 'object-version'
  conflictGranularity: 'line' | 'token' | 'object' | 'cell' | 'none'
  hasPullRequests: boolean
  hasReviewWorkflow: boolean
  hasMergeQueue: boolean
  identityScheme: 'email' | 'ed25519' | 'oauth' | 'iam'
  provenanceNative: boolean
}

// ProviderCapabilities<F> is the discriminated union of all of these.
type ProviderCapabilities<F extends ProviderFamily> =
  F extends 'sandbox' ? SandboxProviderCapabilities :
  F extends 'vcs' ? VersionControlProviderCapabilities :
  // ... etc
  never
```

**Why flat:** the scheduler needs to query "give me all `sandbox` providers in scope where `supportsPauseResume = true` and `regions includes 'us-east-1'` and `idleCostModel != 'metered'`." A nested struct makes that query expensive; flat structs let the host index capabilities for fast lookup.

**Why declared up-front:** loading a provider's code to ask its capabilities defeats the lazy-load model. The manifest is the contract; the runtime verifies — but the scheduler decides on declarations alone.

**Discrepancy detection:** the host SHOULD verify, at activation, that runtime behavior matches declared capabilities (e.g., a sandbox declaring `supportsPauseResume: true` must respond to the pause verb). Mismatches should fail activation with a clear error and never silently degrade. Tenants can opt to mark a provider as quarantined rather than disabled when verification fails repeatedly — useful for partial-rollout debugging.

## Native-rich UX, typed-internal contract

The capability struct above governs the *typed-internal* contract surface — what the scheduler, dispatch hot path, OAuth/webhook plumbing, and Layer 6 hooks reason about across providers. It does NOT govern the user-visible surface. Workflow nodes, workflow verbs, CLI subcommands, templates, and editor palettes are **native-rich per provider** — each provider exposes its full differentiating affordances, not a shared lowest-common-denominator shape.

Concretely:

- **Cross-provider** (this contract): `Provider<F>`, `ProviderCapabilities<F>`, scope resolution, signing, lifecycle hooks. Typed; reasoning happens by capability flag, not provider identity.
- **Per-provider** (out of this contract, in the verb registry per `015` and the workflow grammar per `016`): `linear.agent_session.acknowledge`, `github_issues.task_list.checked`, `vercel.deploy`, `atomic.patch.commit`. Verb names carry the provider prefix and stay native-rich.

Capability flags drive UX filtering: the workflow editor reads enabled-integrations + capability flags and shows only the nodes/verbs the active providers actually support. Users on a Linear-only org never see GitHub-Issues nodes; users with no Vercel integration never see `vercel.deploy`. Doubling node count when a second provider lands is the correct cost.

The discipline is binding across all eight Provider Families and any added in the future. Detail and rationale: `ADR-2026-05-10-native-rich-providers.md`. Verb-namespace prefix-reservation enforcement (the registry-side check that prevents accidental generic-name verbs like `tracker.*`, `vcs.*`, `sandbox.*`) lives in `015-plugin-spec.md` § "Workflow Verb registry"; palette-filtering and compile-time verb-provider gating live in `016-workflow-engine.md`.

## Scope resolution

A Provider is activated only within the scope it declares. Four levels, most-specific wins:

```ts
interface ProviderScope {
  level: 'project' | 'org' | 'tenant' | 'global'
  selector?: ScopeSelector
}

interface ScopeSelector {
  // Identity matchers (any/all semantics declared per matcher)
  project?: string | string[]         // project IDs/names
  org?: string | string[]
  tenant?: string | string[]

  // Path matchers — for monorepo / per-project provider variation
  paths?: string[]                    // glob patterns
  excludePaths?: string[]

  // Conditional matchers — provider only applies when X capability is present
  // or when another provider is active
  requiresCapability?: string[]       // host-side, e.g., 'memory:graph'
  requiresProvider?: string[]         // ids of other providers that must be active
}
```

Resolution rules:

1. **Most-specific scope wins.** A project-scoped `KitProvider` for `apps/family-ios` overrides a tenant-scoped one. An explicit project match overrides a glob path match.
2. **Same-level conflicts are an error**, not a silent overwrite. Two project-scoped providers with the same `id` in the same project must be reconciled by the tenant (typically by version-pinning one).
3. **Selector matching is conjunctive across matchers, disjunctive within.** `{ project: ['a','b'], paths: ['apps/**'] }` means "(project a OR b) AND (path matches apps/**)."
4. **Empty selector at non-global level is invalid.** `{ level: 'project' }` with no selector throws — declare what project, or use `level: 'global'`.

Scope is resolved at session-start, not at provider-load. Adding a project doesn't reload providers; the next session in that project sees the updated scope.

## Signing and trust

The OSS execution layer ships **optional signing** with secure defaults; the SaaS control plane ships **mandatory signing for enterprise tenants** with pluggable signature backends.

```ts
interface ProviderSignature {
  signer: string                      // identity (URL or DID)
  publicKey: string                   // PEM or multibase
  algorithm: 'sigstore' | 'cosign' | 'minisign' | 'ed25519'
  signatureValue: string              // base64
  manifestHash: string                // canonical-JSON sha256
  attestedAt: string                  // ISO timestamp
  attestations?: Record<string, unknown>
                                      // signer-defined extensions:
                                      // SLSA provenance, in-toto attestations,
                                      // CodeQL scan results, etc.
}
```

Verification policy is tenant-driven, set in tenant config:

| Trust mode | OSS | SaaS Standard | SaaS Enterprise |
|---|---|---|---|
| `permissive` (warn on unsigned) | default | default | not allowed |
| `signed-by-anyone` | optional | optional | optional |
| `signed-by-allowlist` | optional | optional | default |
| `attested` (requires SLSA-equivalent provenance) | optional | optional | optional |

Failed verification semantics: a Provider with an invalid signature MUST NOT activate. The host emits a structured event (consumed by Layer 6 observability) and excludes the Provider from candidate selection. Tenants may override via explicit per-provider `trustOverride: 'allowed-this-once'` for incident response, but the override is itself logged and timestamped.

**Two non-obvious details that matter:**

- **Sign the manifest, not the implementation.** The implementation may be re-fetched (npm, registry) and might legitimately differ in non-substantive ways. The manifest declares what the implementation must do; signing the manifest is what the contract verifies. Capability discrepancy detection (above) catches implementations that diverge from their declared manifest.
- **Trust is composable, not transitive.** A signed `KitProvider` that declares `entry.kind = 'remote'` does NOT thereby trust whatever the remote URL serves. The remote response carries its own provider manifest, which is verified independently. Chained trust requires the tenant explicitly to enroll the remote signer in the allowlist.

## Lifecycle hooks

The base contract exposes only `activate` and `deactivate` directly. *All* other lifecycle interception happens through the Layer 6 hook surface, attached at well-known points:

```ts
// Hook taxonomy — consumed by Policy/Security/Observability.
// The host emits these; providers don't implement them.

type ProviderHookEvent =
  // Activation lifecycle
  | { kind: 'pre-activate'; provider: ProviderRef }
  | { kind: 'post-activate'; provider: ProviderRef; durationMs: number }
  | { kind: 'pre-deactivate'; provider: ProviderRef; reason: string }
  | { kind: 'post-deactivate'; provider: ProviderRef }

  // Family-specific verb invocation (each family declares its verbs)
  | { kind: 'pre-verb'; provider: ProviderRef; verb: string; args: unknown }
  | { kind: 'post-verb'; provider: ProviderRef; verb: string; result: unknown; durationMs: number }
  | { kind: 'verb-error'; provider: ProviderRef; verb: string; error: Error }

  // Agent-runtime tool-call invocation (added 2026-05-12 per ADR-2026-05-12-cross-process-hook-bus-bridge)
  // Distinct from `pre-verb`/`post-verb` above: those are PROVIDER-method-level operations
  // (`provision`, `acquire`, `runSession`); these are AGENT tool calls executed inside an
  // AgentRuntime session (`Read`, `Bash`, `mcp__af_code_search_symbols`). Session-scoped
  // and correlation-keyed by `toolUseId` so consumers can pair pre/post for the same call.
  | { kind: 'pre-tool-use'
    ; provider: ProviderRef
    ; sessionId: string
    ; toolUseId: string
    ; toolName: string
    ; toolInput: unknown
    ; toolCategory?: string
    }
  | { kind: 'post-tool-use'
    ; provider: ProviderRef
    ; sessionId: string
    ; toolUseId: string
    ; toolName: string
    ; toolOutput: string
    ; durationMs: number
    ; isError: boolean
    }
  | { kind: 'tool-use-error'
    ; provider: ProviderRef
    ; sessionId: string
    ; toolUseId: string
    ; toolName: string
    ; error: string
    }

  // Capability discrepancy
  | { kind: 'capability-mismatch'; provider: ProviderRef; declared: unknown; observed: unknown }

  // Scope events
  | { kind: 'scope-resolved'; chosen: ProviderRef[]; rejected: { provider: ProviderRef; reason: string }[] }
```

This is the surface that policy rules attach to. Examples:

- `pre-verb sandbox.provision args.region != 'us'` → block, log to audit.
- `post-verb workarea.acquire` → emit cost event, attach to issue thread.
- `verb-error vcs.push` → notify oncall.
- `post-tool-use toolName=Read` → derive `currentFile` context entry; retrieve relevant past observations for the touched file.
- `post-tool-use toolName=Bash input.command~/git push/` → notify deployment monitor.
- `capability-mismatch` → quarantine provider, page security.

The base contract guarantees that these events fire consistently across all seven plugin families. Without that consistency, the policy layer can't be one thing.

### Cross-process providers and the hook bus

A provider may run **in-process** (TypeScript, instrumented via `InstrumentedProvider`) or **cross-process** (e.g. the Go `donmai agent run` daemon, future RPC-shaped providers). Cross-process providers emit equivalent hook events through a **bridge owned by the platform's ingest route for that provider's transport**. From a subscriber's view, an event emitted by a cross-process provider is indistinguishable from one emitted in-process; the bus contract is identical.

For the Go daemon today (per `ADR-2026-05-12-cross-process-hook-bus-bridge`), the bridge surface is the `POST /api/sessions/<id>/activity` ingest route. The daemon's wire payload carries the canonical fields the new event kinds reference (`toolUseId`, `toolInput`, `toolOutput`, `isError`, `durationMs`, `providerName`); the platform side reconstructs the appropriate `pre-tool-use` / `post-tool-use` / `tool-use-error` event and emits it on `globalHookBus`. Cross-replica visibility is achieved by fan-out via the platform's existing Redis session-event channel (a new `provider_hook_event` `SessionEvent` type). See `006-cross-provider-interactions.md` Seam 10 for the cooperation contract.

## How provider families extend this contract

Each family's reference doc (`003`–`008`) defines:

1. The family-typed `Provider<F>` interface with family-specific verbs (`provision`, `acquire`, `clone`, etc.).
2. The family-specific `Capabilities<F>` struct.
3. The family-specific `Spec` types passed to verbs (`SandboxSpec`, `WorkareaSpec`, etc.).
4. At least one OSS-shipped reference implementation.

Per the OSS↔SaaS discipline (`001`), every family must have a working OSS implementation. The base contract above doesn't itself ship — it's a typescript interface and a runtime that loads/verifies/activates providers. Both the OSS execution layer and the SaaS control plane consume the same base; the difference is the set of registered Providers.

## Agent Runtime providers — current contract

The `AgentRuntime` family (the runners that execute one agent session — Claude, Codex, Ollama, Gemini, Amp, OpenCode, …) ships in Go in `donmai/agent/` and is consumed by the local daemon's per-session `donmai agent run` subcommand via a `runner.Registry`. It predates the unified manifest-based discovery described above; capabilities are declared on the Provider instance rather than in a separate manifest file. The contract below is what implementations target today; **v2 enrichments accepted 2026-05-06** (end of this section) define the in-place additions that align it with the unified base contract without a major version bump.

### Interface (verbatim, Go)

```go
// agent/provider.go
type Provider interface {
    Name() ProviderName
    Capabilities() Capabilities
    Spawn(ctx context.Context, spec Spec) (Handle, error)
    Resume(ctx context.Context, sessionID string, spec Spec) (Handle, error)
    Shutdown(ctx context.Context) error
}

// agent/handle.go
type Handle interface {
    SessionID() string
    Events() <-chan Event
    Inject(ctx context.Context, text string) error
    Stop(ctx context.Context) error
}
```

Lifecycle expectations (per `agent/provider.go` doc comment):

- Construction (`provider.New`) does fail-fast probing — `which claude`, `GET /api/tags`, `codex app-server` initialize handshake, etc. Probe failures wrap `agent.ErrProviderUnavailable`. Daemon startup logs WARN per failed probe and ERRORs only when zero providers register.
- `Spawn` returns a `Handle` whose `Events()` channel emits exactly one `InitEvent`, then 0..N assistant/tool/system events, then exactly one terminal `ResultEvent` (or `ErrorEvent` followed by close), then closes.
- `Resume` continues a previously interrupted session. Capability-gated by `SupportsSessionResume`; providers that do not support resume return `ErrUnsupported`.
- `Shutdown` releases provider-level resources (long-lived child processes such as the codex app-server). Per-session-process providers (Claude CLI) may no-op.

The 8-variant `agent.Event` discriminated union (`init` / `system` / `assistant_text` / `tool_use` / `tool_result` / `tool_progress` / `result` / `error`) is the normalized shape every provider emits regardless of its native protocol.

### Capability matrix

Verbatim, from `agent/types.go::Capabilities`:

```go
type Capabilities struct {
    SupportsMessageInjection            bool
    SupportsSessionResume               bool
    SupportsToolPlugins                 bool
    NeedsBaseInstructions               bool
    NeedsPermissionConfig               bool
    SupportsCodeIntelligenceEnforcement bool
    EmitsSubagentEvents                 bool
    SupportsReasoningEffort             bool
    ToolPermissionFormat                string // "claude" | "codex" | "spring-ai"
    HumanLabel                          string
}
```

Reference declarations:

| Provider | Inject | Resume | Tools | BaseInstr | Permissions | CodeIntel | Subagents | Effort | PermFormat | Tier |
|---|---|---|---|---|---|---|---|---|---|---|
| `claude` | ✅ | ❌ (v0.5.0) | ✅ | ❌ | ❌ | ❌ (gated on canUseTool) | ✅ | ✅ | claude | T1 |
| `codex` | ❌ | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ | ✅ | codex | T1 |
| `stub` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | claude | T1-test |
| `ollama` | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | claude (default) | T2 |

Capability declarations are stable for the lifetime of the Provider instance. Implementations MUST NOT advertise capabilities they cannot deliver — the runner gates Spec field selection on the matrix before calling Spawn, and the matrix is the contract.

### Reference implementations

Each implementation is a peer-package under `donmai/provider/`:

- `provider/claude/` — Claude Code CLI shell-out. Per-session subprocess; JSONL stream-json mode; mid-session injection via fresh `claude --resume <id> -p <text>` subprocess that streams onto the parent Handle's events channel.
- `provider/codex/` — Codex `app-server` JSON-RPC over stdio. Long-lived subprocess; multiple sessions multiplex via `thread/start`; permission-config bridge implements canUseTool-equivalent.
- `provider/stub/` — deterministic scripted-event sequences for tests and the F.4 smoke harness; supports every capability so the runner exercises every gating branch.
- `provider/ollama/` (added 2026-05-06) — local-first HTTP. Probe via `GET /api/tags`; spawn via streaming `POST /api/chat`; deliberately conservative capability profile (no inject, no resume, no tools).
- `provider/gemini/` (added 2026-06-02) — native HTTPS client to `generativelanguage.googleapis.com`. Auth via `GEMINI_API_KEY` (BYOK); `GOOGLE_API_KEY` accepted as fallback; key resolved per-`Spawn` from `Spec.Env` (supports per-session BYOK + rotation). Probe via API-key presence check. Drives a multi-turn `POST /v1beta/models/{model}:generateContent` conversation (the provider owns the `contents` history; REST is stateless). Tool-use via native `functionDeclarations` in the request `tools` array, with a **session-local in-provider tool executor** that runs native tools (Bash/Read/Edit/Write) in the session Cwd/Env and folds `functionResponse` turns back (the raw REST API returns `functionCall`s expecting the caller to execute them — unlike the CLI-wrapping providers whose tools run inside the vendor binary). Reasoning effort maps to `thinkingConfig` (`thinking_level` for 3.x model IDs, `thinkingBudget` for 2.5). `MaxTurns` enforced as a hard round-trip ceiling. **MCP-server spec is NOT yet honored** (`acceptsMcpServerSpec=false`): there is no in-box MCP stdio client; an MCP→`functionDeclaration` bridge is a documented follow-up. Stability tier: `beta`.

Provider construction (`buildAgentRunRegistry`, `donmai/afcli/agent_run.go:387`) is best-effort — each ctor probes fail-fast and the daemon logs WARN per failure but only ERRORs when zero providers register. This means an operator without Ollama installed sees the registry skip Ollama silently (visible in the WARN log), while sessions resolved to `provider="ollama"` then fail at `runner.Resolve` with `agent.ErrNoProvider` — the correct loud failure when the requested local runtime is missing.

### v2 enrichments — Accepted (2026-05-06)

Adding Ollama, Gemini, and the registration-only Amp / OpenCode probes (this wave) surfaced where the legacy `agent.Provider` contract diverges from the unified base contract above. The five items below are **accepted as v2 enrichments** to the existing contract — there is no `apiVersion: 2` bump and no migration guide (rationale in *Decision 3* below). Each is enriched-in-place against the v1 surface; future "real" Amp / OpenCode implementations drop in against the enriched surface without a contract refactor.

1. **Manifest separation.** *Accepted.* The current contract embeds discovery (binary probe, HTTP probe) in `provider.New`. The base contract requires capabilities to be readable *before* loading code. Each provider package exports a `Manifest()` static value (compile-time constant struct) consumed by daemon startup before calling `New`; `New` becomes activation-only. The existing `New(opts Options)` constructor pattern stays wired in the four call sites; the manifest is added alongside, not in place of, that constructor — so the change is additive at the provider-package boundary. **Real for the HARNESS family per ADR-2026-06-06:** the AgentRuntime/Harness providers now ship the pre-load `Manifest()` (a `HarnessManifest` carrying agent-loop caps + the new **Drive surface**), making this enrichment concrete rather than forward-looking.

2. **`Health()` lifecycle verb.** *Accepted.* The base contract defines `health() → ProviderHealth { ready | degraded | unhealthy }`. Today only `Shutdown` is part of the lifecycle; degraded states are surfaced ad-hoc via ErrorEvents. v2 adds `Health(ctx) (Health, error)` to `agent.Provider` so the daemon can drop unhealthy providers from rotation without a full re-registration. Stub-by-default for providers that have no meaningful liveness signal beyond Spawn.

3. **`Family()` discriminant.** *Accepted.* The current `agent.ProviderName` is a string enum (`"claude" | "codex" | "ollama" | "gemini" | "amp" | "opencode" | …`). The base contract scopes provider IDs by family (`Provider<F>`); the AgentRuntime family is implicit today. v2 keeps `ProviderName` as the within-family identifier and adds `Family() ProviderFamily = "agent-runtime"` so future cross-family registries can group by family. **Per ADR-2026-06-06, the AgentRuntime family's human surface is renamed "Harness"** — the family-discriminant string stays `agent-runtime` (byte-identical), and only the user-facing label changes. Its providers now declare a **Drive surface** (`Drives []WireProtocol` + `DrivesHosts []ServingHost` — which wire protocols/serving hosts the harness can drive), so a harness is "a driver that can drive these protocols via these serving styles," not a fused vendor id. The companion model-serving axis moves to the new `model-endpoint` family (see the `ProviderFamily` enum above).

4. **Capability flags split into Core + typed Extensions.** *Accepted.* The v0.5.0 matrix is family-specific and not extensible without a struct change — adding e.g. `SupportsImageInput` for multimodal models requires a coordinated cross-package edit rather than a per-provider extension. v2 splits flags into `Core` (always present, defined here) and `Extensions` (a typed map keyed by extension name; each extension is itself a typed struct). An extension graduates into `Core` once two providers ship it. This is the same fallback pattern used for worker `Capabilities []string` (see §"Capability-tag-to-typed-struct migration path").

5. **Streaming-RPC contract for daemon-RPC use.** *Accepted.* The `Handle.Events() <-chan Event` channel works in-process. When the daemon exposes an RPC API for remote workers (per `001` Phase F.5+), the same contract generalizes to a server-streaming gRPC: `RunSession(spec) → stream Event` plus a control channel (`SendInput`, `Cancel`). Cataloged here so the in-process and remote-worker surfaces share one shape.

The four architectural-space additions below sit alongside these five — they extend the contract surface so future "real" Amp and OpenCode (today registration-only) and other not-yet-shipped providers can drop in without forcing another contract revision.

### v2 contract surface — additions

These four additions are part of the contract definition (not separate proposals). They harden the contract for providers that today register cleanly and fail at Spawn (Amp, OpenCode), so when their upstream APIs stabilize we drop in real implementations without a refactor.

#### A. Stability tier declaration

Every provider declares a stability tier in its manifest:

```ts
type ProviderStability =
  | 'stable'              // production-ready; safe for any work
  | 'beta'                // feature-complete; expect minor breakage
  | 'unstable'            // pre-1.0 upstream API, breaking changes possible
  | 'registration-only'   // probes succeed, Spawn fails with a clear error;
                          //   reserves the ID for future implementation
```

The runtime warns when an `unstable` provider is selected for production work and refuses (by tenant policy) to dispatch to a `registration-only` provider unless the session is explicitly tagged as a probe / dry-run. The orchestrator (`013`) consults stability tiers when placing work. Today's matrix:

| Provider | Tier (2026-05-06) | Updated |
|---|---|---|
| `claude` | `stable` | |
| `codex` | `stable` | |
| `stub` | `stable` (test-only) | |
| `ollama` | `beta` | |
| `gemini` | `beta` | Promoted to first-class 2026-06-02; tool-use now `beta` (native function-calling + in-provider tool executor for Bash/Read/Edit/Write). MCP-server support deferred (`acceptsMcpServerSpec=false`) |
| `amp` | `registration-only` (Sourcegraph public stable HTTP API not shipped) | |
| `opencode` | `registration-only` (SST pre-1.0; per-minor breakage) | |

Tier upgrades are a manifest change and a one-line PR; no contract revision required.

#### B. Streaming transport flag

Capabilities declare the wire-level streaming transport so future providers (notably WebSocket-based variants) drop in cleanly:

```ts
type StreamingTransport =
  | 'sse'         // Server-Sent Events (Anthropic, OpenAI streaming, Gemini)
  | 'ndjson'      // newline-delimited JSON (Ollama, codex app-server JSON-RPC framing)
  | 'websocket'   // bidirectional; reserved for streaming Amp variants and
                  //   any future provider that needs full duplex
  | 'none'        // request/response only
```

The current four implementations cover SSE (Claude, Gemini) and NDJSON (Codex JSON-RPC, Ollama). Declaring the transport explicitly future-proofs for a streaming Amp variant when Sourcegraph ships its API; the contract doesn't need to learn about WebSocket later because it already names it.

#### C. Probe versioning hint via structured `ProbeResult`

`Probe()` returns a structured result rather than `(ok bool, err error)`:

```ts
interface ProbeResult {
  healthy: boolean
  apiVersion?: string                  // upstream API version, if discoverable
  supportedFeatures?: string[]         // feature names this build of the
                                       //   upstream supports; declared
                                       //   features outside this list are
                                       //   gracefully degraded
  reason?: string                      // when !healthy
}
```

The registry logs `Connected to Amp v0.4 — 2 features unavailable in this version` rather than forcing the provider to fail loudly on every minor mismatch. This is the surface that lets us tolerate OpenCode's pre-1.0 per-minor breakage: the OpenCode provider declares a feature set, probes it against the running OpenCode build, and reports back with `supportedFeatures` truncated to what this build actually exposes.

#### D. Tool-use surface

The base contract declares the wire surface every provider must answer for, so capability declarations and runner gating share one shape:

```ts
interface ToolUseSurface {
  supportsToolPlugins: boolean
  toolPermissionFormat: 'claude' | 'codex' | 'gemini' | 'spring-ai' | 'opencode' | 'none'
  acceptsMcpServerSpec: boolean        // Spec.MCPServers honored at Spawn
  acceptsAllowedToolsList: boolean     // Spec.AllowedTools honored at Spawn
}
```

Capability declarations must reflect reality, not aspiration. The runner enforces this: `Spec.MCPServers` and `Spec.AllowedTools` are stripped (warn-and-ignore, with a `SpecFieldNote` on the spawn plan) before the call to `Spawn` for any provider that declares the corresponding flag false. Tests in `donmai/afcli/tooluse_matrix_test.go` and `donmai/runner/spec_translation_test.go` enforce the matrix at compile time — the per-provider declarations and the gating behavior cannot drift. The matrix evolves with provider implementations: when a provider's runner gains real tool support, the capability flag and this doc table update in lockstep.

##### Provider × tool-use surface (2026-05-06, wave 8)

| Provider | SupportsToolPlugins | acceptsAllowedToolsList | acceptsMcpServerSpec | ToolPermissionFormat | Notes |
|---|---|---|---|---|---|
| `claude` | true | true | true | claude | `tools[]` from `AllowedTools`; MCP via `--mcp-config <tmpfile>` |
| `codex` | true | false | true | codex | MCP supported via `config/batchWrite mcpServers`; flat `AllowedTools` list not honored (per-tool permission flows through the approval-bridge grammar in `Spec.PermissionConfig`) |
| `ollama` | false | false | false | claude | future: openai-compat tools on supported models (llama3.1, gemma3) |
| `gemini` | true | true | false | gemini | native `functionDeclarations` in `generateContent` `tools` array; `AllowedTools` honored by filtering the declaration set; native tools executed by a session-local in-provider executor. `acceptsMcpServerSpec=false` — no in-box MCP client yet (the runner therefore strips `Spec.MCPServers` for gemini); MCP→functionDeclaration bridge is a follow-up. `ToolPermissionFormat=gemini` (gating via `functionCallingConfig.mode`, not the Claude allow-list grammar) |
| `stub` | true | true | true | claude | test affordance only — fields observed by the runner gating layer; the scripted handler does not consume them |
| `amp` | false | false | false | claude | registration-only (Sourcegraph stable HTTP API not shipped) |
| `opencode` | false | false | false | claude | registration-only (SST pre-1.0; per-minor breakage) |

Note: `ToolPermissionFormat` differs from the wire format the provider consumes — it names the *permission-config grammar* the orchestrator emits. Today only `codex` declares a non-`claude` value (matching the legacy capability matrix earlier in this doc); every other shipped runner consumes the `claude` grammar regardless of native protocol. The matrix above mirrors the live `Capabilities()` declarations in `donmai/provider/*/`.

### Decisions (2026-05-06)

The four open questions from the prior draft are resolved:

1. **Hot-reload during development — Default NO; opt-in via dev flag.** The host does not re-activate providers when their manifest file changes on disk by default. A `--provider-hot-reload` flag (CLI) or `DONMAI_PROVIDER_HOT_RELOAD=1` env var (daemon) opts into reload-on-manifest-change. The reload boundary: **manifest metadata, capability declarations, and scope selectors are reload-safe**; **long-lived clients (HTTP keep-alive pools, child processes such as the codex app-server, MCP server processes) are NOT reload-safe** and require a full daemon restart to pick up. Reload-safe changes apply at the next session boundary; in-flight sessions retain the pre-reload provider snapshot. Kit authors iterating on declarative manifests benefit; agent-runtime authors hacking on provider implementations should still restart the daemon.

2. **Cross-family dependencies — Adopt kit manifest spec in lockstep with v2.** A provider may declare it consumes a kit's contributions (e.g., the Claude provider declares it needs the `node-sandbox` kit's toolchain at runtime). The shape lives in `005-kit-manifest-spec.md`'s `dependsOn` / `provides` model; this contract cross-references it rather than redefining it. Concrete shape: a provider's manifest gains an optional `consumesKits: KitDependency[]` field that names kits by `id` and minimum version, with the host resolving the dependency at activation. **Cross-doc lockstep:** `005` is updated in the same wave to introduce the `[provides]` / `[depends_on]` blocks the v2 contract references — see *Cross-doc updates* at the foot of this doc.

3. **Versioning the base contract itself — Stay on `v1`.** There are zero production users of the v1 contract; we are not bumping a major version for breaking changes. The contract gets enriched in place. **No `apiVersion: 'rensei.dev/v2'` field exists** and **no migration guide is written**. Future readers should not expect one. Once the platform has real production users, the next breaking change will carry a major bump and a deprecation policy; until then, the v1 surface absorbs additions freely. This is a deliberate, time-bounded decision, not a permanent stance.

4. **Capability schema evolution — Unfettered additions until production users.** Adding, removing, or changing capability semantics is unfettered today. Once the platform has real users, the next major change will start an `apiVersion` bump cadence and a deprecation policy (one minor of overlap, hard error after). This is documented forward-looking — **no gating is implemented yet**. Providers SHOULD still be conservative in declaring capabilities they cannot deliver, but the contract does not enforce backward-compatibility on flag changes during this pre-users phase.

### Status of the seven legacy proposals against the current stack

The five proposals captured by the prior draft are now accepted as v2 enrichments (above). None are blocking the current stack — Ollama, Gemini, Amp, and OpenCode were all added against the v1 contract without forcing a refactor. The v2 enrichment is alignment work that lets the *next* wave of provider work (real Amp, real OpenCode, multimodal extensions) land without churn. The four architectural-space additions (A–D above) are decided as part of the contract; the orchestrator (`013`) and the kit spec (`005`) consume them.

### Two-axis decomposition (per ADR-2026-06-06)

The full `ModelEndpoint` capability shape (the company-named `Resolve(EndpointRequest) → EndpointBinding` verb, `HostDesc` cells, the 5-mode AuthMode vocabulary, cost model) and the HARNESS **Drive surface** (`Drives`/`DrivesHosts` and the `(harness × endpoint)` validity rule) are specified in **ADR-2026-06-06-two-axis-provider-model**. Go-manifest hosting for both new axes (the `harness` and `model-endpoint` provider-manifest registrations) is defined in `015-plugin-spec.md` § "Provider Family registrations".

## OSS vs SaaS responsibilities

| Concern | OSS (`donmai`) | SaaS (Donmai Platform) |
|---|---|---|
| Base interface definitions | ✅ owns | consumes |
| Manifest schema + validation | ✅ owns | consumes |
| Discovery (static, project-local) | ✅ ships | inherits |
| Discovery (registries) | ✅ supports configured | ✅ ships hosted registry |
| Signature verification | ✅ ships permissive default | ✅ ships allowlist + attested modes |
| Scope resolution | ✅ ships | inherits |
| Lifecycle hook emission | ✅ ships | inherits |
| Hook consumers (policy rules) | ❌ not in OSS | ✅ owns |
| Multi-tenant administration | ❌ not in OSS | ✅ owns |

The OSS layer is fully usable single-tenant — single project, single user, optionally signed providers. The SaaS layer adds the rest.

## Capability-tag-to-typed-struct migration path

The codebase ships a precedent worth citing: `donmai/worker/types.go`'s `RegisterRequest.Capabilities []string` field is a lightweight, untyped capability declaration (`["claude", "codex", "amp"]`). Workers tag themselves; the orchestrator matches by string membership.

The migration to typed structs (per this doc) follows the standard fallback pattern:

1. **Today:** workers declare untyped `Capabilities []string`.
2. **Phase 1:** workers declare both — `Capabilities []string` (legacy) AND `CapabilitiesTyped SandboxProviderCapabilitiesV1` (typed). The orchestrator prefers typed when present; falls back to tag matching otherwise.
3. **Phase 2:** workers declare typed-only. Tag list deprecated with a one-major-version overlap window.
4. **Phase 3:** tag list removed.

This is the same migration the legacy `AgentProvider.capabilities` struct will follow as it's renamed to `AgentRuntimeProvider.capabilities` (rename in corpus only; codebase keeps the existing type). Apply the same pattern to any future untyped-to-typed capability migration.

## Cross-doc updates accompanying v2

- **`001-layered-execution-model.md`** — Layer 3 description gains a sentence on stability tiers so readers encountering execution-layer providers see the tier vocabulary at first contact.
- **`005-kit-manifest-spec.md`** — gains `[provides]` and `[depends_on]` manifest blocks. The v2 provider `consumesKits` field references kit `id` + version against this surface. **Lockstep change:** ship 002 v2 and the 005 dependency model together; do not let the contract reference a kit surface that isn't documented.
- **`013-orchestrator-and-governor.md`** — orchestrator placement consults stability tiers when deciding work placement (warn on `unstable`, refuse on `registration-only` unless probe-flagged).

## Open questions (post-decisions)

The four open questions in the prior draft are resolved above (Decisions 1–4). Remaining open items are tracked elsewhere:

- **Probe-result schema evolution** — `ProbeResult.supportedFeatures` is a free-form string array today. If a small number of features become canonical across providers, we may type them. Defer until at least three providers report overlapping feature names.
- **Hot-reload reload-safe surface boundary** — the boundary documented above (manifest metadata + capability declarations + scope selectors are reload-safe; long-lived clients are not) is conservative. Future work may admit hot-swapping HTTP client pools or MCP server processes once we have a clean shutdown signal in the family interfaces. Out of scope for v2.
