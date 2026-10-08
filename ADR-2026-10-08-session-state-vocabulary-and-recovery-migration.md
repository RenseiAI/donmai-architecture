---
status: Proposed
date: 2026-10-08
boundary: shared
split: sibling-extensions
---

# ADR-2026-10-08 — Session lifecycle state vocabulary and recovery-taxonomy migration

**Status:** Proposed. Split on 2026-10-08 from
[`ADR-2026-08-31-session-recovery-taxonomy-and-state-vocabulary.md`](ADR-2026-08-31-session-recovery-taxonomy-and-state-vocabulary.md)
when the founder accepted that ADR's D1 (the closed recovery taxonomy) and D2
(session state outlives the process) and kept its D3 and D4 Proposed. The two
decisions below are carried over unchanged and keep their original numbers, so
references to "ADR-2026-08-31 D3" and "D4" resolve here. Nothing in this ADR is
built, and it grants no rename, migration, release or activation authority
until it is accepted.
**Date:** 2026-10-08 (decisions authored 2026-08-31)
**Boundary:** shared (the naming law and the migration and proof plan are
canonical here; the concrete persisted enum, the surfaces that render it, and
the migration sequencing belong in implementation-specific extensions)
**Authors:** resilience and recoverability lane; split by the architecture lane
at the parent's partial acceptance.

## Context

The parent ADR's Context gives both pressures that produced these decisions:
live sessions degraded to a non-terminal, resumable-looking state whose name
asserted that somebody had chosen it, and a resume capability whose central
precondition was the opposite of the rebind invariant. The parent's D1 (the
closed taxonomy) and D2 (session state as a retained tier, declared deletion
only) are Accepted and bind. This ADR holds what remains open: what the
involuntary recoverable state is called and how the taxonomy and the rename
are migrated and proved.

D4's proof list covers the parent's D1 and D2 as well as D3. Until this ADR is
accepted those items are a proposal, not obligations, except where another
accepted decision already requires them (for example the D8 test plan of
`ADR-2026-10-07-headless-session-shim-adoption.md`).

## Decision

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

- An operator can tell a recoverable session from a finished one from its name,
  without reading a host by hand.
- A reserved `paused` remains available for the deliberate capability, at the
  cost of one unused enum value.
- Consolidating the state fan-out removes a recurring class of contradictory
  readings across surfaces.

### Negative

- The rename is two changes, not one, and the first delivers operator value
  while leaving a known inconsistency between what is displayed and what is
  stored.

### Risks

- **`stalled — host not holding` hardens into a terminal state in practice**
  because nothing ever clears it. Mitigation: it is defined as an ambiguity
  state, it carries an age, and clearing it is an obligation rather than a hope.
- **The display-first rename stalls at display.** Mitigation: the migration is
  named as the completion of this decision, and consolidating the fan-out is
  stated as its precondition rather than its replacement.

## Alternatives considered

- **Keep `paused` and explain it in a tooltip or subtitle.** Rejected: the value
  travels through interfaces, logs, receipts, and operator speech. A gloss
  attached at one surface does not survive the trip, and the name is what people
  repeat.
- **Rename the persisted value first and let surfaces catch up.** Rejected on
  sequencing, not on merit: with independent per-surface translations it yields
  partial renames and a disagreement window. Deferred behind the presentation
  map, not abandoned.
- **Accept D3 and D4 with D1 and D2.** Not taken: the founder accepted D1 and
  D2 on 2026-10-08 and kept these two Proposed.

## Affected documents

On acceptance this ADR amends:

- `014-tui-operator-surfaces.md` — the canonical state presentation map, the
  `stalled` vocabulary and its two sub-states, and the rule that conditions
  render beside states.
- `ADR-2026-08-31-continuous-host-holdings-claim.md` — the holdings claim is what
  makes the two `stalled` sub-states distinguishable without reading a host by
  hand.
- `ADR-2026-08-31-session-recovery-taxonomy-and-state-vocabulary.md` — its
  "Split at acceptance" note records the acceptance of this ADR.

## Affected work items

- Canonical state presentation map consumed by every surface, followed by the
  persisted-value migration.
- The two `stalled` sub-states and their suggested operator actions.
- Conformance fixtures for both shipped proxy-selection failures.

No private tracker references belong in this public ADR.

## Implementation notes

- Build the presentation map as a single module with per-surface render tests
  before touching storage; the tests are what stop the fan-out from regrowing.
- Keep the two `stalled` sub-states derived, not stored. They are a function of
  the current holdings claim, and storing them creates a third thing that can be
  stale.
