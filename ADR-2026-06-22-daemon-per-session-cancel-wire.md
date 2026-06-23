---
status: Accepted
date: 2026-06-22
boundary: OSS-only
---

# ADR-2026-06-22 — Daemon per-session cancel-wire and progress watchdogs

**Status:** Accepted
**Date:** 2026-06-22
**Boundary:** OSS-only
**Authors:** agent:claude (groomer design session)

## Context

The local daemon's HTTP control API (`ADR-2026-05-07-daemon-http-control-api.md`,
`011-local-daemon-fleet.md` § "HTTP Control API") had a **daemon-wide**
`POST /api/daemon/stop` that drains and stops the whole daemon process, but **no
way to stop one in-flight session** while leaving the rest of the fleet running.
The only per-session termination paths were the blunt instruments: drain the
entire daemon, or kill the worker child out-of-band.

This created three concrete failures during grooming and other long-running
batch work:

1. **No operator cancel.** An operator (or the orchestrator) who wanted to abort
   one runaway session — wrong target, looping, superseded by a newer dispatch —
   had to take down the whole daemon. There was no `donmai`-native single-session
   stop.
2. **Cancel got laundered into a crash, then re-dispatched.** When a session was
   killed out-of-band, the daemon's exit-classification path (the same one
   covered by the memory note "Runner funnels blocked agent as a crash") treated
   the non-zero exit / missing-result as a *crash*, which the orchestrator's
   backstop then **re-dispatched**. An intentional cancel came back to life — the
   worst possible behavior for "stop this."
3. **No idle/no-progress detection.** A session that hung — agent runtime wedged,
   waiting on an input that will never come, spinning without emitting tokens or
   advancing turns — occupied a pool member indefinitely. Drain's
   `drainTimeoutSeconds` only fires on a full daemon restart, not on a single
   stuck session.

These fixes ship in donmai v0.49.2. This ADR records the per-session cancel-wire
contract and the progress watchdogs as OSS-canonical.

## Decision

The daemon gains a **per-session cancel-wire** — an in-process `StopSession`
primitive, a localhost-only HTTP edge that drives it, a fast in-band stop signal
threaded through the existing lock-refresh channel, and a distinct **operator-
cancelled failure mode that is NOT re-dispatched**. It additionally gains an
**idle/no-progress watchdog** that self-cancels a wedged session, and an explicit
**multi-root exclusion** for the deferred-exit-trigger path so a deferred exit
cannot be misread across sibling roots.

### D1 — `WorkerSpawner.StopSession(sessionID, mode)`

The in-process primitive. The component that owns worker children
(`WorkerSpawner`) gains `StopSession`:

- Looks up the live worker child for `sessionID`. Unknown/already-exited id → a
  not-found result (not an error to the caller; the session is already gone).
- Signals the child to stop cooperatively first (in-band stop, D3), then escalates
  to SIGTERM, then SIGKILL on a bounded grace timer if the child does not exit.
- Records the session's terminal classification as `mode` (D4) **before** the
  child's exit is observed by the generic exit-classification path — so the cancel
  intent wins over the exit-code heuristic and the session is not laundered into a
  crash.
- Releases the session's workarea with `mode: archive` (consistent with drain
  semantics in `011` § "Drain semantics"), so a cancelled session's state is
  inspectable post-mortem.

`StopSession` is the single in-process choke point: the HTTP edge (D2), the
watchdog (D5), and any future internal canceller all go through it, so the
terminal-classification-before-exit ordering is enforced in exactly one place.

### D2 — `POST /api/daemon/sessions/:id/stop` (localhost-only)

The HTTP edge that drives `StopSession`. It extends the existing per-session
namespace (`GET /api/daemon/sessions`, `GET /api/daemon/sessions/<id>`):

```
POST /api/daemon/sessions/<id>/stop
     body : { reason?: string }
     → 200 { sessionId, stopped: true,  mode: "operator-cancelled" }   # was running, now stopping
     → 200 { sessionId, stopped: false, reason: "not-found" }          # unknown / already exited
```

Auth model is identical to the rest of the daemon API
(`ADR-2026-05-07` § D2): **localhost-only, no bearer.** The daemon binds
`127.0.0.1`; the `Authorization` header is ignored and MUST NOT be sent. A
per-session stop is a local operator/orchestrator action against a localhost
service; it inherits the daemon's localhost trust boundary and adds no new auth
axis. The optional `reason` is recorded with the terminal classification for
operator-visible attribution.

### D3 — Fast in-band stop via the lock-refresh `stop` field

A session's worker child periodically refreshes its work-lock with the daemon
(the lock-refresh heartbeat that keeps a claimed work item owned). That refresh
response gains a **`stop` field**:

```jsonc
// lock-refresh response (daemon → worker child)
{
  "leaseOk": true,
  "stop": true            // NEW: daemon is asking this session to stop now
}
```

When `StopSession` is invoked, the daemon flips the session's pending-stop flag;
the **next lock-refresh response carries `stop: true`**, and the worker child
stops cooperatively in-band — flushing any partial result, releasing cleanly —
rather than waiting for an out-of-band signal it might not handle gracefully.
This is the fast path: it rides the heartbeat the session is already making, so
in-flight cancel latency is bounded by the lock-refresh interval rather than by a
SIGTERM grace timer. SIGTERM/SIGKILL (D1) remain the escalation for a child that
ignores the in-band `stop` or is wedged below the heartbeat loop.

### D4 — `FailureOperatorCancelled` — a terminal mode that is NOT re-dispatched

A new failure mode joins the daemon's terminal-classification enum:

```
FailureOperatorCancelled
```

It is **terminal and intentional**: the orchestrator's backstop MUST NOT
re-dispatch a session that exited `FailureOperatorCancelled`. This is the fix for
the laundered-cancel bug — the cancel-wire sets `FailureOperatorCancelled` via
`StopSession` *before* the child's exit is observed, so the generic
exit-classification path (which would otherwise see a non-zero exit / missing
result and call it a crash, then re-dispatch) never reclassifies it. The
distinction is load-bearing:

- `FailureCrash` (and kin) → re-dispatchable (the work didn't get a fair run).
- `FailureOperatorCancelled` → **not** re-dispatchable (a human/orchestrator said
  stop; honoring that is the whole point).

### D5 — Idle/no-progress watchdog → `FailureNoProgress`

The daemon runs a per-session **progress watchdog**. "Progress" is defined as the
session advancing its observable state — emitting tokens, advancing a turn, or
otherwise updating its session-handle (`ADR-2026-06-13-daemon-sessionhandle-
enrichment.md`). If a session emits no progress for a configured idle window, the
watchdog self-cancels it via `StopSession` with a distinct terminal mode:

```
FailureNoProgress
```

The idle window is configurable via `daemon.yaml` (e.g.,
`session.noProgressTimeoutSeconds`); it defaults conservatively so a legitimately
long-thinking turn is not killed. Like `FailureOperatorCancelled`,
`FailureNoProgress` routes through the single `StopSession` choke point, so the
wedged session is stopped cleanly (in-band stop → escalate) and its workarea
archived.

`FailureNoProgress` is its own mode (not folded into `FailureCrash` or
`FailureOperatorCancelled`) because its re-dispatch posture is a separate policy
question: a no-progress hang *might* succeed on a fresh run (unlike an operator
cancel, which must stay dead), but it must not be silently treated as a normal
crash either. Keeping it a distinct mode lets the orchestrator's backstop apply a
bounded-retry policy specific to hangs rather than the generic crash policy.

### D6 — Deferred-exit-trigger multi-root exclusion

Some workflows defer a session's exit behind a trigger (the deferred-exit-trigger
path: the session has finished its work but its *exit* is gated on a downstream
signal). When a workflow has **multiple roots** (sibling entry points that run
under one logical unit of work), a deferred exit on one root must NOT be
interpreted as a stop/exit applying to its siblings.

The contract: **the deferred-exit-trigger is excluded from the multi-root case.**
A deferred exit is scoped to the single root that armed it; it never cascades to
sibling roots, and the cancel-wire's progress watchdog (D5) does not count a
sibling root's still-running work as the deferred root's "no progress." Without
this exclusion, a multi-root workflow where one root legitimately parks on a
deferred-exit trigger would risk (a) the watchdog killing a sibling that is
actually working, or (b) a deferred exit being misread as a unit-wide stop.
Excluding the deferred-exit-trigger from the multi-root path keeps each root's
exit/stop accounting independent.

## Consequences

### Positive

- One session can be stopped without taking down the daemon — the missing
  operator/orchestrator primitive for "abort this run."
- An intentional cancel stays dead: `FailureOperatorCancelled` is never
  re-dispatched, fixing the laundered-cancel-then-resurrect bug at its root (the
  classification is set before the exit-code heuristic runs).
- The in-band `stop` field gives a fast, cooperative cancel that rides the
  existing lock-refresh heartbeat — bounded latency, clean partial-result flush —
  with SIGTERM/SIGKILL only as escalation.
- The no-progress watchdog reclaims pool members from wedged sessions
  automatically, instead of leaving them stuck until a full daemon drain.
- All cancel paths (HTTP, watchdog) funnel through `StopSession`, so the
  classification-before-exit ordering and clean-archive release are enforced in
  one place.

### Negative

- A new terminal-mode enum (`FailureOperatorCancelled`, `FailureNoProgress`)
  widens the classification surface the orchestrator backstop must reason about;
  every consumer of the failure mode must learn the no-re-dispatch rule for
  cancel and the bounded-retry rule for no-progress.
- The in-band `stop` field adds a field to the lock-refresh contract that the
  worker child must honor; a child that ignores it falls back to the slower
  SIGTERM path, so old/non-compliant workers get a degraded (but still correct)
  cancel.
- The no-progress watchdog's idle window is a tuning knob: too tight kills
  long-thinking turns (false `FailureNoProgress`); too loose leaves hangs
  occupying pool members longer. The conservative default trades reclaim latency
  for safety.

### Risks

- **Classification race.** If `StopSession` does not set the terminal mode
  *before* the child's exit is observed, the exit-classification path can win and
  relabel a cancel as a crash (re-introducing the laundering bug). Mitigation:
  the single-choke-point design (D1) makes the ordering enforceable and testable
  in one spot; tests pin "cancel sets mode before exit is read."
- **In-band stop missed.** A child wedged below its heartbeat loop never sees
  `stop: true`. Mitigation: SIGTERM→SIGKILL escalation on a bounded grace timer
  guarantees the child dies even if the in-band path is dead; the workarea is
  archived regardless.
- **No-progress false positive.** A long, legitimate single turn (large
  reasoning, slow tool) could trip the watchdog. Mitigation: conservative default
  window + per-session config; `FailureNoProgress` being its own mode lets the
  backstop retry rather than abandon.
- **Multi-root accounting drift.** If the deferred-exit-trigger exclusion (D6) is
  not honored, a deferred park on one root can either kill a working sibling or be
  misread as a unit-wide stop. Mitigation: D6 makes the per-root independence
  explicit; tests cover a multi-root workflow with one root on a deferred-exit
  trigger and a sibling still running.

## Alternatives considered

- **Reuse the daemon-wide `POST /api/daemon/stop` and just drain faster.**
  Rejected: drain stops the whole fleet. There was no way to express "stop session
  X, leave the rest running"; a per-session edge is the missing primitive.
- **Kill the worker child out-of-band (SIGTERM from outside) and let the existing
  classifier sort it out.** Rejected: this is exactly the laundered-cancel bug —
  the classifier reads a killed child as a crash and re-dispatches. The cancel
  intent must be recorded *before* the exit is classified, which requires an
  in-process primitive (`StopSession`), not an external kill.
- **Fold operator-cancel into the existing crash failure mode with a "do not
  retry" side flag.** Rejected: a side flag on a crash mode is easy to drop on a
  serialization boundary, and the whole bug class is a cancel being treated as a
  crash. A distinct `FailureOperatorCancelled` mode makes the no-re-dispatch rule
  structural, not a flag a consumer can forget.
- **Out-of-band stop signal (e.g., a sentinel file or a separate control socket)
  instead of the lock-refresh `stop` field.** Rejected: the session already makes
  a lock-refresh heartbeat; piggybacking the stop signal on it needs no new
  channel and bounds cancel latency to the existing heartbeat interval. A separate
  channel is more surface for no benefit.
- **A single generic `FailureCancelled` covering both operator-cancel and
  no-progress.** Rejected: the two have opposite re-dispatch postures (operator
  cancel must stay dead; no-progress may be retried under a bounded policy).
  Collapsing them forces one wrong default on one of the cases.

## Affected documents

- `011-local-daemon-fleet.md` — § "HTTP Control API" endpoint inventory gains
  `POST /api/daemon/sessions/<id>/stop` (localhost-only); a new note under the
  drain/recovery sections describes the per-session cancel-wire, the
  `FailureOperatorCancelled` / `FailureNoProgress` terminal modes and their
  re-dispatch postures, and the no-progress watchdog.
- `ADR-2026-05-07-daemon-http-control-api.md` — the per-session stop edge extends
  this ADR's `/api/daemon/*` namespace and inherits its localhost-only / no-bearer
  auth model (D2 here references D2 there). No content edit to that ADR is needed;
  the cross-reference is captured here and in `011`.
- `README.md` § ADRs and `AGENTS.md` § Read order (ADRs) — add the index line for
  this ADR.

No edit touches a `BOUNDARY-SYNC`-marked region. The cancel-wire is OSS-execution-
layer plumbing on a localhost daemon; there is no platform-extension delta beyond
the orchestrator backstop's existing consumption of failure modes (the backstop's
re-dispatch policy is platform-side, but the *modes* and the no-re-dispatch rule
for cancel are OSS-canonical here).

## Affected work items

Shipped in donmai v0.49.2. The orchestrator backstop's handling of the new
terminal modes is tracked platform-side; this OSS ADR carries no internal tracker
id.

## Implementation notes

- `StopSession` lives on the worker-spawner component; the HTTP handler at
  `daemon/handle_sessions.go` (or sibling) wires `POST /api/daemon/sessions/<id>/
  stop` to it. The handler is localhost-only and attaches no auth, consistent with
  the rest of the daemon API.
- The `stop` field is added to the lock-refresh response struct shared by daemon
  and worker; the worker's refresh loop checks it each cycle and initiates a
  cooperative in-band stop when set.
- The terminal-mode enum gains `FailureOperatorCancelled` and `FailureNoProgress`;
  the exit-classification path is taught to defer to an already-set intentional
  mode rather than overwrite it with a crash classification.
- The no-progress watchdog is a per-session timer reset on any observable progress
  event (token/turn/session-handle update per `ADR-2026-06-13`); on expiry it
  calls `StopSession(id, FailureNoProgress)`.
- The deferred-exit-trigger multi-root exclusion is enforced where the
  deferred-exit path decides scope: a deferred exit is keyed to its arming root
  only and never enumerated across sibling roots; tests pin the multi-root case.
