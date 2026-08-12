---
status: Accepted
date: 2026-08-12
boundary: shared
split: inline-addenda
---

# ADR-2026-08-12 — The placement composition law: six stages, one authority each, one fallback rule

**Status:** Accepted
**Date:** 2026-08-12
**Boundary:** shared (OSS-canonical here — the law, the vocabulary, and the decision-record shape. The concrete resolver mechanics stay downstream in the platform corpus; D5 states the rule that decides which is which, and settles the standing precedent conflict about it.)
**Authors:** routing-refactor session (Claude Fable 5), with product-owner rulings recorded in D1.2, D1.5 and D2

## Context

### Six accepted decisions, no composition

Placement — deciding where a new execution context lands, and which live peer
receives delegated work — is currently governed by six separately Accepted
decisions plus this corpus's own routing algorithm. Each is locally right. None
of them says how they compose.

- `ADR-2026-08-07-execution-context-pool-and-placement-vocabulary.md` settled the
  **nouns**: execution context, sandbox, pool, capacity profile; pools stay
  single-provider (D6.1); the per-project route is promoted to a named,
  org-authored, project-granted capacity profile (D6.2, undelivered); authors
  name pools, never hosts (D9); there is no burst mechanism and the first
  iteration is failure-triggered routing-around (D7); per-pool grants are
  advisory by deliberate decision, with a recorded exit condition (D8).
- `ADR-2026-08-05-versioned-execution-cell-and-session-reference.md` settled the
  **admission equation**: admission is an intersection, never a rewrite (D4);
  fallback is denied by default with alternatives named in advance (D3); a
  `claim_bound` placement re-runs a narrow-only gate at the claiming host and
  writes a separate immutable receipt (D4).
- `004-sandbox-capability-matrix.md` carries the **routing algorithm**: filter by
  capability, filter by policy, filter by health, take the first surviving pool
  in the profile's declared order, route around acquisition failure.
- `001-layered-execution-model.md` assigns placement to **Layer 3**, names the
  Layer-4 toolchain demand as a scheduler signal, and gives Layer 6 a veto.
- `ADR-2026-06-14-model-host-awareness.md` gave a model identity a `hosts[]`
  list of **inference hosts** "for the future scheduler" — an axis no accepted
  decision has ever reconciled with the closed `PlacementRef` enum.
- `ADR-2026-05-07-daemon-http-control-api.md` ships an **explain surface** whose
  wire shape (`RoutingDecision` + `RoutingTraceStep`) was designed so one
  renderer composes both the local and the hosted view.

Every one of these is a statement about *an* authority. None is a statement
about *the order of authorities*, and that is the gap this ADR closes. The
symptom is not that any single decision is wrong; it is that a reader assembling
them gets four incompatible answers to "what happens when the first choice is
unavailable", two incompatible answers to "who picks the winner", one orphaned
knob nobody owns, and one axis that is either a fifth placement dimension or a
capability constraint depending on which document was read last.

### The four contradictions, stated so they can be checked

1. **Ranking is double-booked.** `004` step 4 says the winner is the first
   survivor in the profile's authored order and that no score exists. The
   hosted resolver ships several ordering policies over the same list. Both are
   Accepted. `ADR-2026-08-07` D7's own trap paragraph — that a load-ratio
   ordering would rank an empty provider-configured pool first, always —
   presupposes a load-ordering policy exists to be trapped by.
2. **Three fallback rules, all Accepted.** An implicit fall to a separately
   authored fallback list; deny-by-default with pre-named alternatives (cell
   D3); implicit routing-around bounded by the profile's order (vocabulary D7).
   These cannot all be true of one dispatch.
3. **A pin-strictness knob is orphaned.** A `strictPinMode`-shaped flag selects
   between "fall to the fallback list" and "fail hard" — and no accepted
   decision after it mentions it. Its authority is undefined, which means the
   behaviour of an explicit pin is undefined.
4. **The inference-host axis is unreconciled.** `hosts[]` names where a model is
   *served* (`direct`, a cloud model gateway, an OAuth CLI surface, `local`).
   `PlacementRef.kind` names where a session *runs*. Both are spelled "host".
   Nothing says whether adding an inference host to the model catalog widens the
   placement enum.

### The precedent conflict about where this decision may live

There is also a boundary question, and it has to be answered before the content
can land anywhere. The capacity-pool re-charter in the platform corpus refused
`shared` on the grounds that an OSS half describing pool selection whose only
working implementation is closed would be a boundary violation. The vocabulary
ADR then landed shared pool and capacity-profile nouns plus the routing
algorithm in `001` and `004` — while `004`'s own ownership table records capacity
profiles as hosted-owned. Both precedents are live, and they point opposite ways
for exactly this ADR. D5 settles it.

### Evidence discipline

The findings behind this ADR came from a sweep of both corpora and of shipped
code across the execution layer and the hosted plane. Per `AGENTS.md`, the
*shape* of a hosted-plane finding is architecture and is cited here; the
measurement is operational data and stays in the private run record. Where this
document says something like "no dispatch has ever been re-placed after its
initial binding", that is a shape, and it is the same shape `ADR-2026-08-07` D7
and `013` already record.

## Decision

**One composition law governs every placement decision this execution layer
makes.** Six stages, each holding exactly one kind of power, evaluated against
one candidate set, and emitted as one decision record. Every existing authority
keeps its power and gains a stage; none gains a new one. Nothing in this ADR
grants any component the ability to *rewrite* a decision — placement authority
stays eliminative, as every accepted text before it already required.

### D1 — The six-stage composition law

| # | Stage | Question | Power it holds | On empty | Owner |
|---|---|---|---|---|---|
| 0 | Intent | What did the author ask for? | Names refs and a preference posture | Documented cascade, then loud error | Author / composer |
| 1 | Permission | *May* this run there? | Hard gate, fail-closed | Typed denial | Layer 6 policy |
| 2 | Viability | *Can* this run there? | Hard filter | Typed, loud, per-candidate | Layer 3 + Layer 4 demands |
| 3 | Preference | Where would we *like* it to run? | Ordering and narrowing only | Typed denial naming the pin | Capacity profile / author pin |
| 4 | Ranking | Which survivor is *best*? | Ordering only, never gating | Not reachable — cannot empty a set | Ordering policy (default: authored order) |
| 5 | Bind | Make it so | Intersection, then narrow-only re-gate | Typed denial + receipt | Admission and claim |

Two properties of the table are normative and easy to miss:

- **The stage order is an authority order, not an evaluation order.** Stages 1
  and 2 are both hard filters and their intersection is order-independent, so an
  implementation may evaluate them in any order — `004`'s algorithm evaluates
  capability before policy and stays correct. What the order fixes is
  **attribution**: a candidate excluded by more than one stage is reported at the
  *earliest* stage that excludes it. A pool that is both forbidden and unviable
  is reported as forbidden, so an operator reading a decision record sees the
  authority that actually governs.
- **Power is monotone down the table.** Stage 1 may only remove; stage 2 may only
  remove; stage 3 may only remove or reorder; stage 4 may only reorder; stage 5
  may only refuse. No stage may add a candidate that an earlier stage removed,
  and no stage may substitute a target that was never a candidate.

#### D1.0 — Intent names refs and a posture, never a machine

A dispatch intent carries the reference types the cell contract already defines
(`ADR-2026-08-05` D2) plus an optional placement intent and a **preference
posture** — a cost/latency/quality vector inherited from the owning scope
downward, which any narrower scope may tighten and no scope may widen.

Authors name pools and intents, never hosts (`ADR-2026-08-07` D9 — unchanged and
not reopened). An omitted axis resolves through the documented default cascade,
which ends in a loud error rather than a silent default; a default never bypasses
admission, and an explicitly named invalid selector never silently falls to a
default. This is `013` § "AgentRuntime dispatch" item 1 restated as a stage.

#### D1.1 — Permission is a hard, fail-closed gate

Everything that answers "MAY" evaluates here: Layer 6 policy rulings,
organization and project policy, model-access rules, spend authorization, plan
entitlements, and per-pool grants. Four semantics are fixed:

1. **Deny by default.** An absent, unreadable or erroring policy ruling
   **denies**. It never falls open.
2. **Explicit forbid always wins**, and **deny is monotone downward** — a forbid
   at a wider scope cannot be re-granted at a narrower one.
3. **Allow-merge is INTERSECTION.** *(Product-owner ruling, 2026-08-12.)* An
   allow must exist at **every** scope in the chain for a candidate to survive.
   The alternative — union, where any scope may grant — was consciously rejected
   in favour of the auditable form: with intersection, "who allowed this?" has
   one answer per scope and an operator can revoke at any level with certain
   effect. The cost is accepted and recorded: removing an allow at a wide scope
   blocks everything beneath it, which is a sharp edge that the effective-policy
   display exists to blunt.
4. **A permission may carry an obligation.** "Permitted, but audit tier full" or
   "permitted, but egress must be logged" is a permitted outcome with a
   condition attached. Obligations are discharged at stage 5 or the bind fails;
   an undischarged obligation is never downgraded into a warning.

Because a fail-closed permission stage makes policy availability a
work-stoppage risk, the policy bundle is part of the evaluable snapshot the
resolver reads (D6 and § "Implementation notes"): the designed posture is
fail-closed against a **stale-but-bounded** bundle whose age is exposed on the
decision record, never fail-open against a missing one.

**Engaging `ADR-2026-08-07` D8 rather than overruling it.** D8 deliberately left
the per-pool grant advisory, because enforcing it without a mature policy engine
and org-admin surface would fail closed for reasons a new user could neither see
nor fix — and it recorded an exit condition. This ADR **does not flip that
switch**. What it does is classify: the grant is a *permission* statement, and
its evaluation point is stage 1. That was the ambiguity D8 left behind — an
advisory grant consulted inside an ordering step is a preference wearing a
permission's clothes. When D8's recorded exit condition is met, enforcement is a
switch at a defined stage plus the backfill D8 already specifies, not a
redesign. Until then the grant is evaluated at stage 1 in advisory mode and the
decision record says so.

#### D1.2 — Viability is the full tuple, and its empty set is always loud

A candidate is viable only if the **whole tuple** holds:

```text
model  ×  harness (adapter version)  ×  auth binding and its portability
       ×  kit / toolchain demands (os, arch, OS-locked command lanes)
       ×  execution-host capabilities (os, arch, declared capability flags)
       ×  lane (persistent / on-demand, per 004)
       ×  serving-endpoint reachability, including the inference host (D4)
       ×  health and freshness
       ×  requested session mode and capability requirements
```

Two of these are named as new *signals*, not new *fields* — the schema for both
already exists and neither is read today:

- **Kit and toolchain demands are the Layer-4 input to this stage.** `001`
  Layer 4 already states that a Kit's toolchain demand is a signal to the
  scheduler; this ADR names the seam it arrives through. Demands compile into
  the intent at composition time, so a job whose kit declares an OS-locked
  command lane demands `os=macos` and can only survive on candidates that
  declare it. Kits still know nothing about substrate providers; providers still
  know nothing about kits.
- **Declared execution-host capabilities are claim-time filter inputs**, not
  merely recorded facts.

**∅ is always loud, and it is typed.** When permission ∩ viability is empty the
resolver emits a typed unsatisfiable decision record carrying every candidate
considered and the stage and named rule that excluded it — "these pools were
considered; these lacked the demanded operating system; these were forbidden by
the named policy at the named revision; these were unhealthy" — plus an audit
event and an instance-level failure. Never a silent queue, never a silent
downgrade, never a dead letter discovered later. When candidates exist that are
*viable but unpermitted*, they are named as such: an operator's next action is
to change a grant, and they cannot take it if the decision record hides the
candidate.

#### D1.3 — Preference narrows and orders; it never widens

The **capacity profile** (`ADR-2026-08-07` D6.2) is the preference authority: an
ordered list of pools plus the policy for choosing among them. This ADR adds
one field to its shape and retires one behaviour:

- **Added: an ordering policy** (D3), whose default is the authored order.
- **Retired: a separately authored fallback list.** The ordered surviving set is
  the fallback set (D2). A profile that carried a second, hand-authored list
  would be a second truth source for the same decision — the objection `004`
  § "Why routing does not pick a provider per session" reason 1 already makes,
  applied one level up.

**Pins are hard *within* the law, and only within it.** An explicit pin — a
pinned pool, a pinned peer, an "always use this binding" — narrows the candidate
set to the pinned target. If the pinned target does not survive stage 1 or stage
2, the decision **fails loud with the pin named**; it never quietly becomes a
preference and never escapes permission or viability. This makes a pin-strictness
mode meaningless, and `strictPinMode` is **retired**: there is no non-strict pin.
The two behaviours it selected between are now the two halves of one rule — a
surviving pin is honoured absolutely, a non-surviving pin fails typed.

Auth mode **reorders, never widens** — a preference for a particular credential
posture may promote candidates inside the surviving set and may never restore a
candidate that permission or viability removed. This is the generalization of
the standing correction that endpoint locality is not an authentication method
(`ADR-2026-08-05` D2) and that auth locality must never again act as a scalar
filter over candidates.

#### D1.4 — Ranking orders, and does nothing else

The routing-intelligence layer — load, cost, warm-workspace affinity, a learned
ranker where one is enabled — **orders the surviving candidates and does nothing
else.** Three invariants:

1. **The candidate set is the failover set.** The ranker may not add, remove or
   substitute a candidate. A ranker that can empty a set is a gate, and gating
   is stages 1–3.
2. **Learning payload is written at decision time or forfeited.** Every decision
   record carries the candidate set, the score vector and weights, the selection
   propensity, an exploration flag, and the ruleset revision. A score
   reconstructed after the fact is not evidence of what the ranker did.
3. **Enabling a learned ordering policy is an administrative act at the
   capacity-owning scope.** *(Product-owner ruling, 2026-08-12.)* The scope that
   owns capacity turns learning on; consuming scopes inherit and may tighten
   (opt out) but never opt in unilaterally. A learned ranker is a
   fleet-wide behavioural change, and a consuming scope cannot consent on
   behalf of the fleet.

Session affinity is a *correctness* input at stage 2, not a scoring input at
stage 4: a live tool loop holds a hard lock on its execution context, and moving
a session mid-flight is a correctness event requiring an explicit release. Warm
workspace, by contrast, is a legitimate stage-4 signal.

#### D1.5 — Bind is transactional, and produces receipts

Stage 5 is `ADR-2026-08-05` D4 unchanged, with obligations added to the
intersection:

```text
declared compatibility ceiling
AND live runtime inventory
AND exact auth-binding proof
AND placement reachability / capabilities
AND requested session and capability support
AND required evidence tier
AND stage-1 obligations discharged
```

The intersection yields an immutable admission receipt before enqueue. A
`claim_bound` placement re-runs the **same predicate set, narrow-only**, at the
claiming host and writes a separate immutable claim receipt; a denied claim
receives no credentials and spawns nothing. A wait-for-capacity gate (a
reservation with a timeout) is a bind-stage mechanism, not an ordering policy —
which is what a class of pools with coarse host granularity actually needs, and
what an ordering value named for reservations could never deliver.

### D2 — One fallback rule

**Fallback is the next candidate in the ordered surviving set. There is no other
fallback.**

- The set is *already* permitted and *already* viable, because it survived
  stages 1–3 before ranking ordered it. Falling to the next candidate therefore
  cannot cross a policy boundary — which is the property that makes automatic
  fallback safe at all.
- **Out-of-set substitution never happens.** No ambient default, no implicit
  primary, no separately authored list consulted after the set is exhausted. An
  exhausted set is a typed failure with the full exclusion trace, not an
  invitation to improvise.
- **A separately authored fallback list is retired** along with the implicit
  fall-through that consumed it, and with `strictPinMode` (D1.3).

**How this honours each of the three rules it replaces.**

- **Cell D3 (fallback denied by default, alternatives pre-named).** Honoured in
  substance and strengthened in mechanism. D3's requirement is that no
  alternative is taken which was not named in advance; this ADR satisfies it by
  *computing* the named set at resolve time and writing it into the decision
  record **before** the first acquisition is attempted. Each candidate is a
  complete cell, so D3's prohibition on assembling a cross-product from axes
  belonging to different alternatives is preserved by construction. What changes
  is only the authoring burden: the alternative list stops being hand-maintained
  per intent and becomes a derivation of the profile the org already authored.
- **Vocabulary D7 (failure-triggered routing-around).** This is D7's named first
  iteration, made normative and given a bound. D7's reasoning is untouched:
  routing around an *observed* failure needs no meter, whereas a predictive
  overflow needs one that does not exist. **Predictive escalation remains
  undesigned and is not authorized by this ADR.**
- **The implicit fall to a separately authored list.** Retired. Its two
  behaviours are recovered: automatic continuation is the rule above; hard
  failure is what an exhausted or pinned-and-unviable set already produces.

**Escalation beyond the surviving set is a permission question, never a router
improvisation.** *(Product-owner ruling, 2026-08-12.)* Reaching capacity that the
profile does not name — metered capacity an entitlement makes available, for
instance — re-enters at **stage 1** as an entitlement grant that widens the
candidate set *before* stages 2–4 run. It is therefore visible in the decision
record as a permission event with a named entitlement, not as a routing
surprise. A capacity profile declares its posture toward this explicitly
(`off | manual | auto-when-entitled`); automatic escalation happens only where
the profile opted in. `ADR-2026-08-07` D7's finding stands unchanged: no
overflow policy, no exhaustion trigger and no schema for either exists today,
and the shape of the hosted plane's dispatch history corroborates it — no
fall-back events, and no dispatch ever re-placed after its initial binding.

### D3 — Ranking reconciled: the authored order is the default ordering policy

`004` step 4 states, of the routing algorithm as a whole, that
`There is no cost/latency score and no cross-provider tie-break`.
As an unqualified property of routing, that is **retired**. As the **default
ordering policy of a capacity profile**, it stands and is what the OSS layer
ships.

- A capacity profile declares an **ordering policy**. The default — and the only
  one the OSS layer implements — is `declared`: take the survivors in the order
  the profile's author wrote, unscored.
- Richer ordering policies are a **hosted extension point**. `004`'s ownership
  table already records capacity profiles as hosted-owned; ordering policies are
  a field of that object and inherit the same verdict. The OSS layer defines the
  *seam* (a profile has an ordering policy; the resolver applies it at stage 4)
  and ships a working implementation of the default, which is what the OSS
  contract requires — never only the type.
- **Ordering never gates.** An ordering policy is a permutation of the surviving
  set. A policy that could drop a candidate would be a filter mis-declared as an
  order, and is refused at the contract level.

**Engaging `004`'s three preserved reasons, one at a time.** That section exists
precisely so this decision is not re-proposed carelessly, so it gets answered
rather than cited.

1. **"A second truth source for one decision."** Answered by locating the policy
   *inside* the same authored object. The objection is to a per-session scorer
   that can override an operator's authored order — two levers pointed at one
   outcome, disagreeing silently. An ordering policy declared **on the profile**
   is not a second lever: it is the operator saying, in the one place they
   already author, *how* their list should be traversed. An operator reading the
   profile reads the order and the policy together, and the decision record
   shows which policy ran.
2. **"It assumes a fungibility the lanes do not have."** Answered by stage
   order. The persistent and on-demand lanes are a **viability** input (stage 2,
   as `004` § "Persistent and on-demand are lanes" already requires). By the time
   stage 4 runs, every remaining candidate can serve this request; the ranker
   therefore never compares candidates that cannot substitute for one another.
   The disjointness `004` protects is preserved by making it a filter, which is
   what it always was.
3. **"Its cheapest-wins default is the wrong default under a real load metric."**
   Accepted without qualification, and it is why the default policy stays
   unscored. `004` already states the precondition — a pool with no enrolled
   machines scores as maximally idle and would rank first, always, so any
   load-ordering policy must fix that before it is offered. This ADR does not
   waive that precondition; it inherits it as a gate on shipping any ordering
   policy other than `declared`.

The reasoning `004` moved out of a scoring function and into profile authoring
stays exactly where `004` put it. What changes is that the profile can now say
*how* to traverse what it named — and the OSS default remains the one a human
can read back off the page.

### D4 — The inference-host axis is a viability input, not a placement kind

`PlacementRef.kind` stays a **closed** enum: `host | pool | sandbox |
remote_peer` (`ADR-2026-08-05` D2, `ADR-2026-08-07` D3). Adding an inference host
to a model's `hosts[]` (`ADR-2026-06-14`) does **not** widen it.

- **`hosts[]` names where a model is served.** It enters the law at **stage 2**,
  through the serving-endpoint axis of the viability tuple: an inference host is
  reachable-or-not, permitted-or-not, and compatible-or-not with the requested
  auth binding. Those are filter questions, and the cell contract already carries
  them on `ServingEndpointRef` and `AuthBindingRef`.
- **`PlacementRef` names where a session runs.** A placement is a thing a session
  is *placed into* and that can hold a lock, a workarea and a claim. An
  inference host holds none of those.
- **The collision is a naming defect, and the fix is qualification, not a
  rename.** `host` here has two referents — the **execution host** (a machine
  offering execution-context slots) and the **inference host** (where a model is
  served). This is `ADR-2026-08-03` D4 rule 1 applied preventively, as
  `ADR-2026-08-08-harness-as-versioned-deliverable.md` applied it: prose in this
  corpus qualifies the noun on first use in any passage where both are in scope.
  Neither wire is renamed by this ADR.
- **What this forecloses.** A future "route this session to Bedrock rather than
  the vendor's direct API" is a *serving-endpoint* decision inside the viability
  tuple and the ordering of complete cells, not a fifth placement dimension.
  `ADR-2026-06-14`'s "for the future scheduler" is answered: the scheduler reads
  it, at stage 2, as a constraint — and the model-level list stays
  representation, with the matrix cell binding-authoritative, exactly as that ADR
  scoped it.

### D5 — Vocabulary, and where the law lives

**Vocabulary (one noun, one referent — `ADR-2026-08-03` D4 rule 1):**

- **Placement** — deciding where a **new execution context** lands.
- **Selection** — deciding **which live peer** receives delegated work.
- **Steering** — session-to-session communication between **live** sessions. Not
  a decision at all: a transport, with its own durability posture.
- **Routing** — the umbrella noun for the decision plane (placement +
  selection). The local daemon's own scheduling is *local routing*.
- **Control flow** — the workflow DAG's gates and edges. This is **not** routing,
  and this corpus stops calling it that.

**Selection is the same law with a different candidate kind.** Candidates are
live peers (`PlacementRef{kind: remote_peer}`); permission is delegability and
scope; viability is skill match, declared capabilities and liveness; preference
is an explicit target pin (which short-circuits, exactly as a pool pin does);
ranking is whatever ordering policy is enabled. "Place a new session" and
"delegate to a live peer" differ only in candidate kind — one law, one record,
one explain surface. Selection is only ever as good as the liveness signal it
filters on, which makes peer liveness a stage-2 correctness concern rather than a
best-effort nicety.

**The boundary ruling — which settles the standing precedent conflict.**

> **The law and the vocabulary are shared and OSS-canonical. The concrete
> resolver mechanics are downstream-platform.**

The rule that decides it is point 2 of the five-point boundary discipline: this
corpus may define an interface only where the OSS layer ships a working
implementation of it. Apply that test:

- The **law** passes. The OSS daemon already makes per-session routing decisions
  over its own inventory and already ships an explain surface for them; it
  evaluates the same six stages against a local candidate set, with the default
  ordering policy and the same decision-record shape. Remove the hosted plane and
  the law still runs.
- The **mechanics** fail. A multi-tenant policy engine, the capacity-profile
  schema and its verbs, ordering policies beyond the default, a learned ranker
  and its governance console, and the compiled ruleset snapshot have no OSS
  implementation and are not going to get one. Describing them here would put an
  interface in this corpus whose only implementation is closed — precisely the
  violation the capacity-pool re-charter refused.

So **both precedents are right, about different halves**, and the conflict was a
category error rather than a disagreement: the re-charter's rule governs the
mechanics, and the vocabulary ADR's precedent governs the law and the nouns.
This ADR is `shared` with `split: inline-addenda` on that basis, and the
platform corpus carries the mechanics as its own document rather than as a fat
stub — a companion, not a mirror.

### D6 — One placement decision record

Every placement and selection decision — hosted or local, successful or
unsatisfiable — emits **one record shape**. The daemon's existing
`RoutingDecision` / `RoutingTraceStep` wire shape (`ADR-2026-05-07` D4) is the
seed, and it was already designed so one renderer composes both surfaces.

Contract-level fields:

| Field | Why it is required |
|---|---|
| Candidate set considered | Without it, "why not X" is unanswerable |
| Per-candidate exclusion: **stage + named rule** | Attribution by the D1 order — earliest excluding stage wins |
| Chosen target | The outcome |
| Ordering policy, score vector and weights | What stage 4 did, in the terms it did it |
| Selection propensity + exploration flag | Written at decision time or forfeited (D1.4) |
| Ruleset revision, snapshot age, degraded flag | Bounded, exposed staleness — never silent staleness |
| Obligations, and whether discharged | A stage-1 condition must be checkable at stage 5 |
| Receipts chain (admission → claim) | Ties the record to the immutable receipts |

Three consequences:

- **Explainability is a contract, not a surface.** A decision that cannot be
  explained from its own record is a defect, not a missing feature.
- **The record is a replay input.** Because it carries the ruleset revision and
  the full candidate set, "what would this profile or policy change have done to
  the last N decisions" is a query rather than a simulation — a safety property
  before it is a product one.
- **Degradation is visible per decision.** An evaluator holding a stale snapshot
  is a designed state, not a failure: it evaluates locally, marks the record
  `degraded` with an age, and keeps claims flowing. Authorization still fails
  closed against the cached bundle; ordering and preference fail static. The
  invariant that in-flight sessions never depend on the control plane is
  restated here as a placement invariant rather than a transport accident.

## Consequences

### Positive

- **"Why did this land here?" has one answer, in one shape, everywhere.** The
  same record explains a local daemon decision and a hosted one, and an empty
  candidate set becomes a typed, named, actionable failure instead of a queue
  that never drains.
- **Four contradictions close, and the closures are checkable.** One fallback
  rule, one ranking authority, a defined pin semantics, and a placement enum that
  stays closed under inference-host growth.
- **Automatic fallback becomes safe by construction.** The set that fallback
  walks is the set permission and viability already approved, so continuing down
  it cannot cross a boundary — the property that made every previous fallback
  design require an argument.
- **The kit toolchain demand finally has a seam.** `001` Layer 4 has always said
  it is a scheduler signal; it now has the stage it arrives at and the tuple slot
  it occupies.
- **The boundary question stops recurring.** D5 gives a test — does the OSS layer
  ship a working implementation of this? — instead of a precedent fight.

### Negative

- **Intersection allow-merge is sharp.** Removing an allow at a wide scope blocks
  everything under it, and no narrower scope can compensate. This is the accepted
  cost of an auditable permission chain; an effective-policy display is a
  requirement of shipping it, not a nicety.
- **Fail-closed permission makes bundle distribution load-bearing.** The layer
  gains a hard dependency on the evaluable snapshot reaching evaluators. Bounded,
  exposed staleness is the mitigation, and it is a real mechanism to build.
- **Decision records are not free.** Writing the candidate set and per-candidate
  exclusions for every dispatch costs storage and write bandwidth, and the
  learning payload must be written on the hot path or it is worthless.
- **Several standing knobs die.** A pin-strictness mode, a separately authored
  fallback list, and a reservation-shaped ordering value are retired rather than
  deprecated. Consumers of those shapes change.

### Risks

- **An ordering policy could be shipped that gates.** The contract forbids it;
  nothing mechanically enforces it yet. Mitigation: the decision record makes it
  visible — a stage-4 entry that removes a candidate is a detectable defect, and
  the exclusion field has no stage-4 value to write.
- **The load-ordering inversion could ship anyway.** `ADR-2026-08-07` D7's trap
  is inherited as a gate on any ordering policy other than `declared`. If it is
  forgotten, failure-triggered fallback becomes unconditional routing to metered
  capacity. Mitigation: the precondition is restated in `004` step 4 where the
  implementer will be reading.
- **The stage boundary could erode in implementation.** The single most likely
  regression is a convenience filter added at stage 4 "just for now". Mitigation:
  one resolver, one predicate set, and a record whose shape has nowhere to put a
  stage-4 exclusion.
- **The OSS default could quietly become the only tested path.** If every hosted
  ordering policy is exercised only downstream, the seam rots. Mitigation: the
  seam is narrow by design — a permutation of a set — and the default is a
  degenerate case of it rather than a separate code path.

## Alternatives considered

- **Keep the authorities separate and document their interaction in prose.**
  Rejected: this is the status quo, and it produced four Accepted contradictions.
  A composition rule that lives only in prose has no place to be violated
  visibly.
- **Let the ranker gate (fold viability into scoring, with a threshold).**
  Rejected. A scorer that can zero out a candidate is a filter with no
  attributable rule, and the resulting decision record cannot say *which*
  constraint excluded a candidate — only that it scored low. Explainability is
  the product; a threshold destroys it. This is also `004` reason 1 in a new
  costume.
- **Union allow-merge (any scope may grant).** Rejected by product-owner ruling
  in favour of intersection. Union is friendlier to a project that needs one
  extra pool and worse at every audit question that matters: with union, a wide
  revocation does not bind, and "who allowed this" has as many answers as there
  are scopes.
- **Add `inference_host` to `PlacementRef.kind`.** Rejected (D4). It would make a
  serving fact into a placement dimension, reopen a closed enum for a constraint
  the viability tuple already carries, and cross the two referents of "host"
  permanently rather than qualifying them.
- **Keep a separately authored fallback list alongside the ordered set.**
  Rejected (D2). Two lists for one decision is the exact defect `004` reason 1
  and `ADR-2026-08-07` D6.1 both refuse, and the hand-authored one cannot stay
  consistent with the profile it shadows.
- **Land the whole design as one platform-only ADR.** Rejected (D5). The law has
  a working OSS implementation — the daemon decides and explains its own
  placements — so hiding it downstream would put the OSS layer in the position of
  implementing a contract it is not allowed to read.
- **Land it as one enormous shared ADR with the mechanics inline.** Rejected: it
  would repeat the fat-stub pattern `BOUNDARY.md` caps at roughly fifty lines,
  and it would put closed-resolver internals in a public corpus.
- **Defer ranking until a meter exists.** Rejected as the wrong shape of caution.
  The meter question governs *predictive escalation* (D2), which stays deferred.
  Ordering an already-approved set needs no meter, and refusing to name the
  authority does not make the hosted ordering policies stop existing.

## Affected documents

Every edit below lands in the same commit as this ADR's `Accepted` status, per
this corpus's accepting-commit rule.

- `001-layered-execution-model.md` — § Layer 3 "The building blocks": the
  composition law and the placement/selection/steering/control-flow vocabulary
  added after the nouns. § Layer 4: the toolchain-demand sentence gains its stage
  and tuple slot. No `BOUNDARY-SYNC` region is touched — the corpus's single
  synchronized region, the five-point boundary contract in `001`, is unchanged,
  so no paired byte-identical edit and no simultaneous-PR rule applies.
- `004-sandbox-capability-matrix.md` — § "The routing algorithm" gains a stage
  map and amended steps 4 and 5; § "Open questions" item 2 is updated for the
  ordering-policy seam; the ownership table gains an ordering-policy row.
  Steps 1–3 are unchanged: they are a correct evaluation order under D1's
  authority/evaluation distinction.
- `013-orchestrator-and-governor.md` — § "AgentRuntime dispatch" item 4 is
  amended to the stage-4 invariants and the single fallback rule; the OSS-vs-SaaS
  table gains a decision-record row and an ordering-policy row; the
  routing-around paragraph points at D2.
- `ADR-2026-08-05-versioned-execution-cell-and-session-reference.md` — forward
  annotation on D3 only: the pre-named alternative set is computed from the
  capacity profile at resolve time rather than hand-authored per intent. D3's
  deny-by-default and one-complete-alternative rules are unchanged.
- `ADR-2026-08-07-execution-context-pool-and-placement-vocabulary.md` — forward
  annotations on D6.2 (the profile carries an ordering policy and a declared
  escalation posture) and D7 (failure-triggered routing-around is made normative
  as the single fallback rule). **R2–R5 are not reopened**, and D1, D2, D3, D5,
  D8, D9 and D10 are untouched.
- `ADR-2026-06-14-model-host-awareness.md` — forward annotation: the `hosts[]`
  axis is a viability-tuple input, not a placement kind (D4).
- `README.md` — curated ADR list entry plus the regenerated index block
  (`scripts/gen-adr-index.sh`; the block is never hand-edited).
- `AGENTS.md` — ADR read-order entry.
- `scripts/retired-claim-lint.sh` — three rules for the claims D1.3, D2 and D3
  retire, added in this same commit as the corpus requires.

Not amended, deliberately: `011-local-daemon-fleet.md` and
`ADR-2026-05-07-daemon-http-control-api.md`. The daemon's decision and explain
surfaces are the seed for D6, and they describe what ships today truthfully; the
enrichment to the full record shape is delivery, and those docs get their edit in
the change that ships it rather than a promissory one now.

## Affected work items

This corpus carries no tracker identifiers (`AGENTS.md`), so the delivery
program is named by shape here and enumerated with identifiers in the platform
corpus's companion ADR:

- **Downstream (hosted plane):** one resolver evaluated at both resolve and claim
  time; the capacity-profile object, its verbs and its migration; the ordering
  policies and the learned ranker's governance; the compiled ruleset snapshot;
  the decision-record store and the hosted explain, dry-run and replay surfaces.
- **In this corpus's own repositories:** kit manifests declare operating-system,
  architecture and command-lane demands (`005`); the composition step compiles
  those demands into the intent; the daemon's claim path evaluates the same
  predicate set it already explains and emits the D6 record shape (`011`,
  `ADR-2026-05-07`); the cell wire types carry the ordered surviving set and the
  exclusion trace (`ADR-2026-08-05`).

## Implementation notes

- **One predicate set, two evaluation points.** Resolve time runs all six stages
  and produces the ordered surviving set plus the admission receipt; claim time
  re-runs the *same* predicates, narrow-only, against the claiming host. Any
  second, independently written re-derivation at claim time is the defect this
  ADR exists to prevent — the two points must share code, not intent.
- **The lane split is a filter input, not a code path.** Persistent and
  on-demand remain disjoint (`004`), but they are disjoint *because a stage-2
  predicate says so*, not because two resolvers exist.
- **The evaluable snapshot is the durability unit.** Policy bundle, capacity
  profiles, pool and execution-host inventory, capability matrix, and whatever
  posterior a ranker holds, versioned together. Evaluators hold last-known-good
  and expose age; every record carries revision, age and a degraded flag.
  An air-gapped deployment is the degenerate case where the snapshot is compiled
  locally and never leaves the building — the same evaluator, no new mode.
- **Reconciliation after a disconnect is a declared policy, not undefined
  behaviour.** "The host came back and two copies of the work are alive" needs a
  profile-level answer (how long until lost, whether to replace, which copy
  wins). Today it has none; naming the field is in scope for the profile shape.
- **Intent assembly belongs to the engine, not to node backends.** Every
  dispatching node type declares its execution requirements and the engine
  assembles the intent and calls the resolver at one seam. A per-node-type
  hand-rolled intent is how the headless and interactive paths diverged in the
  first place, and the divergence is what makes a pin mean two different things.
