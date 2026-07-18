---
status: Accepted
date: 2026-07-18
boundary: OSS-only
---

# ADR-2026-07-18 — Bounded terminal workarea leases

**Status:** Accepted
**Date:** 2026-07-18
**Boundary:** OSS-only
**Authors:** architecture agent

## Context

A session can reach a terminal result while the result receiver still needs to
verify evidence in the session's workarea. If ordinary session teardown makes
that workarea available for reuse before the terminal exchange is acknowledged,
verification can observe a different filesystem state from the one that
produced the result. The failure is especially subtle when the replacement has
the same repository and revision metadata: the identity looks equivalent while
the exact bytes under review are no longer owned by the terminating session.

A process-local hold is insufficient. Either side of the terminal exchange can
restart after accepting the result but before acknowledgement or release. The
hold must therefore survive a crash, remain exclusive for the whole verification
window, and still have a finite lifetime so abandoned terminal exchanges do not
consume workarea capacity forever.

## Decision

The terminal status exchange supports a **bounded terminal workarea lease**.
The workarea-owning runtime persists the lease before terminal teardown can make
the workarea reusable, and it releases the workarea only after it observes the
terminal result acknowledgement or after the unacknowledged lease expires and
is reclaimed.

### D1 — Lease identity and durable acquisition

A terminal result that requires workarea-backed verification carries stable
identities for:

- the session;
- the terminal result attempt;
- the exact workarea; and
- the declared settlement budget.

The workarea-owning side of the exchange atomically records the terminal result
attempt and a lease with at least these fields:

```text
lease_id
session_id
terminal_result_id
workarea_id
acquired_at
expires_at
max_expires_at
settlement_budget
state: active | acknowledged | expired | release-pending | released
```

The lease record lives in crash-recoverable host state, not only in worker
memory. A restart reconstructs active leases before it classifies any workarea
as available. Replaying the same `terminal_result_id` is idempotent: it resolves
to the existing terminal outcome and lease rather than creating a second hold.
If durable lease acquisition fails, the exchange fails before teardown and the
workarea remains unavailable for reuse.

### D2 — The exact workarea remains exclusively session-owned

An active lease is an overlay on the workarea's acquired state. It does not
create a second workarea and does not transfer ownership to a verifier. The
originating session remains the exclusive owner from execution through terminal
verification.

All workarea-backed verification addresses the leased `workarea_id` and its
existing path. The runtime must not substitute another workarea merely because
repository or revision metadata appears equivalent. The lease itself grants no
new authority to transform source state; it only preserves identity, ownership,
and availability for the terminal settlement already in progress.

While the lease is active:

- `release` is deferred or rejected;
- the workarea cannot return to an available pool state;
- another session cannot acquire it, including in shared mode; and
- daemon drain, worker exit, and restart recovery retain it as unavailable.

### D3 — Acknowledgement orders release

The terminal result acknowledgement means the receiver has durably accepted the
result and completed, rejected, or durably recorded the declared terminal
verification outcome. A transport-level response that does not carry that
semantic acknowledgement is not sufficient.

The required ordering is:

1. persist the lease;
2. submit or replay the terminal result;
3. perform terminal verification against the leased workarea under the
   originating session's exclusive ownership;
4. durably settle the result;
5. return the terminal result acknowledgement;
6. observe the acknowledgement at the workarea-owning runtime; and
7. transition the lease to `release-pending`, then invoke the provider's normal
   release policy.

The workarea-owning runtime must not release on send success, connection close,
worker exit, or an unacknowledged terminal response. If it restarts before
observing acknowledgement, it replays the same terminal result attempt and
retains the same lease. If it restarts after acknowledgement but before provider
release completes, recovery resumes from `release-pending`.

### D4 — Expiry exceeds the full settlement budget

Every lease is finite. Its initial expiry must be strictly later than the full
worst-case settlement budget:

```text
expires_at - acquired_at
  > maximum verification duration
  + maximum terminal-result retry and backoff duration
  + maximum acknowledgement delivery duration
  + clock and scheduling safety margin
```

The declared `settlement_budget` includes all of those components; it is not
only the verifier timeout. Configuration is invalid if the maximum permitted
lease lifetime cannot exceed the maximum permitted settlement budget plus its
safety margin.

A lease may be renewed only by the same session and terminal result identity,
and never beyond the finite `max_expires_at` fixed at initial acquisition. If
settlement cannot finish inside that absolute bound, the result enters explicit
reconciliation; the runtime does not extend the lease indefinitely. Expiry is
not an implicit successful acknowledgement and does not change the terminal
verdict.

### D5 — Reaping is bounded and fail-closed

The daemon runs a periodic expired-lease reaper with a configured finite
interval and batch size. For workarea capacity `C`, reaper batch size `B`, and
interval `I`, every expired lease must be considered for reclamation within at
most `ceil(C / B) * I` after expiry. Implementations may use a tighter bound.

A reap attempt first marks the lease `release-pending`, then invokes the normal
provider release policy with a configured finite attempt timeout `R`. For a
responsive provider, reclamation completes within `ceil(C / B) * I + R` after
expiry. A provider failure leaves the workarea unavailable, retries with capped
backoff and the same per-attempt timeout, and emits an operator-visible error;
failure must not make the workarea appear reusable. Successful provider release
records `released` before the workarea can re-enter an available state.

## Consequences

### Positive

- Terminal verification observes the exact workarea that produced the result.
- Exclusive session ownership now spans execution, verification, durable result
  settlement, and acknowledgement.
- Restart recovery preserves correctness without relying on a live worker
  process.
- A finite lifetime and bounded reaper prevent abandoned exchanges from leaking
  workarea capacity indefinitely.
- Idempotent replay makes ambiguous connection loss safe: retrying neither
  duplicates settlement nor creates competing holds.

### Negative

- Terminal completion can retain a workarea beyond worker-process exit, reducing
  immediately reusable capacity during slow verification.
- The host must persist a new lease state machine and recover it before pool
  admission.
- Settlement-budget configuration becomes a cross-component invariant; a
  verifier timeout cannot be raised independently past the lease bound.

### Risks

- **Budget underestimation.** A lease could expire during legitimate settlement.
  Mitigation: the expiry formula includes verification, retries, acknowledgement,
  and safety margin, and configuration rejects an impossible ordering.
- **Acknowledgement ambiguity.** A generic successful response could be mistaken
  for durable settlement. Mitigation: only the explicit terminal result
  acknowledgement advances the lease to `release-pending`.
- **Recovery ordering error.** A restarted daemon could admit a workarea before
  loading its lease. Mitigation: lease recovery precedes workarea availability
  classification and fails closed when host state is unreadable.
- **Provider release failure.** An expired lease could remain unavailable longer
  than intended. Mitigation: bounded retry, operator-visible failure, and no
  reuse until release is durably confirmed.

## Alternatives considered

- **Release when the worker process exits.** Rejected: process lifetime ends
  before terminal settlement and does not prove acknowledgement.
- **Retain an equivalent replacement workarea for verification.** Rejected:
  matching metadata does not prove identity with the bytes that produced the
  terminal result.
- **Use an unbounded hold until an operator intervenes.** Rejected: abandoned
  exchanges would permanently consume finite capacity.
- **Keep the hold only in process memory.** Rejected: a restart reintroduces the
  early-reuse race this decision exists to prevent.
- **Treat expiry as acknowledgement.** Rejected: reclamation is a capacity action,
  not evidence that verification or durable settlement succeeded.

## Affected documents

- `003-workarea-provider.md` — adds the lease overlay, exclusive-ownership rule,
  release ordering, expiry formula, and bounded reaper contract.
- `011-local-daemon-fleet.md` — drain and restart recovery retain actively leased
  workareas until acknowledgement or expiry.
- `013-orchestrator-and-governor.md` — terminal completion now includes lease,
  verification, acknowledgement, and release ordering.
- `ADR-2026-06-22-daemon-per-session-cancel-wire.md` — its post-mortem release
  statements are constrained by the newer rule that an active terminal lease
  retains the exact workarea until acknowledgement or expiry; the historical
  ADR remains unchanged.
- `README.md` and `AGENTS.md` — add this ADR to the corpus indexes.

No synchronized boundary region is changed. This is OSS execution-layer
lifecycle behavior and requires no sibling-corpus edit.

## Affected work items

No tracker identifier is embedded in this OSS ADR. Implementations should link
their own work item to this decision.

## Implementation notes

- Persist leases beside the host's session and workarea lifecycle state so boot
  recovery can load them before pool admission.
- Key terminal-result replay by `terminal_result_id`; use `workarea_id` as an
  invariant checked against the stored lease, not as the idempotency key.
- Expose lease state, remaining lifetime, and last release error through existing
  workarea observability surfaces.
- Tests should cover restart before acknowledgement, restart after
  acknowledgement, duplicate terminal submission, expiry during a lost
  connection, reaper batching, and provider release failure.
