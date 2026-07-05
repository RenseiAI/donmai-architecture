# 007 — Intelligence Services

**Status:** Reference (initial draft)
**Last updated:** 2026-07-04
**Boundary:** shared (OSS-canonical; platform extensions live at `rensei-architecture/007-intelligence-services-platform-extensions.md`)
**Related:** `001-layered-execution-model.md`, `005-kit-manifest-spec.md`, `006-cross-provider-interactions.md`

## Why this exists

The single most important user commitment from `001`: **using Donmai across LLM providers, sandbox providers, and issue trackers must produce a strictly better result than using any of those providers alone.** If we fail at that, we are an integration vendor.

Memory, Code Intelligence, and Architectural Intelligence are how that commitment is honored. They are the layer where the OSS execution layer accumulates compounding value: every session enriches the knowledge graph, every codebase improves the index, every PR refines the architectural understanding.

This is also where the **Day-1-vs-Day-40 quality commitment** from `001` is honored. Conversational quality stays consistent because conversations have compounding context; agent-fleet quality decays today because each session reads the issue, the codebase, maybe a CLAUDE.md, and starts fresh. Intelligence Services is the fix: persistent context that compounds across sessions and is actively retrieved at session start.

This doc defines the three services, the contracts they expose to kits and agents, and the cooperation rules with the rest of the architecture. The services are intentionally specified as capabilities that compose with provider-orthogonal sessions: an agent running on a snapshot-paused workarea using a Spring Java kit benefits from the same memory graph, same code index, and same architectural understanding as one running on a local pool with a TS kit.

## Implementation status (2026-05-07)

> **AMENDED 2026-06-07 by `ADR-2026-06-07-intelligence-implementation-is-platform.md`:** the OSS reference-impl commitment for **Memory** and **Architectural Intelligence** is **retracted**. There is no Go-reachable delivery path (the OSS binary is Go; these libraries are TS) and no OSS-standalone consumer (the fleet dashboard doesn't use them; the Node CLI is being retired). Intelligence *implementation* is platform-only; OSS keeps the **contracts + kit extension points** in this doc, plus execution and the fleet dashboard. Code Intelligence (which has a shipped reference impl + a Go reimpl in flight) is unaffected. Read the ADR for the boundary rationale and the migration.

> **AMENDED 2026-06-08 by `ADR-2026-06-08-arch-intel-go-native-af-arch-deprecation.md`:** the decision **splits** along the two layers. **Layer 1** (the diff-reader + drift gate; pure regex/JSON, no LLM, no DB) is **execution-layer** and goes **Go-native** as the default for `donmai arch assess` — with a real `gh` diff-fetch so the gate runs on actual PR content. This is OSS-canonical and ships today. **Layer 2** (the SQLite observation graph + *learned baseline* + LLM deviation detection) is **not** ported to OSS: it stays **platform-owned** per `ADR-2026-06-07` (intelligence is platform-implemented; OSS ships contracts + kit extension points only — no OSS reference implementations; the platform moved arch-intel onto platform-native code: clustering, synthesis, and a drift API). An OSS-standalone Go-native Layer 2 is **deferred** to a future dedicated ADR (`ADR-2026-06-07` decision point 5) and is not undertaken here. The legacy TS delivery surface is **retired**: the standalone `af-arch` CLI (`@donmai/cli`) and the TS `@donmai/architectural-intelligence` package (incl. its `sqlite-impl` reference) are deprecated/legacy with no live consumer (EOL with `donmai-libraries`), and the Go exec-shim that subprocessed `af-arch` is demoted to an opt-in, deprecation-warned `DONMAI_ARCH_BIN` fallback. Net: the `ArchitecturalIntelligence` *contract* stays OSS-canonical; the OSS *implementation* is the Layer-1 gate only, and Layer-2 *intelligence* remains platform-owned.

> **AMENDED 2026-07-04 by `ADR-2026-07-04-code-intel-index-schema-v2-go-authoritative.md`:** the Code Intelligence Go reimpl is **shipped/hardened** — all six `donmai code` subcommands are native Go with no external binary. The persisted index moved to a **Go-authoritative schema v2** (TS byte-compat deliberately dropped; version-gated clean rebuild), with real PageRank over the persisted import graph, real content-hash dedup, Go-native hybrid search (Voyage + Cohere, env-key opt-in, BM25 fallback), and real Merkle-diff incremental indexing. That ADR also **explicitly restates that Code Intelligence is exempt from the `ADR-2026-06-07` retraction and continued** (the carve-out previously lived only in this doc's 2026-06-07 annotation, while that ADR's Decision-1 text ambiguously listed Code Intelligence among the retracted surfaces). The TS exec-shim (`DONMAI_CODE_BIN`) now emits a deprecation warning and is removed when `donmai-libraries` is archived.

Per Wave 10 Phase 1 resolutions Q4: this doc is the **forward-looking canonical contract**. Three of the implementation surfaces below have OSS-shipped reference impls today; the others are scheduled.

| Surface | OSS-shipped today | Scheduled |
|---|---|---|
| Code Intelligence (`@donmai/code-intelligence`, six MCP tools) | yes | n/a |
| Code Intelligence (Go reimpl, `donmai code` subcommands) | **shipped/hardened** (2026-07-04 — all six subcommands native; schema v2, real PageRank, real content dedup, Go-native hybrid search, real incremental indexing; see `ADR-2026-07-04-code-intel-index-schema-v2-go-authoritative.md`) | n/a |
| Memory query/write API + sqlite single-tenant reference impl | no | scheduled — see "Implementation status" annotation in § Memory below |
| Architectural Intelligence — `donmai arch assess` Layer 1 (Go diff-reader + drift gate, real `gh` diff-fetch) | yes (default native path) | n/a |
| Architectural Intelligence — Layer 2 (SQLite observation graph + learned baseline + LLM deviation detection) | no — platform-owned (`ADR-2026-06-07`) | OSS-standalone Go-native port deferred to a future ADR (`ADR-2026-06-07` decision point 5) — not undertaken here |
| Architectural Intelligence — `af-arch` CLI + `@donmai/architectural-intelligence` (TS) | retired/legacy (deprecated, no live consumer, EOL with `donmai-libraries`) | n/a |

The contracts below are stable; they predate complete OSS implementations. This is the same forward-looking pattern the Wave 9 ADR used for `partialCoverage: true` on the daemon's provider endpoint. Forward-looking claims are retained because the contract shape is what plugins, kits, and integrations build against today; OSS shipping the reference impl is a wave-by-wave rollout, not a contract change.

## Memory

### Architecture summary

- **Knowledge graph** in storage (sqlite + vectors for OSS single-tenant reference impl; multi-tenant variants on the platform side).
- **Observation capture** during sessions: real-time FS event matching, AST-driven file-op extraction.
- **Cross-session injection** at session start: relevant prior context recalled into the agent's working memory.
- **Proactive memory**: real-time observation matching surfaces context-aware suggestions during sessions.
- **Context compaction** keeps long sessions productive.
- **Memory governance + open-format API** are explicit positioning constraints — the open-format API survives the OSS↔platform split; lock-in around accumulated graphs is the *opposite* of differentiation.

The OSS layer owns the Memory **contract** (`MemoryQuery`/`MemoryWrite`) and the kit extension points; the **implementation** (storage, recall, multi-tenant tenant model) lives on the platform side. See the platform extensions doc.

> **Implementation status — AMENDED 2026-06-07 (`ADR-2026-06-07-intelligence-implementation-is-platform.md`):** the prior commitment to ship an OSS single-tenant sqlite memory store is **retracted**. The interface below stays the canonical contract kits/agents target; the implementation is platform-only. A standalone OSS memory store, if ever pursued, must be built Go-native (the TS libraries can't serve the Go binary) — out of scope until there is a consumer. (For Architectural Intelligence, `ADR-2026-06-08-arch-intel-go-native-af-arch-deprecation.md` took only its **execution-layer** Layer-1 drift gate Go-native; the Layer-2 *intelligence* store stays platform-owned, and an OSS-standalone Go-native Layer 2 is deferred to a future ADR. Memory is in the same position — its intelligence implementation stays platform-only until there is a real OSS-standalone consumer.)

### Contract: what kits and agents see

Kits interact with memory through three interfaces.

```ts
// Memory query: agents and kits read context from the graph
interface MemoryQuery {
  query: string                         // natural-language or structured
  scope: ProviderScope                  // tenant / org / project bounds
  contextHints?: {
    sessionId?: string                  // current session — pulls recents
    issueId?: string                    // pulls per-issue history
    paths?: string[]                    // bounds to specific code regions
  }
  limit?: number
  includeKinds?: NodeKind[]             // 'observation' | 'entity' | 'decision' | etc.
}

interface MemoryQueryResult {
  nodes: GraphNode[]
  edges: GraphEdge[]
  citations: Citation[]                 // back to the originating session/change
}

// Memory write: kits + agents emit observations, decisions, entities
interface MemoryWrite {
  kind: NodeKind
  payload: unknown                      // schema per kind
  scope: ProviderScope
  source: {
    sessionId: string
    workareaSnapshotRef?: WorkareaSnapshotRef
    changeRef?: ChangeRef
    kitId?: KitProviderId
  }
}

// Intelligence extractor (kit-shipped): runs against a workarea, emits
// domain-specific nodes/edges that enrich the generic AST extraction
interface IntelligenceExtractor {
  language: string                      // 'java' | 'rust' | etc.
  emits: NodeKind[]                     // declared up-front
  run(workarea: Workarea): AsyncIterable<MemoryWrite>
}
```

Three properties matter:

- **Scope is per-write and per-query.** A node written at `project` scope is invisible to queries at `tenant` scope unless explicitly federated. The OSS single-tenant impl enforces project/global scope; multi-tenant scope (`tenant`, `org`) is meaningfully implemented only in platform-side variants where the Postgres+RLS layer lives.
- **Citations are mandatory on reads.** Every returned node carries `citations` back to the session, change, or external source that produced it. Agents may hallucinate; the citation chain is what makes their outputs auditable.
- **Extractors are kit-contributed.** A Spring kit ships a JPA-entity extractor; an iOS kit ships a SwiftUI navigation extractor. Generic AST stays in core; domain enrichment grows via kits. This is the natural extension point that Tessl-as-tile-source (`005`) and Anthropic Skills don't try to provide.

### Observation cooperation with workarea

Detail is in `006` (Seam 1). Contract summary:

- Workarea handles carry an `observationCursor` keyed on `(streamId, position)`.
- The memory writer dedupes idempotently on the cursor.
- Pause/resume preserves the cursor; pool reuse mints a fresh cursor.

Without this contract, every snapshot resume double-emits, every pool reuse leaks state, and eval replay (Seam 5) is unreliable. The seam doc is the authoritative source; this layer's contract just states the obligations on the memory side.

### Memory access from external contexts

The principle: a tenant's accumulated graph is *theirs*, exportable in a documented schema. Two practical surfaces:

- **MCP tools** expose memory as MCP-callable tools; any MCP-aware agent can read tenant memory under proper auth.
- **Direct API** (HTTP+JSON) exposes the same surface for non-MCP consumers. The schema is published.

This is a constraint on the implementation, not a design choice: tenants who can't export their graph won't trust accumulating one in the first place. Lock-in around memory is the *opposite* of the differentiation we're trying to build — durable value comes from being the best place to *grow* the graph, not the only place to read it.

## Code Intelligence

### Architecture summary

The existing `@donmai/code-intelligence` package (formerly `@renseiai/agentfactory-code-intelligence`, being deprecated; functionality migrating to the Go `donmai` binary) is the OSS-shipped reference implementation. Six in-process MCP tools today:

- `donmai_code_get_repo_map` — PageRank-ranked file importance map
- `donmai_code_search_symbols` — function/class/type definition search
- `donmai_code_search_code` — BM25 keyword search with code-aware tokenization
- `donmai_code_check_duplicate` — exact + near-duplicate detection before writing code
- `donmai_code_find_type_usages` — switch/case + mapping + usage sites for a type
- `donmai_code_validate_cross_deps` — cross-package import validation

Optional enhancements when API keys are configured:
- `VOYAGE_AI_API_KEY` — semantic vector embeddings (hybrid BM25 + vector mode)
- `COHERE_API_KEY` — cross-encoder reranking for precision

Index persists to `.donmai/code-index/` (Merkle-diff incremental indexing). First-run cost ~5–10s; subsequent reuses near-instant.

### Contract: what kits and agents see

Code Intelligence exposes its surface in two ways:

```ts
// As MCP tools (the dominant path for agent use)
// Already shipped via the donmai_code_* tools listed above.
// Kits don't redefine these; they consume them transitively when an
// agent runs in a workarea where Code Intelligence is registered.

// As a programmatic API (for kits' intelligence_extractors and host code)
interface CodeIntelligence {
  repoMap(workarea: Workarea, opts?: RepoMapOpts): Promise<RepoMap>
  searchSymbols(workarea: Workarea, query: SymbolQuery): Promise<SymbolHit[]>
  searchCode(workarea: Workarea, query: CodeQuery): Promise<CodeHit[]>
  checkDuplicate(workarea: Workarea, content: string): Promise<DuplicateReport>
  findTypeUsages(workarea: Workarea, typeName: string): Promise<UsageSite[]>
  validateCrossDeps(workarea: Workarea, packagePath?: string): Promise<DepValidation>
}
```

Properties that matter:

- **Indexed per workarea, keyed by `cleanStateChecksum`.** When the workarea is reused (same checksum), the index is reused. When the workarea changes, the diff is incremental (Merkle tree). This is what makes the OSS local pool fast.
- **Provider-orthogonal.** The code index doesn't care which sandbox/workarea provider hosts the workarea. Indexes are computed against the filesystem path; results are the same on snapshot-restored vs locally-pooled workareas.
- **Domain-extensible via kits.** Kits' intelligence extractors (`005`) augment the index with domain-specific concepts (e.g., "Spring Bean wired into this controller"). Generic stays in core; domain stays in kits.

### Cooperation with workarea

Detail in `006` (Seam 9). Summary:

- Code Intelligence subscribes to workarea lifecycle hooks.
- On `workarea-acquired`, it triggers (re-)index, reusing cached index when `cleanStateChecksum` matches.
- On `workarea-releasing`, it ensures pending writes flush.
- The index is keyed on `(workareaProviderId, repository, ref, cleanStateChecksum)`.

## Architectural Intelligence

The third intelligence service. Pairs with Code Intelligence (file/symbol level) and Memory (event level) by operating at the **system level**: synthesized understanding of the user's architecture that compounds across PRs, refactors, and agent decisions.

> **Implementation status — AMENDED 2026-06-07 (`ADR-2026-06-07-intelligence-implementation-is-platform.md`):** the OSS single-project-synthesis reference impl is **retracted** (was "scheduled"). The `ArchitecturalIntelligence` contract below stays OSS-canonical for kits/agents; the implementation — single- and multi-project synthesis, storage, the architecture browser — is platform-only. The `@donmai/architectural-intelligence` package's platform-coupled `postgres-impl` + `current_org_id` RLS adapter is removed from OSS as the platform migrates onto its own graph store.
>
> **Implementation status — AMENDED 2026-06-08 (`ADR-2026-06-08-arch-intel-go-native-af-arch-deprecation.md`):** the decision **splits** by layer. **Layer 1** (the diff-reader + drift gate; pure regex/JSON, no LLM, no DB) is execution-layer and ships **Go-native** as the default path for `donmai arch assess`, with a real `gh` diff-fetch so the gate runs on actual PR content — no Node, no subprocess, no external CLI. **Layer 2** (the SQLite observation graph + *learned baseline* + LLM deviation detection — `assessChange`-against-baseline) is **not** ported to OSS: it remains **platform-owned** per `ADR-2026-06-07` (intelligence is platform-implemented; OSS ships contracts + kit extension points only; the platform moved arch-intel onto platform-native code: clustering, synthesis, and a drift API). An OSS-standalone, Go-native Layer 2 is **deferred** to a future dedicated ADR (`ADR-2026-06-07` decision point 5) — the prototyped substrate is parked unmerged and is not undertaken here. The legacy TS delivery is retired: the `af-arch` CLI and the `@donmai/architectural-intelligence` package (including its `sqlite-impl` reference) are deprecated/legacy with no live consumer (EOL with `donmai-libraries`), and the Go exec-shim that subprocessed `af-arch` is demoted to an opt-in, deprecation-warned `DONMAI_ARCH_BIN` fallback. Net: the `ArchitecturalIntelligence` contract stays OSS-canonical; the OSS implementation is the Layer-1 gate only.

### The user-facing premise

The user shouldn't author architectural docs to benefit from architectural understanding. The system observes their codebase continuously, infers patterns, conventions, decisions, and deviations, and injects that understanding at session start so agents act with senior-engineer-level context — even on Day 90 of a project they've never seen before.

User journey:

- **Day 1:** Empty. The system starts indexing.
- **Day 7:** "This is a Next.js + tRPC + Drizzle stack. Auth is centralized in `lib/auth/middleware.ts`. Error handling uses `Result<T, E>` pattern." Agents see this in their session prompt.
- **Day 30:** Conventions, patterns, gotchas, and team decisions ("we picked Drizzle over Prisma because of edge-runtime support — see PR #142") are part of every session's context.
- **Day 90:** Drift detection. "This PR introduces a new pattern not present elsewhere — recommend aligning with established X or proposing an architectural change." Agents catch their own divergence before the human reviewer does.

This is how the Day-1-vs-Day-40 gap closes. Memory captures observations; Code Intelligence indexes the corpus; Architectural Intelligence **synthesizes** across both into structured understanding that retrieval can target precisely.

### Architecture summary

- **Inference pipeline:** consumes Memory observations + Code Intelligence index + PR/commit history. Synthesizes architectural patterns, conventions, decisions, deviations.
- **Storage:** structured graph nodes for inferred architectural concepts (patterns, conventions, decisions, drift events) keyed back to source code, PRs, and originating sessions for citation.
- **Retrieval:** at session start, retrieves the slices relevant to the workType and paths touched. Becomes part of the agent's session prompt.
- **Synthesis on request:** produces human-readable architectural docs (markdown, mermaid) when the user asks. The structured graph IS the source-of-truth; the markdown is a rendering.
- **Drift detection:** flags PRs whose changes diverge from established patterns. Surfaces in QA workflows.

Implementation layout (per `ADR-2026-06-08-arch-intel-go-native-af-arch-deprecation.md`):

```
donmai arch assess                   # Go-native (system level): Layer 1 diff-reader +
                                     #   drift gate (regex/JSON, real gh diff-fetch). The
                                     #   OSS execution-layer impl. Layer 2 NOT shipped in OSS.
@donmai/architectural-intelligence   # TS package — RETIRED/LEGACY (no live consumer; EOL)
af-arch                              # standalone CLI — RETIRED/LEGACY (use `donmai arch`)
                                     # Layer 2 (graph + learned baseline + LLM deviation):
                                     #   platform-owned (ADR-2026-06-07)
```

The earlier-anticipated TS `architectural-intelligence` package and its `af-arch` CLI are legacy. The OSS-standalone Architectural Intelligence is realized Go-native **for Layer 1 only** (the diff-reader + drift gate) in the `donmai` binary; **Layer 2** (the SQLite observation graph + learned baseline + LLM deviation detection) is platform-owned and is **not** shipped in OSS (`ADR-2026-06-07`). An OSS-standalone Go-native Layer 2 is deferred to a future ADR. Code Intelligence keeps its language-host federation (below): TS-shipped indexer for TS codebases, Go-shipped for Go, etc.

### Contract

```ts
interface ArchitecturalIntelligence {
  /**
   * Retrieval — get architectural context relevant to a session.
   * Called automatically at session start; agents may also call directly.
   */
  query(spec: ArchQuerySpec): Promise<ArchView>

  /**
   * Contribution — observations and inferences feed the graph.
   * Producers: PR merges, refactors, agent decisions, kit-shipped extractors.
   */
  contribute(observation: ArchObservation): Promise<void>

  /**
   * Synthesis — produce human-readable architectural docs on request.
   */
  synthesize(scope: ArchScope, format: 'markdown' | 'mermaid' | 'json'): Promise<string>

  /**
   * Drift detection — flag changes that diverge from established patterns.
   * Surfaces in QA workflows; used by agents during PR self-review.
   */
  assess(change: ChangeRef): Promise<DriftReport>
}

interface ArchQuerySpec {
  workType: WorkType
  paths?: string[]                     // narrow to relevant code regions
  issueId?: string                     // pull issue-specific architectural context
  scope: ProviderScope
  maxTokens?: number                   // bound the retrieved context size
}

interface ArchView {
  patterns: ArchitecturalPattern[]    // "Auth is centralized in lib/auth/middleware.ts"
  conventions: Convention[]           // "All API routes use Result<T, E>"
  decisions: Decision[]               // "Picked Drizzle over Prisma — PR #142"
  citations: Citation[]               // every assertion has a source
  drift?: DriftReport                 // current state of divergences in this region
}

interface ArchObservation {
  kind: 'pattern' | 'convention' | 'decision' | 'deviation'
  payload: unknown                    // schema per kind
  source: {
    sessionId?: string
    changeRef?: ChangeRef
    extractorId?: string              // when produced by a kit's extractor
  }
  confidence: number                  // 0..1; observations may evolve into stronger nodes
}
```

### Cooperation with the rest of the architecture

- **Kits** (`005`) ship `intelligenceExtractors`. A Spring Java kit's JPA-entity extractor feeds Memory; a Spring kit's *architectural-pattern* extractor feeds Architectural Intelligence with domain-specific signals (e.g., "this codebase follows hexagonal architecture; ports live in `domain/`, adapters live in `adapters/`"). Generic stays in core; domain-specific extension via kits.
- **Memory** is the storage substrate. Architectural Intelligence's nodes are graph nodes with kind=`pattern|convention|decision|deviation`; queries against them flow through the same scope-resolution layer.
- **Code Intelligence** provides the file/symbol-level grounding. An "Auth is centralized in `lib/auth/middleware.ts`" pattern node references the actual file via Code Intelligence's symbol map; refactoring that file invalidates the pattern node automatically.
- **Workareas** (`003`) emit observation events; Architectural Intelligence subscribes alongside Memory.
- **Workflow Engine** (`016`) — drift assessment becomes a verb (`architecture.assess_change`) usable in custom QA workflows, backed Go-native by `donmai arch assess` (the Layer-1 gate over real PR diffs). Layer-2 learned-baseline deviation detection is a platform-side capability (`ADR-2026-06-07`), not part of the OSS verb. PRs that diverge from established patterns can be flagged or blocked per tenant policy.
- **The architecture corpus (this repo)** — *our team's* canonical architecture is human-authored; user-facing Architectural Intelligence is system-inferred. Same shape, different authorship pipelines. The corpus's structure (layered model, plugin families, capability flags) informs the Architectural Intelligence's *synthesis vocabulary* — when the system describes a tenant's architecture, it uses concepts from the corpus.

### Active context injection at session start

The piece that closes Day-1-vs-Day-40 specifically. When a session starts:

1. The orchestrator invokes `ArchitecturalIntelligence.query({ workType, paths, issueId, scope })`.
2. Returned `ArchView` is rendered into a structured section of the agent's session prompt.
3. The session also receives Memory query results (per-issue history) and Code Intelligence summaries (relevant repo map slices).
4. As the session progresses, observations feed back into all three subsystems.
5. At session end, observations are flushed; new pattern/convention/decision nodes are inferred from the diff and committed back to the graph.

This is a retrieval-augmented prompt construction — the same shape Cursor, Continue, and others use, but with an architectural-understanding layer they don't have.

The injection is **bounded** — `maxTokens` ensures we don't blow the context window. Priority ordering: drift warnings > active issue patterns > project-wide conventions > org-wide patterns. Tenants can tune the slicing per project.

### OSS vs SaaS responsibilities

| Concern | OSS | SaaS |
|---|---|---|
| `ArchitecturalIntelligence` interface (contract + kit extension points) | ✅ owns | consumes |
| Drift gate + diff observations (Layer 1, `donmai arch assess`) | ✅ ships (Go-native) | inherits |
| Single-project graph storage / learned baseline (Layer 2) | ❌ — platform-owned (`ADR-2026-06-07`) | ✅ owns |
| Single-project synthesis / LLM deviation detection (`assessChange`-against-baseline) | ❌ — platform-owned (`ADR-2026-06-07`) | ✅ owns |
| Multi-project federated synthesis | ❌ | ✅ owns |
| Drift detection rules | basic patterns (Layer 1 gate only) | advanced + tenant policy |
| User-facing architecture browser | ❌ TUI only | ✅ owns (dashboard) |
| Cross-tenant pattern library | ❌ | ✅ owns (with privacy controls) |
| Synthesis-on-request (`synthesize()`) | ❌ — platform-owned (`ADR-2026-06-07`) | ✅ owns |

OSS users get the **Layer-1** drift gate Go-native: drift detection over real PR diffs (via `gh` diff-fetch) ships today — no Node, no subprocess, no external CLI. **Layer 2** (the observation graph, learned baseline, LLM deviation detection, and synthesis-on-request) is **platform-owned** per `ADR-2026-06-07`; OSS keeps the contract canonical but ships no Layer-2 implementation. An OSS-standalone Go-native Layer 2 is deferred to a future ADR (`ADR-2026-06-07` decision point 5). SaaS owns single- and multi-project synthesis, a user-facing architecture browser, and a tenant-scoped pattern library; see platform extensions doc for the SaaS column's runtime story.

### Strategic positioning

This is the first-class user-facing differentiator the platform commits to. A raw LLM doesn't have it. A static docs folder rots. Only active, automatic, agent-fed architectural synthesis compounds. Two non-negotiable principles, called out so they survive future contributors:

1. **Tenant data is portable.** The architectural graph exports as a documented format (markdown + structured JSON) on demand. Lock-in is the *opposite* of differentiation; tenants will refuse to grow what they can't export.
2. **The system never silently overrides human architectural intent.** When a tenant has authored architectural docs (project-level CLAUDE.md, ADRs, etc.), Architectural Intelligence treats those as **higher-confidence** sources than its own inferences. Authored intent always wins; inferences fill gaps and detect drift.

Lose either principle and Architectural Intelligence becomes a wrapper, not a differentiator.

## Language-host boundary for Code Intelligence

The Donmai exploration produced a Go reimplementation of Code Intelligence (`donmai code` subcommands using Go AST). The TS package `@donmai/code-intelligence` (formerly `@renseiai/agentfactory-code-intelligence`) is one of multiple OSS-shipped implementations.

The principle: **the indexer must be written in the language of the codebase being indexed; the consumer interface stays uniform.**

- TS/JavaScript codebases — TS-shipped indexer (tree-sitter-typescript, etc.).
- Go codebases — Go-shipped indexer (`go/ast`).
- Rust codebases — Rust-shipped indexer (`syn`).
- Python codebases — Python-shipped indexer (`ast` stdlib).
- ...

Each implementation registers as a `CodeIntelligenceProvider` (a sub-shape of the Provider Family pattern from `002`); the resolver picks one per workarea based on the detected primary language. Consumers (agents, kits, MCP tools) call the same interface regardless. This is the same shape as `WorkareaProvider`'s multiple implementations behind one contract.

Practical implication: the corpus does not pick "the OSS impl" — it specifies the contract. Every language ecosystem ships its own indexer; the registry federates them. The `donmai_code_*` MCP tools resolve to whichever indexer claims the workarea's language.

## Eval and Scoring (related, not the same)

Eval and scoring (Agentic DORA, cost-per-issue, code survival, agent-PR attribution, eval pipeline + model graders, guardrails, reasoning budget, Routing Intelligence) are *not* Memory or Code Intelligence; they're a separate concern that lives next to Intelligence Services and consumes both.

### Why eval/scoring isn't memory

- Memory is *what the system knows*; scoring is *how well the system performs*.
- Memory grows monotonically with use; scoring is statistical aggregate over outcomes.
- Memory is queried by agents during sessions; scoring is consumed by humans (and the routing layer) post-hoc.

### Conceptual cooperation hooks

Two cooperation points matter to memory and code intelligence:

- **Eval replay needs deterministic workarea state.** Detail in `006` Seam 5 — eval references `WorkareaSnapshotRef`, not commit SHAs. The workarea provider's snapshot retention contract is what makes this work.
- **Scoring datasets reference the graph.** A code-survival metric ("did this change still exist N days later?") queries the graph for change history; a routing-intelligence metric ("which model made better decisions for this kit?") queries kit detection events. Scoring builds dashboards over Memory + Observability events.

The dedicated eval/scoring doc is deferred until we have implementation experience. The hooks above (snapshot retention, graph queries) are the contracts that keep options open. SaaS-side eval dashboards + the Routing Intelligence panel live on the platform side; see platform extensions doc.

## OSS vs SaaS responsibilities

| Concern | OSS | SaaS |
|---|---|---|
| Memory query/write API | ✅ owns | consumes |
| Single-tenant local memory store (sqlite + vectors) | ✅ ships — scheduled | inherits |
| Multi-tenant Postgres + RLS + Cedar | ❌ | ✅ owns |
| Cross-project federation | ❌ | ✅ owns |
| Open-format API (export schema + endpoints) | ✅ ships per-tenant | ✅ ships hosted |
| MCP tool exposure | ✅ ships | inherits + extends |
| Code Intelligence API | ✅ owns | consumes |
| `donmai_code_*` MCP tools | ✅ ships | inherits |
| Voyage / Cohere optional integration | ✅ ships when keys present | ✅ ships hosted alternative |
| Index storage (`.donmai/code-index/`) | ✅ ships | inherits |
| Domain extractors | shipped via kits (both layers) | shipped via kits |
| Eval/scoring system | ❌ basic local logs only | ✅ owns dashboards + routing intelligence |

OSS users get a working memory + code-intelligence experience locally (Code Intelligence today; Memory + Architectural Intelligence per implementation status above). The SaaS extensions to multi-tenant, governance, cross-project federation, and the dashboard surface live in the platform-extensions doc.

## Strategic positioning notes

Two non-negotiable principles, called out so they survive future contributors:

1. **Tenant data is portable.** Memory exports must be a documented format with a working endpoint. Lock-in around accumulated graphs makes us the *opposite* of differentiated; tenants will refuse to grow what they can't export.
2. **Quality compounds via kits.** The platform doesn't internally maintain Spring/JPA/SwiftUI/Cargo expertise — kits do. Kits ship intelligence extractors, the platform composes them into the graph. Vendors and language communities contribute their domain knowledge; we provide the substrate. The Spring team's offer to contribute "Spring Java" support is the proof case.

Lose either principle and Intelligence Services becomes a wrapper, not a differentiator.

## Open questions

1. **Kit-shipped extractor sandboxing.** A malicious extractor could read sensitive memory state under tenant scope. Trust model: extractors run in the workarea sandbox (not orchestrator process), with memory writes filtered by signed-kit allowlist. Concrete enforcement lives in `010-security-architecture.md` once drafted.
2. **Memory write attribution.** A node written by a kit's extractor vs. by an agent's tool call vs. by an automated observation pipe should be distinguishable. Default: every `MemoryWrite` carries a `producer` field with `{ kind, kitId?, agentId?, sessionId }`. Consumers can filter; queries default to all sources.
3. **Cross-tenant federation for kit-distributed extractors.** A kit shipping a useful extractor (e.g., "Spring Bean Diagram Builder") doesn't want each tenant to re-train it from scratch. Public-domain seed graphs? Open question, deferred.
4. **Code intelligence index portability.** When a workarea moves between providers (snapshot archive → snapshot restore on a different provider), can the index move too? Currently no — indexes are local to the host running Code Intelligence. Probably acceptable; revisit if real workloads demand cross-provider index transfer.

These are intentional gaps for ADRs as we get implementation experience.
