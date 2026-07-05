---
status: Accepted
boundary: OSS-only
date: 2026-07-04
---

# ADR-2026-07-04 — code-intel index schema v2: Go authoritative; TS byte-compat dropped; exec-shim decommission plan

**Status:** Accepted (shipped this wave)
**Date:** 2026-07-04
**Boundary:** OSS-only (the decision covers the `donmai` Go execution layer; no SaaS control-plane dependency)
**Authors:** code-intel capability run, W1 engine-hardening wave (`runs/2026-07-04-code-intel-capability/`, decision D3)

**Summary:** The persisted code-intelligence index (`.donmai/code-index/index.json`) moves to a **Go-authoritative schema v2**: a top-level `version` field gates loads (any mismatch → clean full rebuild), and `FileIndex` gains `contentHash`, `simHash`, `imports`, and `exports`. Byte-compatibility with the deprecated TypeScript `@donmai/code-intelligence` package is **deliberately dropped**. On top of the new fields, this wave shipped: real PageRank over the persisted import graph (replacing the exported-count heuristic), dedup against real file content (replacing symbol-text hashing), Go-native hybrid search (Voyage embeddings + Cohere rerank over BM25 candidates, env-key opt-in, BM25 fallback), and real incremental indexing (hash-before-extract Merkle diff). The TS exec-shim (`DONMAI_CODE_BIN` / legacy `AGENTFACTORY_CODE_BIN`) now emits a one-time deprecation warning and is scheduled for removal when `donmai-libraries` is archived. This ADR also explicitly restates that **Code Intelligence is exempt from the ADR-2026-06-07 intelligence retraction and is continued** — resolving a textual ambiguity in that ADR's Decision 1.

## Context

- **`donmai-libraries` (the JS engine) is deprecating.** The TS `@donmai/code-intelligence` package is unbuilt/unpublished and deprecate-bucketed; per the capability run's decision D4, no JS interim is adopted — the deprecation is paperwork-only (`package.json` `deprecated` field + README banner), and the JS sources (`pagerank.ts`, `dependency-graph.ts`, `hybrid-search.ts`) serve as **port references only**. The Go engine (`afclient/codeintel` in the `donmai` repo) is the sole client-side implementation going forward; all six `donmai code` subcommands (get-repo-map, search-symbols, search-code, check-duplicate, find-type-usages, validate-cross-deps) run natively in Go with no external binary.
- **The old `index.json` schema was constrained to TS byte-compat.** As `afclient/codeintel/types.go:10-19` stood, the persisted shape was pinned to the legacy TS `IncrementalIndexer.save()` output (`{ "files": …, "rootHash": … }`, `FileIndex` matching the TS `FileIndexSchema`), and `SymbolKind` strings carried a "Do NOT change these strings without also updating the TS side" constraint. With the TS package deprecating, that cross-repo sync constraint pinned the Go engine to a schema with no version tag, no import graph, and no content-identity fields — which in turn forced three dishonesties in the engine: "PageRank-ranked" repo maps that were actually an `exported*2 + symbolCount` heuristic, "duplicate detection" that hashed path+symbol-signature text rather than file content, and "incremental" indexing that re-parsed the whole tree on every call (the git-blob hash was compared only *after* extraction had run).
- Discovery anchors: `runs/2026-07-04-code-intel-capability/discovery/01-go-engine.md` (engine surface, verified file:line), `discovery/05-index-lifecycle.md` (index lifecycle), `01-architecture.md` decision D3 (founder-locked v1 scope).

## Decision

1. **Go owns the index schema; TS byte-compat is dropped.** The persisted shape is now
   `{ "version": 2, "files": { "<filePath>": FileIndex, … }, "rootHash": "<hash>" }`
   (`IndexSchemaVersion = 2`, `afclient/codeintel/native.go`). `SymbolKind` strings and `FileIndex` fields are Go-authoritative; there is no longer a TS side to keep in lockstep. `FileIndex` gains four fields: `contentHash` (xxHash64 of the file's normalised content — exact content identity), `simHash` (64-bit Charikar fingerprint — near-duplicate identity), `imports` and `exports` (module specifiers / exported names feeding the import graph). `gitHash` (git-blob SHA1) remains the change-detection / Merkle key. The new fields are computed only when a file is actually (re)extracted, so they cost nothing on the incremental hash-match fast path.
2. **The `version` field is a hard gate: mismatch → clean full rebuild.** On load, a persisted index whose top-level `version` is missing (0, i.e. every legacy v1 index) or does not equal `IndexSchemaVersion` is discarded wholesale and rebuilt from scratch (`loadIndex`). Never a half-migration. Bumping `IndexSchemaVersion` is the sanctioned mechanism for future shape changes.
3. **Real PageRank replaces the exported-count heuristic.** `get-repo-map` ranking is now genuine PageRank (damping 0.85, ≤100 iterations, tolerance 1e-6, deterministic node ordering — `pagerank.go`, a faithful port of the TS reference) over a file-level import graph built from the persisted per-file `imports` (`import_graph.go`). The rank IS the PageRank score; the old `exported*2 + symbolCount` heuristic is deleted. Documented limitation carried over from the reference: only **relative** import specifiers resolve to intra-repo edges, so PageRank is meaningful chiefly for JS/TS-style relative-import repos; bare/package specifiers (Go, Python, Rust module paths) produce no edge.
4. **Dedup compares real content hashes.** `check-duplicate` previously hashed `path + serialized symbol signatures` and compared the query against *that* — byte-identical source duplication was never actually detected. Both tiers now target the schema-v2 content fields: exact = query normalised-content xxHash64 vs each file's persisted `contentHash`; near = query SimHash vs persisted `simHash` by Hamming distance. Files without a content fingerprint are skipped (no spurious matches).
5. **Hybrid search is Go-native, env-key opt-in, with BM25 fallback.** `search-code` rescoring is a direct Go HTTP client pair (`voyage.go`, `cohere.go`, `hybrid.go`): the top-40 BM25 candidates are re-scored with Voyage embeddings (cosine blended with normalised BM25) and optionally reordered with Cohere cross-encoder rerank. No vector store, no HNSW, no whole-corpus embedding — at most **3 HTTP calls per query, independent of corpus size**. Gating contract: without `VOYAGE_AI_API_KEY`, zero network calls are made and BM25 order is returned unchanged; any Voyage/Cohere failure degrades gracefully to the best available order with at most one stderr warning — never a hard error. **Network-egress consequence (the opt-in boundary):** candidate text (symbol names/signatures/docs/file paths) leaves the process **only** when the operator opts in by setting `VOYAGE_AI_API_KEY` (`COHERE_API_KEY` additionally enables rerank). This adds a network-egress + secret-delivery axis to sandboxes running the engine; the env key IS the consent mechanism, and neither client logs request/response bodies or key material.
6. **Incremental indexing (Merkle diff) is now real.** `BuildIndex` does a cheap read + git-blob-hash pass over the tree, diffs the resulting Merkle tree against the persisted index (`MerkleDiff`), and invokes the expensive language extractors **only** on added/modified files; unchanged files reuse their `FileIndex` verbatim, and a Merkle-identical tree short-circuits with no extraction and no re-save. A long-lived process (the Wave-2 MCP server) additionally holds an in-process warm index behind an RWMutex, serving queries without re-walking or re-hashing. Supporting scope change shipped alongside: the default index root is the **enclosing git repository root** (worktree-aware `.git` discovery, `gitroot.go`), with `--repo-path` subtree scoping for monorepos.

## Clarification: Code Intelligence is exempt from the ADR-2026-06-07 retraction

`ADR-2026-06-07-intelligence-implementation-is-platform.md` Decision 1 reads: "The OSS layer no longer commits to ship reference implementations of **Memory / Code Intelligence / Architectural Intelligence**." Taken literally, that text retracts the Code Intelligence reference implementation along with the other two. The operative carve-out lives only in the amendment annotation in `007-intelligence-services.md` ("Code Intelligence (which has a shipped reference impl + a Go reimpl in flight) is **unaffected**") — a reader of the ADR alone gets the wrong answer.

**This ADR resolves the ambiguity explicitly: Code Intelligence is exempt from the 2026-06-07 retraction and is continued as an OSS-shipped implementation.** The retraction's own rationale never applied to it: Code Intelligence had a shipped reference impl and a Go-reachable delivery path (`donmai code`, now the sole and complete native implementation shipped by this wave), whereas Memory and Architectural Intelligence Layer 2 had neither. The 007 annotation, not the ADR's Decision-1 list, states the operative scope; this ADR restates it in decision-grade text so neither document has to be read against the other. (Architectural Intelligence's own split is governed by `ADR-2026-06-08-arch-intel-go-native-af-arch-deprecation.md`; nothing here changes it.)

## Exec-shim decommission plan

The legacy TS code exec-shim — the subprocess path resolved via `DONMAI_CODE_BIN` (legacy alias `AGENTFACTORY_CODE_BIN`), `donmai-code` on PATH, or `pnpm donmai-code` — is demoted to an opt-in compatibility escape hatch:

- **Now (shipped this wave):** every shim resolution emits a one-time-per-process deprecation warning to stderr (`warnCodeShimDeprecated`, `afclient/codeintel/runner.go`), naming the resolution route and pointing at the native path. This mirrors the arch-shim precedent from `ADR-2026-06-08` — same one-time guard, same tone.
- **Removal trigger:** the shim (env vars, PATH probing, and the subprocess runner behind them) is **removed when `donmai-libraries` is archived**. Until then it remains available for A/B testing against the legacy TS implementation.
- The shim writes/reads whatever the TS binary produces; it is exempt from the v2 schema gate only in the sense that the native engine never trusts a foreign index — a v1 index left behind by the shim is discarded and rebuilt by the version gate (Decision 2).

## Consequences

### Positive

- The Go engine can evolve the persisted schema without a cross-repo sync constraint, and did so immediately: real PageRank, real dedup, real incremental indexing, and hybrid search all depend on v2 fields.
- The three honesty gaps (fake PageRank claim, symbol-text "dedup", re-parse-everything "incremental") are closed with fails-before/passes-after tests (`native_pagerank_test.go`, `native_dedup_test.go`, `native_incremental_test.go`, `native_schema_test.go`, `hybrid_test.go`, `native_warm_test.go`).
- Schema migration policy is trivial to reason about: one integer, discard-and-rebuild, no migration code to maintain.
- Hybrid quality upgrade costs a bounded ≤3 HTTP calls per query and is impossible to trigger accidentally — no key, no egress.

### Negative

- **One-time rebuild on upgrade:** every existing v1 index is discarded on first v2 load (~5–10s for a large repo; incremental thereafter). Accepted — clean rebuild beats half-migrated data.
- **No downgrade path:** an older binary cannot read a v2 index (and the v2 gate likewise discards any future-version index). Accepted for a client-side derived cache that can always be rebuilt from source.
- The deprecated TS package can no longer read Go-written indexes. Accepted: the TS package is EOL and the index is host-local derived state, not an interchange format.

### Risks

- **PageRank degrades on non-relative-import repos** (Go/Python/Rust bare package paths produce no intra-repo edges → near-uniform ranks). Documented in `import_graph.go`; language-aware import resolution is future engine work, not blocked by the schema (v2 already persists the raw specifiers).
- **Hybrid egress is operator-controlled but transitive:** an operator who sets `VOYAGE_AI_API_KEY` in a sandbox image opts in every session run in that image. The gating contract confines the exposure to top-K candidate metadata per query; secret-delivery hygiene for sandboxes is the cross-target-delivery wave's concern.

## Alternatives considered

- **Keep TS byte-compat and version out-of-band.** Rejected: the compat constraint was the direct cause of the missing fields, and the TS consumer is deprecating — compatibility with a corpse buys nothing.
- **In-place v1→v2 migration.** Rejected: the index is a derived cache; a full rebuild is seconds and cannot produce half-migrated state.
- **Port the JS hybrid-search pipeline (vector store + persisted embeddings).** Rejected per D3.4: a direct HTTP client pair with per-query cost bounds is sufficient at repo scale and avoids persisting embeddings (which would themselves need schema/versioning and would widen the egress surface).
- **Ship GA on honest BM25-only and defer hybrid.** Offered to the founder as a descope option; the founder locked hybrid into v1 scope with the env-key opt-in boundary.

## Affected documents

- `007-intelligence-services.md` — implementation-status table: the "Code Intelligence (Go reimpl, `donmai code` subcommands)" row moves from `partial (in flight)` to **shipped/hardened (2026-07-04, this ADR)**; annotation added pointing here. Updated in the same commit.
- `ADR-2026-06-07-intelligence-implementation-is-platform.md` — **not edited** (accepted ADRs are immutable); its Decision-1 ambiguity is resolved by the Clarification section above, which is now the citable statement of Code Intelligence's exemption.

## Affected work items

- `runs/2026-07-04-code-intel-capability/` W1 (engine hardening — this ADR documents its shipped state); W2 (MCP server) consumes the warm-cache/concurrency contract; W6 (badge removal + JS deprecation paperwork) executes the donmai-libraries archive that triggers exec-shim removal.

## Implementation notes

Shipped in the `donmai` repo (branch `feat/codeintel-v1-engine`): `afclient/codeintel/{types.go,native.go,import_graph.go,pagerank.go,hybrid.go,voyage.go,cohere.go,simhash.go,gitroot.go,runner.go}` and `afcli/code.go`. Verified via `GOWORK=off go build ./... && GOWORK=off go test ./...` plus `CGO_ENABLED=0` builds of `./afclient/... ./afcli/...`.
