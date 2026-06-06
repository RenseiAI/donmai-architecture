# 015 — Plugin Spec

**Status:** Reference (initial draft)
**Last updated:** 2026-04-27
**Related:** `001-layered-execution-model.md`, `002-provider-base-contract.md`, `016-workflow-engine.md`, `005-kit-manifest-spec.md`, ADR-2026-04-27.

## Why this exists

A **Plugin** is the unit of distribution. One installable artifact. One OAuth grant. Atomic lifecycle. A plugin declares zero, one, or many implementations of typed Provider Family interfaces, AND zero, one, or many named Workflow Verbs. This decouples *what gets installed* from *what typed contracts the platform reasons about*, which lets a single Donmai plugin (e.g., "Donmai Vercel Integration") provide Deployment + Sandbox + Observability capabilities under one OAuth flow rather than forcing tenants to maintain three separate authentications and three seat allocations.

The shape comes from a survey of mature ecosystems (Backstage, GitHub Apps, Vercel Integrations, n8n, Temporal, Argo Events, Inngest, Pipedream, VSCode extensions). Three findings drove the design:

1. **Every consumer-facing ecosystem chose typed-arrays-per-capability + single-artifact + atomic-auth.** VSCode (one VSIX), n8n (one npm), GitHub Apps, Vercel Integrations all converge on this. Multi-artifact and capability-level scoping have all regressed to atomic in the systems that tried them.
2. **Webhook surface is singular per plugin.** GitHub Apps, Vercel, Inngest all use one webhook URL with an event-type discriminator inside the payload. None expose one URL per event type.
3. **Verb namespace conventions exist but aren't enforced.** Every system surveyed has had verb collisions because they recommend `<plugin>.<verb>` but don't enforce it. We enforce.

Kits (`005`) are a sibling concept — also packaged units, but specifically for language/framework contributions. A Kit is a kind of Plugin: one with a manifest that focuses on language detection, toolchain demand, and prompt/skill contributions rather than Provider Family interfaces. The two specs share lineage (single artifact, signed manifest, registry distribution) and diverge in `provide` semantics.

## The Plugin manifest

```yaml
# donmai-plugin.yaml — checked into the plugin's repo root.
# May also be embedded as `donmai` field in package.json.

apiVersion: donmai.dev/v1
kind: Plugin

metadata:
  id: vercel                          # globally unique within the registry
  name: Donmai Vercel Integration
  version: 1.4.0
  description: Vercel deploys, sandbox compute, and log streaming
  author: Donmai
  authorIdentity: did:web:donmai.dev
  license: Apache-2.0
  homepage: https://donmai.dev/plugins/vercel
  repository: https://github.com/donmai-dev/plugin-vercel
  iconUrl: https://donmai.dev/plugins/vercel/icon.svg

# Compatibility — host checks at install
engines:
  donmai: ">=0.9 <2.0"

# Supported platforms (OS/arch). See 005 for the same convention.
supports:
  os: [linux, macos, windows]
  arch: [x86_64, arm64]

# ─── Provider Family registrations ────────────────────────────────────
# Typed-arrays-per-capability. A plugin can register zero, one, or many
# implementations of each family interface. The runtime treats each entry
# as a registration into that family's resolver.

providers:
  deployment:
    - id: vercel.deployment
      class: ./dist/providers/deployment.js#VercelDeploymentProvider
      capabilities:
        supportsAtomicDeploy: true
        supportsRollback: true
        regions: [iad1, sfo1, hnd1, lhr1]
  sandbox:
    - id: vercel.sandbox
      class: ./dist/providers/sandbox.js#VercelSandboxProvider
      capabilities:
        transportModel: dial-in
        supportsFsSnapshot: true
        supportsPauseResume: false
        billingModel: active-cpu
        regions: [iad1]
  observability:
    - id: vercel.logs
      class: ./dist/providers/logs.js#VercelLogDrainProvider

# ─── Workflow Verb registry ───────────────────────────────────────────
# Flat list. Verbs are namespaced strings; the registry validates the
# `<plugin>.` prefix at install. Schemas resolve at compile time of any
# workflow that references the verb.

verbs:
  - id: vercel.deploy
    description: Deploy a project to Vercel.
    inputSchema: ./schemas/deploy.input.json
    outputSchema: ./schemas/deploy.output.json
    implementedBy: vercel.deployment
    sideEffectClass: external-write
    idempotencyKey: ${input.deploymentId || hash(input.projectId, input.commit)}

  - id: vercel.list_deployments
    description: List recent deployments for a project.
    inputSchema: ./schemas/list.input.json
    outputSchema: ./schemas/list.output.json
    implementedBy: vercel.deployment
    sideEffectClass: read-only

  - id: vercel.get_logs
    description: Tail runtime logs for a deployment.
    inputSchema: ./schemas/logs.input.json
    outputSchema: ./schemas/logs.output.json
    implementedBy: vercel.logs
    sideEffectClass: read-only

  - id: vercel.deployment.completed
    kind: gate                        # special verb kind for workflow gates
    description: Block until a deployment reaches a terminal state.
    inputSchema: ./schemas/gate.input.json
    outputSchema: ./schemas/gate.output.json
    implementedBy: vercel.deployment
    eventSubscription: vercel.deployment.succeeded|vercel.deployment.failed

# ─── Event surface ────────────────────────────────────────────────────
# Singular webhook URL per plugin. Event-type discriminator in payload.

events:
  webhookPath: /webhooks/vercel
  signatureHeader: x-vercel-signature
  signatureAlgorithm: sha1-hmac
  types:
    - vercel.deployment.created
    - vercel.deployment.succeeded
    - vercel.deployment.failed
    - vercel.deployment.canceled

# ─── Auth ─────────────────────────────────────────────────────────────
# Atomic. One OAuth flow per install grants the full declared scope set.
# Capability-level scoping is not supported (every system that tried it
# regressed to atomic).

auth:
  type: oauth2
  authUrl: https://vercel.com/oauth/authorize
  tokenUrl: https://vercel.com/oauth/access_token
  scopes:
    - deployments:read
    - deployments:write
    - projects:read
    - logs:read
  refreshable: true
  perOrgInstall: true                 # one install per Donmai org, not per user

# ─── Configuration UI ────────────────────────────────────────────────
# Optional. The platform renders a config form at install time using
# this schema. TUI consumes the same schema for terminal config.

configSchema: ./schemas/config.schema.json

# ─── Tooling, observability, signing ─────────────────────────────────

metricsPrefix: donmai_plugin_vercel
logScope: plugin.vercel

# Signature verification at install (002 trust model). Optional in OSS;
# required in SaaS allowlist + attested modes.
signature:
  signer: did:web:donmai.dev
  algorithm: sigstore
  manifestHash: sha256:abc123...
  signatureValue: base64...
  attestedAt: 2026-04-15T10:00:00Z
```

The manifest is signable as a unit — hash the canonical JSON, sign that, attach the signature. Trust verification at install is one hash check regardless of how the implementation classes are loaded.

## Provider Family registrations

The `providers` map is typed by family name. Each entry is a `ProviderRegistration`:

```ts
interface ProviderRegistration<F extends ProviderFamily> {
  id: string                            // globally unique within the family
  class: string                         // module path + export name (e.g. './dist/x.js#Y')
  capabilities: ProviderCapabilities<F> // family-typed; declared up-front
  scope?: ProviderScope                 // defaults to plugin's scope; overridable
}
```

The runtime treats each registration as it would a standalone provider declaration — same discovery, same capability matching, same lifecycle hooks (`002`). The plugin is just the *bundling* layer; once registered, providers are first-class peers in the family's resolver.

A plugin can register zero providers in a family (purely workflow-verb-only plugins exist), one provider (the common case), or multiple (e.g., a plugin that ships both `vercel.sandbox.iad` and `vercel.sandbox.sfo` as separate sandbox providers — though typically capabilities like `regions` make this unnecessary).

**Two-axis LLM families (per ADR-2026-06-06).** The `providers` map now also hosts the two LLM axes as Go provider manifests: `harness` (the renamed `AgentRuntime` loop-driver — discriminant string stays `agent-runtime`) and `model-endpoint` (the company-named model-serving family). A `harness` registration declares the agent-loop caps plus the Drive surface (`drives`/`drivesHosts`); a `model-endpoint` registration declares the company, its serving hosts, auth modes, wire protocol(s), and cost model. Both are signed manifests registered exactly like any other family entry; the registry computes the valid `(harness × model-endpoint)` cells from the protocol intersection — the cells are never hand-authored. See ADR-2026-06-06 for the family contract.

**Third-party LLM-provider onboarding.** A company contributes a `model-endpoint` (and/or a `harness`) by shipping a signed manifest via a `ProviderEntry kind: static | npm | binary | remote` (the same trust model and two-tier listing below). The safest path is **zero-Go**: `kind: remote` + `protocol: openai-compat`, driven by the OSS OpenAI-compat client — the platform holds the key and calls *out* to the vendor's `baseUrl`, so the vendor never receives a key. As with every other family, listings are two-tier: `verified` (platform-probed, allowlisted, in the curated matrix) vs `community` (signed and installable, flagged unverified, excluded from the curated matrix). The valid cells against existing axes appear automatically once the manifest is merged — no platform code change and no lock-step release.

## Workflow Verb registry

Verbs are the operational vocabulary. Each verb declares:

```ts
interface VerbDeclaration {
  id: string                            // <plugin>.<verb> or <plugin>.<resource>.<verb>
                                       // enforced by registry validation
  description: string
  kind?: 'action' | 'condition' | 'trigger' | 'gate'
                                       // defaults to 'action'

  inputSchema: string                  // JSON Schema path
  outputSchema: string

  // Wiring to provider implementations
  implementedBy?: string               // provider id from this plugin's `providers` map
                                       // optional — verbs may also be backed by
                                       // module-level functions for stateless verbs

  sideEffectClass: 'read-only' | 'external-write' | 'internal-only'
                                       // policy hooks attach to side-effect classes

  idempotencyKey?: string              // expression evaluated against input
                                       // used by the workflow engine to dedupe

  // For gate verbs
  eventSubscription?: string           // pipe-delimited event type ids
}
```

**Namespace enforcement.** Every verb id must start with `<plugin-id>.` (the same `metadata.id` from the manifest). The registry validates at install:

```
ERROR: plugin 'vercel' declares verb 'deploy' — must be 'vercel.deploy'.
ERROR: plugin 'slack' declares verb 'vercel.notify' — verb namespace must match plugin id.
```

This is the discipline none of the surveyed ecosystems enforce, and they all suffer collision incidents because of that gap. We enforce.

**Reserved generic prefixes.** The registry additionally rejects verb ids whose plugin segment matches a Provider Family name (`tracker`, `vcs`, `sandbox`, `workarea`, `agent-runtime`, `deployment`, `agent-registry`, `kit`). Verbs are *provider-shaped*, not *family-shaped* — `linear.comment.create` and `github_issues.comment.create` are correct; `tracker.comment.create` is not. This prevents accidental lowest-common-denominator drift across Provider Families and is the registry-side enforcement of `ADR-2026-05-10-native-rich-providers.md`.

**Verb kinds and the workflow engine.** The `kind` field tells the workflow engine how to treat the verb in a graph:

- `action` (default) — invokable; runs to completion; outputs feed downstream.
- `condition` — invokable; outputs a discriminator that routes to a branch in the parent workflow node.
- `trigger` — externally-driven; cannot be invoked by the engine, only fires from `events.types`.
- `gate` — invokable but suspends until `eventSubscription` matches; pairs with workflow gate nodes.

Detail on how these compose into workflow nodes lives in `016`.

## Discovery

Plugins are found through four sources, resolved in `002`'s standard precedence:

1. **Bundled** — shipped with the host binary (typically core integrations like `linear`, `donmai`).
2. **Project-local** — `.donmai/plugins/*.plugin.{json,yaml}` in the workarea.
3. **Configured registries** — `registry.donmai.dev` (SaaS-managed; free for OSS users), enterprise self-hosted registries.
4. **Programmatic** — for embedding scenarios; manifest still required.

Conflict resolution: most-specific scope wins, then version pin, then registry priority order.

## Auth

Atomic per-plugin, regardless of how many capabilities the plugin exposes. The OAuth (or API-key, or whatever the plugin's auth shape requires) flow runs once at install and grants the full scope set. Two strong reasons to keep this atomic:

- **Every system that tried capability-level scoping regressed.** Early IFTTT, some Slack permission UIs — the UX cost of "approve some scopes, reject others" was higher than the security benefit.
- **Capability-level decline doesn't compose.** If a tenant rejects the Sandbox capability of a plugin but accepts Deployment, what happens to a workflow that references both? Atomic means workflows reason about whole plugins, not partial enrollments.

If a tenant wants only some capabilities of a vendor's plugin, **the answer is to ship a separate plugin** — `vercel-deploy-only`, etc. This puts the decomposition burden on the publisher (where it belongs) rather than the installer (where it doesn't compose well).

**Per-org install vs per-user.** Plugins declare `auth.perOrgInstall: true` to indicate one OAuth grant covers the entire Donmai tenant org. This is what closes the Vercel friction the user described — a Donmai org installs the Vercel plugin once; individual users don't burn Vercel seats with personal OAuths.

## Lifecycle

| Phase | Plugin verb | What happens |
|---|---|---|
| **Install** | none | Manifest validated, signed-hash verified, OAuth flow run, providers registered, verbs added to registry, webhook URL configured at the source system. |
| **Configure** | `configSchema` form | Tenant fills in plugin-specific config (e.g., default Vercel project ID, log retention). |
| **Enable** | `activate()` | Provider lifecycle activates per `002`. Verbs become invokable in workflows. Webhooks start firing. |
| **Disable** | `deactivate()` | Providers deactivate. Verbs grayed out (workflows referencing disabled verbs error at compile, not at run). Webhooks suspended. |
| **Uninstall** | none | Reverse of install. OAuth revoked at source. Local config retained for re-install convenience unless tenant explicitly purges. |

Pause/resume happens at the plugin level, not per-capability. A disabled plugin's verbs are unavailable to all workflows simultaneously; partial disable would create the same composability mess as capability-level auth.

## Versioning

Plugins ship as semver. Workflow Definitions reference plugins by id + major version pinning:

```yaml
# In a Workflow Definition
spec:
  steps:
    - id: deploy
      type: action
      config:
        action: vercel@1:vercel.deploy   # pinned to major version 1
```

Three-tier version policy:

| Bump | Triggered by | Workflow impact | Tenant action |
|---|---|---|---|
| **Patch** | Bug fixes, internal refactors. No surface change. | None. | Auto-applied. |
| **Minor** | Additive only — new optional input field, new output branch on a switch verb, new verb in the registry. | None on existing workflows. New optional fields ignored unless workflow opts in. | Auto-applied; lint warnings for workflows that haven't opted into new branches. |
| **Major** | Breaking — renamed verb, removed verb, changed input/output schema in incompatible ways. | Workflows pinned to old major continue working. New major must be installed explicitly. | Tenant approves the new major; plugin maintainer must continue shipping old major's verbs (under the same id) until the runtime sees no installed workflows reference them. |

**Auth scope changes** are a special case. Adding a new auth scope re-prompts consent (GitHub App pattern) — workflows continue running on the old scope set until the operator approves. Removing a scope requires a major bump.

**Verb-version pinning at the verb level.** Within a major version, individual verbs may be marked `@deprecated: true` and a successor declared:

```yaml
verbs:
  - id: vercel.deploy
    deprecatedSince: 1.3.0
    deprecatedAfter: 2026-09-01      # hard cutover date
    successor: vercel.deploy.v2
  - id: vercel.deploy.v2
    inputSchema: ./schemas/deploy-v2.input.json
    # ...
```

The workflow engine refuses to compile a workflow whose pinned verb version is past its deprecation date, forcing migration. (Temporal's pattern.)

## Worked examples

### Donmai Vercel Integration

The full manifest above. One install gives the org:
- Three Provider Family registrations (`DeploymentProvider`, `SandboxProvider`, `ObservabilityProvider`)
- Four workflow verbs covering deploy, list, log tail, deployment-complete gate
- One webhook ingress (Vercel pings `/webhooks/vercel`; payload discriminates four event types)
- One OAuth scope set granted atomically

A workflow can use `vercel@1:vercel.deploy` as an action, then `vercel@1:vercel.deployment.completed` as a gate, then route on success/failure. Same install also lets a different workflow query `vercel@1:vercel.list_deployments` for monitoring.

### Donmai Slack Integration (sketch)

```yaml
apiVersion: donmai.dev/v1
kind: Plugin
metadata: { id: slack, name: Donmai Slack Integration, version: 1.0.0 }

providers:
  issue-tracker:                       # @-mentions trigger issue creation
    - id: slack.mention-tracker
      class: ./dist/issue-tracker.js#SlackMentionTracker
  notification:                        # not yet a Provider Family in the architecture
                                       # — might land in a future addition
    - id: slack.notifier
      class: ./dist/notifier.js#SlackNotifier

verbs:
  - id: slack.send_message
    implementedBy: slack.notifier
    sideEffectClass: external-write
  - id: slack.thread.replied
    kind: gate
    eventSubscription: slack.thread.message
  - id: slack.mention
    kind: trigger
  - id: slack.user.has_role
    kind: condition
    inputSchema: ./schemas/has-role.input.json
    outputSchema: ./schemas/has-role.output.json

events:
  webhookPath: /webhooks/slack
  types: [slack.mention, slack.thread.message, slack.message.created]

auth:
  type: oauth2
  scopes: [chat:write, channels:read, users:read]
  perOrgInstall: true
```

Same single-artifact, multi-capability shape. A user @-mentions Donmai in a Slack thread → `slack.mention` trigger fires → workflow extracts the request → routes to backlog-writer → creates a Linear issue.

### Spring Java Kit (referenced from `005`)

A Kit is a specialized Plugin — its manifest emphasizes `[provide]` blocks (toolchain, commands, prompt fragments, MCP servers, intelligence extractors) rather than Provider Family registrations. See `005` for the manifest shape. The Plugin spec here governs the *shared* aspects (signing, scope, lifecycle, registry, version pinning).

## OSS vs SaaS responsibilities

| Concern | OSS | SaaS |
|---|---|---|
| Plugin manifest schema + parser | ✅ owns | consumes |
| Manifest validation (signature, semver, namespace) | ✅ ships | inherits |
| Project-local plugin discovery | ✅ ships | inherits |
| Bundled core plugins (linear, donmai) | ✅ ships | inherits |
| Verb registry (in-process) | ✅ ships | inherits |
| Hosted plugin registry | ❌ | ✅ owns (`registry.donmai.dev`) |
| Plugin signing CI + provenance | partial (sigstore) | full (sigstore + tenant allowlist + attestation chain) |
| Multi-tenant install management | ❌ (single-tenant) | ✅ owns |
| Plugin marketplace UX | ❌ | ✅ owns |
| Per-tenant plugin policy | ❌ | ✅ owns |

OSS users can install plugins from local manifests or any registry their config points at. SaaS tenants get the curated registry, the marketplace UX, multi-tenant install isolation, and policy controls.

Net-new items to implement (full list in `009` after expansion):

- Plugin manifest schema + validator implementation
- Plugin loader runtime (manifest → registered providers + verbs)
- `registry.donmai.dev` hosting infrastructure
- Plugin marketplace UI (SaaS)
- Sigstore signing CI
- `DonmaiVercelPlugin` reference implementation
- `DonmaiSlackPlugin` reference implementation
- `DonmaiAtomicPlugin` (per `008`)

## Open questions

1. **Stateless verbs without provider registration.** Some verbs are pure functions over their inputs (e.g., `linear.issue.is_terminal` is logic over an issue payload). Should they require a provider registration anyway, or be allowed without `implementedBy`? Default: allow without; provider registration is for stateful resources (clients, connections, capacity).
2. **Verb input/output cross-typing.** Should the engine type-check across nodes (output of step A flows into input of step B)? Yes — but inter-node piping is currently absent (see `016`). Open issue.
3. **Plugin <-> plugin dependencies.** A plugin may depend on another's verbs or providers. Default: declare via `requires` in metadata; install fails if dependency missing. Concrete syntax in a future ADR.
4. **Hot-reload.** When a plugin's manifest changes during development, can the host pick up new verbs without restart? Default: no; plugin reload is a tenant-initiated action that disables/re-enables. Dev-mode flag opts in.

These ship as defaults-and-document in the OSS reference; ADRs lock answers as we get implementation experience.
