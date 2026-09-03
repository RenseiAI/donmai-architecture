---
status: Accepted
date: 2026-09-03
boundary: shared
split: synchronized-mirror
---

# ADR-2026-09-03 — An exhausted readoption window withdraws the lineage unconditionally

**Status:** Accepted
**Date:** 2026-09-03
**Boundary:** shared (the withdraw-unconditionally decision and the
`OnReadoptionWindowExhausted` hook are OSS-canonical here; any composing
control plane's downstream handling of the withdrawal — reaper predicates,
reconciliation, and embedder wiring — is a platform extension)
**Authors:** session-continuity design lane

## Context

`ADR-2026-08-17-session-shim-adoption.md`'s core contract rule 8 covers a live
shim whose controller stream ended for a carrier fault. Its *Amended
2026-09-03* section ("re-adoption window bounded by observed liveness") added
a **lineage-live mode**: while the daemon still observes the shim process
alive and still holds the lineage, re-adoption retries with exponential
backoff for a configurable window that MAY exceed the resolved orphan
deadline, with the daemon extending the shim's orphan-clock keepalive for the
duration so the shim does not reap itself while still being retried.

That amendment left window **exhaustion** underspecified: it said exhaustion
with a live shim "yields the configured post-window outcome," naming
quarantine as the default but leaving room for a composing deployment to
configure a different outcome — including a **retain** outcome, in which the
daemon kept the lineage in its adopted set past exhaustion rather than acting
on it.

A retained lineage past window exhaustion is invisible to the reconciliation
machinery this corpus already defines. The daemon's quarantine-only
reconciler walks the currently-quarantined set; a retained lineage is neither
quarantined nor cleanly adopted-and-live (the very re-adoption attempts that
would prove liveness have exhausted their window), so it sits in neither the
set the reconciler inspects nor a set with any other durable path to
resolution. If the shim process eventually died on its own — the ordinary
case a bounded orphan deadline exists to bound — its terminal tombstone would
land in the registry for a lineage no live path was still watching and no
reconciler was still walking. The lineage would be stranded: not adopted, not
withdrawn, and with no mechanism scheduled to ever look at it again.

## Decision

Window exhaustion with a live shim in lineage-live mode fires the
`OnReadoptionWindowExhausted` hook and then withdraws the lineage
**unconditionally**. No configured post-window outcome exists — retain
included. Withdrawal stops the daemon's orphan-clock keepalive extension for
that lineage, so the shim's own bounded orphan deadline (rule 8's opening
clause) runs its course on schedule from there: the shim terminates and reaps
its own harness process group, persists the terminal observation, and retains
a tombstone for later adoption — all within one orphan deadline of the window
exhausting.

This closes the general invariant the core contract already implies for every
other bounded recovery episode it defines: **no non-success disposition of a
readoption window (or of any bounded recovery episode this corpus defines)
may leave a lineage in a state that is neither adopted nor withdrawn.**
Quarantine (rule 7) and expiry-with-proof (rule 10) already satisfy this
invariant by construction; the prior "configured post-window outcome" clause
was the one place it was left open, and closing it removes the only readoption
disposition capable of stranding a lineage.

## Consequences

### Positive

- A lineage-live readoption window can no longer strand a lineage. Every
  disposition of the window — success, or exhaustion — now lands the lineage
  in a state some existing mechanism observes: adopted-and-live on success,
  or reaped-with-a-tombstone within one orphan deadline on exhaustion.
- The shim reaps deterministically within a bounded time of exhaustion instead
  of depending on a composing deployment's own configuration choice, which
  removes a class of deployment-specific divergence from the core contract.
- Embedders gain an explicit hook (`OnReadoptionWindowExhausted`) fired at the
  exact moment the daemon commits to withdrawal, rather than having to infer
  the moment from a subsequent quarantine or tombstone event.

### Negative

- A composing deployment that had configured (or was relying on the freedom
  to configure) a retain outcome loses that option. There is no longer a way
  to keep a lineage in the adopted set past window exhaustion while still
  observing the shim alive.
- The window can no longer be extended past exhaustion by any means other than
  re-entering a fresh window before the current one exhausts; there is no
  grace period on the withdrawal itself.

### Risks

- `OnReadoptionWindowExhausted` firing does not by itself guarantee the
  withdrawal or the subsequent reap completed; an embedder that treats the
  hook firing as proof of a reaped process makes the same class of mistake
  `ADR-2026-09-02-outcome-unknown-launch-commit-resolution.md`'s
  `OnSpawnAborted` contract exists to forbid for the launch path. The hook
  states that withdrawal has begun, not that the harness process group is
  gone.

## Alternatives considered

- **Keep the configured post-window outcome, including retain, as originally
  amended.** Rejected: this is exactly the shape that strands a lineage — the
  context section above traces the concrete path from a retained lineage to
  one no reconciler ever revisits.
- **Make the quarantine-only reconciler also walk retained-past-exhaustion
  lineages.** Rejected: this adds a second durable set the reconciler must
  track, with its own membership and eviction rules, to solve a problem the
  unconditional-withdraw path already solves without adding any new durable
  state. A reconciler that must inspect two disjoint sets to reach the same
  conclusion — "this lineage needs to be reaped" — is strictly worse than one
  that reaches it from a single set.
- **Leave the outcome configurable but default it to withdraw.** Rejected:
  a configurable default is exactly the surface that let a deployment
  configure retain in the first place. The invariant this decision closes is
  a core-contract property, not a deployment preference, so it belongs in the
  contract unconditionally rather than behind a default that can be flipped.

## Affected documents

- `ADR-2026-08-17-session-shim-adoption.md` — core contract rule 8, the
  *Amendment 2026-09-03 — re-adoption window bounded by observed liveness*
  section. The "Window exhaustion with a live shim yields the configured
  post-window outcome" clause is replaced with the unconditional-withdraw
  text above. **This edit lands inside the
  `adr-2026-08-17-session-shim-core-contract` synchronized region** and ships
  via paired PRs to both corpora per `BOUNDARY.md` § "Simultaneous-PR rule for
  synchronized sections"; `scripts/check-boundary-sync.sh` must pass before
  either PR merges.

## Affected work items

None cited in this corpus — tracker issue references belong in the platform
mirror per `BOUNDARY.md`.

## Implementation notes

Shipped in the OSS execution layer (`donmai`, PR #542): the lineage-live
re-adoption state machine fires `OnReadoptionWindowExhausted` and transitions
directly to withdrawal on window exhaustion, with the orphan-clock keepalive
extension stopped at the same transition so the shim's already-defined
bounded-orphaning path (rule 8's opening clause) takes over without a second
timer or a second reap path.
