---
status: Proposed
date: 2026-11-14
boundary: shared
split: sibling-extensions
amends: ADR-2026-10-17-sponsored-agent-principals.md
---

# ADR-2026-11-14 — A grant may name a coordination scope

**Status:** Proposed (2026-11-14). Architecture only: nothing in it is built. It
amends D2 of `ADR-2026-10-17-sponsored-agent-principals.md` (Accepted) and keeps
every other rule of that record. The edits listed under "Affected documents" land
in the commit that flips this record to Accepted. No synchronized region changes.
**Date:** 2026-11-14
**Boundary:** shared. This record is OSS-canonical for the rule: what a grant may
name, how a principal's resolved set is formed, and what the fences, executions and
records do with it. How a control plane stores coordination scopes, which scopes it
offers, who may edit their membership, and its surfaces belong in the platform
corpus, which carries a mirrored stub of this record.
**Authors:** architecture lane

## Context

`ADR-2026-10-17-sponsored-agent-principals.md` D2 gives a sponsored agent principal
one explicit set of project grants. Each grant names one project. The set bounds
every reach, it is never inherited, and every execution runs in a project of the set.
The record rejects org-wide reach by default: a principal that should reach every
project is granted every project.

A control plane now needs one agent principal, a coordinator, to coordinate work
across several projects that belong to one initiative. Three facts make per-project
grants a poor fit.

1. **The list changes.** Projects join and leave the initiative over time.
2. **The list is often a rule.** "Every project", or "the projects that hold work
   items under this item", is how a human states the initiative's reach. It is not
   a list they maintain by hand.
3. **A copied list drifts.** Per-project grants copied from the rule go stale the
   moment the rule's answer changes. Nothing on the copy says why it exists.

A second bound beside the grant set would fix the drift, but it would break D2 rule
1 ("the set is the bound") and D2 rule 2 ("one bound for everything"). This record
keeps one set and lets a grant name more than one project.

## Decision

**A grant may name a coordination scope instead of a single project. The principal
still holds one set: its per-project grants and the member projects of the scopes
it is assigned to, resolved when the reach is used. That resolved set is the only
bound.** D1 to D6 state the rules.

### D1 — A grant may name a coordination scope

1. **Coordination scope.** A coordination scope is a named set of member projects
   that a control plane defines and humans maintain, for example a program or an
   initiative. Its membership is an explicit list of projects or a declared rule.
2. **Assignment is a grant.** Assigning a principal to a coordination scope is a
   grant. A human who may administer agent principals makes it explicitly. It is
   recorded, audited and revocable, like a per-project grant.
3. **Same org.** A coordination scope, its member projects and its assignments
   belong to one org (sponsored-agent-principals D1 rule 6).

### D2 — Still one set, still the only bound

1. **The resolved set.** The principal's set is the union of the projects its
   per-project grants name and the member projects of every coordination scope it
   is assigned to.
2. **Resolved at use.** The set is resolved when the reach is used: at every
   admission, every wake and every call that a fence checks. A project removed from
   a scope leaves the set at once. A project added to a scope joins it at once.
3. **One fence input.** Every fence named in sponsored-agent-principals D2 rule 2
   reads the one resolved set. D2 rule 2 is unchanged: a target outside the resolved
   set is refused, never narrowed (set-broad R2).
4. **A rule that cannot resolve adds nothing.** If a scope's membership rule cannot
   be resolved, the scope contributes no projects, and a call that needed one is
   refused with a typed error. It is never read as "every project". A rule that
   reads work items resolves through the `IssueTracker` provider family and
   degrades explicitly, as sponsored-agent-principals D6 rules 2 and 3 require.

### D3 — Explicit, never default

1. **No assignment, no added reach.** A principal with no assignment reaches only
   what its per-project grants name. An empty set still reaches nothing.
2. **"Every project" only by declaration.** A rule that covers every project is
   allowed only as the declared membership of a coordination scope that a human
   assigned the principal to. It is never the meaning of "unset", "empty" or
   "unresolvable".
3. **Reach changes only by a human's act.** Reach never follows the sponsor and
   never grows by use. It changes only when a human changes a grant, an assignment,
   or a scope's membership, including the declared rule. For a rule, the human's
   act is declaring it: its answer then moves with the facts it reads.
4. **No self-widening.** A principal may not change the membership of a scope it is
   assigned to, or assign itself. Its own writes cannot add a project either: work
   created in a project is a write there, and a write needs that project to be in
   the resolved set already.

### D4 — Executions still stay inside one project

1. **Not an execution scope.** A coordination scope is not an execution scope and
   adds no level to the cascade (set-broad R1). It is a way of naming projects in a
   grant, nothing more.
2. **One project per execution.** Every execution that acts as the principal runs in
   exactly one project of the resolved set and resolves that project's own
   configuration. There is still no project-less execution.
3. **Home project.** A control plane may name a home project for an assignment,
   where sessions started through it begin by default. The home must be a project
   of the resolved set, through the scope or through a per-project grant; when it
   leaves the set, it stops being the home.

### D5 — Access level

1. **Per assignment.** An assignment carries an access level, read or read and
   write, like any grant. A control plane may set it per assignment and may refine
   the write level as sponsored-agent-principals D2 rule 1 allows.
2. **Overlap.** When more than one grant or assignment covers a project, the
   principal's access there is the highest level among them. The principal's own
   access in a target (sponsored-agent-principals D3 rule 2) is that level.

### D6 — Attribution

1. **The project and the path.** An action taken through an assignment records the
   member project it touched and the coordination scope it came through. Where a
   per-project grant supplied the access, the record names that grant instead.
2. **The inventory shows both.** The positive inventory (set-broad R4) lists the
   resolved set, and for each project the grant or scope that puts it there.

## Consequences

### Positive

- A coordinator's reach follows the initiative it serves. Nobody re-copies a
  project list when the initiative changes.
- A record shows why a project is in reach: a named grant or a named scope.
- One bound remains. The fences and the inventory read one set.

### Negative

- Fences must resolve the set at use. They cannot read a stored project list on
  the principal.
- A project list stored on a session is a display snapshot, not the bound. Nothing
  may enforce from it.
- Removal takes effect on the next call. An execution already running in a removed
  project finishes; its next admission or wake into that project is refused.
- A human who edits a scope's membership changes the reach of every principal
  assigned to it, often without looking at those principals.

### Risks

- **A broad rule granted by habit.** "Every project" is one assignment away.
  Mitigation: the assignment needs a human who administers agent principals, is
  recorded and shown in the inventory, and the rule is shown by its text, not only
  by its current answer.
- **Membership edits widen agents.** Someone who may edit a scope but not
  administer agent principals can widen an assigned principal. Mitigation: every
  membership change is recorded, and the control plane decides who may make it.
  The platform corpus states that policy.
- **A rule widened by work-item data.** A rule that reads work items gains a
  project when someone files work in it. Mitigation: D3 rule 4 stops the principal
  from doing this itself, and the record names the scope behind each reach.
- **A failed resolution read as wide.** Mitigation: D2 rule 4. Write that test on
  the input first.

## Alternatives considered

- **Org-wide reach by default.** Still rejected (sponsored-agent-principals,
  alternatives). An unset or empty grant set never means every project. This record
  differs in the respect that rejection names: reach to every project comes only
  from a human's explicit assignment to a scope whose declared membership is every
  project, and the record names that scope.
- **Materialize the scope's membership into per-project grants on the principal.**
  Rejected. A copy drifts the moment a rule-defined membership changes, and a
  copied grant hides why it exists, so a reviewer cannot tell a deliberate grant
  from a stale copy.
- **A second bound for coordination scopes beside the grant set.** Rejected. It
  contradicts sponsored-agent-principals D2 rules 1 and 2, and every fence would
  read two sources.
- **Make the coordination scope an execution scope.** Rejected. It would add a
  level to the cascade and allow executions that belong to no single project.

## Affected documents

These edits land in the accepting commit. None touches a `BOUNDARY-SYNC` region.

- `ADR-2026-10-17-sponsored-agent-principals.md`
  - An amendment note at the head pointing here.
  - **D2 rule 1.** "Each grant names one project" becomes "each grant names one
    project or one coordination scope". The set is the resolved set (D2 rules 1
    and 2).
  - **D2 rule 3.** Add D3 rules 2 and 4: "every project" only by declaration, and
    no self-widening.
  - **D2 rule 4.** "A project of its set" reads as one project of the resolved set;
    the home may be named per assignment (D4 rule 3).
  - **D3 rules 2 and 4.** The principal's own access in a project is the level of
    D5 rule 2. The inventory lists the resolved set and the grant or scope behind
    each project.
  - **D5.** Records name the member project and the scope (D6).
  - **D7 rule 5.** For an agent principal, the allowed projects are exactly its
    resolved set.
  - **Alternatives.** "Org-wide reach by default" gains the distinction above, and
    the materialize alternative is added.
- `ADR-2026-06-20-byoa-requester-registration-record.md`: the head amendment note
  says the allowed projects of an agent principal are "exactly its explicit grant
  set". It becomes "exactly its resolved set". Inbound requesters are unchanged.
- `README.md` and `AGENTS.md`: the index and read-order entries for
  `ADR-2026-10-17-sponsored-agent-principals.md` describe "one explicit set of
  project grants". They gain "a grant names one project or one coordination scope".

Reviewed and unchanged: `ADR-2026-10-05-set-broad-enforce-the-minimum.md`. Its head
note, D3 rule 6 and its alternatives say "an explicit grant set", which stays true,
and R3 inside the synchronized region does not say what a grant names.

## Affected work items

This corpus carries no tracker identifiers. The delivery work is named by shape and
enumerated in the platform corpus's stub.

- **Control plane:** coordination scopes with list or rule membership, the
  assignment as a grant with an access level and an optional home project, set
  resolution at use in every fence, the overlap rule, attribution through the
  scope, and the inventory entry.
- **This corpus's repositories:** none required.

## Implementation notes

- **Additive.** A principal with no assignment behaves exactly as before.
- **Tests are written on the input.** A project removed from a scope is refused on
  the next call; a project added is reached on the next call; an unresolvable rule
  refuses with a typed error and reaches nothing; a principal cannot edit a scope it
  is assigned to; a read assignment refuses a write; a session's stored project list
  is not consulted by any fence. Write each refusal test first and watch it fail.
