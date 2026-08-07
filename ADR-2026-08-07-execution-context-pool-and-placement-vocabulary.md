---
status: Proposed
date: 2026-08-07
boundary: shared
split: inline-addenda
---

# ADR-2026-08-07 — Execution context, pool, and placement: one noun per referent, and where unlike capacity composes

**Status:** Proposed
**Date:** 2026-08-07
**Boundary:** shared
**Authors:** mark, agent:claude

## Context

### The question that prompted it

> Execution / Capacity pools were meant to bring capacity to project needs
> without the end user needing to choose a specific host, account, config per
> workflow. The issue is, they currently only support bundling together like
> capacity since a pool has only one provider configured as the flavor of the
> pool. I don't think this is an immediate issue, but it does confuse some of
> the wording of the [product's] building blocks.

Alongside it, four baseline positions, offered as design input rather than
settled decisions: the role that onboards capacity is usually not the role that
authors workflows, so provisioning belongs at org level with access handed out
per project; organizations will not want execution single-threaded per laptop;
bursting from exhausted local capacity (token or system) to cloud capacity is
expected; and **"the term sandbox is just an execution context (local, e2b, k8s,
etc). So it's a single unit. A pool is a collection of them."**

A second observation arrived with it: harness is the biggest missing node in the
composition category — composing `harness:claude-code` × `model:<some model>` ×
an ephemeral cloud execution context is what determines how capabilities get
wired into a run — and yet harness is not a composition input at all today; it
is derived from the model profile. Meanwhile `sandbox` **is** in the composition
schema and was deprecated in favour of a capacity-pool reference by a
2026-05-21 runbook that no ADR in either corpus records.

So the open question was posed as: is the realisation surface
`(harness, model, sandbox)` or `(harness, model, pool)` — and what is a pool, if
a sandbox is the unit?

### The short answer, stated before the evidence

**The model is mostly right and the wording is mostly wrong.** This ADR is
therefore weighted toward renames and reconciliation, and is deliberately thin
on new mechanism. Three findings drive that:

1. **The realisation surface is neither of the two candidates, and it is already
   Accepted.** `ADR-2026-08-05-versioned-execution-cell-and-session-reference.md`
   D2–D4 makes it five independent axes — `HarnessRef`, `ModelRef`,
   `ServingEndpointRef`, `AuthBindingRef`, `PlacementRef` — plus session mode and
   capabilities. **Placement is one axis**, whose `kind` discriminates
   `host | pool | sandbox | remote_peer` and whose `resolution` discriminates
   `exact | claim_bound`. Pool-versus-execution-context was never a choice
   between two axes.
2. **Harness as a first-class, independently-selected axis is also already
   Accepted** (`ADR-2026-06-06-two-axis-provider-model.md` D1;
   `ADR-2026-08-05` D2/D3/D4; `001-layered-execution-model.md` § "The executable
   unit"). Deriving harness from model or provider identity is already ruled a
   defect: `ADR-2026-06-06` D4 deletes the imperative provider-rewrite, and
   `ADR-2026-08-05` D8 requires any harness inferred from a legacy provider
   mapping to be recorded as a `legacy_inference` resolver decision. The
   observation "harness is not a composition input" is **true of the code and
   false of the corpus**. It needs delivery, not deliberation.
3. **One-provider-per-pool was never decided.** No ADR in either corpus states
   it, defends it, poses it as a question, or lists it as a rejected alternative.
   It exists only as a single provider field threaded through the closed
   resolver. The premise in the framing above is correct, and there is no
   position to overturn — only one to take.

### Where the corpus and the code disagree

Recorded plainly, because two documents in this area assert things the code
contradicts, and because several recent ADRs in this corpus already carry honest
non-implementation checkpoints that a reader should not mistake for shipped
behaviour.

- **`004-sandbox-capability-matrix.md` has not been touched since this repo's
  initial public release** (`a22bd3d`, 2026-05-24). Its header still reads
  `Last updated: 2026-05-06`. It therefore predates the two-axis provider model
  (2026-06-06), the SDK axis freeze (2026-06-14), the CLI noun tree (2026-08-03),
  and the execution cell (2026-08-05); it contains zero occurrences of
  `DispatchIntent`, `ResolvedExecutionCell`, `AdmissionReceipt`, or
  `PlacementRef`. Two specific claims in it are now counterfactual:
  - **It advertises burst routing that does not exist.** `004` § "OSS vs SaaS
    division of labor" carries the row `Capacity-aware burst routing | ✅ ships
    local-only | ✅ ships hybrid (local + cloud)`, and its opening premise (`:9`)
    is scaling "cloud-burst across multiple providers." The platform corpus
    records the opposite: the routing column that carried burst intent was hard
    deleted as one of seven behaviourally-dead knobs, and its own Consequences
    section names the loss — the *names* documented an intent that now has no
    schema footprint at all. Burst was schematised, never wired, then deleted.
  - **It specifies a per-session cross-provider scheduler that the accepted
    routing model rejects.** `004` § "The cross-provider scheduler" defines
    `SandboxScheduler.schedule(spec, hints)` with `preferredProviders` /
    `forbiddenProviders` / cost + latency budgets, filtering by capability then
    policy then capacity and picking the lowest-scored *provider* per session —
    i.e. per-session routing across providers, heterogeneous by construction.
    The accepted platform decision is that substrate kind is an
    implementation-detail of a pool and not a standalone routing dimension, with
    ordering coming from per-project pool lists; a second global
    substrate-priority lever was explicitly rejected as a conflicting truth
    source. Both are labelled canonical in their own corpus. `004` has never
    been amended to reconcile.
- **`001`, `006`, and `013` carry stale `Last updated:` headers** while their
  bodies are current (each has commits dated later than its header). Judge
  freshness from `git log`, not from the header line.
- **Two accepted vocabularies describe the pool↔context relation differently.**
  `ADR-2026-08-05` D2 makes `pool` and `sandbox` **sibling kinds of one axis**.
  The operator wire and `ADR-2026-08-03` D1/D4 make a pool a **container of live
  instances** discriminated by `instanceKind: persistent_host |
  on_demand_sandbox`. Only the second matches the "a pool is a collection of
  them" intuition. Neither has been amended to acknowledge the other. D3 below
  resolves this without changing either contract.

### The mechanical root of the wording confusion

`ADR-2026-08-03` D4 rule 1 states: *"One noun, one referent, at every depth. A
word may not appear at two depths meaning different things."* That rule was
applied to `host` and `provider`. It was never applied to `pool` — which today
has **four live referents**, three of them in this corpus:

| # | Referent | Where |
|---|---|---|
| 1 | The org-owned capacity pool (a routing primitive) | platform corpus, throughout |
| 2 | **One machine.** "one long-running daemon per machine, registers as a worker pool" | `013-orchestrator-and-governor.md:160`; same usage `004:350`, `004:444`, `004:471` |
| 3 | **The warm cache of prepared workareas** | `003-workarea-provider.md:239-241`; `011-local-daemon-fleet.md:419-420` (`GET /api/daemon/pool/stats`, `POST /api/daemon/pool/evict`), `011:510` (`donmai daemon stats --pool`) |
| 4 | **This machine's local disk envelope**, `capacity.poolMaxDiskGb` | `011:513`; `ADR-2026-08-03:104` |

`sandbox` carries three live meanings as well: the provider family and execution
context kind (this corpus, correct); a deprecated composition-schema field in the
closed control plane; and a legacy per-project setting whose CLI verb still
ships. Both of the latter two actually resolve to capacity-pool rows — so even
the "sandbox as a unit" surfaces are pool pointers. And one shared ADR in this
corpus already slides between the nouns: `ADR-2026-06-01-code-survival-pool-execution.md:31`
writes "the **user-configured capacity pool / sandbox**" as a single
interchangeable phrase.

That is the confusion. It is a naming failure with a rule already on the books,
not a missing abstraction.

### What is decided-and-built, decided-and-not-built, and never decided

The distinction matters for what this ADR is allowed to assert.

- **Decided and built:** pool as the routing primitive with capability filtering
  before policy; pool serving as two independent booleans; the CLI noun tree.
- **Decided and not built** (the corpus is ahead of the code and says so in its
  own status blocks): the execution cell, admission/claim receipts and
  `SessionRef` (`ADR-2026-08-05` states it "accepts the architecture only");
  harness connections and live inventory; harness as a composition output field;
  the harness adaptation plan and applied receipt. These need delivery.
- **Never decided:** one-provider-per-pool; bursting/overflow in any form; the
  composition-schema deprecation of the sandbox field. Only this third group
  needs judgement, and this ADR proposes positions on two of the three and
  explicitly defers the rest.

## Decision

**The unit of execution is an *execution context*. A *pool* is a named source of
execution contexts, not a kind of one. *Placement* is the single axis that says
where a run happens, and the difference between naming a pool and naming a
context is a difference of *time*, not of *kind*: a pool is a placement resolved
at claim (`claim_bound`), a context is a placement resolved exactly. Unlike
capacity does not compose inside a pool; it composes one level up, in the
ordered list of pools a project draws on. Harness is an authoring input on the
same footing as model, never derived from it.**

Everything below is either a **rename** of an existing referent or a
**reconciliation** of two accepted texts, except D6 and D7, which record
positions on things never previously decided. Nothing here changes admission,
routing, or scheduling behaviour. The rename/behaviour split is tabulated
explicitly after D7.

### The nouns, one sentence each

| Noun | Definition |
|---|---|
| **Execution context** | The single concrete place one session runs — a slot on an enrolled host, or one provider-minted ephemeral box; the only thing that can actually realise a capability, and the exact placement a `ResolvedExecutionCell` must carry. |
| **Sandbox** | An execution context of the ephemeral, provider-minted kind; **not** the generic word for the unit. |
| **Host** | A machine whose daemon persistently offers execution contexts to an org, enrolled once and referenced thereafter. |
| **Pool** | An org-owned, named **source** of execution contexts — one substrate provider plus its credential and configuration — that enrolls hosts or mints ephemeral contexts on demand; a scheduling-time concept with no runtime existence of its own. |
| **Route** | The ordered list of pools a project may draw on, plus the policy that orders them; the only place unlike capacity composes today. |
| **Capacity** | The org's aggregate, observed ability to run sessions — a rollup you read, never an object you configure. |
| **Placement** | The one axis of the executable unit that answers "where does this run", with `kind` naming what was requested and `resolution` naming whether it is a promise or a fact. |
| **Harness** | The agent program that drives a session and determines how capabilities are wired into it; an axis of the executable unit, co-equal with model and independent of it. |
| **Substrate provider** | A driver that can mint or attach execution contexts of one kind; never the model vendor, and never to share a field with it. |

### D1 — The unit is an *execution context*; `sandbox` narrows to one kind of it

`sandbox` stops being the generic word for the unit and means only the
ephemeral, provider-minted kind. The generic unit word is **execution context**,
surfaced in operator wire and CLI as **instance**, matching the already-shipped
`instanceKind: persistent_host | on_demand_sandbox` discrimination that
`ADR-2026-08-03` D4 rule 1 already cites as the org-side vocabulary.

This makes the framing's "sandbox is just an execution context (local, e2b, k8s)
— a single unit" **true in substance and adjusted in wording**: the substance
(one unit, one place, any substrate) is adopted; the word for it is `execution
context` / `instance`, because calling an enrolled long-lived machine a
"sandbox" collides with the ephemeral kind that already owns the word in the
provider family (`004`), in the wire, and in the CLI noun tree.

The `SandboxProvider` family name is **not** renamed. It is the provider of
execution contexts of every kind, its OSS contract is Accepted, and the SDK
readiness table (`ADR-2026-06-14`) already has the sandbox axis marked NEXT
pending the W3 loader bridge — renaming a family whose contract is still in
motion would compound, not reduce, churn. This ADR narrows the *unit* noun only.

### D2 — `pool` names exactly one thing; the other three referents are renamed

Applying `ADR-2026-08-03` D4 rule 1 to the word it was never applied to.

1. **Keep:** `pool` = the org-owned capacity pool (referent 1).
2. **Rename referent 2 (one machine).** `013:160` and `004:350`/`:444`/`:471`
   stop saying a daemon "registers as a worker pool." A daemon registers **as a
   host** and offers execution contexts. This is prose only — no wire, no code.
3. **Rename referent 3 (the warm workarea cache).** `003` § "The local-pool
   implementation" becomes the **workarea cache**; `011`'s daemon control
   surface becomes `GET /api/daemon/workarea/stats` and
   `POST /api/daemon/workarea/evict`, with `donmai daemon stats --workarea`.
   This one **is** a wire change on the OSS daemon control API, which this
   corpus owns (`ADR-2026-05-07`), so it takes the deprecation discipline of
   `ADR-2026-08-03` D5.4: the old paths and flag ship as aliases that **declare
   their removal version at creation**, and a release gate fails the build when
   an alias outlives its declared version. An alias with no removal version is a
   defect.
4. **Rename referent 4 (local disk envelope).** `capacity.poolMaxDiskGb` becomes
   `capacity.workareaMaxDiskGb`, same alias discipline. Note this key also
   compounds the `capacity` collision — it reads as an org concept on a
   machine-local setting; the rename resolves both.

`ADR-2026-06-01:31`'s "capacity pool / sandbox" phrase is corrected to name one
noun.

### D3 — Pool and execution context are the same axis at two times, not two axes

`ADR-2026-08-05` D2's sibling kinds and the wire's containment view are both
correct, about different moments, and neither is amended:

- A **`DispatchIntent`** may carry `placement.kind='pool'` with
  `resolution='claim_bound'` — a *promise* that some execution context will
  exist, with the concrete one unknown until claim. This is what an author or a
  project route names.
- A **`ResolvedExecutionCell`** carries an exact placement. At claim time the
  claiming host re-runs the narrow-only gate and writes a separate immutable
  `ClaimReceipt` naming the concrete host and effective cell, exactly as
  `ADR-2026-08-05` D4/D5 already specify.

So `kind` answers *what was named*, `resolution` answers *promise or fact*, and
the containment reading ("a pool has instances in it") is the **observed** view
of the same relation after resolution. There is no missing axis, no new
placement kind, and no contract edit. `PlacementRef` stays a closed enum under
`additionalProperties: false`; adding a kind would be a breaking wire change
across the generated contract artifacts in three repositories, and nothing here
requires one.

### D4 — A pool has a configured membership and an observed membership

Stated because "a pool is a collection of them" is true of one face and not the
other, and conflating them is what makes pool-level capacity feel undefinable.

- **Configured membership** = capacity *sources*: enrolled hosts, or one
  provider configuration able to mint ephemeral contexts. This is what an
  operator edits.
- **Observed membership** = the live execution contexts currently attributable
  to the pool, of both kinds. This is what an operator reads, and it is already
  the shipped wire shape.

Consequence worth naming: **capacity accounting today exists only on the
configured-host face.** A pool whose configured membership is a provider
configuration rather than enrolled machines has no ceiling of its own — a fact
that D7 depends on.

### D5 — The authoring surface names sources and intent; the realisation surface is the execution cell

- **Authoring** (composition graph, trigger parameters) names: a **harness**
  (via a harness connection), a **model**, and a **capacity intent** — a pool or
  the project's route. It does not name a machine.
- **Realisation** is the `ResolvedExecutionCell`: harness, model, endpoint, auth
  binding, and an **exact** placement, plus session mode and granted
  capabilities. Authors never author this; the resolver produces it.
- **Exact placement is not an authoring default.** It is legitimate at the
  connections layer — a host-bound subscription must pin an exact host — and for
  operators. Whether an author may ever pin one deliberately is deferred (Q4).

**Harness is an authoring input, and inferring it from model or provider
identity remains a defect.** This restates `ADR-2026-06-06` D1/D4 and
`ADR-2026-08-05` D2/D8 rather than deciding anything new; it is recorded here
because the closed implementation currently resolves harness *out of* the model
profile and offers no authoring node for it, which is the direct cause of the
"harness is missing from composition" observation. The correction is delivery of
an accepted decision. It is also smaller than it appears: the closed control
plane already carries a fire-time harness parameter on published workflow
definitions and a `harness` resource kind, so what is missing is the authoring
node and the resolver's willingness to take harness as an **input** — including
the typed pre-spawn denial when a requested harness has no admissible cell for
the resolved model, endpoint, and auth binding. That denial already exists on
the OSS runner side.

### D6 — A pool is single-provider; unlike capacity composes one level up

The premise in the framing is factually correct — a pool carries exactly one
substrate provider — and this ADR proposes **keeping** it, for three reasons:

1. **The composition point already exists.** A project's route is already an
   ordered, heterogeneous set of homogeneous pools with a policy over them. That
   is precisely "bundling unlike capacity", one level up from the pool.
2. **Making pools heterogeneous breaks the lane split, not just a column.** The
   provider field is what decides whether a pool can host persistently-enrolled
   hosts at all; the persistent and on-demand resolvers are disjoint because of
   it. Mixing providers inside a pool is a resolver rewrite, not a schema
   relaxation.
3. **A second provider-priority lever is already foreclosed.** The platform
   corpus rejected a global substrate-priority setting on the grounds that the
   pool list *is* the substrate-priority list and a second lever creates two
   truth sources that can conflict silently. A mixed-provider pool re-introduces
   exactly that conflict, inside the pool.

What is **wrong** today is not the single-provider pool; it is that the place
where unlike capacity composes is invisible. The route has no name, no operator
surface of its own, and is not experienced as an object at all — so the concept
the framing is reaching for genuinely has no word. Whether that object gets
promoted and named is deferred (Q2), because it carries a permission change and
a migration.

### D7 — There is no burst; the two artifacts that say otherwise are corrected now, and the design is deferred

**Recorded as fact:** no accepted overflow policy, no local-exhaustion trigger,
no schema, and no ADR anywhere describes when or how a pool spills to another.
The routing column that carried the intent was deleted. The only place local
exhaustion is detected today does the opposite of bursting — it ends the
dispatch and prints an instruction for a human to start a daemon or re-route,
which is also a direct violation of `ADR-2026-08-07-onboarding-is-the-only-user-action.md`
D4 (no remediation hint for platform-computable state) delivered to the wrong
role.

**Decided now (removal of false claims):**

- `004`'s `Capacity-aware burst routing` row and its "cloud-burst" premise are
  removed or explicitly marked historical.
- The composing CLI's route help text still advertises a `cloud-burst` selector
  against a column that was dropped server-side and is pinned-absent by an
  existing test. It is deleted. (Platform-side; see the mirrored stub.)

**Deferred (Q3):** what a burst is. Four candidate exhaustion signals exist and
are not interchangeable — host slots full, daemon offline, token/credit
exhaustion, queue latency. **Token exhaustion, named explicitly in the framing,
has no representation in the capacity model at all**: nothing on a pool, a host,
or a route reads a token or credit budget, so choosing it commissions a meter
that does not exist. And because overflow to metered capacity spends money
unattended, a burst design is coupled to a spend-authorization decision. This
ADR does not invent either.

One clarification, because it is the kind of true statement that would be the
wrong mechanism to cite: **within the persistent lane the scheduler already
falls through from a full host to a lower-ranked pool's host.** That is
host-level overflow inside one lane; every candidate must still be
persistent-capable, so it can never cross into an ephemeral cloud pool. It is
not burst.

### Rename versus behaviour change — explicit

| Decision | Kind | What actually changes |
|---|---|---|
| D1 `sandbox` → execution context / instance for the unit | **Rename** | Prose and surface wording. No contract, no schema. `SandboxProvider` family name unchanged. |
| D2.2 daemon "worker pool" → host | **Rename** | Prose in `013`, `004`. Nothing executable. |
| D2.3 workarea cache + `/api/daemon/pool/*` | **Rename with a wire break** | OSS daemon control paths and one CLI flag. Aliases with declared removal versions; behaviour identical. |
| D2.4 `capacity.poolMaxDiskGb` | **Rename with a config-key break** | Alias with declared removal version. |
| D3 placement as one axis, two times | **Reconciliation** | Documentation only. `PlacementRef` unchanged; no new kind. |
| D4 configured vs observed membership | **Clarification** | Documentation only. Names a gap (no ceiling on provider-configured pools); does not fill it. |
| D5 harness as authoring input | **Delivery of an accepted decision** | Behaviour change in the closed implementation only; the OSS contract already says this. |
| D6 pools stay single-provider | **Records an undecided given as a decision** | No change. Closes the question. |
| D7 burst | **Removal of false claims + deferral** | Two documents and one help string corrected. No mechanism added. |

## What this ADR does not decide

Deliberately deferred. Each carries the default this ADR would take absent a
preference, so a decision to say nothing is still a decision with a known
outcome.

1. **Q1 — the unit noun in user-facing surfaces.** `execution context` /
   `instance` (D1's proposal, matching shipped wire) versus `sandbox`
   everywhere (which requires renaming the wire vocabulary and calling an
   enrolled machine a sandbox). **Default: D1 as written.**
2. **Q2 — whether the route is promoted to a named, org-authored,
   project-granted object.** This is where unlike capacity visibly composes. It
   carries a permission change and a grant backfill. **Default: keep the route
   as-is and fix only the vocabulary**, since the composition already works.
3. **Q3 — what triggers a burst, and against which budget.** No default is
   safe here: a burst design that can spill to metered capacity without an
   authorized ceiling converts a failed dispatch into unattended spend.
   **Default: no burst; keep failing, but fix the failure so it converges and
   addresses the operator rather than the author.**
4. **Q4 — whether an author may ever pin an exact placement**, or whether exact
   placement stays operator- and connection-layer-only. **Default:
   operator-only.**
5. **Q5 — whether capacity provisioning becomes an enforced permission.** The
   org→project grant mechanism exists in the closed schema and is set on zero
   pools in production, so the org-side grant is advisory today. **Default:
   record the gap, change nothing until Q2 is answered**, since the two share a
   migration.

Also explicitly out of scope and unchanged: cross-org pool sharing; open-ended
substrate capability kinds; provider-honoured serving; and whether the OSS
daemon may ever advertise capability — that last needs its own OSS-canonical
ADR and is not pre-approved by anything here.

## Consequences

### Positive

- **The reported confusion is resolved without an architecture change.** Four
  referents of `pool` collapse to one, three meanings of `sandbox` to one, and
  the two vocabularies that describe the pool↔context relation are reconciled
  as two views of one axis.
- **The framing's core intuitions are all preserved and made precise**: a
  sandbox really is a unit (narrowed to the ephemeral kind, with a generic word
  supplied); a pool really is a collection (of sources, observed as contexts);
  bursting really is missing (and now recorded as missing rather than advertised
  as present).
- **The false-choice question is closed.** Nobody has to relitigate
  `(harness, model, sandbox)` versus `(harness, model, pool)`.
- **Two documents stop lying.** A reader of `004` today would conclude cloud
  burst ships; an operator reading the route help would conclude a burst
  selector exists.
- **The expensive contract edit is avoided** — no new placement kind, so no
  lock-step break across generated contract artifacts in three repositories.
- The noun rule from `ADR-2026-08-03` gains its third and fourth applications,
  making it a rule rather than two precedents.

### Negative

- **A wire and a config key move.** `/api/daemon/pool/*` and
  `capacity.poolMaxDiskGb` are the only executable surfaces in the rename, and
  both are OSS-owned, but both require an alias cycle with a declared removal
  version and a release-gate check.
- **The renames are broad in documents even where they are narrow in code** —
  a corpus sweep, a docs sweep on the platform side, and one CLI alias cycle.
- **The genuinely missing capability is still missing.** Deferring burst means
  local exhaustion continues to end dispatches. This ADR reduces that from a
  silent contradiction to an open question, which is progress but not a fix.
- **`004` needs real work, not a header bump.** Marking it historical is the
  cheap move; amending it properly is a separate piece of authorship.

### Risks

- **Renaming without promoting the route leaves the founder's concept still
  unnamed.** If Q2 comes back "yes, promote it", part of this vocabulary lands
  twice. Mitigation: D6 deliberately names the route as the composition point,
  so promotion is an addition rather than a correction.
- **The `sandbox` narrowing is being applied to an axis whose SDK contract is
  explicitly not frozen** (`ADR-2026-06-14`: sandbox is NEXT pending the W3
  loader bridge). D1 touches the unit noun only and leaves the family name
  alone, but any deeper sandbox-vocabulary work should wait for that freeze.
- **Deferring burst while removing its advertisements could read as a
  retirement.** It is not. D7 records absence and defers design; a future ADR
  authoring burst is expected and is not blocked by this one.
- **Capacity is an area where the code has repeatedly moved first** — two recent
  platform ADRs in this area are retro-records of changes that shipped without
  one, and one of them states that for a day the corpus was authoritatively
  wrong about a load-bearing routing concept. Any implementation of this ADR
  should re-verify against the resolver and the live data rather than against
  this text.

## Alternatives considered

- **Make pools heterogeneous (multi-provider).** Rejected for now (D6): it
  rewrites the lane split rather than relaxing a field; it re-creates inside the
  pool the two-truth-source conflict that the platform corpus already rejected
  at org level; and the existing route already composes unlike capacity. Worth
  revisiting only if Q2 comes back "the route is not the right object."
- **Add a fifth placement kind, or split placement into pool-vs-context axes.**
  Rejected: it would break a closed enum whose generated artifacts are digest-
  pinned across three repositories, to express something `resolution:
  exact | claim_bound` already expresses.
- **Rename the `SandboxProvider` family to `ExecutionContextProvider`.**
  Rejected: the family contract is Accepted and its axis is deliberately not yet
  frozen; renaming a moving contract compounds churn. Revisit after the W3
  loader-bridge freeze.
- **Leave `pool` ambiguous and disambiguate by context.** Rejected: that is
  precisely what `ADR-2026-08-03` D4 rule 1 forbids, and the reported symptom is
  the predicted consequence.
- **Design burst in this ADR.** Rejected: the trigger is unchosen, one candidate
  trigger (token exhaustion) has no meter anywhere in the model, and the design
  is coupled to a spend-authorization decision that is not this ADR's to make.
- **Do nothing, on the grounds that the framing itself says "not an immediate
  issue."** Rejected narrowly: that judgement is correct about mechanism and
  wrong about documents. Two artifacts actively advertise a capability that was
  deleted, and a four-referent noun is the cheapest defect in the corpus to fix
  and the most expensive to leave while a capacity redesign is being considered.

## Affected documents

Per corpus convention these edits land **in the accepting commit**, not in this
proposal.

- `004-sandbox-capability-matrix.md` — remove the `Capacity-aware burst routing`
  row and the "cloud-burst" premise at `:9`; reconcile or mark historical the
  cross-provider scheduler section; rename the "worker pool" usages at `:350`,
  `:444`, `:471`; refresh the `Last updated:` header. Largest single edit.
- `003-workarea-provider.md` — § "The local-pool implementation" → workarea
  cache; member/eviction vocabulary.
- `011-local-daemon-fleet.md` — `:419-420` daemon control paths, `:510`
  `--pool` flag, `:513` `capacity.poolMaxDiskGb`, each with its alias and
  declared removal version.
- `013-orchestrator-and-governor.md` — `:160` "registers as a worker pool".
- `001-layered-execution-model.md` — the noun table: state the unit word and
  the pool definition alongside the existing execution-cell paragraph. Refresh
  the stale `Last updated:` header.
- `ADR-2026-06-01-code-survival-pool-execution.md` — `:31` "capacity pool /
  sandbox".
- `ADR-2026-08-03-cli-noun-tree-fleet-retirement.md` — record `pool` and
  `sandbox` as the third and fourth applications of D4 rule 1.
- No `BOUNDARY-SYNC` region is touched by the decisions as written. If a later
  amendment reaches `ADR-2026-06-06-two-axis-provider-model.md` (which carries
  synchronized markers and names the sandbox axis), the paired byte-identical
  commit rule applies, OSS side first, verified with
  `scripts/check-boundary-sync.sh`.

Platform-side amendments are enumerated in the mirrored stub.

## Affected work items

None yet — this ADR is Proposed and no issue should be moved against it until
Q1–Q5 are answered. On acceptance, the tracker work splits into four lanes,
which are deliberately independent: (1) corpus renames and the `004` amendment;
(2) the OSS daemon workarea-surface alias cycle; (3) platform-side vocabulary
unification and the stale help-string deletion; (4) harness as an authoring
input — which is delivery of `ADR-2026-06-06` / `ADR-2026-08-05`, not new scope,
and should be tracked against those.

## Implementation notes

- **Sequencing rationale.** The contract-level work is cheapest **now** and gets
  monotonically more expensive: the execution-cell and harness-connection tables
  hold no production rows, so a shape change today rewrites nothing. That window
  closes the moment the first admission receipt is written. Conversely the
  vocabulary work has no such window and can proceed independently.
- **Order:** corpus first (this ADR + reference-doc edits), then the OSS alias
  cycle, then platform-side vocabulary, then docs sites — **after** acceptance,
  never before. Publishing an unsettled model is worse than publishing nothing.
- **Verify before asserting.** The implementation of D2.3/D2.4 should confirm
  the current daemon surface against the shipped binary, not against `011`,
  given the header-staleness pattern recorded above.
- **Do not treat "the scheduler already falls through when a host is full" as
  burst** — see D7's clarification. It is host-level overflow within one lane.
