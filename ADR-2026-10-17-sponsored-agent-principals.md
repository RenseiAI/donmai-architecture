---
status: Accepted
date: 2026-10-17
boundary: shared
split: sibling-extensions
---

# ADR-2026-10-17 — Sponsored agent principals: an agent identity with a human sponsor, a named handle and one explicit grant set

**Status:** Accepted (2026-10-17, product-owner acceptance of the rulings of
2026-10-12; no further proposal round). Architecture authority only: nothing is
built, and implementation follows the delivery program named by shape under
"Affected work items". The edits under "Affected documents" landed in the
accepting commit, including the paired edit to R3 inside the synchronized region
`adr-2026-10-05-set-broad-enforce-the-minimum`.
**Date:** 2026-10-17
**Boundary:** shared (OSS-canonical here: what a sponsored agent principal is, its
identity, sponsor, handle and grant set, how it resolves the cascade, who may bind
it, attribution, and tracker neutrality. Storage, the policy-engine rules, operator
surfaces, routing among several agent principals in one project, approval
audiences and the concrete work-item scope type live in the platform corpus's
companion ADR; that corpus carries a mirrored stub of this one.)
**Authors:** architecture lane

## Context

`ADR-2026-10-05-set-broad-enforce-the-minimum.md` makes the workflow decide who an
execution acts as (R3, D3) and rejects two shortcuts: a service identity for
unattended runs, because accountability then names nobody, and a separate
coordinator class with its own limits. In practice that leaves one kind of actor:
a person. Three forces push against that.

1. **A long-running coordinator agent borrows a person.** An agent that starts,
   steers and reads other sessions across several projects, around the clock,
   acts today as the person who launched it. Every session it starts is that
   person's act, every record names that person, and its reach is that person's
   whole access. One person cannot carry several such agents with distinct names,
   cursors and reaches.
2. **A person's access is the wrong bound.** The access such an agent needs is a
   deliberate set of projects chosen for its job. A person's access grows and
   shrinks for reasons that have nothing to do with the agent.
3. **The record the corpus needs already exists for inbound agents.**
   `ADR-2026-06-20-byoa-requester-registration-record.md` names a durable,
   registered principal, distinct from its credentials, with a handle unique in its
   org, a project allow-list and a lifecycle. It covers an external agent that
   submits work. It does not cover an agent that acts inside the control plane as
   the actor of its own executions.

The rejection of a service identity holds: accountability must reach a person.
What the corpus lacks is an agent identity that is not minted for the occasion:
created once, by a named human who answers for it, with a reach that someone chose.

## Decision

**A sponsored agent principal is a first-class, durable identity for an agent. An
accountable human (its sponsor) creates it once; it carries a named handle, holds
one explicit set of project grants, and resolves the permission cascade like any
principal. It may be the actor of R3.** D1 to D6 state the rules. D7 lists the
amendments to the canonical texts that bind it.

### D1 — A first-class identity with a sponsor and a handle

1. **First-class.** A sponsored agent principal is a principal in its own right. It
   is not a person's session, a delegated slice of a person's access, or a
   credential. Its credentials are bound to it and rotatable, exactly as the
   requester registration binds its credentials (that ADR's Decision 1 and 3).
2. **Identity.** Its canonical identity is `agent:<org>:<handle>`. The handle is
   chosen at creation, is unique in the org across every kind of registered
   principal, and is never derived from a person's identity. A person's own
   identity is never an agent principal.
3. **Sponsor.** The human who creates it is its sponsor, recorded on it. Only a
   human with authority to administer agent principals in the org may create one.
   The agent never acts as its sponsor and never holds its sponsor's access. The
   sponsor answers for having created it.
4. **The sponsor's standing is re-checked.** If the sponsor loses the authority to
   administer agent principals, the principal is suspended at its next admission
   or wake until another human with that authority adopts it, and the adoption is
   recorded. This is set-broad D3 rule 5, "re-checked at every admission and every
   wake", applied to the accountable human.
5. **Lifecycle.** It follows the registration lifecycle (that ADR's Decision 2):
   only an active principal resolves, and a credential bound to a principal in any
   other state authenticates to nothing dispatchable. Suspension (rule 4) disables
   it until it is adopted. Retirement revokes its grants and credentials, stops its
   live sessions, and keeps every record it authored. A retired principal is never
   reactivated; a new one is created instead.
6. **Never across orgs.** The principal, its grants and its sessions belong to one
   org.

### D2 — One explicit grant set

1. **The set is the bound.** A principal holds one explicit set of project grants.
   Each grant names one project and an access level: read, or read and write. A
   control plane may refine the write level (for example, to say which principal
   receives unaddressed work in a project) without adding a second bound.
2. **One bound for everything.** The set bounds every reach the principal has:
   starting and steering sessions, dispatching work, observing sessions, reading
   and writing run records, discovering and messaging peers, and writing to a
   work-item tracker. Reads need any grant; writes need a write grant. A target
   outside the set is refused, never narrowed (R2).
3. **Explicit, never inherited.** The set is granted by a human who administers
   agent principals. It never follows the sponsor's access and never grows by use.
   **An empty set reaches nothing**; "unset means org-wide" does not apply to an
   agent principal.
4. **Executions stay inside a project.** Every execution that acts as the principal
   runs in a project of its set. A control plane may name one project of the set as
   the principal's home, where its sessions start by default. An agent principal
   adds no scope to the cascade and creates no project-less execution.
5. **No quantities on the principal.** It stores no numeric limit. Cost, sessions,
   children and every other quantity come from the cascade (R1), clamped and
   reported exactly as for a person.

### D3 — It resolves the cascade like any principal

1. **An actor of either kind.** Wherever the cascade, admission or the positive
   inventory takes an actor, the actor is a person or a sponsored agent principal.
   No scope is added to the chain, and no rule of R1, R2 or R4 changes.
2. **Its own access is its grant.** The actor's own access in the target, the last
   term of every admission (set-broad D3 rule 5), is the principal's live grant in
   that project. A setting that resolves to "the actor's projects" resolves to its
   grant set.
3. **Children act as it.** A session that acts as the principal, and every child of
   that session, acts as the principal and is re-checked at every admission and
   every wake. A revoked grant stops the next dispatch into that project.
   Suspension or retirement parks a waking run with a recorded decision.
4. **The inventory names it.** The positive inventory (R4) names the agent principal
   as the actor and lists its grant set as the projects it may reach.
5. **A kind of principal, not a class of session.** Its authority comes from its
   grants and the effective settings, never from being an agent. The set-broad
   rejection of a separate coordinator class stands: a broader coordinator agent is
   a broader grant set and broader settings, not a special object.
6. **Single-machine deployments are unchanged.** The operator who starts the daemon
   is the actor (set-broad D3 rule 7). A single-machine deployment needs no agent
   principal and loses nothing without one.

### D4 — Who may bind a workflow to it

1. **Itself, or a human who administers it.** A workflow is bound to act as a
   sponsored agent principal only by the principal's own act (a session acting as
   it) or by a human who administers agent principals in the org, acting from the
   principal's own administration surface. Authoring a workflow never binds it:
   configuration alone is not authority (R3).
2. **Not a project's author.** A person who may edit a project's workflows but does
   not administer agent principals may not bind one. The binding would lend the
   principal's reach in other projects to a workflow in theirs.
3. **Recorded and removable.** Every bind and unbind is recorded and attributable,
   and is removable by the principal or by a human who administers it. A control
   plane's policy engine may restrict binding further.

### D5 — Accountability and attribution

1. **Records name the agent.** Receipts, audit records and run records name the
   agent principal by handle, and the session, as the actor.
2. **A human is always reachable.** Where an attribution must name a human, it names
   the sponsor, the one stable human for a principal that a schedule or a queue can
   wake. `ADR-2026-10-03-commit-coauthor-and-session-trailers.md` leaves to the
   control plane whose credit a session carries; for an agent principal, that credit
   is the sponsor.
3. **Not minted for the occasion.** A sponsored agent principal is created once, by
   a named human who is on record, with a reach that human chose. That is the line
   set-broad D3 rule 6 draws, and accountability still never names a service
   identity minted for the occasion.

### D6 — Tracker-neutral

1. **Nothing in the principal names a tracker.** Its identity, grants, resolution
   and binding are defined without reference to any work-item tracker. A deployment
   with no tracker can create and use one.
2. **A work-item scope is tracker-neutral.** A control plane may narrow a grant to
   part of a project's work items (a subtree of items, a container, a label set or a
   saved query), so that several agent principals can share one project. The scope
   is expressed in terms any tracker can supply or refuse, and it is resolved through
   the `IssueTracker` provider family (`002-provider-base-contract.md`), never by
   reading one tracker's fields.
3. **Degradation is explicit.** A tracker that cannot supply what a scope asks for
   (no hierarchy, no manual order, no blocking relations) degrades the scope to one
   it can supply. The effective scope and what it degraded from are reported
   wherever the scope is shown. A scope that cannot be resolved at all is refused
   with a typed error, never treated as unscoped.
4. **Issues remain human intent** (`001-layered-execution-model.md` Principle 1). A
   scope reads the hierarchy humans built; nothing creates work items to decompose
   work.

### D7 — Amendments to the canonical texts

1. **Set-broad R3**, inside the synchronized region
   `adr-2026-10-05-set-broad-enforce-the-minimum` and edited in both corpora in
   paired commits, OSS side first: the actor is a person or a sponsored agent
   principal, and a binding of a sponsored agent principal may also be the recorded
   act of a human who administers it.
2. **Set-broad D3 rule 2** gains the second binding route of D4.
3. **Set-broad D3 rule 6** gains D5.
4. **Set-broad alternative "A service identity for unattended runs"** stays rejected
   and is narrowed: a sponsored agent principal is not one.
5. **The requester registration record** gains the second kind. A registration is
   one of two kinds, fixed at creation: an inbound requester
   (`external:<org>:<handle>`) or a sponsored agent principal
   (`agent:<org>:<handle>`). Both kinds share the handle namespace, the credential
   binding, the resolve-at-dispatch gate and the lifecycle. For an agent principal
   the allowed projects are exactly its grant set, and an empty set reaches nothing.
   Every reader checks the kind.

## Consequences

### Positive

- A long-running coordinator agent stops borrowing a person. Each one has its own
  handle, records, reach and audit trail, and several can run side by side in one
  project.
- The reach an agent holds is the reach someone chose for it, not whatever its
  launcher happens to hold.
- The record and fences already defined for inbound requesters serve it; there is
  no second identity record.
- Accountability still reaches a person: the sponsor.
- Work-item scoping does not assume one tracker.

### Negative

- R3 now has two kinds of actor, and every admission, inventory and attribution
  path must handle both.
- The registration record holds two kinds of principal, and every reader must check
  the kind.
- A human who administers agent principals can lend an agent's reach to a workflow
  by binding it. The act is recorded, but nobody else reviews it by default.
- Tracker providers must declare which scope capabilities they supply.

### Risks

- **An orphaned principal**, whose sponsor leaves or loses authority. Mitigation:
  suspension at the next admission or wake until adopted (D1 rule 4).
- **Reach leaks through a binding.** Mitigation: only the principal or a human who
  administers it may bind (D4), and every bind is recorded and removable.
- **An empty grant set read as unlimited**, because the requester record's "unset
  means org-wide" carries over. Mitigation: D2 rule 3 and D7 rule 5; write the test
  on that input first.
- **A degraded scope read as exact.** Mitigation: the effective scope and its
  degradation are shown wherever the scope is (D6 rule 3).
- **Agent principals as a back door to a service account.** Mitigation: creation
  needs a human who administers agent principals, recorded as the sponsor, and a
  principal without an adopted sponsor is suspended.

## Alternatives considered

- **Keep the person as the only actor**, with the agent acting as whoever launched
  it. Rejected: one person cannot carry several agents with distinct names and
  reaches, and the agent's reach becomes that person's whole access.
- **A delegated slice of a person's access, limited to a verb set.** Rejected: it
  keeps a person accountable for work they never see, and it would be replaced by
  this record anyway.
- **A service identity for unattended runs.** Still rejected (set-broad
  alternatives). A sponsored agent principal differs in exactly the respects that
  rejection names: it is created once, it is named, its sponsor is on record, and
  its reach is an explicit grant set.
- **A new identity record beside the requester registration.** Rejected: it would
  duplicate the handle namespace, the credential binding, the project fence and the
  lifecycle, and every fence would read two sources.
- **A separate coordinator class with its own limits.** Still rejected (set-broad
  alternatives): an agent principal stores no quantities and is bounded by the
  cascade like a person.
- **Org-wide reach by default.** Rejected: reach is explicit. A principal that
  should reach every project is granted every project.

## Affected documents

Every edit below landed in this ADR's accepting commit.

- `ADR-2026-10-05-set-broad-enforce-the-minimum.md` — R3 inside the synchronized
  region `adr-2026-10-05-set-broad-enforce-the-minimum`; an amendment note at the
  head; D3 rules 2 and 6; the "service identity" alternative.
- `ADR-2026-06-20-byoa-requester-registration-record.md` — an amendment note for
  the second registration kind (D7 rule 5).
- `README.md`, `AGENTS.md` — index and read-order entries; the set-broad entries
  note the R3 amendment; the generated ADR index.

The synchronized region changes in R3 only. Its paired edit is in the platform
corpus's mirrored stub of `ADR-2026-10-05-set-broad-enforce-the-minimum.md`, landed
after this one. The platform corpus also carries a mirrored stub of this ADR and
the companion ADR that realizes it.

## Affected work items

This corpus carries no tracker identifiers; the delivery program is named by shape
and enumerated in the platform corpus's companion ADR.

- **Control plane:** the agent principal kind on the registration record, its grants
  and their materialized project set, the sponsor and its standing check, a session
  credential that resolves to the principal, an actor of either kind in the cascade
  resolver and admission, the binding rule in the policy engine, attribution, and the
  tracker-neutral work-item scope on the `IssueTracker` family.
- **This corpus's repositories:** none required. A composing binary may expose agent
  principals in its own command tree.

## Implementation notes

- **Additive.** The new kind is opt-in; every existing registration keeps its kind
  and behaviour.
- **Tests are written on the input.** An empty grant set refuses every target; a
  read grant refuses a write; a project author cannot bind; an administrator's
  binding is recorded and removable; a sponsor's lost authority suspends the
  principal at its next admission; a degraded scope reports its degradation. Write
  each refusal test first and watch it fail.
