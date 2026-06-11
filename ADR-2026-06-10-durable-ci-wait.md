---
status: Accepted
boundary: shared
date: 2026-06-10
---

# ADR-2026-06-10 — Durable CI wait: the develop→verify hop suspends at the orchestration layer, not in the agent session

**Status:** Accepted · **Boundary:** shared (canonical here; mirrored stub + platform delta in `rensei-architecture`)
**Date:** 2026-06-10
**Authors:** delivery-sweep design lane (agent)

## Context

The SDLC chain dispatches each stage as a **one-shot agent session** on the
runner (`donmai` `runner` package). The runner streams provider events to a
terminal `ResultEvent`, scans the agent's final message for the durable
`WORK_RESULT` marker, posts the terminal status, and tears the provider
down (`runner/loop.go`: the deferred `handle.Stop` fires as soon as
`consumeEvents` returns on the terminal event). The platform side then emits
a session-exit CloudEvent that an exit workflow routes (`passed` /
`failed` / `blocked` / `unknown_result`) to advance the issue and dispatch
the next stage.

The development stage's termination contract today requires **"PR open AND
CI green"** before the agent may emit `WORK_RESULT:passed` — and the marker
must appear in the agent's *final* message. Remote CI takes minutes to tens
of minutes. The only waiting mechanism available *inside* the session is
in-process harness state: schedule-wakeup timers, background polls, `gh run
watch` loops. All of it dies with the session process. The observed live
failure (twice during a 2026-06 chain rebuild) is exactly that:

1. The dev agent finishes the work, pushes, opens the PR.
2. It parks on an in-process CI monitor (a harness schedule-wakeup),
   intending to emit its marker after CI completes.
3. Its turn ends; the runner sees the terminal event, stops the provider;
   the scheduled wakeup dies with the process.
4. No durable marker → the exit workflow routes `unknown_result` → the
   chain stalls and needs a **manual nudge for every development hop**.

This is the top loop-autonomy defect in the chain. A second cost rides with
it: when the agent *does* manage to wait in-session (bash sleep loops), it
burns idle tokens — the 2026-06-04 deterministic-CI investigation found
in-session CI waiting to be the single most expensive polling behavior in
the stack.

What already exists (and what is missing):

- **Suspend/resume substrate (working, production-proven).** The platform's
  workflow executor has a Redis-backed gate registry (signal / timer /
  webhook gates, per-gate `expiresAt` in a timer sorted set), webhook-ingest
  resume (any inbound CloudEvent is matched against waiting gates), and an
  every-minute gate-timer cron driving timeouts through the resume pipeline.
  See `016-workflow-engine.md` § `gate`.
- **A CI gate node (shipped 2026-06-04, never correlated).** `gate.ci_check`
  suspends on `com.github.workflow_run.completed` filtered on
  `workflow_run.head_sha`, resumes on BOTH conclusions, and routes named
  `passed` / `failed` / `timeout` handles. It is wired into one reference
  template — but its correlation input (the develop step's head commit SHA)
  is **produced nowhere**. The binding resolves to nothing, so the gate can
  never match.
- **A typed-but-dead wire field.** The OSS result envelope
  (`agent/types.go`) already declares `CommitSHA` ("head commit sha of the
  work branch when known") — no code populates it, and the runner's terminal
  status post does not carry it.

So the missing piece is not machinery — it is **one correlation wire** (the
head SHA from the runner to the exit event) plus a **contract decision**
about who owns the CI wait.

## Decision

**The CI wait is orchestration-owned and durable. Agent sessions never wait
for remote CI, and never park on in-process timers expecting to outlive
their final message.** Concretely:

1. **The development termination contract is redefined.**
   `WORK_RESULT:passed` now means: implementation complete, **local**
   verification green (tests / typecheck / lint), branch pushed, and PR
   open where the agent owns PR-open. The agent emits its marker and ends
   the session immediately. "All checks pass" no longer includes remote CI.
   A general rule joins the completion contract
   (`013-orchestrator-and-governor.md` § Completion contracts): *session
   end is the end of agent compute; in-process wake-up state does not
   survive the terminal event and must not be relied on.*

2. **The develop→verify hop suspends durably at the orchestration layer.**
   The development exit path inserts a `gate.ci_check` signal gate
   correlated on the session's head commit SHA. The webhook ingest path
   resumes it on `workflow_run.completed` (routing `passed` / `failed` by
   conclusion); the gate-timer cron resumes it on timeout. Zero agent
   tokens are spent waiting; the wait survives process and host restarts.

3. **The runner supplies the correlation key.** At envelope-build time —
   *after* tail recovery and the backstop, both of which may add commits —
   the runner captures `git rev-parse HEAD` in the session worktree and
   stamps the already-typed `Result.CommitSHA`. The terminal status post
   carries `commitSha` (and `pullRequestUrl`, today absent from the status
   wire) so the platform can stamp `headSha` onto the session-exit
   CloudEvent that the gate's filter binds against.

4. **No new timer table.** Gate registrations live in the existing Redis
   gate registry (`wf:gate:*` + the `wf:gate:timers` sorted set); instance
   persistence stays in the existing workflow-instance store; the existing
   every-minute gate-timer cron drives timeouts. Shipped templates set a
   default CI-gate timeout (45 min) with `onTimeout: 'skip'` so the
   `timeout` handle routes to a **reconciliation step** (one-shot checks
   poll → pass / fail / still-running) — the chain degrades to bounded
   latency, never to a wedge, and never advances silently.

### Target state machine (development hop)

```
develop dispatch
 └─ agent session: code → local verify → commit → push (+ PR where agent-owned)
      └─ final message: WORK_RESULT:passed|failed|blocked      (NO CI wait)
 └─ runner: terminal event → steering/backstop → CommitSHA capture → status post
 └─ platform: session-exit CloudEvent { result, headSha, branch, pullRequestUrl, … }
 └─ exit workflow:
      result switch
       ├─ passed + stage==development
       │    └─ [ensure PR open]                  (template-owned variant)
       │    └─ gate.ci_check  shaRef=headSha · timeout 45m · onTimeout:skip
       │         ├─ passed  → approval-gate mode → advance forward → next stage
       │         ├─ failed  → CI-fix loop: comment with run URL + re-dispatch
       │         │            development with failure context (bounded), or
       │         │            reject to the failure terminal after N attempts
       │         └─ timeout → reconcile (one-shot checks poll):
       │              success → advance · failure → fix loop ·
       │              still-running / no-runs → operator escalation comment
       ├─ passed + other stage → existing advance path        (unchanged)
       └─ failed / blocked / unknown_result → existing paths  (unchanged)
```

## Contract changes

OSS (`donmai`):

- **`Result.CommitSHA` is populated** (runner, envelope-build time, post-
  backstop `git rev-parse HEAD` in the worktree). The field already exists
  on the wire type; this is behavior, not schema.
- **The terminal status post gains `commitSha` and `pullRequestUrl`**
  (`result/poster.go` status body). Additive fields; old platforms ignore
  them.
- **Prompt-template contract** (`prompt/templates/user_development.tmpl`,
  `system_base.tmpl`): the `passed` definition drops "all checks pass"
  CI language in favor of "local verification green + branch pushed + PR
  open"; a new hard rule states *do NOT wait for remote CI, and never
  schedule in-process wake-ups expecting them to outlive your final
  message — the orchestration layer owns the CI wait.*
- **Lock-step release.** The additive wire fields touch the embed surface,
  so the OSS binary and the closed platform-aware superset binary bump and
  ship together, per the standing embed-surface rule.

Platform (specifics live in the `rensei-architecture` mirrored stub):

- Terminal-status route persists `commitSha`; the session-exit CloudEvent
  carries `data.headSha` (+ `data.pullRequestUrl`).
- The default SDLC template's development exit path gains the CI gate, the
  bounded fix loop, and the timeout-reconciliation branch; stage prompts
  are re-worded to match the OSS templates.
- **Suspend-time guard:** registering a signal gate whose resolved filter
  is empty (e.g. `headSha` absent because an old runner produced the exit
  event) must not create an unmatchable waiting gate — the known
  hang class for dynamically-resolved filters. The gate degrades to its
  timeout path instead.

## Failure modes

| Failure | Behavior under this design |
|---|---|
| Webhook ingest down (the precipitating incident class) | Gate waits → 45 min timeout → reconciliation poll → chain advances/fails correctly; latency degrades, the chain never wedges. |
| `headSha` missing (mixed-version fleet: old runner, new template) | Suspend-time guard routes the timeout/reconciliation path (poll via PR URL); never an unmatchable filter. |
| Multiple CI workflows on one repo | v1: first `workflow_run.completed` for the SHA resumes the gate — a fast lint workflow can mask a slower failing test workflow. Documented limitation; mitigations: optional `workflow_run.name` filter (follow-up) and the reconciliation poll double-checking aggregate status on the `failed`/`timeout` branches. |
| CI re-run after a failure | Gate already resumed `failed`; the fix loop owns retries. |
| Repo with no CI configured | Timeout → reconciliation finds no runs → escalation comment (a template option may allow-advance for CI-less repos). |
| Redis loss | Waiting gates AND their timer entries vanish → suspended instances orphan. Mitigation (named follow-up): an orphan sweep that escalates suspended instances older than T with zero waiting gates. |
| Force-push / amend after capture | Out of contract: nothing pushes after envelope-build (backstop precedes capture; the session is torn down). |

## Consequences

### Positive

- Development hops chain hands-free — the manual nudge per dev hop
  disappears; this was the top loop-autonomy defect.
- Zero agent tokens spent waiting on CI; the wait is durable across
  process and host restarts.
- **CI failure becomes a routable branch.** Today a red CI run is invisible
  to the chain (the agent either lies, stalls, or fails opaquely); under
  this design it routes an explicit fix loop with the run URL attached.
- The same pattern generalizes: the qa/acceptance "PR open + CI green"
  *preconditions* can bind the gate output instead of re-polling, and a
  future merge-queue gate (suspend until merged) reuses the identical
  suspend/resume shape.

### Negative

- Chain latency now has an explicit floor of the CI duration (previously
  the same wait was hidden inside agent sessions — or skipped).
- The development exit path grows real branching complexity (gate + fix
  loop + reconciliation) that templates must carry and tests must cover.
- SHA correlation assumes the pushed head is what CI runs against;
  rebase/squash flows that rewrite the SHA between push and CI are out of
  contract (acceptable: the runner pushes and never rewrites afterward).

### Risks

- Webhook delivery reliability becomes load-bearing for chain *latency*
  (not correctness) — bounded by the timeout-reconciliation backstop.
- First-completed-wins (v1) can declare `passed` while a slower workflow
  later fails; bounded by the follow-up name filter and by qa-stage
  verification downstream.

## Alternatives considered

**(b) Runner holds the session through CI.** The runner (not the agent)
polls CI after the terminal event and only then posts the terminal status.
Rejected: it ties up a fleet slot, a worktree, and the heartbeat ownership
lock for the entire CI duration; it interacts badly with per-stage
wall-clock budgets (a 30-min CI wait inside a 30-min stage budget); and it
is still process-resident state — a runner crash or host restart loses the
wait, merely moving the non-durable park from the harness into the runner.
It also leaves CI-failure routing as an afterthought (what does the runner
post when CI is red — `failed` without a fix loop?).

**(c) Terminal-marker nudge before park.** Teach the agent to emit
`WORK_RESULT:passed` first and *then* keep monitoring CI in-session.
Rejected: the marker contract requires the marker in the final message, so
"marker then park" inverts terminal detection (the runner would tear down
on the marker turn anyway — the park still dies); it splits the source of
truth for "did the stage pass" between the agent's claim and CI reality;
and it does nothing for the CI-failure path. The salvageable spirit of (c)
— emit the durable marker at push-time, reconcile CI reality elsewhere —
is exactly what (a) ships, with the "elsewhere" made durable.

**(d) Derive the SHA platform-side from the PR API** instead of the runner
capture. Rejected as the primary path: an extra API hop at exit time, and
it leaves push-without-PR template variants uncovered. The runner capture
is one git command into an already-typed field. The PR-API lookup survives
as the reconciliation fallback for `headSha`-less exit events.

## Affected documents

- `013-orchestrator-and-governor.md` § "Completion contracts and backstop"
  — amended in this commit: development's required outputs end at
  push/PR-open; CI verification is orchestration-owned; agents never park
  on in-process timers.
- `016-workflow-engine.md` — no change required: the generic gate contract
  (signal gates, named branches, timeout actions) already covers this; the
  CI gate is template-level usage of it.
- `rensei-architecture` (paired commit, OSS-side first): mirrored stub for
  this ADR carrying the platform delta — exit-event field stamping, default
  SDLC template wiring, prompt re-words, migration order.

No `BOUNDARY-SYNC`-marked region is touched.

## Implementation notes (migration order — each step shippable alone)

1. **OSS runner:** populate `Result.CommitSHA` + add `commitSha` /
   `pullRequestUrl` to the status post. Additive; nothing reads them yet.
2. **Platform persistence:** accept + persist the new status fields; stamp
   `data.headSha` on the session-exit CloudEvent. Additive.
3. **The behavior flip, shipped as one unit:** the template change
   inserting the gate AND the prompt-contract change (OSS templates +
   platform stage prompts). The prompt change without the gate would
   advance dev hops with red CI; the gate without the prompt change
   double-waits (harmless but slow). Mixed-version safety: the gate's
   suspend-time guard degrades `headSha`-less events to the
   timeout-reconciliation path, so an old runner stalls a hop by at most
   the timeout window, never forever.
4. **Sweep the remaining prompt surfaces** (work-type cards, any kit
   skills) for in-session CI-wait instructions and remove them.

Follow-ups registered by this ADR (not blocking acceptance): optional
`workflow_run.name` filter on the CI gate; orphaned-suspended-instance
sweep; merge-queue gate reusing the same suspend shape.
