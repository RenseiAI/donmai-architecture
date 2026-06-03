---
status: Proposed
boundary: shared
split: sibling-extensions
---

# ADR-2026-06-03-batch-work-type-category

**Status:** Proposed
**Date:** 2026-06-03
**Boundary:** shared
**Authors:** mark, claude

## Context

`ADR-2026-06-01-code-survival-pool-execution` introduced the first **non-agent, scheduled batch work-type**: code-survival scans, dispatched over the worker poll/claim loop, that do **not** drive an `AgentRuntimeProvider`. It framed this as a one-off ("There is currently no home for scheduled, non-agent, tooling-driven batch work in the execution model"), and declared — but never applied — amendments to `001-layered-execution-model.md` §Layer 3 and `013-orchestrator-and-governor.md` §The governor.

A **second** such workload now exists: **Knowledge-Graph (KG) extraction** (platform delta in `rensei-architecture/ADR-2026-06-03-kg-extraction-batch-lane-runner-fleet.md`). KG extraction is scheduled (a periodic driver), queue-dispatched per-org, non-interactive, and returns **structured output** (validated graph triples) rather than the free-text summary an agent session produces. It also adds a new requirement code-survival did not have: the batch job must run an LLM **under the org's resolved auth mode** (host-session / local) and emit a **schema-constrained JSON** result.

Two instances justify promoting the pattern from an ad-hoc carve-out to a first-class category, and applying the deferred `001`/`013` amendments now — generalized to cover both.

## Decision

Introduce a **batch work-type category** as a first-class Layer-3 execution concept, and apply the `001`/`013` amendments code-survival deferred.

### 1. A `Worker` may run agent-driven OR batch work

A worker consumes two kinds of work over the **same** poll/claim loop:

- **agent work** — a `SessionSpec` that drives an `AgentRuntimeProvider` (the traditional path).
- **batch work** — a `BatchJobSpec` discriminated by `workType`, executed by a registered **batch handler**, that does **NOT** invoke an `AgentRuntimeProvider`.

A batch worker still composes the other Layer-3 sub-concepts as needed (`SandboxProvider` for compute, `WorkareaProvider` for filesystem state) — it only omits the AgentRuntime dispatch. Code-survival uses Sandbox + Workarea + tooling; KG extraction uses neither a worktree nor tooling, only an LLM call. The category spans both.

### 2. Batch work has two structured-output shapes

A batch work-type declares whether its handler returns:

- **side-effecting / report** (code-survival: writes findings, posts a results payload), or
- **structured-data** (KG extraction: returns a schema-validated JSON document the platform ingests).

Structured-data batch handlers carry an emit contract on the work item (`{ resultEndpoint, resultAuth, <result JSON schema> }`) and POST a validated result to the platform; the platform binds tenancy server-side from the result-auth token, never from the returned body.

### 3. An LLM-bearing batch handler runs under the dispatched auth mode

A batch work-type MAY invoke an LLM **without** being an agent session. When it does, it runs under the auth mode the platform resolved at dispatch (`host-session` / `local`), exactly as agent work does — host-session/local require local pool capacity and inject no platform credential. Under host-session the provider is agentic (a single constrained turn that emits the result via an emit mechanism); under `local` it may be a raw completion. This is the OSS substance that makes "run my subscription model for a non-interactive job" expressible without a coordinator session.

### 4. Batch dispatch rides a time-driven governor loop

The governor is split into an **issue-driven loop** (existing: scan trackers → `SessionSpec`) and a **time-driven loop** (select due batch rows → `BatchJobSpec`), both enqueuing to the **same** work queue. Workers claim either spec via the same atomic poll/claim. Unknown `workType`s are logged and skipped so stale workers degrade gracefully.

## Consequences

### Positive

- Promotes a proven one-off (code-survival) into a reusable category; future scheduled, non-interactive workloads (audits, re-indexing, extraction) declare a `workType` + handler and reuse the poll loop, JWT tenancy envelope, capability gate, and time-driven dispatch — minimal new surface each.
- Makes "non-interactive LLM job under the user's own auth" a first-class capability, not an agent-session hack.
- Applies the `001`/`013` amendments code-survival deferred, so the canonical model finally reflects shipped reality.

### Negative

- One more axis in the execution model (work-type category) that every Layer-3 implementor must understand.
- Two structured-output shapes (report vs structured-data) to keep coherent as more batch types land.

### Risks

- **Handler sprawl** — without discipline, every feature grows a bespoke batch handler. Mitigation: handlers are thin; shared concerns (claim, auth resolution, result-auth, tenancy binding) stay in the loop/platform, not the handler.
- **Structured-output reliability under host-session** — agentic emit can drift from the schema. Mitigation: the platform Zod-validates and rejects per-item; a bad item never corrupts the store (bounded to a dropped result).

## Alternatives considered

- **Keep code-survival a one-off; make KG a second one-off.** Rejected — two bespoke carve-outs with copy-pasted claim/auth/result plumbing is exactly the duplication a category prevents.
- **Model KG extraction as a constrained agent *session*.** Rejected — batch items are not sessions (no `activeSessions`/quota entry, no tracker issue); forcing them through the session FSM mismodels them and couples extraction to agent-session lifecycle.
- **Run extraction in-platform only (status quo).** Rejected at the platform layer (see the platform ADR) because it forecloses host-session/local auth; this OSS ADR exists to make the fleet path expressible.

## Affected documents

- `001-layered-execution-model.md` §"Layer 3 — Execution" — amended: a `Worker` may run agent-driven or batch work; batch work omits `AgentRuntimeProvider`. (Applied in this change.)
- `013-orchestrator-and-governor.md` §"The governor" / §"The worker" — amended: governor split into issue-driven and time-driven loops; workers claim batch work via the same poll loop. (Applied in this change.)
- Supersedes the deferred "Affected documents" amendments declared in `ADR-2026-06-01-code-survival-pool-execution.md` (generalized here to cover both workloads).

Platform sibling (the platform-extension delta — cron driver, per-org queue, ingestion, KG-pinned auth ladder, security): `rensei-architecture/ADR-2026-06-03-kg-extraction-batch-lane-runner-fleet.md`.

## Affected work items

- REN-1166 / REN-1265 (KG memory) — the second batch workload that motivates the generalization.
- Precedent: `ADR-2026-06-01-code-survival-pool-execution` (first batch workload).

## Implementation notes

- OSS substance: the worker poll loop already decodes `batchWork[]` and routes by `workType` to a registered batch handler (`donmai/worker`, `donmai/codesurvival`). The KG handler (`donmai/kgextract/`) mirrors the code-survival handler and adds the LLM-emit + structured-result POST path.
- The platform-side time-driven driver, per-org queue, result ingestion, and KG-pinned auth resolution are the platform delta (see the sibling ADR); they reuse the model-access matrix (`ADR-2026-06-02-model-access-matrix`) and credential-provider family (`ADR-2026-05-17-credential-provider-family`).
</content>
