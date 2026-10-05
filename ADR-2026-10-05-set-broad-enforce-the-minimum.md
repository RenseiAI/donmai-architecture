---
status: Accepted
date: 2026-10-05
boundary: shared
split: sibling-extensions
---

# ADR-2026-10-05 — Set broad, enforce the minimum: cascaded limits, the workflow-decided actor, the positive capability inventory and dispatch-only

**Status:** Accepted (product-owner rulings, 2026-10-05; no proposal round).
Architecture authority only: implementation, migration, release and activation
follow the delivery program named by shape under "Affected work items". The
reference-doc edits listed under "Affected documents" landed in the accepting
commit.
**Date:** 2026-10-05
**Boundary:** shared (OSS-canonical here: the cascade law, the clamp and refuse
split, the actor rule, the capability inventory, dispatch-only as a tool
allow-list, and the amendment to execution-security composition. The concrete
limit document, entitlement storage, policy-engine rules, admission, refusal
codes, operator surfaces and migration live in the platform corpus's companion
ADR; this corpus holds a thin mirrored stub that carries the four rules below
verbatim.)
**Authors:** architecture lane, filed by the coordinator session

## Context

A control plane that lets one agent start another has to answer four questions,
and today each mechanism answers them separately and differently:

1. **How much may it do?** Limits (children, cost, sessions, tokens, reachable
   targets, model access, execution-security levels) are cascaded through the
   scope chain. Some mechanisms refuse, **at write time**, a value that is
   broader than the value of the scope outside it. The one this corpus states is
   `ADR-2026-09-27-execution-security-levels.md` D2 rule 3. A
   write-time refusal ties the validity of a stored value to its parent's value
   at the moment of writing. A later change upstream can leave the two
   disagreeing with no one told, an author must know and restate every
   upstream value before saving, and the refusal protects nothing, because the
   effective value is the stricter one at evaluation time anyway.
2. **Who is it acting for?** The actor is inferred from the trigger type. A
   manual trigger carries a principal and a schedule or queue trigger does not,
   so whether an agent can act at all depends on how it was started rather than
   on what the workflow says.
3. **What does it know it can do?** An agent is told nothing, or is given a
   prose list of prohibitions. A prohibition is enforced by obedience, and
   obedience weakens as a session lengthens and compaction thins the prompt.
4. **Can it be held to one job?** A coordinator that should only start, steer
   and read other sessions has no way to be held there that does not depend on
   the model following its instructions.

Decisions already Accepted bind this one and are reused, not re-derived:

- `ADR-2026-08-12-placement-composition-law-and-single-fallback-rule.md` D1.1:
  permission is fail-closed, deny is monotone downward, allow-merge is
  intersection. This ADR keeps that law as the evaluation law and removes only
  a write-time mechanism that sat beside it.
- `ADR-2026-09-27-execution-security-levels.md`: strongest wins across the scope
  chain, fail closed, no compiled-in default.
- `ADR-2026-08-08-harness-authority-admission-plane-parked.md` D3: a grant must
  intersect an **executor-attested** inventory, and an admission that grants what
  its executor will refuse is worse than none. The inventory below is the same
  rule applied to what an agent is told.
- `ADR-2026-08-13-capability-realization-registry-and-viability-of-absence.md`:
  an absent realization is a denial, never a downgrade.
- `ADR-2026-10-03-sub-agents-for-dispatched-sessions-and-non-native-harnesses.md`:
  a workflow grants spawning under a max-children cap, and a parent and its
  children share one budget.

## Decision

Four rules. They are stated once here, byte-identical in the platform corpus's
mirrored stub, and elaborated in D1 to D5.

<!-- BOUNDARY-SYNC-START: adr-2026-10-05-set-broad-enforce-the-minimum -->
<!-- This block states the four rules of the set-broad-enforce-the-minimum decision. It is mirrored byte-for-byte in donmai-architecture (canonical) and rensei-architecture (stub). Edit both in paired commits; run scripts/check-boundary-sync.sh. -->

**R1. Set broad, enforce the minimum.** Any scope may store any value for a cascaded limit, including unlimited, without consulting the scopes outside it. The effective value is computed at evaluation time, never at write time, and is never cached across admissions. Numbers take the minimum, lists take the intersection, booleans resolve to the most restrictive value, ordered ladders resolve to the strongest, and an unlimited value contributes nothing. Every effective value reports the scope that binds it, and a tie reports the outermost scope. A stored value that is broader than the effective value is redundant and never effective, and a change at an outer scope applies on the next evaluation.

**R2. Clamp quantities, refuse capabilities.** A request for more of a quantity than the effective value runs at the effective value and says so in the response, the receipt and the inventory. Once a quantity is used up, the next request is refused and names the binding scope. A request for a capability that the effective settings do not grant is refused with a typed error that names the binding scope and a remedy. A capability is never silently narrowed.

**R3. The workflow decides who an execution acts as.** An execution acts as the principal that the workflow's configuration or an explicit run parameter names, never the principal its trigger type happens to carry. A binding is the bound principal's own recorded act, and authored configuration alone is not authority. With no actor, no agent execution runs. Children act as the same actor, whose own access is the last term of every admission.

**R4. Every agent starts with a positive inventory, and a narrow job is a tool allow-list.** An agent starts with the exact list of what it can do and how, derived from the same resolution that admitted it. Prohibitions are not enumerated, and a capability that is absent fails at call time with a typed error. A session restricted to orchestration is enforced below the prompt, as an allow-list on the tools the harness will run and on the credentials the session holds, never as an instruction.

<!-- BOUNDARY-SYNC-END: adr-2026-10-05-set-broad-enforce-the-minimum -->

### D1 — Set broad, enforce the minimum (R1)

The scope chain is the control plane's, outermost first, ending at the session.
A control plane may place a scope for what an account is entitled to between its
outermost scope and its tenant scopes; the law does not care how many scopes
there are.

| Kind of value | Combinator across the chain | Example |
|---|---|---|
| Number | minimum | children per session, daily cost, token budget |
| List | intersection | reachable targets, dispatchable agents, model access |
| Boolean | most restrictive | delegation enabled, dispatch-only |
| Ordered ladder | strongest | the six execution-security dimensions |

1. **Any scope stores any schema-valid value.** The schema is closed: an unknown
   key or an unrecognized version is refused, as everywhere else in this corpus.
   A value broader than the scope outside it saves without error. A scope never
   has to read, restate or know the value of a scope outside it.
2. **Unlimited contributes nothing.** An unlimited number, an absent list and an
   absent boolean inherit. The outermost scope holds a value for every limit
   that must always exist, and an absent or unreadable outermost value fails
   closed exactly as `ADR-2026-09-27-execution-security-levels.md` D2 rule 4
   states.
3. **Evaluation, not storage, is the authority.** The effective value is
   computed at each admission from the values stored at that moment. A tightening
   upstream applies to the next admission with no repair of anything stored below
   it, and a loosening upstream likewise. Nothing caches an effective value across
   admissions. A running session keeps what it was admitted with, as the
   execution-security stamp already does (that ADR's D2 rule 8).
4. **The binding scope is reported.** Each effective value carries the value, the
   scope that bound it and that scope's id. A tie reports the outermost scope, the
   rule `ADR-2026-09-27-execution-security-levels.md` D2 already uses for source
   attribution. A surface shows, for every limit, the stored value, the effective
   value and which scope set it, so an author never has to restate an upstream
   limit to be sure it holds.
5. **Where the law applies.** Delegation limits, cost, session and seat counts,
   model access, reachable targets and the execution-security levels.
6. **Conveniences are not the authority.** A surface may grey out an option that
   is weaker than the effective value. The check that counts is the evaluation.
7. **What is unchanged.** Permission stays fail-closed with intersection as the
   allow-merge. Per-machine narrowing (`ADR-2026-06-06-two-axis-provider-model.md`
   D5) was already an evaluation-time intersection and is untouched. A caller's
   typed parameters against a workflow's base are a different surface and keep
   `ADR-2026-09-28-agent-request-dispatches-a-card.md` D5: a loosening value is
   refused there, never clamped, because it is a malformed configuration rather
   than a request for more of a shared resource.

### D2 — Clamp quantities, refuse capabilities (R2)

| Kind | Examples | Behaviour at admission |
|---|---|---|
| Quantity | cost per run, cost per day, active sessions, active children, token budget, depth | **Clamp.** The request runs at the effective value and a note says so: "children clamped to 6 (set by project)". The note appears in the response, in the receipt and in the inventory (D4). When the quantity is exhausted, the next request is refused with the binding scope, as in "daily limit reached". |
| Capability | delegation itself, reachable targets, dispatchable agents, models, tool and credential scopes, dispatch-only, execution-security levels | **Refuse** with a typed error, at call time, naming the binding scope and a remedy. |

1. **A capability is never silently narrowed.** Handing an agent a narrower set
   than it asked for would let it believe it holds what it does not. A refusal it
   can log and surface is the honest outcome, and `ADR-2026-08-13` already rules
   that an absent realization is a denial, never a downgrade.
2. **A quantity is a shared resource,** so running at the effective value is a
   fair answer to an over-ask, provided it is visible.
3. **A child may ask for less.** A child request for a narrower capability set or
   a smaller quantity is honored. A child request for a broader capability set
   than its parent holds is a capability request and is refused.
4. **Exhaustion is a refusal, not a clamp.** A request with no headroom left
   cannot run at zero, so it is refused with the binding scope and, where a
   daily boundary exists, the time it frees.

### D3 — The workflow decides the actor (R3)

1. **The workflow declares who an execution acts as.** Either the workflow's own
   configuration binds a principal, or the run carries an explicit actor
   parameter. The trigger type never decides. A schedule, a queue append, a
   tracker event and a manual start are all just triggers of a workflow whose
   configuration says who it acts as.
2. **A binding is the bound principal's own act.** It is recorded, attributable
   and removable by the principal it names. A control plane decides which
   principals may bind through its policy engine, and may restrict that later
   without changing this rule. What this corpus requires is that binding
   **another** principal is never possible by authoring: configuration alone is
   not authority.
3. **A parameter is accepted only when it is the authenticated caller,** or when
   it is carried from run state that an authenticated caller set when the run
   began.
4. **No actor, no agent execution.** A workflow that needs an actor and has none
   is refused at admission with a typed error naming the missing actor. A control
   plane warns at publish time when a workflow that takes the actor as a
   parameter has a trigger that cannot supply one.
5. **Children act as the actor.** The actor's own access in the child's target is
   re-checked at every admission, so a lost role stops the next dispatch. A
   long-running run that wakes repeatedly resolves the actor and the limits again
   on every wake, and a revoked binding or a lost role parks it with a recorded
   decision instead of letting it continue.
6. **Accountability follows the actor.** Attribution, including the commit credit
   of `ADR-2026-10-03-commit-coauthor-and-session-trailers.md`, names the actor
   and never a service identity minted for the occasion.
7. **Single-machine deployments** need no control plane for this: the operator
   who starts the daemon is the actor.

### D4 — The positive capability inventory (R4, first half)

1. **What it lists.** The actor, the effective limits with their binding scopes
   and any clamp notes, whether the session is dispatch-only, the targets and
   agents it may dispatch, its peers, its program or run, its remaining budget and
   its execution-security levels.
2. **Positive only.** A prohibition is not enumerated. Whatever is absent is
   absent, and trying it fails at call time with a typed error that names the
   binding scope. This keeps the inventory short and keeps enforcement out of the
   prompt.
3. **Derived, not authored.** The inventory is computed in the same resolution
   that admitted the session, from the composed workflow, the harness and the
   effective settings. It lists only what the executor's attested surface can
   deliver. An inventory that names a capability its executor will refuse repeats
   the failure `ADR-2026-08-08-harness-authority-admission-plane-parked.md` D3
   describes, one layer up.
4. **Rendered into the session's standing instructions,** never into the user's
   first prompt, and kept to a size bound the control plane declares so it cannot
   crowd out the work.
5. **Fresh.** A tool returns live headroom on demand, and every wake of a
   long-running session receives a freshly resolved inventory.
6. **Receipted.** The receipt records a digest of the inventory the session
   started with, the way a role-intent digest is recorded today.

### D5 — Dispatch-only is a tool allow-list (R4, second half)

A session may be restricted to orchestration: starting, steering, stopping and
watching other sessions, reading receipts, messaging peers, recording to its
run, querying its capabilities, and reading repositories.

1. **It is a capability.** It is refused and never clamped, and a true value at any
   scope wins (D1: booleans take the most restrictive).
2. **It does not depend on the prompt.** A long-running frontier-model session
   drifts as compaction weakens the instructions it was given, so the constraint
   is enforced where it cannot drift, in two layers.
   - **The control plane's surface:** only the orchestration tools are exposed to
     the session, and the session holds no credential that can write to a
     repository, so it cannot push whatever it runs.
   - **The harness:** `toolApproval` at `allow-list` with the orchestration set
     as the allow entries (`ADR-2026-09-27-execution-security-levels.md` D1).
3. **Honest limit, stated by name.** A harness that cannot render `allow-list`
   does not enforce the second layer. The inventory then says that the harness's
   native tools remain, and no surface claims enforcement the executor does not
   perform (the mirror of `ADR-2026-08-08` D3). The exit condition is the harness
   rendering the level, proven by the negative fixture
   `ADR-2026-09-27-execution-security-levels.md` D3 already requires.

### D6 — Execution security joins the cascade (amends `ADR-2026-09-27-execution-security-levels.md`)

1. **Same chain, same law.** The levels cascade through the scope chain with R1.
   A control plane may add entitlement scopes between its outermost scope and its
   tenant scopes. An organization's levels are a floor for every project and
   workflow beneath it, whatever those authors store.
2. **No write-time refusal.** Any scope may store any level. A stored level weaker
   than the inherited one is redundant, displayed as such with the scope that
   binds, and never effective. D2 rule 3 of that ADR is replaced, and the
   `execution_security_weakening_refused` code is retired with it.
3. **A minimum carried on a request is stage-0 intent.** One below the inherited
   level is redundant. It cannot lower anything, as before.
4. **Unchanged.** Strongest wins; fail closed on an absent or unreadable
   outermost value; no compiled-in default; list contents authored only at the
   workflow scope and composed monotonically (rule 7); the stamp fixed at
   admission and tightening with its parent (rule 8); every session mode gets the
   same levels (rule 5); no in-band override (rule 6).
5. **Transmission needs no wire change.** The stamp's per-dimension `sources` is an
   opaque reference and the digest covers levels only, so a new scope in the chain
   reaches the runner as an ordinary source.

## Consequences

### Positive

- An author sets what they mean and never has to restate an upstream limit. An
  upstream change applies on the next admission with no repair pass.
- One cascade serves delegation, cost, seats, model access, reachable targets and
  execution security, so a surface can say which scope binds any of them.
- Whether an agent can act no longer depends on how it was started.
- An agent knows what it can do and cannot be talked out of a hard constraint by
  a long session, because the constraint is enforced below the prompt.
- Over-asks on quantities degrade instead of failing, and the note says so.

### Negative

- Stored values can disagree with effective ones. A surface must show both, or
  authors will read the stored value as the truth.
- A write that used to fail loudly now succeeds quietly. The visible "set by"
  attribution is the replacement for that loud failure and must not be omitted.
- Clamping hides the difference between what was requested and what ran unless
  the note is carried everywhere it is read.
- Dispatch-only is not fully enforced until each harness renders `allow-list`.

### Risks

- **A clamp read as a grant.** An agent that ignores the note believes it got what
  it asked for. Mitigation: the note rides the response, the receipt and the
  inventory, and capabilities are never clamped.
- **A broader value at an outer scope after an author relied on a narrower one.**
  Setting broad means the inner value now binds. That is the intended behavior and
  the reason surfaces show both values.
- **A binding used after its author's access changes.** A bound workflow acts with
  its binder's access. Mitigation: access is re-checked at every admission and
  every wake, a binding is removable by the principal it names, and the policy
  engine can restrict who may bind.
- **Tightening an execution-security scope empties candidate sets.** Unchanged
  from `ADR-2026-09-27-execution-security-levels.md`: loud and typed by design.

## Alternatives considered

- **Keep write-time refusal of a broader value.** Rejected. It forces an author to
  know and restate every outer value, goes stale silently when an outer value
  changes, and protects nothing that evaluation does not already guarantee.
- **Clamp everything.** Rejected for capabilities: a silently narrowed capability
  set lets an agent believe it holds access it does not.
- **Refuse everything.** Rejected for quantities: an over-ask on a shared resource
  has a sensible partial answer, and refusing it stops work that could run.
- **Derive the actor from the trigger.** Rejected. It makes the same workflow
  behave differently by how it is started and gives a schedule no actor.
- **A service identity for unattended runs.** Rejected. Accountability then names
  nobody, and the access the run holds is not any person's.
- **List prohibitions in the prompt.** Rejected. It spends the prompt on what the
  agent cannot do, and the constraint lasts only as long as the model follows it.
- **A separate coordinator class with its own limits.** Rejected. A coordinator is
  an agent card, a model profile and the capabilities a workflow wires in. A
  broader coordinator is broader settings, not a special object.

## Affected documents

Every edit below landed in this ADR's accepting commit.

- `ADR-2026-09-27-execution-security-levels.md` — D2 rule 3 replaced, the D5 code
  table loses `execution_security_weakening_refused`, an amendment note at the
  head, and the Consequences line stays true.
- `scripts/retired-claim-lint.sh` — rule `WRITE_TIME_WEAKENING_REFUSED` for the
  retired claim.
- `README.md`, `AGENTS.md` — index and read-order entries; the entries for
  `ADR-2026-09-27-execution-security-levels.md` no longer say weakening is refused
  at write time.

No other `BOUNDARY-SYNC` region changes. This ADR adds one, with the id
`adr-2026-10-05-set-broad-enforce-the-minimum`, carried verbatim in the platform
corpus's mirrored stub.

## Affected work items

This corpus carries no tracker identifiers; the delivery program is named by shape
and enumerated in the platform corpus's companion ADR.

- **Control plane:** the cascade engine, entitlement and tenant limit stores, the
  actor binding and its policy rule, admission with typed refusals, the inventory
  and its tool, the dispatch-only surface, and the execution-security scope and
  write-path changes.
- **This corpus's repositories:** the runner renders `toolApproval: allow-list` per
  harness, followed by a lock-step release of the composing binary.

## Implementation notes

- **One predicate, evaluated at admission.** The effective value, its binding scope
  and any clamp note come from one resolution. A second derivation of the same
  value at another point is the defect `ADR-2026-08-12-placement-composition-law-and-single-fallback-rule.md`
  exists to delete.
- **Tests are written on the input.** The binding tests assert that a value stored
  broader than its outer scope saves, that the effective value is the outer one,
  that the binding scope is named, and that a capability over-ask is refused while a
  quantity over-ask runs clamped with the note. Write the refusal test first and
  watch it fail.
