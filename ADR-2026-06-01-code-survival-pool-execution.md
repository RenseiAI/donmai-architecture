---
status: Accepted
boundary: shared
split: sibling-extensions
---

# ADR-2026-06-01-code-survival-pool-execution

**Status:** Accepted (founder sign-off 2026-06-01)
**Date:** 2026-06-01
**Boundary:** shared (OSS-canonical; platform extensions live at `rensei-architecture/ADR-2026-06-01-code-survival-pool-execution-platform-extensions.md`)
**Authors:** synthesis + architect agent (REN-1247 code-survival runtime re-architecture)

## Locked decisions (founder sign-off 2026-06-01)

- **Default privacy posture:** the executor clones the target repo **ephemerally** into the user's configured capacity pool, scrubbed on `release`. Never a founder/platform-owned host, never a long-lived clone (CodeRabbit/Greptile posture).
- **Scale target ~12mo:** ~1,000s of PRs/day → the queue, worker fan-out, and **atomic claim** are built for real concurrency from the start (batch dispatch + per-pool throughput limits), not retrofitted.
- **Reachability weight:** soft `W_COLD=0.25` multiplier, `unknown`→hot — never a hard reachable/dead gate (Go RTA false-positives).
- **Reachability mechanism:** baked `ts-morph` node subprocess for TS/JS; native `golang.org/x/tools/go/callgraph` for Go.
- **Result seam is versioned:** the payload carries `contractVersion` (`platform/src/lib/factory/code-survival-scan-contract.ts`, `CODE_SURVIVAL_CONTRACT_VERSION`); ingestion rejects unknown majors so a stale worker image cannot write malformed rows.
- **#1 build risk (acknowledged):** the worker poll/claim loop is agent/session-oriented today; the non-agent `code-survival-scan` work-type over it is net-new substrate (owned by RW0/RW1), not free reuse.

## Context

Code-survival (REN-1247) re-scans each agent-authored merged PR at day 1/7/30/90, git-blames how many merged lines still exist, and (WI1) weights surviving lines by static reachability from user-facing entrypoints — feeding a Bayesian routing reward. The feature is **dark in production** (`code_survival_metrics` has 0 rows ever) because the current scanner is a platform-side serverless function that cannot run git: no git binary, no clones, and `go/callgraph` cannot run in a JS serverless function at all (`runs/2026-06-01-code-survival-runtime-research/00-RESEARCH.md §2`).

There is currently **no home for scheduled, non-agent, tooling-driven batch work** in the execution model. Every work type today assumes an `AgentRuntimeProvider` dispatch driven by an issue tracker (`013-orchestrator-and-governor.md` §"The governor"). The governor scan loop is issue-driven; there is no time-driven loop and no `Worker` work-type that does NOT invoke an `AgentRuntimeProvider`.

The forces:
- Blame requires the **full git history reachable to the merge commit** (shallow clones omitting the merge commit fail). Reachability requires the **full repo tree + language toolchains** (`go`, `node`). These can only run where git + toolchains live — a real sandbox, not a serverless function.
- The platform must NOT host users' private source on any single personal/founder machine (SaaS-first mandate, 2026-06-01); execution must run in the **user-configured capacity pool / sandbox**.
- The OSS layer must ship a working implementation; the contract must be reusable by on-prem and SaaS identically.

A directly analogous pattern already exists and ships: the **in-box git-ops runner** (REN-1554) clones a repo and runs git with per-org injected credentials inside the session sandbox, via the `WorkareaProvider` + `VersionControlProvider` contracts (`003`, `008`). Code-survival is the same shape (clone → run git → return a result), but **scheduled and non-agent**.

## Decision

### 1. Code-survival is a non-agent, scheduled batch work-type executed in a capacity pool

Introduce a **batch-job work-type category** in the execution model: tooling-driven, timer/queue-driven, dispatched over the existing worker poll/claim loop, that does **NOT** invoke an `AgentRuntimeProvider`. Its first concrete instance is `code-survival-scan`. The reference executor is a Go work-type handler in the donmai worker (`donmai/worker/`).

The scan handler:
1. `WorkareaProvider.acquire(spec)` with `source.repository = prRepo`, `source.ref = mergeSha`, `toolchain = {go, node}` — receiving a deterministic workarea (`003`; `cleanStateChecksum` verified).
2. The workarea provider calls `VersionControlProvider.clone(uri, dst)` (`008` §"Required verbs"). Clone MUST reach `mergeSha`; if history cannot reach it (force-push/rewrite), the scan returns `status:"skipped", skipReason:"shallow_history"`.
3. Survival: `git diff-tree` to find modified files, `git blame -l --line-porcelain <mergeSha>` and `<HEAD>` per file, accumulate surviving vs total lines.
4. Reachability (WI1): per-language static pass from user-facing entrypoints (`ts-morph` for TS/JS, `golang.org/x/tools/go/callgraph` for Go) → reachable symbol set; classify each surviving line `hot | cold | unknown`.
5. Returns the **result payload** (§3); the executor **never writes a database directly** — it POSTs the payload to the orchestrating control plane or returns it via the worker completion hook.
6. `WorkareaProvider.release(workarea, mode)` honoring disposition (`return-to-pool` enables reuse across checkpoints when the pool supports it).

### 2. The scheduler/executor split is the architectural answer

Batch jobs require a **time-driven loop** separate from the governor's issue-driven loop:
- **Issue-driven loop** (existing governor, `013`): scans issue trackers, dispatches agent sessions.
- **Time-driven loop** (new): selects due batch-work rows by `due_at`, builds a `BatchJobSpec`, enqueues it to the **same work queue** the governor uses. Workers claim `BatchJobSpec` and `SessionSpec` via the **same poll loop** (`013` §"The worker"); the spec's work-type discriminates handling (agent vs batch).

Both loops are stateless across cycles; restart re-scans. The queue claim is atomic, so multiple workers/pools execute concurrently without fighting for work.

### 3. The result payload contract (the seam)

```jsonc
{
  "attributionId": "uuid",   "checkpoint": 30,   "mergeSha": "…", "headSha": "…",
  "status": "ok|partial|skipped|failed",   "skipReason": null,
  "survival":   { "linesTotalAtMerge": 312, "linesSurviving": 210, "survivalRatePct": 67.31 },
  "hotWeighted": { "hotLinesSurviving": 180, "coldLinesSurviving": 30,
                   "wCold": 0.25, "hotWeightedRatePct": 60.10 },   // null when reachability skipped
  "perSymbol":  [ { "file": "…", "symbol": "…", "startLine": 10, "endLine": 40,
                    "linesSurviving": 25, "reachable": "hot|cold|unknown" } ],
  "executor":   { "poolProviderId": "e2b", "workerVersion": "…",
                  "toolchains": { "go": "1.23", "node": "20", "git": "2.45" } }
}
```

`survivalRatePct` is computed by the canonical arithmetic ported verbatim from the existing scanner (`computeSurvivalRate`). The hot-path weight is a **soft multiplier (`W_COLD`, default 0.25), NEVER a hard reachable/dead boolean** — Go RTA produces false positives (`00-RESEARCH.md §5`); `reachable:"unknown"` (unresolvable dynamic imports / RTA false-positive risk) is weighted as hot. Batch jobs MUST be idempotent: re-running a checkpoint MUST produce an identical payload for an unchanged repo.

### 4. Pool capability requirements (`runtime_provides`)

A pool MUST declare it can satisfy the `code-survival-scan` work-type via the existing capability mechanism (`ADR-2026-05-12-capacity-pools-and-substrate-resolution.md §2`, the platform-side resolver). The base contract adds these **requirement kinds** to the substrate vocabulary:
- `git` — git binary present.
- `full-history-clone` — can clone deep enough to reach an arbitrary merge commit (NOT `--depth 1`).
- `toolchain:go`, `toolchain:node` — language toolchains for the reachability pass.

Provider-class capability (informative; operator override always wins):

| Provider class | git | full-history-clone | toolchain:node | toolchain:go |
|---|---|---|---|---|
| `local`, `docker`, `kubernetes` | yes | yes | yes | yes |
| `e2b`, `daytona`, `modal` | yes | yes | if template baked | if template baked |
| `vercel` (Sandbox) | yes | yes | yes | **no** |

A pool lacking `toolchain:go` may still run survival + TS reachability; Go repos return `status:"partial"` (survival only). A pool lacking `git`/`full-history-clone` cannot run the work-type and MUST be filtered out before dispatch.

### 5. Credential path for delayed re-clone (no active session)

Day-30/90 scans run with no live session. The orchestrating layer mints a short-lived, single-repo-scoped git credential at dispatch time and injects it into the workarea exactly as the in-box runner does (REN-1554; `008` clone uses it). The credential is scrubbed on `release`; it is never persisted in the workarea. The OSS contract names the injection point (`VersionControlProvider.clone` receives provider-supplied auth); the credential-minting authority is the credential provider family (`ADR-2026-05-17-credential-provider-family.md`).

### 6. Tenant isolation

The dispatch carries the JWT envelope `{proj, org, sub, claims}` stamped at enqueue (per `ADR-2026-04-29-long-running-runtime-substrate.md §6`). The worker re-verifies the JWT signature against its configured trust anchor and rejects a spec whose `org` claim mismatches its registration with a `permission_denied` audit event — the same path journaled async work already uses. This is the multi-tenant batch-isolation answer (open question in research).

### 7. Layer 6 hook events for batch execution

The batch loop emits hook events on the existing Layer 6 hook bus (`ADR-2026-05-12-cross-process-hook-bus-bridge.md`): `batch.job.dispatched`, `batch.job.started`, `batch.job.progress`, `batch.job.completed`, `batch.job.failed`. Reuses the `ProviderHookEvent` shape (no distinct event type) so existing observability subscribers work unchanged; the work-type field discriminates.

### 8. Home for the code

- Batch-job work-type category + scheduler-executor split: OSS-canonical (this ADR + `013`).
- The `code-survival-scan` Go handler: `donmai/worker/`.
- The pure survival arithmetic (`computeSurvivalRate`) is ported into the handler as the canonical formula.
- The due-checkpoint queue, per-project enablement config, result ingestion, and the Bayesian reward are **platform extensions** (see the platform-extensions sibling ADR).

## Consequences

### Positive

- Unblocks the dark feature with a GA-grade, multi-tenant design from day one — no founder-machine dependency.
- Reuses the in-box git-ops runner (REN-1554), `WorkareaProvider`/`VersionControlProvider`/`SandboxProvider` contracts, the worker poll loop, and the JWT tenancy envelope — minimal new surface.
- Survival and reachability run where toolchains live; `go/callgraph` finally has a home.
- On-prem and SaaS share one worker image, one work-type, one payload — the only difference is the pool and the control-plane owner.
- Reward half is fully decoupled and unchanged; the executor never touches the DB or the routing stores.

### Negative

- Introduces a second governor loop (time-driven) and a non-agent work-type — net-new architectural surface in `013`.
- The reference executor moves from TS to Go; the existing TS scanner is re-authored, not reused (the pure arithmetic survives).
- Pool capability declarations must be kept accurate; an operator who under-declares a pool silently loses Go reachability for that pool.

### Risks

- **Template toolchain drift:** e2b/modal/daytona templates must bake git+go+node; a stale template silently degrades to survival-only. Mitigation: the executor reports `toolchains` in the payload; the platform can alert on missing toolchains.
- **Large-repo blame/reachability cost:** quadratic blame on huge histories, O(repo-size) RAM for reachability. Mitigation: parallelize blame per-file; degrade reachability to `partial` on OOM/timeout (survival still succeeds, retry only on blame failure).
- **Idempotency under double-delivery:** "POST + completion-hook" both firing. Mitigation: idempotency-key dedupe at the seam + idempotent upsert (platform side).

## Alternatives considered

- **Serverless / isomorphic-git (Option B).** No `blame`/`diff` in isomorphic-git; Go callgraph impossible in serverless; OOM risk; no prior art (`00-RESEARCH.md §2`, §5). Rejected — this is the dark path we are leaving.
- **Dedicated platform host (mac-studio, Option A).** Fastest to ship, zero scanner change, but puts users' private source on a single founder-owned machine — eliminated by the 2026-06-01 mandate. Survives only as a `local`/`docker` pool a self-hoster may configure.
- **TUI-local results-only (Option C).** Best privacy, but zero coverage for cloud/web users and no day-90 retention guarantee. Viable as an opt-in pool flavor later (the `local` pool on a user's own daemon), not the default.
- **Adopt the long-running runtime journal (ADR-2026-04-29) for resumable blame-walks.** Deferred — not required for v1; can be layered later for resumable large-repo scans (`batch_job_checkpoints` recording last-completed line-range).

## Affected documents

- `001-layered-execution-model.md` §"The eight plugin families" / Layer 3 — note the non-agent batch work-type (a `Worker` that does not drive an `AgentRuntimeProvider`).
- `013-orchestrator-and-governor.md` §"The governor" — split into issue-driven and time-driven loops; §"The worker" — batch work-type claimed via the same poll loop.
- `004-sandbox-capability-matrix.md` — add the `code-survival-scan` requirement kinds (`git`, `full-history-clone`, `toolchain:go`, `toolchain:node`) and the per-provider-class capability row.
- `003-workarea-provider.md` — note `ToolchainDemand{go,node}` + `ref:mergeSha` usage by batch scans (no contract change).
- `008-version-control-providers.md` — note delayed-re-clone credential injection by batch scans (no contract change).

## Affected work items

- **REN-1247** — code-survival (this re-architecture).
- **REN-1554** — in-box git-ops runner (reused pattern).
- Cross-program: router-learning A1 (shipped) is the per-session signal the reward blends onto; unchanged by this ADR.

## Implementation notes

- Go handler lives in `donmai/worker/`; reuse the REN-1554 clone+creds path.
- Port `computeSurvivalRate` verbatim; re-author `scanPrSurvival`/`countLinesByCommit` in Go.
- Reachability: `go/callgraph` (Go, native) + a baked `ts-morph` node script (TS/JS) invoked via subprocess; `reachable:"unknown"` → weight as hot.
- Emit the Layer 6 batch hook events; carry the JWT envelope; re-verify on consume.
