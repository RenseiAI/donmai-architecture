---
status: Proposed
date: 2026-08-31
boundary: shared
split: sibling-extensions
---

# ADR-2026-08-31 — Session recovery taxonomy and lifecycle state vocabulary

**Status:** Proposed
**Date:** 2026-08-31
**Boundary:** shared (the taxonomy, the evidence polarity rule, the
state-artifact retention law, and the naming law are canonical here; the
concrete persisted enum, the surfaces that render it, and the migration
sequencing belong in implementation-specific extensions)
**Authors:** resilience and recoverability lane

## Context

`ADR-2026-08-30-recovery-semantics-for-stateful-links.md` settles how one
stateful link recovers. It is deliberately careful at its own edge: a link
observer may not terminalize a session because its own projection disappeared,
and the canonical lifecycle may independently enter its own non-terminal states.
It does not name those states, and it does not say what recovering a *session*
means when the thing that is gone is the process rather than the binding.

Two pressures forced that question on 2026-08-31, from opposite directions.

**From operations.** Live sessions were degraded to a non-terminal,
resumable-looking state by a correct degrade path, and nothing resumed them.
An operator could not distinguish a session that was recoverable right now from
one that was genuinely finished without reading the host's registry and process
table by hand. The state name available to them made this worse rather than
better: it asserted that somebody had chosen the state, and nobody had. A reader
who trusts the name spends their first diagnostic minutes looking for a decision
that was never made.

**From product.** A separate stream of work is building **resume** — starting a
new incarnation of a session seeded with prior context, keyed on the harness's
own session artifact and on context the coordinating layer supplies.

These two are opposites on their central precondition, and one word currently
covers both. The invariant being enforced correctly in the rebind work —
*never resurrect a session with recorded terminal evidence* — is right for
rebind and would **forbid resume outright** if it were written as a general rule
about session recovery. A session that exited cleanly is the ordinary thing one
would want to resume. Writing that invariant at the wrong altitude would
foreclose a capability the roadmap already contains.

The conflation is not hypothetical; it has already shipped twice. In one
observed failure a relaunch was classified as a resume because a surviving
record said so, spawn-time briefing was skipped by design for resumes, and the
harness conversation nevertheless started completely blank — the operator was
handed an empty seat presented as a continuation. In another, a *fresh* session
that merely carried a name took the resume path and failed at spawn against a
saved session that had never existed. Both are the same mistake: the mechanism
was selected from a proxy signal rather than from evidence that the artifact
the mechanism needs is actually there.

## Decision

Session recovery is not one verb. It is a closed taxonomy whose member is
selected from evidence; registered terminal evidence is a **prohibition** for
one member and an **ordinary precondition** for another; the artifact a member
depends on has a lifetime independent of the process that produced it; and a
lifecycle state name may never assert intent the system did not have.

### D1 — The closed recovery taxonomy

| Mechanism | Harness process | Prior context | Registered terminal evidence | Result |
|---|---|---|---|---|
| **continue** | alive, binding intact | in the live process | disqualifying | the same realization proceeds; no recovery occurred |
| **rebind** | **alive** | in the live process | **disqualifying** | the *same* incarnation regains its lost binding |
| **resume** | **gone** | retained and verified readable | **ordinary precondition** | a *new* incarnation seeded from retained context |
| **restart** | gone | absent or unreadable | permitted | a new session; prior work is not carried, and this is said plainly |
| *(none yet)* | unknown | unknown | unknown | preserve and degrade; classify before choosing |

Six rules fall out of the table, and the table is worth little without them.

**Rebind preserves identity; resume creates an incarnation.** A rebind is the
same canonical session, the same harness process, the same conversation — only
the binding was lost, and recovery restores it. A resume is a **new execution
incarnation**, and it is represented as one: it carries its own incarnation
identity under the same logical session, and it records its provenance — what
it was seeded from, and by which mechanism. A resume that presents itself as
the old incarnation silently continuing is a falsified record, and it is what
makes a blank seat indistinguishable from a live one.

**Terminal evidence has opposite polarity across the two.** For rebind,
registered terminal proof under `ADR-2026-08-30` D7 is **disqualifying**: a
session that genuinely ended cannot regain a binding, and no live claim may
overturn that. For resume, a clean terminal observation is the **normal**
case — it is the evidence that the prior incarnation is finished and its
artifact is complete. The prohibition is therefore a property of the *rebind
transition*, stated as such, and never a property of "session recovery" in
general. This ADR exists in large part to prevent that generalization from
being made by accident.

**Absence never selects a member.** Not-claimed, deadline-elapsed, a missing
discovery record, a vanished supervisor, a dead process id without a matching
start identity — none of these select rebind, resume, restart, or *none*. They
select "classify further," which is `ambiguous` under `ADR-2026-08-30` D2.
Absence of the harness process does not authorize resume either: resume requires
**positive** evidence that the context artifact exists and is readable, not the
inference that because the process is gone the artifact must be what remains.

**The mechanism is selected from evidence, never from a proxy signal.** A name
being present, a flag on a payload, a surviving lifecycle row, an operator's
stated intent, or the fact that a session existed before are all
**instructions** — inputs that may *request* a mechanism. The mechanism is
settled only when the artifact that mechanism requires has been verified to
exist. The two shipped failures above are both this rule violated: one keyed on
a name, one keyed on a record. An instruction to resume with no verifiable
artifact is a typed, actionable refusal that names what was missing — never a
silent fall-through to a different mechanism, and never a spawn that fails
obscurely at the harness.

**Resume is verified at the layer that performs it.** A resume asserted by a
coordinating layer but not realized by the harness is a **failed resume**, not a
resume. It downgrades to the honest alternative — a seeded fresh incarnation,
briefed as fresh — and it says so in its record. This is
`ADR-2026-08-30` D2's rule that a transport-level acknowledgement without the
durable post-condition is `ambiguous`, applied to context handoff: the
coordinating layer's belief that a resume happened is an acknowledgement; the
harness's conversation actually being present is the post-condition.

**Granularity is one session.** Every member of the table operates on exactly
one session. There is no host-wide member and no batch member. This follows
from `ADR-2026-08-30` D1's scoping of failure to the link, and it is stated here
because the operational verb that existed on the day this was written was a
whole-host restart, and a taxonomy that does not say "no host-wide member" will
acquire one.

### D2 — Session state outlives the process that produced it

If resume is a capability, then the artifact resume is keyed on is **session
state**, not process scratch. Its lifetime is governed by the session's own data
lifecycle — not by the process, not by the working directory, not by the
workarea, and not by a sweep's heuristic about what looks temporary.

**Location.** Harness session state lives at a declared, session-owned location
that a replacement controller can resolve *without* the original process — the
same resolvability requirement adoption already places on a session's workarea
root. Two placements are specifically excluded, and both exist today across
different harnesses: **inside the repository checkout**, where it leaks into
diffs and is destroyed by ordinary workspace hygiene, and **in a system
temporary directory**, where it is destroyed on a schedule nobody declared and
nobody can see.

**Retention.** Deleting session state is an explicit lifecycle transition with a
resolved policy and a receipt, under the session data lifecycle law
(`ADR-2026-08-19-session-data-lifecycle-tiering-and-rehydration.md` D8). The
rule that matters is a single sentence and it is easy to get backwards:
**process death is the precondition for resume, so it cannot also be the trigger
for deleting what resume needs.** Any sweep whose criterion is "the process that
made this is gone," "this directory looks orphaned," or "nothing has touched
this recently" is applying exactly the condition under which resume becomes
relevant.

**Declaration.** A cleanup path may delete only what a manifest declares
deletable. A sweep that *discovers* deletable state by walking the filesystem
cannot know whether it is deleting a resume key, and no amount of care in
writing its predicate changes that — the predicate is being asked a question the
filesystem cannot answer. Requiring declaration makes the rule mechanically
checkable rather than a matter of diligence, and it is the only form of this
rule that survives contact with a future contributor.

The cost is honest and worth stating: this lengthens what a host retains and
charges disk against sessions that have finished. The answer is a declared
retention tier with a receipt, not an undeclared sweep.

### D3 — A state name may never assert intent the system did not have

A lifecycle state name is read as a claim about **how the system arrived at
that state**. `paused` claims an actor chose it. When nothing chose it, the
name is false, and every reader pays for the falsehood by looking for a decision
that does not exist. Naming an involuntary condition after a voluntary one
spends the word as well: if the voluntary capability is later built, it cannot
have the name that fits it.

Applied to the state this ADR was written about:

- **`stalled`** — involuntarily not active, and able to become active again when
  the surrounding conditions permit. This is the honest name for the state a
  degrade path produces when a session loses its binding: nobody chose it, the
  work is not finished, and the condition is expected to clear.
- **`paused`** — **reserved** for a deliberate act by a human or a coordinator.
  That capability does not exist today. Reserving an unused name is nearly free;
  recovering a spent one costs a migration and a period of ambiguity across
  every surface that ever rendered it.

The sub-distinction operators actually need is about **what is missing**, and it
is expressible only because the host's holdings become continuously legible
under `ADR-2026-08-31-continuous-host-holdings-claim.md`:

- **`stalled — host holding`** — a host still claims the session. Rebindable
  now, and the suggested action is a rebind.
- **`stalled — host not holding`** — no host currently claims it. This is
  **not** terminal and **not** a synonym for dead. It may become rebindable once
  that host's own identity recovers; it may be **resumable later on a different
  host** if its context was retained; or it may have genuinely ended — and only
  registered terminal proof settles the last of those. Defining this state as
  effectively terminal is the specific corner this ADR exists to avoid, because
  it would quietly delete the resume case from the design.

**The rename lands at the projection before the store, and the reason is not
timidity.** Where one state value is read by many independent surfaces that each
carry their own translation, renaming the persisted value first produces as many
partial renames as there are surfaces, plus a window in which surfaces disagree
about one session at one moment — which is the exact diagnostic cost this
decision exists to remove. So: one canonical presentation map from lifecycle
state to displayed name and condition, rendered by **every** surface; the
persisted value migrates afterwards, under its own change, once every surface
reads from the map. Consolidating the fan-out is a **precondition** for the
storage migration, not a substitute for it, and an implementation that stops at
the display layer has done half of this decision, not all of it.

**A condition is not a state, and this is what makes the rule enforceable.** A
degraded live-view channel, a retrying carrier, a stale claim, an unreconciled
holding — these are conditions *on* a session. They render **beside** the state,
never in place of it. A surface that substitutes a condition for a state has
re-created the same lie in a different word: it reports something true about the
transport as though it were true about the work.

### D4 — Migration and proof

The taxonomy lands as a typed discriminator with a recorded reason before it
changes any behavior: every existing recovery path declares which member it is
performing and on what evidence, the selection runs in shadow against the path's
current decision, and the disagreements are reconciled. Only then does the
discriminator drive.

Required proof, each demonstrated red with the production seam disabled and
green after restoration:

- rebind refused against registered terminal proof;
- rebind admitted on a fresh live holdings claim, and refused when the claim is
  merely absent;
- resume admitted on a clean terminal observation **plus** a verified readable
  artifact;
- resume refused when the artifact is absent, with a typed error naming exactly
  what was missing;
- a resume instruction whose harness incarnation started blank classified as a
  failed resume and downgraded to seeded-fresh with briefing restored;
- a fresh incarnation carrying a name never selecting the resume path;
- session state artifacts surviving a controller restart, an orphan sweep, and a
  workspace hygiene pass, and their deletion producing a receipt;
- a cleanup path refusing to delete undeclared state;
- every surface rendering the same state name for one session at one moment; and
- a condition never replacing a state on any surface.

Proposed status authorizes no reference-doc edit, protocol change, rename,
migration, release, or activation.

## Consequences

### Positive

- The rebind invariant is written where it is true and stops forbidding a
  capability that is being built.
- An operator can tell a recoverable session from a finished one from its name,
  without reading a host by hand.
- A resume that did not actually resume becomes a detectable, named failure
  instead of a blank seat presented as a continuation.
- The artifact resume depends on stops being scratch that any sweep may claim.
- A reserved `paused` remains available for the deliberate capability, at the
  cost of one unused enum value.
- Consolidating the state fan-out removes a recurring class of contradictory
  readings across surfaces.

### Negative

- Four mechanisms are more to reason about than one verb, and every existing
  recovery path must now declare which one it performs.
- Resume as a distinct incarnation means the session model carries incarnation
  identity and provenance it did not carry before.
- Retaining session state past process death costs disk and lengthens teardown.
- The rename is two changes, not one, and the first delivers operator value
  while leaving a known inconsistency between what is displayed and what is
  stored.

### Risks

- **The taxonomy is treated as advisory and a path keeps selecting by proxy.**
  Mitigation: the discriminator is typed and recorded with its evidence, and the
  proof set includes the two shipped proxy-selection failures as fixtures.
- **`stalled — host not holding` hardens into a terminal state in practice**
  because nothing ever clears it. Mitigation: it is defined as an ambiguity
  state, it carries an age, and clearing it is an obligation rather than a hope.
- **Retention becomes indefinite.** Mitigation: retention is a declared tier
  with a receipt under the existing session data lifecycle law, not an absence
  of deletion.
- **The display-first rename stalls at display.** Mitigation: the migration is
  named as the completion of this decision, and consolidating the fan-out is
  stated as its precondition rather than its replacement.
- **Incarnation identity is mistaken for a new session.** Mitigation: the
  logical session identity is unchanged and canonical; incarnation is a
  qualifier beneath it, per the one-session substrate.

## Alternatives considered

- **State one general rule: never recover a session with terminal evidence.**
  Rejected: it is correct for rebind and forbids resume, which is the corner
  this ADR was written to avoid. Terminal evidence is a per-mechanism
  precondition, not a session-level one.
- **Treat resume as a special case of rebind.** Rejected: they have opposite
  preconditions on terminal evidence and produce different things — the same
  incarnation versus a new one. Conflating them is what produced a blank
  continuation in one direction and a forbidden-resume design in the other.
- **Treat "no host claims it" as terminal.** Rejected: it is an unobservability
  statement, not a death certificate, and it would delete the case where a
  session resumes later on a different host.
- **Keep `paused` and explain it in a tooltip or subtitle.** Rejected: the value
  travels through interfaces, logs, receipts, and operator speech. A gloss
  attached at one surface does not survive the trip, and the name is what people
  repeat.
- **Rename the persisted value first and let surfaces catch up.** Rejected on
  sequencing, not on merit: with independent per-surface translations it yields
  partial renames and a disagreement window. Deferred behind the presentation
  map, not abandoned.
- **Let each harness own where its session state lives.** Rejected: the
  divergence is the defect. Today one harness writes into the checkout and
  another into a system temporary directory, and neither placement survives what
  resume requires.
- **Detect resume-ability by scanning for artifacts at spawn time.** Rejected:
  it makes the filesystem the authority for a lifecycle question and reproduces
  the proxy-selection failure with a slower proxy. The instruction comes from
  the record; the artifact check verifies it.

## Affected documents

On acceptance this ADR amends:

- `001-layered-execution-model.md` — Layer 3 gains the recovery taxonomy and the
  incarnation-versus-session distinction.
- `013-orchestrator-and-governor.md` — recovery paths declare their mechanism
  and its evidence; resume classification requires harness-layer verification;
  completion contracts distinguish a resumed incarnation from a continued one.
- `011-local-daemon-fleet.md` — session state root placement, resolvability
  without the originating process, and declared-deletion-only cleanup.
- `014-tui-operator-surfaces.md` — the canonical state presentation map, the
  `stalled` vocabulary and its two sub-states, and the rule that conditions
  render beside states.
- `ADR-2026-08-30-recovery-semantics-for-stateful-links.md` — the session-level
  taxonomy sits above the link-level contract; the rebind prohibition is
  anchored to the rebind transition.
- `ADR-2026-08-19-session-data-lifecycle-tiering-and-rehydration.md` — harness
  session-state artifacts are a retained tier with declared deletion, not
  scratch.
- `ADR-2026-08-22-session-owned-multi-repository-workarea.md` and
  `ADR-2026-08-30-workspace-root-and-lazy-repository-materialization.md` —
  exact-harness state under the session-owned root is resume-bearing state and
  inherits this retention law.
- `ADR-2026-08-31-continuous-host-holdings-claim.md` — the holdings claim is what
  makes the two `stalled` sub-states distinguishable without reading a host by
  hand.
- `ADR-2026-08-16-one-session-substrate-and-typed-event-spine.md` — incarnation
  identity is a qualifier beneath the canonical session identity, never a second
  session.

## Affected work items

- Typed recovery-mechanism discriminator with recorded evidence on every
  existing recovery path.
- Harness-layer resume verification and the failed-resume downgrade to
  seeded-fresh with briefing.
- Session state root placement, resolution without the originating process, and
  declared-deletion-only cleanup with receipts.
- Canonical state presentation map consumed by every surface, followed by the
  persisted-value migration.
- The two `stalled` sub-states and their suggested operator actions.
- Conformance fixtures for both shipped proxy-selection failures.

No private tracker references belong in this public ADR.

## Implementation notes

- Record the selected mechanism and the evidence that selected it on the session
  record itself. A mechanism inferred at read time from surrounding state is the
  proxy-selection defect with an extra step.
- Represent a resumed incarnation explicitly rather than by mutating the prior
  one back to active. The prior incarnation's terminal record is the evidence
  that authorized the resume; overwriting it destroys the authorization.
- Make the declared-deletable manifest the *only* input to any sweep that
  removes session-adjacent directories, and fail a sweep that encounters
  undeclared state rather than letting it choose.
- Build the presentation map as a single module with per-surface render tests
  before touching storage; the tests are what stop the fan-out from regrowing.
- Keep the two `stalled` sub-states derived, not stored. They are a function of
  the current holdings claim, and storing them creates a third thing that can be
  stale.
- When a resume instruction cannot be satisfied, the error names the artifact
  and the location it was expected at. An error that says only that resume
  failed sends the reader to the harness, which is the layer that was right.
