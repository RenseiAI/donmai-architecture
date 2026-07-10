# 005 — Kit Manifest Spec

**Status:** Reference. `[provides]` / `[depends_on]` cross-family-consumption blocks **Accepted (2026-05-06)** in lockstep with `002` v2. Package integrity and deterministic command/catalog composition **Accepted (2026-07-10)** by `ADR-2026-07-10-deterministic-kit-packages-and-command-composition.md`.
**Last updated:** 2026-07-10
**Related:** `001-layered-execution-model.md`, `002-provider-base-contract.md`, `003-workarea-provider.md`, `006-cross-provider-interactions.md`, `ADR-2026-07-10-deterministic-kit-packages-and-command-composition.md`

> **Naming note:** "Kit" is a placeholder. The brand team is selecting from a candidate list (Ofuda 🪧, Inro 📿, Haori 🧥) under the parent brand "donmai." A future ADR replaces the term throughout this corpus once chosen. Until then, every reference to "Kit" in this doc is a placeholder for the final family name.

## Why this exists

Working with Rust, Go, Ruby, TypeScript, Next.js, C++, iOS, or non-code workflows (marketing, ops, social media plans) is fundamentally different. Carrying the entire weight of every framework into every agent session is wasteful and slow. Worse, it forces the platform to maintain support for every language internally — Spring Java, Cocoa, Cargo, etc. — which doesn't scale.

The fix is the buildpacks pattern adapted for AI agents: third parties contribute language, framework, and domain support via a declarative manifest with detection rules and contribution types. The host runs detect against a target workload, picks applicable kits, composes their contributions into the session, and provisions the workarea/sandbox combination that satisfies their toolchain demands.

This doc defines the manifest schema, lifecycle, composition rules, and registry model. The strategic timing call lives here: the AI ecosystem (MCP Registry, Anthropic Skills, AgentStack, nori-skillsets, Tessl tiles) is converging on a buildpacks-like shape, but no system today bundles all four required dimensions — manifest, host-driven detection, registry, and deterministic composition. Landing this layer with a real spec is a chance to set the standard.

## The interface

```ts
interface KitProvider extends Provider<'kit'> {
  /**
   * Run the kit's detection logic against a target. Returns a confidence
   * score and the toolchain demands the kit would impose if applied.
   * Side-effect free — host may run multiple kits' detect() in parallel.
   */
  detect(target: KitDetectTarget): Promise<KitDetectResult>

  /**
   * Materialize this kit's contribution to a session. Called only after
   * detect returned a positive match and the host has decided to apply.
   */
  provide(ctx: KitProvideContext): Promise<KitContribution>
}

interface KitDetectTarget {
  // Filesystem snapshot of the workarea (or a candidate workarea before
  // it's provisioned, in which case this is the repo's HEAD).
  fileTree: FileTreeView         // sparse, lazily-loaded; declarative
                                 // detect doesn't trigger fetches

  // Repo metadata
  remoteUrl?: string
  defaultBranch?: string
  primaryLanguageHint?: string   // host-detected via linguist or similar

  // Project context
  scope: ProviderScope
  monorepoPath?: string          // when the kit is being detected for a
                                 // specific subdirectory in a monorepo
}

interface KitDetectResult {
  applies: boolean
  confidence: number             // 0..1; ties broken by manifest priority
  reason?: string                // human-readable for logs
  toolchain?: ToolchainDemand    // pre-revealed so scheduler can plan
                                 // workarea before provide() runs
}

interface KitProvideContext {
  workarea: Workarea             // already acquired
  workType: WorkType             // 'development' | 'qa' | 'refinement' | etc.
  scope: ProviderScope
  otherActiveKits: KitProviderId[]
                                 // for conflict-aware contributions
}

interface KitContribution {
  // Validation / build / test commands — feed into existing template
  // variables (validateCommand, buildCommand, testCommand)
  commands?: KitCommandSet

  // Prompt fragments — Handlebars partials with declared activation
  promptFragments?: KitPromptFragment[]

  // Tool permissions — extends the agent's allowed shell/tool surface
  toolPermissions?: ToolPermissionGrant[]

  // MCP servers — kit-shipped tool servers; host registers with agent runtime
  mcpServers?: McpServerSpec[]

  // Skills (SKILL.md) — conforming to agentskills.io spec
  skills?: SkillRef[]

  // Agent definitions — kit-shipped specialized agents
  agents?: AgentDefinitionRef[]

  // A2A skills the kit exports (kit-as-A2A-peer)
  a2aSkills?: A2ASkillRef[]

  // Code intelligence extractors — domain-specific AST/semantic extractors
  // (e.g., a Spring kit shipping a JPA-entity extractor for the memory graph)
  intelligenceExtractors?: IntelligenceExtractorRef[]

  // Workarea provisioning hints — what to clean, what to keep
  workareaConfig?: KitWorkareaConfig

  // Lifecycle hooks specific to this kit
  hooks?: KitHooks
}
```

The interface is intentionally rich. The buildpacks insight: the lifecycle is the runtime, regardless of whether contributions are declarative or executable. A simple kit ships only `commands` and `promptFragments` from a TOML manifest; a sophisticated kit ships custom agents, MCP servers, and code extractors. Same lifecycle, same composition rules.

## The manifest

Kit manifests are TOML files (familiar to Cargo/buildpacks/most ecosystems).
They declare what a kit does, but they are not the complete distribution or
signature target. A conforming distributable kit is a directory-backed package
whose signed canonical descriptor inventories `kit.toml` and every payload
path, digest, size, and portable mode. See
`ADR-2026-07-10-deterministic-kit-packages-and-command-composition.md`.

```toml
api = "rensei.dev/v1"

[kit]
id = "spring/java"
version = "1.0.0"
name = "Spring Java"
description = "Maven/Gradle Spring Boot projects"
author = "Spring Framework Team"
authorIdentity = "did:web:spring.io"
license = "Apache-2.0"
homepage = "https://spring.io"
repository = "https://github.com/spring-team/rensei-spring-kit"
priority = 80                     # tiebreaker for confidence-tied detection

[supports]
# Which OS/arch combinations this kit applies to. Kit detect is short-
# circuited to no-match on incompatible platforms — a session running
# on linux/x86_64 will not consider a kit declaring only macos/arm64.
os = ["linux", "macos"]
arch = ["x86_64", "arm64"]

[requires]
rensei = "^1.0"
capabilities = ["workarea:toolchain", "memory:graph"]

# ─── Detection ───────────────────────────────────────────────────────────
[detect]
# Declarative match — fast path, no executable required
files = ["pom.xml", "build.gradle", "build.gradle.kts"]
# Optional executable detect for nuanced cases (Spring Boot vs plain Spring)
exec = "bin/detect"               # invoked in workarea sandbox
                                  # only when declarative match passes

# Toolchain pre-declaration so scheduler can provision workarea before
# the kit's provide() runs
[detect.toolchain]
java = "17"

# ─── Contributions (provide) ────────────────────────────────────────────
[provide.commands]
build = "./mvnw compile"
test = "./mvnw test"
validate = "./mvnw verify -DskipTests"

[[provide.tool_permissions]]
shell = "./mvnw *"

[[provide.tool_permissions]]
shell = "java *"

[[provide.prompt_fragments]]
partial = "spring-conventions"
when = ["development", "qa"]
file = "partials/spring-conventions.yaml"

[[provide.mcp_servers]]
name = "spring-context"
command = "./bin/spring-mcp"
description = "Bean wiring queries, JPA entity introspection"

[[provide.skills]]
file = "skills/spring-test-debugging/SKILL.md"

[[provide.agents]]
id = "spring-test-fixer"
template = "agents/spring-test-fixer.yaml"
work_types = ["qa", "refinement"]

[[provide.a2a_skills]]
id = "spring-pr-reviewer"
description = "Reviews Spring/JPA PRs against best practices"
endpoint = "agents/spring-pr-reviewer.yaml"

[[provide.intelligence_extractors]]
name = "jpa-entity-extractor"
language = "java"
emits = ["entity", "repository", "named-query"]

[provide.workarea_config]
clean_dirs = ["target", ".gradle/caches/build-cache"]
preserve_dirs = ["~/.m2/repository"]   # cache that survives release-to-pool

# Per-OS toolchain install — used by the workarea provider when the
# requested toolchain is not pre-warmed in the pool. Kits declare these
# so the platform doesn't have to maintain Spring/Rust/Cargo install
# logic for every OS.
[provide.toolchain_install.linux]
java_17 = "sdk install java 17.0.13-tem"
maven   = "sdk install maven 3.9.9"

[provide.toolchain_install.macos]
java_17 = "brew install openjdk@17 && ln -sfn $(brew --prefix openjdk@17)/libexec/openjdk.jdk /Library/Java/JavaVirtualMachines/openjdk-17.jdk"
maven   = "brew install maven"

[provide.toolchain_install.windows]
# Optional. If omitted, kit declares it does not support windows.
java_17 = "scoop install openjdk17"
maven   = "scoop install maven"

# Per-OS command overrides — when validate/build/test differ.
# Defaults from [provide.commands] above; this overlay only specifies
# OS-specific deviations.
[provide.commands_override.windows]
build = ".\\mvnw.cmd compile"
test  = ".\\mvnw.cmd test"

[provide.hooks]
post_acquire = "bin/setup"        # one-time setup after workarea ready
pre_release = "bin/teardown"

# Hooks may also be OS-keyed. The most-specific match wins.
[provide.hooks.os.windows]
post_acquire = "bin\\setup.cmd"

# ─── Composition rules ───────────────────────────────────────────────────
[composition]
# Conflicts with these other kits — host warns and tenant must choose
conflicts_with = ["maven-only", "gradle-only"]

# This kit composes well with these — informational, not enforced
composes_with = ["docker-compose", "postgres-dev"]

# Order — runs after foundation kits (e.g., generic-jvm) but before
# project-specific kits
order = "framework"               # 'foundation' | 'framework' | 'project'

# ─── Provides / depends_on (cross-family consumption) ────────────────────
# Symbolic capabilities this kit makes available to *other consumers*
# (other kits and providers from other families — see `002` v2). The keys
# below are free-form strings; the host uses them to resolve cross-family
# dependencies declared by providers via `consumesKits`.
[provides]
capabilities = [
  "toolchain:java-17",            # consumers can declare depends_on this
  "toolchain:maven-3.9",
  "build:spring-boot",
]

# Other kits this kit needs in order to provide() correctly. The host
# composes dependencies in order: required kits run first.
[depends_on]
kits = [
  { id = "generic-jvm", version = "^1.0" },
]
capabilities = [
  "workarea:toolchain",           # host-side capability required
]
```

The schema is open along well-defined extension points (additional `provide.*` arrays, custom `detect` checks via `exec`). Adding a new contribution type requires bumping `api`; consumers verify they understand it before activating.

### Package envelope and path-bearing fields

The manifest above is the logical contribution contract. Publication wraps it
in a `donmai.dev/kit-package/v1` package descriptor. That descriptor is the
signature subject and inventories every regular payload file; a detached
manifest signature is a legacy, manifest-only trust artifact. The descriptor
also names a stable publisher identity; the pinned catalog snapshot or explicit
local trust policy must authorize that signer for the kit-id namespace.

Every field whose value can name package-owned content must become explicitly
typed as a package path in the next manifest revision. Inline shell text,
system executable names, URLs, and package paths are distinct kinds. A
publisher must not infer ownership from slashes or filename extensions. Package
paths are normalized, contained beneath the package root, present in the signed
inventory, and resolved without symlinks or special files. The full normative
path, digest, size, mode, and reference-closure rules live in the accepted ADR.

Legacy `rensei.dev/v1` manifests remain parseable during the compatibility
window, but a verified signature over only `kit.toml` is reported as
`legacy-manifest-verified`, never `package-verified`.

## Being consumed by providers (`002` v2 lockstep)

Per `002-provider-base-contract.md` v2 (Decision 2 / Cross-family dependencies), a *provider* from any family may declare it consumes a kit's contributions. The example: the Claude AgentRuntime provider declares it needs the `node-sandbox` kit's toolchain to satisfy a Node-based skill it ships. The mechanism is symmetric to kit-to-kit dependencies above.

A provider's manifest gains an optional `consumesKits` field (typed in `002`):

```ts
// in 002-provider-base-contract.md ProviderManifest<F>
interface KitDependency {
  id: string                  // kit id
  version?: string            // semver range; defaults to latest
  capabilities?: string[]     // [provides].capabilities the provider relies on
}
```

Resolution rules:

1. The host resolves `consumesKits` at provider activation. The named kit must be in scope (per `002` scope resolution) and must declare each requested capability under `[provides].capabilities`.
2. Activation fails with a clear error if the kit is missing, the version range doesn't satisfy, or a requested capability is not declared.
3. Cross-family consumption does not bypass detection — a kit consumed-by-provider still runs its `detect` against the workarea, and if the kit doesn't apply, the consuming provider activates without those contributions (with a warning log) rather than failing silently. Providers that *require* a kit's contributions to function should declare so via the manifest's `requires.capabilities` rather than soft `consumesKits`.

The kit doesn't know which provider consumed it; the provider doesn't know how the kit produced the capability. The `[provides].capabilities` namespace is the contract between them — same compositional shape as kit-to-kit dependencies, extended to the cross-family case.

## Platform compatibility (OS / CPU architecture)

Kits declare `[supports]` to bound applicability:

```toml
[supports]
os = ["linux", "macos"]            # required
arch = ["x86_64", "arm64"]         # required
```

The host short-circuits detect to `applies: false` when the workarea's `os`/`arch` (resolved by the workarea provider per `003`) is not in the kit's supported set. The kit's detect logic never runs on incompatible platforms; this is both a performance win (fewer detect-execs) and a correctness guarantee (no false-positive matches that would explode at install time).

Per-OS contributions: kits declare OS-keyed install scripts under `[provide.toolchain_install.<os>]`, OS-keyed command overrides under `[provide.commands_override.<os>]`, and OS-keyed hooks under `[provide.hooks.os.<os>]`. The most-specific match wins (OS-keyed > generic).

For very-platform-specific kits (e.g., an iOS kit), declaring `os = ["macos"]` is the natural way to gate. For platform-agnostic kits (e.g., a generic-TS kit), declare all three OS values; the kit ships installation paths only for the platforms it tests against. Kits SHOULD NOT silently no-op on unsupported platforms — declare what you support.

The platform's expected coverage today:
- **macos** + **arm64 / x86_64** — Mac Studio / MacBook Pro fleets (primary OSS target)
- **linux** + **x86_64 / arm64** — most cloud sandbox providers, enterprise self-hosted K8s
- **windows** + **x86_64 / arm64** — deferred for OSS, in scope for enterprise (regulated banking demands)

The architecture admits all three; OSS shipping order tracks user demand.

## Detection lifecycle

Detection runs in two phases:

### Phase 1 — Declarative

For every kit in scope, the host evaluates `[detect]` declarative matchers against `KitDetectTarget`. Matchers:

- `files` — array of file/glob patterns. Match if any file exists.
- `files_all` — array; match only if all files exist.
- `content_matches` — `[ { file: "package.json", json_path: "$.dependencies.next" } ]` for structured-content matching.
- `not_files` — exclusion conditions.

Cheap: no I/O beyond an indexed file-tree lookup. Runs in parallel for all candidate kits. Output: list of (kit, declarative-match-passed) pairs.

### Phase 2 — Executable (only if declarative passed)

For kits with `[detect].exec`, the host runs the detect binary inside the workarea sandbox (or a minimal scratch sandbox if no workarea is yet provisioned). The binary returns a `KitDetectResult` JSON to stdout.

Phase 2 is gated on Phase 1 to keep cost bounded. Tenants may set policy: "only run executable detection for kits whose author identity is in the trusted-signers list" — guards against malicious detection logic.

### Confidence and selection

If multiple kits return `applies: true`, the host:

1. Filters by `composition.conflicts_with` — emit error if conflicting kits both apply unmediated.
2. Sorts by `confidence`, then `priority`, then `kit.id` (deterministic tie-break).
3. Applies the top-K (configurable; default unbounded) within an `order` group.
4. Applies in `order` group sequence: `foundation` → `framework` → `project`.

The result is an ordered list of kits to materialize.

## Composition rules

Composition is where most subtle bugs live; explicit rules prevent silent surprises.

### Per-contribution-type composition

| Contribution | Rule |
|---|---|
| `commands` (build/test/validate) | Retain every owner-qualified command. Each generic alias has one explicit owner; ambiguous claims fail before execution. Never last-applied-wins. |
| `prompt_fragments` | Concatenated in apply order. Each carries `when` filter; only fragments matching `workType` are included. |
| `tool_permissions` | Union. A command allowed by any active kit is allowed in the session. |
| `mcp_servers` | Concatenated; duplicate `name` is an error. |
| `skills` | Concatenated; duplicate `id` is an error. |
| `agents` | Concatenated; duplicate `id` errors. Multiple agents may share `work_types`. |
| `a2a_skills` | Concatenated; duplicate `id` errors. |
| `intelligence_extractors` | Concatenated by `language` + `emits`. Multiple extractors may emit same kind; results de-duped at the memory layer. |
| `workarea_config.clean_dirs` | Union. |
| `workarea_config.preserve_dirs` | Union. |
| `hooks` | All run; failure of any aborts. Foundation hooks run first. |

### Command ownership and generic aliases

Command identity is the structured tuple `(kit id, local command name, package
digest)`. Generic names such as `build`, `test`, and `validate` are aliases, not
identities. Distinct owner-qualified commands merge additively; their shell text
is never concatenated, merged, or treated as authority.

An OS-specific command override specializes a command owned by the same
package. Cross-kit replacement requires either an operator-approved
composition-lock binding or a signed delegation from the displaced command's
authorized owner (or catalog policy authorized for that owner's namespace).
The delegation names both exact active commands and its scope. A replacement
kit's own declaration is only a request and cannot grant itself authority over
another kit's alias. Every replacement edge must be authorized; chains must be
complete, acyclic, and end at one owner. Multiple unresolved claimants are a
composition error that lists every claimant and the required binding action.

Order group, confidence, priority, registry source, and discovery/scan order do
not select a generic-command owner. Disjoint monorepo path scopes compose into
separate command plans; overlapping scopes resolve aliases together and fail on
ambiguity. The active registry generation records every alias binding and a
composition digest.

The v1 `[provide.commands]` map is a legacy alias claim. Two v1 kits exporting
the same key conflict unless an external composition lock selects the owner. A
new manifest revision is required to encode structured aliases, replacement
requests, and target-owner delegations; consumers that do not understand it
must reject that revision rather than fall back to last-wins behavior. Full
semantics are in
`ADR-2026-07-10-deterministic-kit-packages-and-command-composition.md` §4.

### Scope composition

Per `002-provider-base-contract.md`, a kit's scope can be project, org, tenant, or global. Composition respects scope:

- Project-scoped kits override org-scoped of the same `id`.
- Multiple project-scoped kits with different `id`s compose normally.
- Conflict: same `id` at the same scope level → error unless an explicit active
  package/catalog lock selects one exact package digest. Source order never
  resolves the conflict.

### Monorepo path scoping

Kits can scope to specific paths via the `Provider` base scope's `paths` selector:

```ts
scope: {
  level: 'project',
  selector: { project: 'renseiai', paths: ['apps/family-ios/**'] }
}
```

The `iOS Kit` only contributes when sessions touch `apps/family-ios/**`. The `TS
Kit` only contributes when sessions touch `apps/social/**`. A coordinator
session spanning both pulls both kits' contributions. Disjoint scopes produce
separate command plans; if selectors overlap, generic aliases resolve together
and ambiguous owners fail before execution. Hooks retain deterministic
foundation-first order within each effective scope.

## Registry sources

Kits are discovered through multiple sources, identical to the base contract's discovery model (`002`) but with kit-specific federation:

1. **Local manifests** — `.rensei/kits/*.kit.toml` in the workarea. Highest priority. Used for project-bespoke kits.
2. **Bundled kits** — shipped with the OSS execution layer. Default TS/Next.js kit lives here.
3. **Donmai-hosted registry** — `registry.donmai.dev` (SaaS-managed, available to OSS users via free tier).
4. **Tessl registry** — `registry.tessl.io`. Tessl tiles map onto kit contributions: skills (SKILL.md), docs (prompt fragments), rules. Tessl has no detect phase or toolchain demand, so a Tessl-imported kit ships only the contribution subset Tessl declares; the host wraps it with a default detect.
5. **Anthropic Skills registry** — `agentskills.io`. Same model as Tessl: import a skill, wrap it as a single-skill kit.
6. **Other community / enterprise registries** — declared in tenant config; same manifest schema and signature requirements.

Federation order is candidate-discovery order only. It is not package identity
or conflict authority. An official publication is a signed immutable catalog
snapshot that maps each `kit id + version` to one package digest. A consumer
pins the snapshot digest and resolves only those exact rows. Duplicate
id/version rows, an id/version under a different digest, missing material, or
unsupported package/manifest schemas fail closed.

Local/operator packages can coexist outside the official snapshot only when the
active composition lock records their source, trust state, exact digest, scope,
and override authority. Mutable branch names, `latest`, directory walk order,
and “first valid manifest” are never resolution inputs.

### Why Tessl and agentskills.io are sources, not separate plugin families

Tessl is a context distribution layer that sits beside git. Anthropic Skills is a packaging spec for individual agent capabilities. Neither is a full kit (no detect phase, no toolchain, no compositional ordering). But both ship valid *contribution subsets* (skills, prompt fragments, MCP server pointers). Treating them as registry sources for kits — wrapping each imported asset in a synthesized kit manifest — gives us interoperability without fragmenting the architecture.

The implication for tenants: "import a Tessl tile" is a valid action, and the host treats it as an installation of a single-purpose kit with a registry-derived manifest.

## Daemon kit registry

The local `donmai` daemon ships an in-process Kit registry and exposes it via
the operator control API. A package-aware registry selects one immutable active
generation containing exact package digests, catalog snapshot digest, and
generic-command bindings. Only complete packages referenced by that generation
are discoverable by detection or execution.

**Package store and legacy scan path.** Physical package-cache layout is an
implementation choice. Activation is the atomic generation switch defined in
`ADR-2026-07-10-deterministic-kit-packages-and-command-composition.md` §3.

During legacy compatibility, the daemon may also scan flat
`~/.donmai/kits/*.kit.toml` files. Configurable legacy paths use `daemon.yaml`:

```yaml
kit:
  scanPaths:
    - ~/.donmai/kits
    - /opt/donmai/kits           # operator-installed shared kits
```

Scan order is not authority. The same `kit.id` at the same effective scope is a
conflict unless the active lock names one exact package digest. Legacy paths do
not silently override one another, and a legacy manifest never impersonates an
official package from the pinned snapshot.

**Endpoints.** Per `ADR-2026-05-07-daemon-http-control-api.md` § D4:

```
GET    /api/daemon/kits
GET    /api/daemon/kits/<id>
GET    /api/daemon/kits/<id>/verify-signature
POST   /api/daemon/kits/<id>/install
POST   /api/daemon/kits/<id>/enable
POST   /api/daemon/kits/<id>/disable
GET    /api/daemon/kit-sources
POST   /api/daemon/kit-sources/<name>/enable
POST   /api/daemon/kit-sources/<name>/disable
```

The list endpoint returns a summary view (`Kit` struct in
`afclient/kit_types.go`); the per-id endpoint returns the full
`KitManifest` view including detect rules, contributions summary, and trust
state. Package-aware responses also expose package digest, catalog snapshot
digest, composition digest, and whether the kit came from an immutable package
or the legacy compatibility path. Packages MUST verify and parse cleanly before
activation; malformed or incomplete material never enters the active
generation.

**Trust verification.** The `verify-signature` endpoint runs the
sigstore-equivalent verification described in `002` § Layer 1. The response
distinguishes `package-verified`, `package-signed-unverified`,
`legacy-manifest-verified`, `legacy-manifest-unverified`, and `unsigned`.
Package verification binds the signed descriptor plus every inventoried file;
legacy verification binds only the manifest bytes.

**Atomic install.** Install fetches an exact package digest from a signed
catalog snapshot or explicit local source, verifies its complete closure in a
private same-filesystem staging directory, preflights composition, moves it to
immutable storage, and atomically switches the active generation. Descriptor,
signature, manifest, and payload are one transaction. Any failure leaves the
previous generation active; signature or payload persistence is never
best-effort. Hooks and detection do not run from staging.

The current manifest-only verifier/flat-file installer predates this contract.
It remains a `legacy-manifest-*` compatibility implementation until the package
publisher, transactional installer, command resolver, and conformance evidence
land together. This reference text does not claim that delivery.

**Empty registry.** If the scan path is empty or absent, the list endpoint
returns `{ "kits": [] }` with HTTP 200. Empty is a valid first-run state.

## Package publication, synchronization, and migration

An official catalog release publishes complete signed kit packages and a
signed canonical catalog lock from one source revision and monotonically
increasing publisher sequence. Each unique kit id/version maps to one package
digest and authorized package signer policy. A consumer pins the catalog-lock
digest, verifies every required package, preflights the proposed active set,
and then switches catalog/registry generation atomically. It never resolves
through a mutable branch, `latest`, first-found manifest, or fallback source
after a digest failure. A lower sequence is accepted only as an explicit,
audited rollback to a previously verified snapshot.

Online synchronization follows TUF 1.0 consistent-snapshot semantics (trusted
root, targets with hashes/lengths, versioned snapshot, expiring timestamp, and
monotonic trusted metadata versions) or a separately reviewed equivalent. A
binary/offline release can instead pin one exact lock digest, but cannot claim
that the pinned snapshot is current.

Package-aware consumers record the catalog snapshot, package, and composition
digests used by each session. A catalog rollback selects a previously verified
generation; it does not reconstruct an older set from mutable sources.

Legacy migration follows four explicit phases: classify existing flat
manifests without upgrading their trust; dual-publish packages and legacy
artifacts for one declared compatibility window; require packages for new
official remote installs; and remove legacy scanning only through a separately
announced breaking change. Official packages are rebuilt and signed by their
publisher. A local wrapper around a vendor-signed manifest cannot inherit the
vendor's package identity. See the accepted ADR §§5–6 for the complete
contract.

## Relationship to MCP

Kits **contain** MCP servers; they don't replace them. MCP is the runtime tool protocol; the kit is the packaging+detection+composition layer above it. A kit's `provide.mcp_servers` array tells the host: "register these MCP tool servers with the agent runtime when this kit is active." The MCP protocol is unchanged.

This positioning aligns with where the wider ecosystem is headed. MCP Registry + `.mcpb` is becoming the standard *transport* for tool servers. Kits become the standard *bundling* unit above it. They compose; one doesn't displace the other.

## Relationship to Anthropic Skills

Identical pattern: a kit's `provide.skills` array references `SKILL.md` files
conforming to `agentskills.io/specification`. The skill entrypoint and every
bundled resource are payload files in the signed package inventory. The agent
runtime loads them via the Skills mechanism it would have used anyway. Kits
contribute Skills; Skills don't displace Kits.

This means a kit can be 100% declarative for the simple case (no executable detect, no MCP servers, no agents — just a few SKILL.md files and some prompt fragments) and still be a valid kit. That keeps the barrier to entry low for vendors contributing simple language/framework support.

## Toolchain → workarea/sandbox seam

The single most important compositional mechanic: kits declare toolchain demands; workarea + sandbox providers satisfy them. Detail in `006-cross-provider-interactions.md`; the contract from this layer's side:

- Detection MAY return `toolchain` even when `applies: false`, to inform "if you applied me, this is what I'd need." Useful for cost preview.
- Detection SHOULD return `toolchain` when `applies: true` so the workarea provider can pre-warm.
- `provide()` runs *after* the workarea is acquired with the resolved toolchain. The kit can rely on `java` being in `PATH`, `JAVA_HOME` being set, etc.

The kit doesn't know which provider satisfied the toolchain. The provider doesn't know which kit imposed it. The toolchain spec (`{ java: "17", node: "20" }`) is the contract.

## OSS vs SaaS responsibilities

| Concern | OSS | SaaS |
|---|---|---|
| `KitProvider` interface | ✅ owns | consumes |
| Manifest schema + parser | ✅ owns | consumes |
| Detection runtime (declarative + executable) | ✅ ships | inherits |
| Composition algorithm | ✅ ships | inherits |
| Default language kits (TS, TS/Next.js, Go, Rust, Java, Python, Ruby) | ✅ ships (OSS catalog in `donmai-kits`) | consumes OSS catalog |
| Local manifest discovery | ✅ ships | inherits |
| Tessl / agentskills.io adapters | ✅ ships | inherits |
| Registry adapters (Donmai + community) | ✅ ships | ✅ ships hosted registry |
| Package signing + verification contract | ✅ owns signed descriptor/inventory, immutable catalog lock, transactional install, legacy trust-state split; current runtime is manifest-only pending ADR conformance | inherits exact package identity; may add tenancy policy/attestation |
| Official catalog publication | ✅ OSS catalog owns deterministic package + signed snapshot publication | may curate/distribute verified snapshots; cannot redefine identity or composition |
| Per-tenant kit policies | ❌ | ✅ owns |
| Kit publication / curation UI | ❌ | ✅ owns (paid) |

Standard discipline: every interface and adapter ships in OSS. SaaS adds the central registry, multi-tenant policy, and publication UX. The package-aware publisher/consumer rows above are accepted target responsibilities, not a claim that the current manifest-only installer has delivered them.

## Open questions

1. **Conflict resolution UX.** The contract is resolved: ambiguous package
   identity or generic-command ownership fails with all claimants and requires
   an explicit lock/binding. The remaining question is presentation — CLI/TUI
   configuration guidance versus a hosted one-click pin — not resolver
   semantics.
2. **Detect parallelism.** Phase 1 declarative is trivially parallel. Phase 2 executable could spawn many sandboxes; do we cap at e.g. 4 concurrent detect-execs? Probably yes, configurable.
3. **Kit versioning at composition time.** Two kits depending on incompatible versions of a third (transitive)? Default: error and require explicit lock. Long-term: a lockfile-shaped resolution akin to npm. Out of scope for v1.
4. **Cross-kit handles.** A Spring kit's MCP server might want to query a generic-Java kit's data. Should kits expose typed handles to each other, or only via shared contributions (memory, MCP)? Default: only via shared contributions; explicit cross-kit APIs are out of scope until demanded.
5. **Non-code kits.** Marketing/social workflows want kits too — but their "build/test/validate" don't apply. Contributions like `commands` may be empty for these; that's fine. The kit shape doesn't break, it just doesn't fill some fields. Worth a non-code reference kit (e.g., "Marketing campaign kit") in the OSS layer to validate.

These are intentional gaps for future ADRs.
