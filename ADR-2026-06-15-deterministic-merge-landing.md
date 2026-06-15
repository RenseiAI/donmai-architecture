---
status: Accepted
boundary: shared
split: sibling-extensions
date: 2026-06-15
---

# ADR-2026-06-15 — Deterministic merge landing is orchestration-owned

**Status:** Accepted
**Date:** 2026-06-15
**Boundary:** shared
**Authors:** deterministic-landing agent (W3)

## Context

In the SDLC acceptance loop, the final step is landing the change: merging the
pull request and advancing the issue to its terminal "accepted" state. Until now
that merge happened **in-session** — the acceptance agent was instructed to
"follow the repository merge strategy" and run the merge itself.

In-session merge has three structural problems:

1. **Non-determinism.** Each agent interprets the merge strategy from prose. A
   weaker tool-using model may pick the wrong merge method, merge with a red
   build, or fail to merge and still emit a "passed" marker — the landing
   outcome depends on the model, not the orchestration.
2. **No durable confirmation.** An agent that calls the merge API and then dies
   leaves the orchestration unable to tell whether the change actually landed.
   In-process wake-ups die with the runner, so a merge confirmation cannot be
   awaited reliably from inside the session.
3. **Uniformity.** Tenant repositories should land changes the same way
   regardless of which agent ran acceptance.

The execution layer already proved the pattern for the upstream half of this
problem: the durable CI wait (`gate.ci_check`) suspends the workflow on a
GitHub `workflow_run.completed` webhook rather than burning agent tokens polling
CI in-session. The merge landing is the same shape — a long-lived wait on an
external event — and belongs on the same durable suspend/resume substrate.

## Decision

**The merge landing is owned by the orchestration layer, not the agent.** The
acceptance agent's job is reduced to judgement: it decides pass/fail and emits
the durable result marker. It does NOT merge.

On a passing acceptance sign-off the orchestration runs a deterministic landing
chain on the workflow:

1. **CI-green precondition** — verify all checks are green for the head commit
   before merging (a one-shot status poll).
2. **Merge** — the orchestration performs the merge via the platform-owned merge
   action node (`github.pr.merge`), with a fixed merge method.
3. **Durable merge confirmation** — a new signal gate node, **`gate.merge`**,
   suspends the workflow on the pull-request-closed webhook
   (`com.github.pull_request.closed`) correlated on the **pull-request number**,
   and routes by the PR's `merged` flag at resume time:
   - `merged` → advance the issue to its terminal accepted state;
   - `closed` (closed without merging) → operator surface, do NOT advance;
   - `timeout` → operator surface, do NOT advance.

`gate.merge` is a signal gate with no executor (mirrors `gate.ci_check`): the
runtime suspends on it and the inbound webhook resumes it, for zero agent
tokens. Its merge-event literal and PR-number correlation path live in a
dedicated wire-types module so the gate's `signalEventType` and the resume
matcher import the same constants — a drift would hang the gate forever.

A worker-level **`merge-queue` capability** is advertised by the daemon (default
**false**). When false (every deployment today), the deterministic landing above
is the path. When a daemon ships an actual merge-queue adapter and advertises
`merge-queue: true`, the runner may instead defer the terminal promotion to that
adapter. The flag is plumbed end to end now so the future adapter is a
one-boolean change; it defaults false so a daemon ⟷ runner version skew cannot
change dispatch behaviour.

## Consequences

### Positive

- **Deterministic, uniform landing.** The merge method, the CI precondition, and
  the advance-on-merge decision are identical across every tenant repo and every
  agent — the orchestration decides, not the model.
- **Durable confirmation.** The issue advances only when the merge webhook
  actually lands. A PR closed without merging, or a merge that never confirms,
  surfaces to an operator instead of silently marking the issue accepted.
- **Zero idle tokens.** The merge wait runs on the same suspend/resume substrate
  as the CI wait — no agent sits polling for the merge.
- **Smaller acceptance contract.** The acceptance agent does one thing
  (judgement); the merge-strategy prose is removed, so weak tool users can't get
  the landing wrong.

### Negative

- One more workflow node type and one more long-lived suspended instance per
  acceptance loop.
- The PR number must be carried on the session-completion event for the gate to
  correlate; a session with no known PR degrades to the gate's timeout path.

### Risks

- A missing/empty PR-number correlation value would be a forever-hang for a
  dynamically-resolved signal filter. Mitigated by the suspend-time guard that
  treats an empty/unresolved correlation value as unmatchable and degrades to
  the gate's timeout path (the same old-runner safety the CI gate uses).
- Daemon ⟷ runner version skew on the `merge-queue` capability. Mitigated by the
  default-false design: an older peer that does not advertise or understand the
  flag sees the prior behaviour. The two sides should still ship lock-step.

## Alternatives considered

- **Keep merging in-session.** Rejected: non-deterministic, no durable
  confirmation, and couples the landing outcome to the agent's tool-use quality.
- **Merge action only, no confirmation gate (advance optimistically on the merge
  API call).** Rejected: a merge API call returning is not proof the change
  landed (branch protection, merge queues, races can close-without-merge). The
  durable gate is what makes the landing trustworthy.
- **A bespoke merge-queue adapter as the default.** Rejected for now: no adapter
  ships today. The capability flag reserves the path without making it the
  default, so the orchestration-owned gate is the universal baseline.

## Affected documents

- `001-layered-execution-model.md` — the workflow-engine layer gains a second
  durable signal gate (`gate.merge`) alongside `gate.ci_check`; the
  daemon/runner gain a per-session worker-capability channel
  (`merge-queue`, default false).

See the platform-side extensions in the mirrored stub
`rensei-architecture/ADR-2026-06-15-deterministic-merge-landing.md` for the
SDLC-template wiring, the acceptance-stage prompt change, and the
session-completion event field that carries the PR number.
