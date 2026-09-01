---
status: Proposed
date: 2026-08-31
boundary: shared
split: sibling-extensions
---

# ADR-2026-08-31 — A host continuously claims what it holds

**Status:** Proposed
**Date:** 2026-08-31
**Boundary:** shared (the holdings projection, its bounds, the reconciliation
laws, and the controller-identity rebind profile are canonical here; concrete
reconciler placement, signal routing, operator surfaces, and rollout sequencing
belong in implementation-specific extensions)
**Authors:** resilience and recoverability lane

## Context

`ADR-2026-08-30-recovery-semantics-for-stateful-links.md` settles what a
recovery owner may conclude and what it may do once it has an observation to
classify. It does not supply the observation. This ADR does.

A host's heartbeat today answers a question about a process: is the controller
serving. The corpus already decided that a bounded per-session projection
belongs on that beat — `ADR-2026-08-17-session-shim-adoption.md` D7 puts
`quarantined_sessions` there, carrying lifecycle identity, shim id, protocol
range, reason code, age, and `consumes_capacity:true`, and requires the local
status and doctor surfaces to render the same projection. The decision was
correct and it stopped one entry short: it published the half of the host's
holdings that the host cannot use, and left unpublished the half it can.

The live half travels in exactly one place. D4 step 12 of that ADR commits one
complete adoption batch per served scope, including empty scans, and step 15
sends the first coherent heartbeat only afterwards. That sequence runs when a
controller boots. So the host's statement of what it holds is a **boot-time
snapshot**, not a continuous fact, and every consumer of host health is reading
a liveness check that has been quietly asked to stand in for a holdings
question it cannot answer.

The host is not short of truth. Its shim registry records the lifecycle
identity, the shim and process correlation, the controller generation, and the
phase for every session it owns, and `Hello`/`Adopted` authenticate each one.
The truth exists; it has no continuous channel.

**What that cost on 2026-08-31.** Four failures in one day, all the same
absence wearing different clothes.

A carrier substrate was restarted while sessions were live. Every room dropped;
every harness stayed alive, because the shims own the processes and the
controller is only the replaceable carrier. The reaper then observed host
bindings lost past grace and degraded the affected rows to a non-terminal
state — degrade-do-not-destroy working exactly as designed, and correctly
refusing to call them failed. Nothing re-established them. The controller never
restarted, so no adoption batch was sent, and there was no other channel on
which the host could say *I still hold these*. The sessions sat in a state that
reads as resumable with nothing that resumes them, one of them holding hours of
live agent context, while the host went on reporting itself ready. The
divergence was resolved by an operator reading the shim registry and the
process table by hand. That is the only diagnostic available today, and it does
not scale past one operator on one machine.

The same window produced three more. A host was stranded when one batch commit
was refused, and stayed stranded until an operator restarted the controller —
a recovery whose blast radius is every session on the machine, used because it
was the only verb that existed. One lineage that could not be represented
aborted composition for the whole host, converting one damaged session into a
host-wide outage. And a discovery deadline was treated as a terminal verdict
while the authoritative record landed moments later.

Each of these is a decision taken on the absence of information that a
continuous holdings claim would have supplied. That is the shape of the
decision below: not a new authority, but the observation channel the existing
authorities were already assuming they had.

## Decision

A host continuously claims the set of sessions it holds. That claim rides the
same beat as its health, health is not expressible without it, and both sides
reconcile the claim against their own records into typed, bounded signals —
never into silent mutations, and never into terminal verdicts.

### D1 — The heartbeat carries holdings, not only liveness

Every heartbeat carries one coherent **holdings projection** covering the
complete set the controller owns, in two classes:

- `held_sessions` — every lineage this controller has adopted and currently
  owns; and
- `quarantined_sessions` — the existing D7 projection, unchanged in meaning.

Per entry, bounded and secret-free: lifecycle identity, shim and process
correlation, that shim's current controller generation, the phase the shim
reports, the capacity charge, and the **liveness assertion the controller
actually verified**, together with how it verified it. A controller may claim
only what it has adopted or quarantined. It never claims a lineage it inferred,
reconstructed from a local file, or expects to adopt.

**Emptiness is explicit and is itself a claim.** A controller that holds
nothing says so. `held_sessions: []` is a fact a receiver may act on; a beat
that omits the projection is not, and a receiver must distinguish the two. This
mirrors D4 step 12's requirement that an empty scan still commits a complete
batch.

**The projection is bounded by construction.** Each beat carries a summary
(counts by class), a lowercase SHA-256 digest over the complete canonical
holdings set, and up to a registered cap of enumerated entries. The digest is
always over the *complete* set even when the enumeration is capped, so a
receiver can always detect that holdings changed and can always tell whether it
has seen everything. When the enumeration is capped or the digest is unfamiliar,
the receiver requests the full set over a separate bounded exchange. A beat is
never permitted to become an unbounded dump, and a large holdings set never
makes the beat itself unreliable.

**The claim is an observation; the batch remains the authority.** The holdings
claim never adopts, never activates, never commits or substitutes for a
complete adoption batch, never grants carrier authority, never advances a
generation, and never satisfies any phase of a registered rebind profile.
Separating the cheap continuous observation from the expensive fenced authority
operation is the entire point: the batch stays event-driven and exact, and the
claim stays frequent and bounded.

### D2 — Health is a statement about holdings

A host that reports ready while holding sessions no other party believes in has
not reported its health. It has reported its process.

Readiness therefore expresses capacity **and** holdings together: ready holding
N reconciled sessions is a different fact from ready holding N sessions of
which K are unreconciled, and the status vocabulary distinguishes them. A
controller that is serving normally but whose holdings disagree with its
counterpart is not simply `ready`; it carries an explicit unreconciled-holdings
condition, visible wherever its health is visible.

Capacity computation already charges adopted **plus** quarantined shims before
the host advertises available slots (D4 step 16). D1 makes that count legible
externally rather than only locally, which is what lets a capacity view stop
reporting a number no consumer can corroborate.

### D3 — Reconciliation is bidirectional and produces signals, never mutations

On receipt, each side compares the claim against its own records. Two
disagreements exist and both are useful; today neither is observable.

**held-not-known.** The host claims a lineage whose counterpart record is
degraded, absent, or pending settlement. This is a **rebind candidacy signal**.
It is not a rebind. It enters evidence classification (`ADR-2026-08-30` D2) as
`healthy` at best and `recoverable_absence` at worst, and any transition that
follows runs the registered phased profile under a recovery-owner fence
(`ADR-2026-08-30` D3, D5). The claim supplies evidence; it never supplies
authority.

**known-not-held.** A counterpart record says a lineage is live on this host and
the host does not claim it. This is a **stranded-record signal**, and it opens a
durable reconciliation obligation. It is emphatically **not** terminal
evidence. A holdings claim is a statement about what a controller can currently
observe; the absence of an entry proves unobservability, never death — the same
distinction the shim-absent attestation already draws, and the same one
`ADR-2026-08-30` D7 requires. The signal never releases a claim, requeues a
session, lowers a floor, or emits a terminal outcome.

**The asymmetry is the load-bearing rule.** A holdings claim may create a
recovery obligation in either direction, but it may only ever **narrow, never
widen, terminal authority**. A host claiming a lineage live cannot resurrect one
that carries registered terminal proof. A host declining to claim a lineage
cannot terminalize it. Reconciliation is one-way toward truth in both
directions, which is not a contradiction: it means each side may learn that
work survives, and neither side may conclude from a claim alone that work
ended.

**Conflicts are surfaced, not resolved.** A claim that contradicts registered
terminal proof is a contract conflict. It records a condition, emits an
operator-visible signal, and holds cleanup. It is never silently picked in
either direction, and it never selects the more convenient of two projections.

**Reconciliation is bounded.** Signals are durable obligations, not immediate
actions, and they are admitted under the per-link and per-authority budgets of
`ADR-2026-08-30` D4. A host returning after a long absence with a large
divergence must not be able to start a synchronized recovery storm; a
divergence of N produces at most the registered admission rate of attempts, and
the remainder waits in a durable scheduled state.

### D4 — A controller rebuilds its own identity in place; a restart is never the recovery unit

The boot sequence is already the recovery sequence. Registration, shim
composition, a complete adoption batch that re-presents every live shim, and
carrier re-establishment are exactly what a wedged host needs. The reason the
operational recovery in use is a whole-process restart is not that a restart is
right — it is that the sequence is bound to process start and can be reached no
other way. That binding is the defect.

**The sequence binds to a state, not to process start.** A controller whose
counterpart-facing rail fails to converge — an identity the counterpart cannot
find while re-registration keeps failing, a receipt that persistently disagrees
with the published projection, a projection stuck demoted or never-ready —
enters a typed identity-recovering condition. After a bounded non-convergence
window it tears down **only its counterpart-facing state**: its worker
identity, its token rails, its composition declaration. It then re-runs the
sequence in place.

**Holdings are untouched.** Shims, harnesses, PTYs, the registry, every adopted
correlation, and every generation floor survive unchanged. This is the exact
inverse of a restart, and it is what makes it safe. It is also not a new idea:
`ADR-2026-08-17` already establishes that the shim owns the process and the
controller is the replaceable carrier. This applies that model to the
controller's own identity — the controller is replaceable, including by itself.

The **controller registration link** is registered as a link kind under
`ADR-2026-08-30` D1, with a phased profile drawn from the existing closed phase
vocabulary of D5; nothing new is invented:

```text
inspect            = fresh authoritative read of the counterpart's view of this host
reserve_candidate  = a new, non-active counterpart-facing identity
acquire_evidence   = the stable-host and adoption-revision receipts for every served scope
adopt              = install the credential rails for that identity
publish            = commit one complete adoption batch per scope from live holdings
activate           = the first coherent heartbeat, accepted with the exact echo
```

Poll, claim, capacity publication, and `Ready` stay disabled until `activate`,
exactly as at boot. Re-bootstrap is an attempt under `ADR-2026-08-30` D4: it
consumes budget, respects positive spacing, opens a circuit when exhausted, and
dead-letters to a loud persistent operator condition rather than looping. A
controller that cannot rebuild its identity degrades visibly; it does not
churn, and it does not take its holdings down with it.

Two corollaries close two of the day's failures, and both are applications of
laws already accepted rather than new ones.

**Preparation failures retry; they do not kill a seat.** A refused batch commit
or a transient refusal at adoption-prepare or carrier re-prepare is `ambiguous`
under `ADR-2026-08-30` D2. It retries under bounded backoff with a typed
degraded condition. Prepare is idempotent by contract; treating one refusal as
session-fatal is precisely the conversion of a transient condition into a
terminal one that D2 forbids, and it is what made a single refusal cost a
machine.

**One lineage never aborts composition host-wide.** `ADR-2026-08-30` D1 scopes
link failure to the link, and one damaged link must leave unrelated links
intact. A batch that cannot represent one lineage fails **that lineage** into
quarantine or attestation and commits the rest; it does not fail the batch, and
a failed batch does not fail the host. The shim-absent attestation already
carved the specific escape hatch for the specific case that forced it; this
states the general rule the hatch was an instance of.

### D5 — A deadline selects eligibility; the claim is the cheaper alternative to guessing

That elapsed time never authorizes a terminal verdict is settled — by
`ADR-2026-08-30` D7 and by `ADR-2026-08-17` D8, which each say it directly for
their own scope. This ADR adds only what the holdings claim makes newly
possible.

Before a deadline-eligible destructive action commits, the actor consults the
most recent holdings claim for the host in question. A claim that names the
lineage is fresh evidence that the deadline was measured against the wrong
thing, and the action is refused rather than merely delayed. A claim that does
not name it remains `ambiguous` and authorizes nothing further; absence is
still absence.

The value is that a deadline-driven path finally has something cheap to consult.
The reason the day's discovery deadline fired moments before the authoritative
record landed was not that the deadline was too short — it was that expiry had
no corroborating source and so had to stand alone as evidence. It no longer
has to.

### D6 — Conditions and observability

Recovery conditions reuse the closed vocabulary of `ADR-2026-08-30` D9 rather
than growing a parallel one. This ADR adds the host-scoped conditions its own
subject requires:

- `host_holdings_unreconciled` — the host's claim and its counterpart's records
  disagree, with the disagreement classified by direction;
- `host_identity_recovering` — a bounded in-place identity rebuild is running;
  and
- `host_holdings_claim_stale` — no fresh holdings claim within the registered
  bound, which is an ambiguity condition and never a terminal one.

All three are current-state projections that clear through explicit resolved
transitions, never sticky fault ledgers. History lives in append-only receipts.
Consumers branch on closed reason codes; human-readable detail is display-only.
Metric cardinality excludes session, lineage, host, credential, and raw error
values.

The same holdings projection appears wherever host health is exposed — the
local status and doctor surfaces and every remote fleet view — which extends
the rule `ADR-2026-08-17` D7 already imposes on the quarantine projection to
the complete set. A local-only rendering is insufficient, because the whole
failure this ADR addresses is a divergence that is only visible locally.

### D7 — Migration is additive and observation-first

1. Emit the holdings projection with no consumer acting on it.
2. Reconcile in shadow, recording every disagreement by direction with its
   evidence classification, and change no behavior.
3. Reconcile the shadow output against every existing destructive path and
   every existing deadline-driven path, and repair the disagreements.
4. Let `known-not-held` open reconciliation obligations, still with no
   destructive consequence.
5. Let `held-not-known` open rebind candidacies routed through the registered
   phased profile.
6. Bind health to holdings on the operator surfaces.
7. Register the controller-registration link kind and enable in-place identity
   rebuild behind its own circuit and cap.

The acceptance gate needs a positive observation window that crosses at least
one full carrier-substrate restart with live holdings on more than one host,
plus one induced non-converging identity state. Across the window, three
counters stay exactly zero: destructive actions taken against a lineage a fresh
holdings claim named; terminal outcomes derived from a holdings claim in either
direction; and holdings claims that granted an authority reserved to the
adoption batch. Any hit resets the window after repair.

Proposed status authorizes no reference-doc edit, wire change, protocol change,
migration, release, or activation.

## Consequences

### Positive

- The divergence that required an operator to read a shim registry by hand
  becomes a fact both sides publish and compare continuously.
- A carrier-substrate restart with no controller restart — the case with no
  trigger to trigger on — is covered, because the claim is unconditional rather
  than event-driven.
- Host health stops meaning process liveness, and a capacity view stops
  reporting a number no consumer can corroborate.
- A wedged host recovers without a verb whose blast radius is every session on
  the machine.
- Deadline-driven destructive paths gain a cheap corroborating source, so
  expiry stops having to stand alone as evidence.
- One damaged lineage stops being able to take a host down with it.

### Negative

- The heartbeat gains a payload that must be bounded, digested, and versioned,
  and both sides gain reconciliation logic that did not exist.
- A controller that can rebuild its own identity is a controller with a second
  path into its own credential rails; that path needs the same fencing and
  budget discipline as any other recovery, and it is more code than a restart.
- Continuous reconciliation surfaces long-standing divergences that were
  previously invisible, so the first activations will look like a regression in
  reported health while actually being the first accurate report.
- Retaining and comparing holdings costs beat size and receiver work
  proportional to fleet size.

### Risks

- **The claim is mistaken for authority.** Mitigation: D1 states the exclusions
  explicitly, the acceptance gate counts authority grants derived from claims,
  and the batch keeps every commit semantic it has.
- **A large divergence starts a recovery storm.** Mitigation: signals are
  durable obligations admitted under the existing per-link and per-authority
  budgets, with circuits and dead letters.
- **A compromised or buggy controller over-claims.** Mitigation: the asymmetry
  rule caps the damage — an over-claim can at most create a rebind candidacy
  that must still pass fresh authority, fencing, and terminal-proof checks; it
  can never resurrect a lineage with registered terminal proof.
- **The beat becomes the expensive thing.** Mitigation: summary plus digest plus
  capped enumeration, with the full set on a separate bounded exchange.
- **In-place identity rebuild loops.** Mitigation: bounded window, per-window
  cap, circuit, and dead-letter to a persistent operator condition.
- **Holdings entries leak sensitive routing or credential data.** Mitigation:
  the projection is secret-free by construction and carries correlations and
  digests, never material.

## Alternatives considered

- **Trigger an adoption batch when a viewer opens a degraded session.** Rejected:
  it cannot cover the case that motivated the work. A substrate bounce with no
  controller restart and no viewer produces no signal, so a trigger-based design
  is asked to trigger on an absence. It also makes correctness depend on a human
  happening to look.
- **Send the adoption batch periodically.** Rejected: the batch is a fenced
  authority operation with commit semantics, per-scope partitioning, and receipt
  retention. On a timer it either becomes cheap enough to be unsafe or expensive
  enough to be skipped under load — and it would be skipped exactly when the
  host is degraded, which is when its holdings matter most.
- **Have the counterpart poll each host for its session list.** Rejected: it
  inverts the direction of trust, since the host is the authority for what it
  holds; it adds per-host fan-out that scales the wrong way; and it fails
  precisely when the rail is degraded.
- **Let the holdings claim adopt or rebind directly.** Rejected: it would turn a
  frequent, cheap, comparison-only projection into an adoption authority,
  discarding the fencing that `ADR-2026-08-17` D4 exists to provide and creating
  a second path to activation that no generation floor guards.
- **Treat a host that stops claiming a lineage as proof the lineage ended.**
  Rejected: it is the absence-as-terminal error the recovery doctrine was
  written to remove, and it would make every transient rail failure a data-loss
  event.
- **Keep restarting the controller.** Rejected: the recovery doctrine already
  rejected process restart as a link-recovery strategy — it disturbs unrelated
  holdings, freezes recovery into process lifecycle, and supplies no
  supersession proof. The day's stranded host is that rejection's evidence.
- **Publish holdings on a separate stream rather than the heartbeat.** Rejected:
  the decision this ADR makes is that health is not expressible without
  holdings. Two streams would let a consumer read one without the other, which
  is the current defect with an extra endpoint.

## Affected documents

On acceptance this ADR amends:

- `011-local-daemon-fleet.md` — the heartbeat payload gains the complete
  holdings projection; host status gains the unreconciled-holdings condition;
  drain/restart and crash recovery gain in-place identity rebuild as a path that
  does not disturb holdings.
- `013-orchestrator-and-governor.md` — the orchestrator gains bidirectional
  holdings reconciliation, the two typed signals, and their budget admission;
  unreachable-session handling consults the most recent claim.
- `014-tui-operator-surfaces.md` — health surfaces render holdings beside
  readiness, and render the two reconciliation directions distinctly.
- `004-sandbox-capability-matrix.md` — capacity reporting for persistent-host
  contexts becomes corroborable against published holdings.
- `ADR-2026-08-17-session-shim-adoption.md` — the heartbeat's session projection
  becomes complete (held plus quarantined); the complete adoption batch retains
  every adoption authority it has; the general one-lineage-never-fails-the-batch
  rule is stated.
- `ADR-2026-08-30-recovery-semantics-for-stateful-links.md` — registers the
  controller-registration link kind and its phased profile, and names the
  holdings claim as an evidence source that can never be an authority.
- `ADR-2026-08-03-daemon-host-status-signal-completion.md` — the status field it
  put on the wire remains necessary and becomes insufficient alone.
- `ADR-2026-08-07-onboarding-is-the-only-user-action.md` — D3 and D4: recovering
  a host's own identity is a runtime operation, so no remediation hint may name
  a restart the host can perform for itself.

## Affected work items

- Holdings projection schema, bounds, digest canonicalization, and version
  negotiation on the host control surface.
- Bidirectional reconciliation with typed signals, budget admission, and durable
  obligations.
- Health and capacity surfaces bound to holdings on both local and remote
  renderings.
- Controller-registration link-kind registration and the in-place identity
  rebuild state machine with its circuit and cap.
- Retry-not-fail treatment of preparation refusals, and per-lineage batch
  failure isolation.
- Deadline-eligible destructive paths consulting the most recent claim before
  committing.
- Shadow reconciliation instrumentation and the acceptance-window counters.

No private tracker references belong in this public ADR.

## Implementation notes

- The projection derives from the adopted and quarantined registry sets the
  controller already maintains. If producing it requires a new source of truth,
  that is a signal the registry is not authoritative and should be fixed there
  rather than worked around here.
- Canonicalize the holdings set before digesting it, and digest the complete set
  even when the enumeration is capped; a digest over a truncated set silently
  reintroduces the problem this ADR removes.
- Keep the full-set exchange separate from the beat and bounded on its own
  terms. A receiver requesting the full set from every host at once is a storm
  in the same family as a recovery storm and is admitted under the same
  budgets.
- Version the projection additively. A receiver that does not understand the
  holdings projection must degrade to today's behavior, not reject the beat.
- Do not let the in-place identity rebuild share a code path with process
  startup by accident of refactoring; the two differ precisely in what they may
  touch, and a shared path will eventually touch holdings.
- Emit the reconciliation direction as a closed reason code from the first
  shadow build. The shadow window's value is entirely in being able to count
  disagreements by kind.
