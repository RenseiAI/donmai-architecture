# 007 — Intelligence Services

**Status:** Reference (initial draft)
**Last updated:** 2026-04-27
**Boundary:** shared (OSS-canonical; platform extensions live at `rensei-architecture/007-intelligence-services-platform-extensions.md`)
**Related:** `001-layered-execution-model.md`, `005-kit-manifest-spec.md`, `006-cross-provider-interactions.md`

## Why this exists

The single most important user commitment from `001`: **using Donmai across LLM providers, sandbox providers, and issue trackers must produce a strictly better result than using any of those providers alone.** If we fail at that, we are an integration vendor.

Memory, Code Intelligence, and Architectural Intelligence are how that commitment is honored. They are the layer where the OSS execution layer accumulates compounding value: every session enriches the knowledge graph, every codebase improves the index, every PR refines the architectural understanding.

This is also where the **Day-1-vs-Day-40 quality commitment** from `001` is honored. Conversational quality stays consistent because conversations have compounding context; agent-fleet quality decays today because each session reads the issue, the codebase, maybe a CLAUDE.md, and starts fresh. Intelligence Services is the fix: persistent context that compounds across sessions and is actively retrieved at session start.

This doc defines the three services, the contracts they expose to kits and agents, and the cooperation rules with the rest of the architecture. The services are intentionally specified as capabilities that compose with provider-orthogonal sessions: an agent running on a snapshot-paused workarea using a Spring Java kit benefits from the same memory graph, same code index, and same architectural understanding as one running on a local pool with a TS kit.

## Implementation status (2026-05-07)

Per Wave 10 Phase 1 resolutions Q4: this doc is the **forward-looking canonical contract**. Three of the implementation surfaces below have OSS-shipped reference impls today; the others are scheduled.

| Surface | OSS-shipped today | Scheduled |
|---|---|---|
| Code Intelligence (`@donmai/code-intelligence`, six MCP tools) | yes | n/a |
| Code Intelligence (Go reimpl, `donmai code` subcommands) | partial (in flight) | finish in next-N waves |
| Memory query/write API + sqlite single-tenant reference impl | no | scheduled — see "Implementation status" annotation in § Memory below |
| Architectural Intelligence (single-project synthesis) | no | scheduled |

The contracts below are stable; they predate complete OSS implementations. This is the same forward-looking pattern the Wave 9 ADR used for `partialCoverage: true` on the daemon's provider endpoint. Forward-looking claims are retained because the contract shape is what plugins, kits, and integrations build against today; OSS shipping the reference impl is a wave-by-wave rollout, not a contract change.

## Memory

### Architecture summary

- **Knowledge graph** in storage (sqlite + vectors for OSS single-tenant reference impl; multi-tenant variants on the platform side).
- **Observation capture** during sessions: real-time FS event matching, AST-driven file-op extraction.
- **Cross-session injection** at session start: relevant prior context recalled into the agent's working memory.
- **Proactive memory**: real-time observation matching surfaces context-aware suggestions during sessions.
- **Context compaction** keeps long sessions productive.
- **Memory governance + open-format API** are explicit positioning constraints — the open-format API survives the OSS↔platform split; lock-in around accumulated graphs is the *opposite* of differentiation.

The OSS layer commits to ship **a working single-tenant memory store** (sqlite + minimal vector index) so OSS users get a meaningfully better experience than no memory at all. Multi-tenant variants (Postgres + RLS + Cedar) live on the platform side; see the platform extensions doc.

> **Implementation status (2026-05-07):** OSS-shipped sqlite reference impl is **scheduled** — interfaces below are forward-looking canonical contract. Forward-looking claim retained because the contract is stable and the OSS layer commits to ship the reference impl.

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

> **Implementation status (2026-05-07):** OSS-shipped reference impl is **scheduled** — single-project synthesis with sqlite + local LLM is on the OSS roadmap. The contract below is forward-looking canonical. Multi-project federated synthesis + the user-facing architecture browser live on the platform side (see platform extensions doc).

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

The package layout will mirror Code Intelligence:

```
@renseiai/code-intelligence          # exists today (file/symbol level)
@renseiai/architectural-intelligence # new (system level) — scheduled
```

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
- **Workflow Engine** (`016`) — drift assessment becomes a verb (`architecture.assess_change`) usable in custom QA workflows. PRs that diverge from established patterns can be flagged or blocked per tenant policy.
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
| `ArchitecturalIntelligence` interface | ✅ owns | consumes |
| Single-project synthesis | ✅ ships (sqlite + local LLM) — scheduled | inherits |
| Single-tenant graph storage | ✅ ships — scheduled | inherits |
| Multi-project federated synthesis | ❌ | ✅ owns |
| Drift detection rules | basic patterns | advanced + tenant policy |
| User-facing architecture browser | ❌ TUI only | ✅ owns (dashboard) |
| Cross-tenant pattern library | ❌ | ✅ owns (with privacy controls) |
| Synthesis-on-request (`synthesize()`) | ✅ ships | inherits + extends |

OSS users get a working single-project Architectural Intelligence — synthesizes their architecture, retrieves at session start, supports drift detection. SaaS adds cross-project federation, a user-facing architecture browser, and a tenant-scoped pattern library; see platform extensions doc for the SaaS column's runtime story.

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
