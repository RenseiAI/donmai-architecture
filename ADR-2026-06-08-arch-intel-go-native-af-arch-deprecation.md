---
status: Accepted
boundary: shared
date: 2026-06-08
---

# ADR-2026-06-08 — The af-arch CLI is deprecated; Layer-1 drift gate goes Go-native (execution); Layer-2 stays platform

**Status:** Accepted · **Boundary:** shared (canonical here; mirrored stub in `rensei-architecture`)

**Summary:** The legacy TS architectural-intelligence delivery surface (the `af-arch` CLI + the `@donmai/architectural-intelligence` package) is retired. The Go-native realization is scoped to **Layer 1 only** — the diff-reader + drift gate (pure regex/JSON, no LLM, no DB), which is execution-layer and OSS-canonical, and becomes the default for `donmai arch assess`. **Layer 2** (the SQLite observation graph + learned baseline + LLM deviation detection) is **not** ported to OSS in this change: it stays platform-owned per `ADR-2026-06-07`. An OSS-standalone Go-native Layer 2 is deferred to a future dedicated ADR.

## Context

Architectural intelligence has historically lived in the TypeScript `@donmai/architectural-intelligence` package, surfaced standalone through the `af-arch` CLI (`@donmai/cli` → `code-arch.ts` → `arch-assess-runner.ts` → `SqliteArchitecturalIntelligence`). The Go binary's `donmai arch assess` command reached it through an **exec-shim** that subprocessed that CLI.

Two things have changed:

1. `ADR-2026-06-07-intelligence-implementation-is-platform` established that intelligence *implementation* is owned by the closed platform, that OSS ships only the **contracts + kit extension points** (no OSS reference implementations), and that any OSS-standalone intelligence must be built **Go-native** (the Go binary cannot import the TS libraries) under its own future ADR (decision point 5). The platform has since (2026-06-07) moved arch-intel off `@donmai/architectural-intelligence` onto platform-native code (clustering, synthesis, and a drift API) — so the package has no remaining platform consumer.
2. **Layer 1** (diff-reader + drift gate; pure regex/JSON, no LLM, no DB) is already Go-native and shipped, and is the **default** path for `donmai arch assess` (`afclient/codeintel/arch_native.go`); the exec-shim is opt-in behind `DONMAI_ARCH_BIN` with no hard-fail.

The two layers sit on opposite sides of the OSS line:

- **Layer 1 is execution.** A diff-reader and a drift gate that run pure regex/JSON over a PR's changed files — no LLM, no datastore, no server. That is exactly the client/execution work the OSS runner owns. Its one real gap is that the native path stubs the PR diff, so `donmai arch assess <pr-url>` runs the gate on empty content end-to-end.
- **Layer 2 is intelligence.** The SQLite observation graph (the six-table `contribute`/`query`/`synthesize` store), a *learned baseline* accumulated across PRs, and LLM deviation detection against that baseline (materialized Deviation nodes + reinforced patterns + decay/clustering). That is synthesis + learned state — precisely the "intelligence implementation" `ADR-2026-06-07` reserved to the platform, where the platform already owns the multi-project, multi-tenant version.

A 2026-06-08 consumer analysis confirmed the TS surface has no live consumer: the platform-aware binary already drops the afcli shim in favor of a platform-API drift command; the platform consumes the package in-process and is now off it; `SqliteArchitecturalIntelligence` has zero non-test consumers; the MCP `af_arch_query`/`af_arch_drift` tools and the orchestrator context-injection hook are dormant. The shim is also effectively unreachable in practice — the Go resolver looks for `donmai-arch` while the published bin is still `af-arch` (rebrand lag).

A Go-native Layer-2 substrate (the SQLite graph + lane-routed `assessChange`) was prototyped but is **not** part of this decision; it is parked unmerged on the `worktree-arch-go-native` branch pending a dedicated ADR.

## Decision

The user chose to **split**: ship the deprecation and the Layer-1 execution work now, and **drop the Layer-2 OSS port**.

1. **Retire the legacy TS delivery surface.** Deprecate the `af-arch` CLI (`@donmai/cli`'s `af-arch` bin + `code-arch.ts` + `arch-assess-runner.ts`) and deprecate the `@donmai/architectural-intelligence` TS package — both EOL'd with `donmai-libraries`. Neither has a live consumer (the platform moved off it). Marked deprecated with a removal plan, not hard-deleted in this change (downstream npm pins may exist).
2. **Layer 1 (drift gate) is Go-native and the default.** The pure-Go diff-reader + drift gate (regex/JSON, no LLM, no DB) is the default path for `donmai arch assess`. Add a **real `gh` diff-fetch** so the gate runs on actual PR/commit content rather than an empty stub. Demote the Go exec-shim to a deprecation-warned, **opt-in** `DONMAI_ARCH_BIN` fallback (removed once it has no callers). This is execution-layer work and is OSS-canonical.
3. **Layer 2 is NOT ported to OSS.** The SQLite observation graph + learned baseline + LLM deviation detection stays **platform-owned**, per `ADR-2026-06-07` (intelligence is platform-implemented; OSS ships contracts + kit extension points only — no OSS reference implementations; the platform moved arch-intel onto platform-native code: clustering, synthesis, and a drift API). OSS keeps the `ArchitecturalIntelligence` *contract* + kit extension points canonical, but ships **no** Layer-2 implementation.
4. **An OSS-standalone Go-native Layer 2 is deferred.** Per `ADR-2026-06-07` decision point 5 ("a genuine OSS-standalone intelligence, if ever wanted, must be built Go-native, under its own ADR"), a Go-native Layer-2 is undertaken only "if ever genuinely wanted" and only under a future dedicated ADR. The prototyped substrate stays parked unmerged on `worktree-arch-go-native`; it is **not** undertaken here.

The single LLM seam, if a Go-native Layer 2 is ever built, is the OSS one-shot lane (`agent.Complete`), never a vendor SDK (upholds `ADR-2026-06-06 §3.5`) — but that is out of scope for this ADR.

## Consequences

- `donmai arch assess` is a complete **Layer-1** native command: it fetches the real PR diff (via `gh`) and runs the diff-reader + drift gate with no Node, no subprocess, and no external CLI. No learned baseline, no LLM, no datastore ships in OSS.
- The `af-arch` CLI and the `@donmai/architectural-intelligence` package are deprecated/legacy and EOL with `donmai-libraries`; the exec-shim is opt-in behind `DONMAI_ARCH_BIN`.
- **Layer 2 remains platform-owned.** OSS users get the drift gate over real diffs; the SQLite observation graph, learned baseline, and LLM deviation detection are platform features (`ADR-2026-06-07`). OSS-standalone Layer 2 is an explicit future-ADR question, not a commitment.
- The platform-aware binary and the closed platform are unaffected (the binary already dropped the shim; the platform is off the TS package and on its own native arch code).
- No new OSS datastore dependency is introduced (no `modernc.org/sqlite` lands in OSS in this change — that would ride the deferred Layer-2 ADR).
- `007-intelligence-services.md` is amended: the Layer-1 drift gate is OSS-canonical and Go-native (✅ ships); the Layer-2 rows (single-project synthesis, learned baseline, LLM deviation) are marked OSS ❌ — platform-owned (`ADR-2026-06-07`), not "in flight"; the `ArchitecturalIntelligence` contract stays OSS-canonical.

## Boundary

`shared`. The substance is twofold: an OSS execution-layer change (the Layer-1 Go drift gate + `gh` diff-fetch, the `af-arch`/TS-package retirement) which is canonical here, and a re-affirmation that Layer-2 intelligence is platform-owned (deferring any OSS-standalone Go port to a future ADR). The closed side carries a `Mirrored` stub noting the platform is off the TS package, owns Layer 2 natively, and that the OSS Layer-1 gate is the execution-side counterpart. No `BOUNDARY-SYNC`-marked region is touched.
