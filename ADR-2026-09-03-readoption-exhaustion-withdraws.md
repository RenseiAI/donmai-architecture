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

> **Amended 2026-10-21:** a lineage the composing layer holds past the window
> (an interactive session nobody asked to stop, with no duration quota spent)
> continues its window instead of exhausting it, and is re-adopted rather than
> quarantined when lost again inside the previous window. Continuing is not
> retaining: the keepalive, the liveness gate and the attempts keep running, so
> the invariant below is unchanged. See § "Amendment 2026-10-21" below.

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

## Amendment 2026-10-21 — a lineage held past the window continues; it is not retained

### Context

The decision above is right for the lineage it was written about: one whose
re-adoption attempts have run out of reasons to continue. It is wrong for a
second shape that the field has since produced. An interactive session's
harness is alive, its shim is observable, and the composing control plane
still holds the session — no stop was requested and no duration quota is
spent — but its carrier cannot be restored inside one window. The cause is
typically a control-plane refusal that repeats identically on every attempt
until a fix on that side lands, or a carrier that flaps and is lost again
minutes after a successful re-adoption. Both shapes end the same way:

- **Window end.** The window exhausts with the shim observable, the lineage is
  withdrawn, the keepalive stops, and the shim reaps a healthy harness one
  orphan deadline later. Nobody asked for that harness to stop.
- **Re-entry.** A controller lost again within one window of the lineage's
  last automatic re-adoption is quarantined `socket_unreachable` with no
  re-adoption attempt at all, and the same reap follows.

The operating rule for interactive work is that a session stays running
unless a session parameter (a requested stop) or a duration quota ends it. A
carrier fault is neither. Reaping the harness turns a recoverable carrier
fault into lost work, and it does so on the one session class whose owner is
waiting for it.

### Decision

1. **A continuation predicate.** The daemon's session-shim configuration
   gains an optional composing-layer predicate, *held past the window*
   (`ReadoptionHeldPastWindow` in the reference implementation). A true
   answer is the composing layer's statement of two facts together: it holds
   this lineage on terms the window does not bound (no stop requested, no
   duration quota spent), **and** nothing outside this host will release the
   lineage's claim while the answer stays true. The second fact is what keeps
   rule 8's §D8 inequality honest once the keepalive runs past the window: the
   external release threshold no longer bounds a lineage this predicate holds,
   so the predicate is the bound. Unset is the default and keeps the decision
   above exactly as written.
2. **Window end continues.** When a lineage-live window ends with the shim
   still observable and both the lineage-held predicate and the
   held-past-window predicate answer true, the daemon starts another window in
   place. The keepalive stays armed, the backoff stays capped, and every
   attempt still runs the full prepare-and-adopt pipeline.
   `OnReadoptionWindowExhausted` does not fire, because nothing is being
   withdrawn.
3. **Re-entry re-adopts.** A controller lost again inside the previous window
   is re-adopted, not quarantined, when the same conjunction answers true. The
   re-entered window starts as an already-continued window, and its first
   attempt waits one backoff, so a flapping carrier costs at most one adoption
   revision per backoff.
4. **The continuation is re-asked constantly.** Once a window has been
   continued (or was re-entered under this authority), the held-past-window
   predicate is consulted at every window end, on every attempt and on every
   paced keepalive tick. The first false answer ends the window the ordinary
   way. A false answer from the lineage-held predicate, or a shim that stops
   being observable, ends it the same way. The ordinary way means
   `OnReadoptionWindowExhausted` first, then the unconditional withdrawal
   above, the keepalive stopped, and the shim's own orphan deadline from
   there.
5. **Configuration is refused when the predicate cannot be bounded.** Setting
   the held-past-window predicate without the lineage-held predicate, or
   outside lineage-live mode, is a configuration error at install time. A
   standalone daemon's implicit "always held" would otherwise turn
   continuation into a re-adoption that nothing could ever release.

### Why this is not the retain outcome the decision rejects

The rejected retain outcome left a lineage adopted with the keepalive
stopped, the attempts over and no reconciler looking at it. A continued
window leaves the lineage in exactly the state it was in during the window:
adopted at its retained revision (the complete-snapshot rule), its keepalive
gated per tick on the composing layer's answer, its liveness gate checked per
attempt, and a live loop that withdraws it the moment any of those fails. A
shim that dies is observed by that loop and goes down the ordinary
lineage-gone path; a stop or a spent quota is observed by the predicate and
goes down the exhaustion path. The invariant in the Decision — no non-success
disposition may leave a lineage neither adopted nor withdrawn — still holds,
because continuation is not a disposition. It is the window still running.

The change also grants no new authority. The harness stays withheld from
claims as before, no carrier is granted without a fresh preparation that the
control plane accepts, and every attestation, proof and fence check on the
re-adoption path is unchanged. The only thing extended is how long the daemon
keeps asking.

### Consequences

- **Positive.** An interactive harness survives a carrier fault that outlasts
  one window or recurs inside one. A control-plane fix, or the carrier
  returning, then re-adopts the same harness instead of finding a tombstone.
- **Negative.** A composing layer that answers true incorrectly keeps a
  harness alive past the point where the external release threshold would
  have bounded it. The predicate's contract makes this the composing layer's
  responsibility, and the per-tick consultation bounds the damage to one
  keepalive interval after the answer changes.
- **Negative.** A continued window keeps spending re-adoption attempts at the
  capped backoff for as long as it continues. Each attempt is a preparation
  the control plane has to answer. The cap bounds the rate. Nothing bounds the
  count except the predicate, and that is deliberate.

### Affected documents

- `ADR-2026-08-17-session-shim-adoption.md`, core contract rule 8: a new
  *Amendment 2026-10-21 — held-lineage continuation (rule 8)* paragraph after
  the 2026-09-03 amendment. **This edit lands inside the
  `adr-2026-08-17-session-shim-core-contract` synchronized region** and ships
  via paired PRs to both corpora per `BOUNDARY.md` § "Simultaneous-PR rule for
  synchronized sections". `scripts/check-boundary-sync.sh` must pass before
  either PR merges.

## Implementation notes

Shipped in the OSS execution layer (`donmai`, PR #542): the lineage-live
re-adoption state machine fires `OnReadoptionWindowExhausted` and transitions
directly to withdrawal on window exhaustion, with the orphan-clock keepalive
extension stopped at the same transition so the shim's already-defined
bounded-orphaning path (rule 8's opening clause) takes over without a second
timer or a second reap path.

The 2026-10-21 amendment ships in the OSS execution layer (`donmai`, daemon
package) as the `ReadoptionHeldPastWindow` session-shim configuration field.
It is consulted only together with `LineageLive`, and validated at install
time. A composing deployment opts in by wiring the predicate, and until it
does the bounded window above is unchanged.
