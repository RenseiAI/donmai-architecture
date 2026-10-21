---
status: Proposed
date: 2026-10-19
boundary: shared
split: sibling-extensions
amends: ADR-2026-10-05-set-broad-enforce-the-minimum.md, ADR-2026-10-17-sponsored-agent-principals.md
---

# ADR-2026-10-19 — Unattended runs act as a registration principal, never as a bound person

**Status:** Proposed (2026-10-19, on the product owner's ruling of the same day). It is
architecture only, and nothing in it is built. The edits listed under "Affected
documents" land in the commit that flips this record to Accepted. That includes the
paired edit to R3 inside the synchronized region
`adr-2026-10-05-set-broad-enforce-the-minimum`, which lands OSS side first.
**Date:** 2026-10-19
**Boundary:** shared. This record is OSS-canonical for the rule: who an unattended run
acts as, where its authority comes from, how the sponsor is recorded, the removal of
the bound-person mode, how children and revocation behave, and the access check for an
interactive launch. The platform corpus carries a mirrored stub of it, with the
storage, the policy-engine rules, the surfaces and the code touch points.
**Authors:** architecture lane (coordinator draft)

## Context

`ADR-2026-10-05-set-broad-enforce-the-minimum.md` R3 lets the workflow decide who an
execution acts as. Its D3 offers two sources: a **binding** in the workflow's
configuration, or an explicit **run parameter** equal to the authenticated caller.
In practice the binding has meant one thing: a person binds a workflow to themself
("run as me"), and every scheduled, webhook, tracker-event or program-wake run of that
workflow then acts as that person.
`ADR-2026-10-17-sponsored-agent-principals.md` later admitted a sponsored agent
principal as a second kind of actor, but the person binding stayed. A control plane
began to honour it for unattended interactive launches.

Three problems showed up once that path was exercised.

1. **The run impersonates a person who is not there.** An unattended run that acts as
   a bound person holds that person's whole access, with that person's name on every
   record, while nobody is present. That is the "borrows a person" problem from the
   sponsored-agent-principals context, applied to every scheduled workflow.
2. **The binding goes stale silently.** A binding is taken when the person binds. The
   workflow keeps changing after that: someone else edits a launch node, an instance
   freezes a snapshot, or a definition cache delays an unbind. Each of these needs its
   own re-confirmation rule, and every rule widens the surface that has to be proven.
3. **Access means the wrong thing.** The interactive-launch access check asks whether
   the bound person holds a project role. That question is about a human, but the run
   is a standing job that somebody chose to create. Its reach should be the grant set
   chosen for that job.

The platform corpus's agent identity tiers decision (accepted 2026-10-19) already
supplies what replaces the bound person. A **standing role** is a durable
registration: startable at any time, at most one live session, and one mailbox,
memory and history across its sessions. A human's own identity is a separate
**person** kind, bound to the identity provider's user. Agents cannot bind it, and it
is never an agent principal.

## Decision

**An unattended run acts as a registration principal: a standing-role registration
that is a sponsored agent principal. It never acts as a person bound to the workflow.
Its authority is its policy-engine grants and the delegation settings, intersected
down the scope hierarchy. Its sponsor is recorded for accountability, not used as the
identity. The bound-person mode is removed. The parameter mode stays.**

### D1 — Who an unattended run acts as

1. **Unattended defined.** A run is unattended when no authenticated human caller
   started it or is driving it. Schedules, inbound webhooks, tracker and other events,
   queue appends and program wakes are unattended. A manual start, and an approval
   decided by an authenticated human, are attended for the session that human drives.
2. **The actor is a registration.** An unattended run acts as the registration
   principal its workflow is bound to. That principal is a durable standing-role
   registration (a sponsored agent principal, `agent:<org>:<handle>`). It is not the
   person kind, a disposable session identity, or a credential.
3. **No registration, no unattended agent execution.** An unattended run of a workflow
   that needs an actor and has no registration bound is refused at admission with the
   typed missing-actor error (set-broad D3 rule 4). The trigger never fills the gap.
   A system marker such as "schedule" or "webhook" is provenance, not an actor.
4. **Who may bind.** Binding follows sponsored-agent-principals D4 unchanged. Only the
   registration itself, or a human who administers agent principals in the org acting
   from the registration's own administration surface, may bind a workflow to it.
   Authoring a workflow never binds it.

### D2 — Where its authority comes from

1. **Grants and delegation settings, nothing else.** The run may do what the
   registration's policy-engine grants allow and what the delegation settings permit.
   Those settings are the projects it may reach, the cards it may start, its budgets,
   and whether it is dispatch-only (set-broad R4).
2. **Intersected down the hierarchy.** Each term resolves through the cascade, from
   system to org, project, workflow and session (set-broad R1). The minimum binds,
   the binding scope is named, and the registration's own grant in the target project
   is the last term of every admission (sponsored-agent-principals D3 rule 2).
3. **Never the sponsor's access.** The sponsor's roles add nothing to the run, and
   losing one takes nothing away from it. The one exception is the standing check of
   sponsored-agent-principals D1 rule 4: a sponsor who loses the authority to
   administer agent principals suspends the registration until it is adopted.

### D3 — The sponsor is recorded, not used as the identity

1. **Lineage names both.** Every session and record of the run names the registration
   as the actor. The lineage also records the sponsor's user id, so that the
   accountable human can be found from any session without becoming its identity.
2. **Human-only attribution names the sponsor.** Where an attribution must name a
   human, such as a commit co-author credit, it names the sponsor
   (sponsored-agent-principals D5). Everything else names the registration.

### D4 — The bound-person mode is removed; the parameter mode stays

1. **Removed.** A workflow can no longer be bound to act as a person. The "run as me"
   binding, its binding action in the policy engine, and the executor fallback that
   turned a bound person into the run's identity are all removed. There is no
   re-bind-on-edit rule, because there is no person binding to keep fresh.
2. **Kept.** The parameter mode is unchanged. A run may carry an actor parameter only
   when it equals the authenticated caller, or when it is carried from run state that
   an authenticated caller set when the run began (set-broad D3 rule 3). An attended
   run acts as that human.
3. **Two actor sources.** After this record, an execution's actor is either the
   authenticated human of an attended run (the parameter mode) or a registration
   bound to the workflow. There is no third source.

### D5 — Children and revocation

1. **Children run as the registration.** Every session that an unattended run starts,
   and every child of those, acts as the registration. Each one is re-checked at
   every admission and every wake (set-broad D3 rule 5).
2. **Revocation stops every instance.** Retiring or suspending the registration,
   unbinding it from the workflow, or revoking its grant in a project stops the next
   admission or wake of every run that acts as it. A waking run parks with a recorded
   decision. No instance keeps a frozen copy of its actor: the actor and its grants
   are resolved live, never cached across admissions.

### D6 — The interactive-launch access check

1. **The registration's grant replaces the human role.** When an unattended run
   launches an interactive session, the access check asks whether the registration
   holds a live write grant in the target project. It does not ask whether a human
   holds a project role. A read grant does not admit a launch.
2. **Attended launches are unchanged.** When an authenticated human launches the
   session, or an approval by an authenticated human resumes the run into it, that
   human is the session's driver. Their own access in the project is checked as
   before.
3. **No silent fallback.** A launch that has neither an authenticated human nor a
   bound registration is refused with the typed missing-actor reason. It never falls
   back to a person named in configuration, trigger data or the trigger's principal.

## Consequences

### Positive

- An unattended run's reach is a grant set that someone chose for the job, not the
  live and drifting access of the person who once bound it.
- One revocation point. Retiring or suspending the registration, or revoking a grant,
  stops every instance on its next admission or wake.
- The stale-binding rules (re-bind on edit, snapshot revocation, unbind propagation)
  disappear, because no person binding exists to go stale.
- Records separate the agent that acted from the human who answers for it.

### Negative

- Every workflow that should run unattended needs a registration created, granted and
  bound before it runs. Until then it is refused with the missing-actor error rather
  than running as a convenient person.
- Two actor kinds remain to reason about: an authenticated human for attended runs, a
  registration for unattended ones.

### Risks

- **A registration with broad grants is a broad standing capability.** It is mitigated
  by explicit grants (an empty set reaches nothing), the cascade minimum, the sponsor
  standing check, and live re-checks at every admission and wake.
- **Migration exposure.** Any live person binding stops working when the mode is
  removed. A control plane must count its live bindings before removal and move each
  one to a registration or refuse it visibly.

## Alternatives considered

- **Keep the person binding and re-bind on edit.** This re-reads the binding at
  launch, requires re-confirmation after a non-binder edits launch nodes, keeps
  machine callers from launching as the bound person, and propagates an unbind.
  Rejected. Every rule patches the same impersonation, and the run still holds a
  person's whole access with nobody present.
- **A service identity for unattended runs.** It stays rejected (set-broad,
  alternatives). A registration is not minted for the occasion: it is created once,
  named, sponsored and explicitly granted.
- **The person kind as the actor.** Rejected. The person kind is the human's own
  identity, and agents cannot bind it (agent identity tiers). Making it an unattended
  actor would restore the bound-person mode under another name.
- **Derive the actor from the trigger.** It stays rejected (set-broad, alternatives).

## Affected documents

These edits land in the accepting commit.

- `ADR-2026-10-05-set-broad-enforce-the-minimum.md`
  - **R3 (synchronized region, paired with the platform corpus's stub, OSS side
    first).** Proposed text: "An execution acts as the authenticated human who started
    or drives it, through an explicit run parameter, or, when no human is present, as
    the sponsored agent principal that its workflow is bound to. It never acts as a
    person bound by configuration, and never as the principal its trigger type happens
    to carry." The rest of R3 is kept.
  - **D3 rules 1 and 2.** The configuration binding names a sponsored agent principal
    only. Add an amendment note pointing here.
  - **D3 rule 5.** Add "revocation stops every instance" (D5 rule 2).
  - **Alternatives.** Add the person-binding alternative above.
- `ADR-2026-10-17-sponsored-agent-principals.md`
  - **D3.** Add "an unattended run's actor is a sponsored agent principal" (D1 rule 2).
  - **D5.** The lineage records the sponsor id (D3 rule 1).
- `README.md`: index entry and table row for this record, with its status.

## Affected work items

The delegated-authority tracking issue and its executor slice (the actor comes from
the workflow), in the platform corpus's tracker. The platform stub cites them.

## Implementation notes

The platform stub lists the code touch points. They are the provider action executor,
the interactive-launch backend's access check, the server-stamped trigger principal,
the policy-engine schema, and session lineage. A single-machine deployment is
unchanged: the operator who starts the daemon is the actor (set-broad D3 rule 7).
