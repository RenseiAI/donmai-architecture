---
status: Accepted
date: 2026-08-07
boundary: shared
split: inline-addenda
---

# ADR-2026-08-07 — Execution context, pool, and placement: one noun per referent, and where unlike capacity composes

**Status:** Accepted 2026-08-07 — the reference-doc edits enumerated in § "What
the accepting commit carried" landed in the accepting commit, as this corpus
requires.
**Date:** 2026-08-07 (proposed and accepted same day; three product-owner
acceptance rulings **R-A–R-C** arrived between the two, recorded in § "What the
accepting commit carried")
**Boundary:** shared
**Authors:** mark, agent:claude

**Amended 2026-08-07, same day, after first draft:** five product-owner rulings
arrived after this ADR was first written and PR'd. They are folded in below as
**R1–R5**, and they answer four of the five questions the first draft deferred.
The status stayed `Proposed` through that amendment — this corpus requires the
affected reference-doc edits to land in the *same commit* that flips an ADR to
`Accepted`, and they were not in that commit. They are in the accepting commit;
see § "What the accepting commit carried" for exactly what it carried and for
the three acceptance rulings that shaped it.

Where a ruling contradicts the first draft's stated default, **the ruling wins
and the draft text has been rewritten**, not annotated. Specifically: the first
draft's Q2 default was "keep the route as-is and fix only the vocabulary"; the
ruling promotes it to a named **capacity profile**. Do not read the earlier
default anywhere in this file — it has been removed.

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

> **Read this subsection as of authoring.** It describes the corpus on
> 2026-08-07 *before* acceptance. The `004` defects it catalogues were fixed by
> the accepting commit — see § "What the accepting commit carried". It is
> retained unedited because it is the evidence the decisions rest on, and
> rewriting it to past tense would erase why they were made.

- **`004-sandbox-capability-matrix.md` has not been touched since this repo's
  initial public release** (`a22bd3d`, 2026-05-24). Its header still reads
  `Last updated: 2026-05-06`. It therefore predates the two-axis provider model
  (2026-06-06), the SDK axis freeze (2026-06-14), the CLI noun tree (2026-08-03),
  and the execution cell (2026-08-05); it contains zero occurrences of
  `DispatchIntent`, `ResolvedExecutionCell`, `AdmissionReceipt`, or
  `PlacementRef`. Two specific claims in it are now counterfactual:
  - **It advertises burst routing that does not exist.** `004` § "OSS vs SaaS
    division of labor" carried the row
    `Capacity-aware burst routing | ✅ ships local-only | ✅ ships hybrid (local + cloud)`,
    and its opening premise (`:9`) was scaling `cloud-burst across multiple providers`.
    `013` § "OSS vs SaaS responsibilities" carried the same qualifier a second
    time, in its `Cross-machine fleet aggregation` row. The platform corpus
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
- **Never decided:** one-provider-per-pool; bursting/overflow in any form;
  whether the composition point is a named object; whether the per-pool project
  grant is enforced; whether an author may name a machine; the
  composition-schema deprecation of the sandbox field. This third group is the
  only one that needed judgement, and the product-owner rulings folded in as
  R1–R5 supply it — see D6 through D10. The one item still without a position is
  *predictive* burst, deferred with cause in D7.

## Decision

**The unit of execution is an *execution context*. A *sandbox* is one KIND of
execution context, not a synonym for it. A *pool* is a single-provider named
SOURCE of execution contexts, not a kind of one and not a container of unlike
ones. A *capacity profile* is a named policy over an ordered list of pools, and
it is the one place unlike capacity composes. *Placement* is the single axis
that says where a run happens, and the difference between naming a pool and
naming a context is a difference of *time*, not of *kind*: a pool is a placement
resolved at claim (`claim_bound`), a context is a placement resolved exactly.
Harness is an authoring input on the same footing as model, never derived from
it.**

Everything below is either a **rename** of an existing referent or a
**reconciliation** of two accepted texts, except D6–D10, which record positions
on things never previously decided. Nothing in D1–D5 changes admission, routing,
or scheduling behaviour; D6 promotes an existing object to a named one. The
rename/behaviour split is tabulated explicitly after D10.

### The building blocks, stated explicitly (R1)

**R1 (product-owner ruling):** *a sandbox is a TYPE of execution context; pools
group execution contexts. Document the building blocks explicitly.* This section
is that documentation, and it is the part of this ADR most likely to be quoted
on its own.

Four blocks, from the runtime unit outward to the authoring policy:

```
capacity profile   named policy: an ordered list of pools + how to choose among them
      │                                                  (org-authored, project-granted)
      ├── pool      a SOURCE of execution contexts from ONE provider
      │   ├── pool  another source, possibly a different provider
      │   └── …     ordering and fallback live in the profile, never inside a pool
      │
      └── each pool yields ▸ execution context   the unit — one concrete place one session runs
                              ├── kind: persistent host slot   (long-lived, enrolled)
                              └── kind: sandbox                (ephemeral, provider-minted)
```

1. **Execution context — the unit.** One concrete place one session runs. It is
   the only thing that can actually realise a capability, and it is what a
   `ResolvedExecutionCell` names as its exact placement. On the operator wire and
   in the CLI the noun is **`instance`**.
2. **Sandbox — one kind of execution context.** The ephemeral, provider-minted
   kind. `sandbox` is *not* the generic word for the unit; using it that way is
   what makes `sandbox` and `pool` read as competing composition inputs. The
   other kind is a slot on a persistently enrolled host. This is already the
   shipped discrimination: `instanceKind: persistent_host | on_demand_sandbox`.
3. **Pool — a single-provider source of execution contexts.** One substrate
   provider plus its credential and configuration, owned by the org and named by
   a human. It enrolls persistent hosts, or mints ephemeral sandboxes on demand.
4. **Capacity profile — a named policy over pools.** An ordered list of pools
   plus the rules for choosing among them (ordering, fallback, constraints).
   Org-authored, granted to projects. This is where unlike capacity composes.

**What a pool is NOT** — stated negatively because every one of these readings
has been made in this program, and each produces a different wrong design:

- **A pool is not a bag of heterogeneous sandboxes.** It is a *source*, not a
  container of unlike things. Mixing substrate providers inside a pool is
  explicitly rejected in D6.
- **A pool is not an execution context, and not a kind of one.** It is a
  scheduling-time concept with no runtime existence of its own. Nothing ever
  runs "on a pool"; a run happens in an execution context the pool produced.
- **A pool has no size.** There is no ceiling attribute on a pool. What capacity
  accounting exists lives on enrolled *machines*, so a pool whose membership is
  a provider configuration rather than enrolled hosts has no ceiling at all
  (D4).
- **A pool is not a host, and not a set of hosts named individually.** Authors
  name pools; they never name hosts (D9).
- **A pool is not the policy over pools.** Ordering, fallback and constraints
  live one level up, in the capacity profile (D6). A pool that carried its own
  fallback would be a second truth source for the same decision.

### The nouns, one sentence each

| Noun | Definition |
|---|---|
| **Execution context** | The unit. The single concrete place one session runs — a slot on an enrolled host, or one provider-minted ephemeral box; the only thing that can actually realise a capability, and the exact placement a `ResolvedExecutionCell` must carry. Wire/CLI noun: `instance`. |
| **Sandbox** | An execution context of the ephemeral, provider-minted kind. One *kind* of the unit; **not** the generic word for it. |
| **Host** | A machine whose daemon persistently offers execution contexts to an org, enrolled once and referenced thereafter. Operators name hosts; authors do not (D9). |
| **Pool** | An org-owned, named **source** of execution contexts — exactly one substrate provider plus its credential and configuration — that enrolls hosts or mints ephemeral contexts on demand; a scheduling-time concept with no runtime existence, no size, and no policy of its own. |
| **Capacity profile** | A named, org-authored, project-granted **policy over pools**: an ordered list plus how to choose among them. The one place unlike capacity composes. Today's per-project execution route is this object, unnamed (D6). |
| **Capacity** | The org's aggregate, observed ability to run sessions — a rollup you read, never an object you configure. |
| **Placement** | The one axis of the executable unit that answers "where does this run", with `kind` naming what was requested and `resolution` naming whether it is a promise or a fact. |
| **Harness** | The agent program that drives a session and determines how capabilities are wired into it; an axis of the executable unit, co-equal with model and independent of it. Retained deliberately — see § "Harness is retained". |
| **Substrate provider** | A driver that can mint or attach execution contexts of one kind; never the model vendor, and never to share a field with it. |

### Reconciliation with what the corpus already Accepted

Stated up front, before any decision, because **the two things this ADR is most
likely to be mistaken for proposing are already Accepted**, and the divergence
is in the code, not in the corpus. Nothing in D1–D10 asks for a contract change
on either point.

**1. `ADR-2026-08-05-versioned-execution-cell-and-session-reference.md` D2 —
"Independent reference types" — already dissolved the sandbox-vs-pool false
choice.** It defines five independent reference types (`HarnessRef`, `ModelRef`,
`ServingEndpointRef`, `AuthBindingRef`, `PlacementRef`), of which placement is
**one axis**:

```ts
PlacementRef { id: string; kind: 'host' | 'pool' | 'sandbox' | 'remote_peer';
               resolution: 'exact' | 'claim_bound' }
```

`pool` and `sandbox` are two `kind` values on one axis, and `resolution`
separates promise from fact. So "is the realisation surface
`(harness, model, sandbox)` or `(harness, model, pool)`?" was never a real
choice — it was one axis read twice. D3 below explains the two *times* that make
both readings feel correct; it changes nothing in the type. `PlacementRef` stays
a closed enum under `additionalProperties: false`, unchanged.

**2. Harness as a first-class, independently-selected composition axis is also
already Accepted** — as an axis of the executable unit (`ADR-2026-06-06` D1;
`ADR-2026-08-05` D2/D3/D4; `001-layered-execution-model.md` § "The executable
unit"), and as a *composition input* in the platform corpus's
`ADR-2026-08-06-platform-service-composition-and-harness-injection.md` D1, whose
`AgentComposerOutput` carries `harnessConnectionRef` and `capacityPoolRef` as
separate fields **and carries no `sandbox` field at all**.

> **Citation trap — two ADRs share the 2026-08-06 date.** The composition-output
> decision is in the platform corpus's *service-composition-and-harness-injection*
> ADR. It is **not** in this corpus's
> `ADR-2026-08-06-harness-adaptation-plan-and-receipt.md`, whose own D1 is
> "layered instruction authority" and which contains no `AgentComposerOutput`.
> A reader citing "ADR-2026-08-06" without the slug will land on the wrong file
> and wrongly conclude the claim is unverified.

**The divergence is in the CODE, not the corpus.** The closed implementation
resolves harness *out of* the resolved model profile and offers no authoring
node for it — the code's own comment states "a harness alone is meaningless — it
is a 1:1 projection of the profile", and it hard-errors if a harness is picked
without a profile. The service-composition ADR's own implementation checkpoint
says the same thing about itself: platform main carries no `AgentComposerOutput`
contract. So the observation that opened this ADR — "harness is not a
composition input" — is **true of the code and false of the corpus.** It needs
delivery, not deliberation, and D5 records it as delivery rather than as new
scope.

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
   defect. **The declared removal version for every alias this ADR creates is
   `v0.59.0`** — one minor after the release that creates them, matching the
   cadence the `daemon`→`host` aliases already set.
4. **Rename referent 4 (local disk envelope).** `capacity.poolMaxDiskGb` becomes
   `capacity.workareaMaxDiskGb`, same alias discipline and the same `v0.59.0`
   removal version. Note this key also compounds the `capacity` collision — it
   reads as an org concept on a machine-local setting; the rename resolves both.
   **The alias here must be a config-struct read alias, not a CLI allowlist
   entry**: the daemon's YAML loader is non-strict, so an unrecognised key is
   silently dropped, and `0` on this field means *no limit* — a CLI-only alias
   would silently disable eviction on an operator's existing config.

`ADR-2026-06-01:31`'s "capacity pool / sandbox" phrase is corrected to name one
noun.

### D3 — Pool and execution context are the same axis at two times, not two axes

`ADR-2026-08-05` D2's sibling kinds and the wire's containment view are both
correct, about different moments, and neither is amended:

- A **`DispatchIntent`** may carry `placement.kind='pool'` with
  `resolution='claim_bound'` — a *promise* that some execution context will
  exist, with the concrete one unknown until claim. This is what an author, or
  the capacity profile a project is granted, names.
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
  (via a harness connection), a **model**, and a **capacity intent** — a pool,
  or the capacity profile the project is granted. It does not name a machine
  (D9).
- **Realisation** is the `ResolvedExecutionCell`: harness, model, endpoint, auth
  binding, and an **exact** placement, plus session mode and granted
  capabilities. Authors never author this; the resolver produces it.
- **Exact placement is not an authoring default.** It is legitimate at the
  connections layer — a host-bound subscription must pin an exact host — and for
  operators. An author may **never** pin one deliberately — D9 settles this:
  authors name pools, and pool naming is the targeting mechanism.

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

### D6 — A pool is single-provider; unlike capacity composes one level up, in a named **capacity profile**

**Product-owner ruling (the answer to what the first draft deferred as Q2):**
*the unlike-capacity object is a named capacity profile. Pools stay
single-provider; today's per-project execution route is promoted to a nameable,
org-authored, project-granted object.*

Two halves, taken in order.

#### D6.1 — Pools stay single-provider

The premise in the framing is factually correct — a pool carries exactly one
substrate provider — and this ADR **keeps** it, for three reasons:

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

#### D6.2 — The route is promoted to a named **capacity profile**

What is **wrong** today is not the single-provider pool; it is that the place
where unlike capacity composes is invisible. The per-project execution route has
no name, no object identity, and no operator surface of its own — so the concept
the framing was reaching for genuinely had no word. It now has one.

A **capacity profile** is:

- **Named.** A human-authored label, not a derived per-project singleton. The
  same naming discipline as pools (D9): profiles are named after the *intent*
  they encode, not after the machines behind them.
- **Org-authored.** Created and edited where capacity is onboarded, by the role
  that onboards capacity — which is usually not the role that authors workflows.
- **Project-granted.** Handed out to projects, and reusable across them. A
  project references a profile; it does not own one.
- **A policy over pools:** an ordered list of pools plus how to choose among
  them — ordering, fallback, and constraints. Nothing else. It holds no capacity
  of its own and mints nothing.

This is a **shape change, not a rename**, and the accepting work must treat it
as such. Today's object is a per-project singleton auto-minted at the org
default and edited through a per-project `show`/`set`/`test` surface. A profile
is a reusable object with list/create/update/delete semantics analogous to
pools, plus a grant edge to projects. Anyone sizing this as "wording only" has
mis-sized it (see § "What the accepting commit carried" and the rename-vs-behaviour table).

Two invariants the promotion must preserve, both already true today:

- **A project is never *required* to configure capacity.** A default profile is
  granted at the org system default, exactly as a route is auto-minted today.
  This is the standing rule that availability governs enablement — a project
  must never be *required* to have any resource.
- **Naming is at the profile and pool level only.** A profile names pools; a
  pool is a source; neither names a host (D9).

Sequencing note: D6.2 and D8 (grant enforcement) share a migration and must be
planned together, but they are **not** the same decision — D6.2 creates the
grantable object; D8 deliberately does not enforce grants yet.

### D7 — There is no burst; the three artifacts that say otherwise are corrected now, and the first iteration is failure-triggered routing-around

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
- **`013`'s `Cross-machine fleet aggregation` row and its extension list carry
  the same qualifier and are corrected the same way.** The row read
  `✅ owns (cloud-burst)` and the paragraph below it listed `cloud-burst aggregation`.
  Aggregation is real and stays; the burst qualifier goes. This
  was missed in the first pass of the accepting commit — which edited `013` at
  `:160` for the D2.2 noun rename without sweeping the file for D7 — and is
  corrected before merge. *(Heading amended 2026-08-07: this decision covers
  **three** artifacts, not two.)*
- The composing CLI's route help text still advertises a `cloud-burst` selector
  against a column that was dropped server-side and is pinned-absent by an
  existing test. It is deleted. (Platform-side; see the mirrored stub.)

**The absence is now measured, not merely unfound.** An independent audit of the
hosted plane's dispatch history returned **zero fall-back events across
1,262,827 audit records** and **zero dispatches re-placed after initial
binding**. The mechanism that does exist is a static capability-mismatch filter
over declared provider flags with **no capacity or availability input**, so it
is structurally incapable of detecting the exhaustion a burst would react to.
This is stronger than "no design exists": no design exists *and* nothing in
production has ever behaved as if one did.

**Deferred, with the reason and the first iteration both named (R2).**

**R2 (product-owner ruling):** *burst-to-cloud requires telemetry we do not
collect. Deferred. The first iteration is failure-triggered routing-around, not
predictive burst.*

Recorded in full so this is not re-litigated:

- **Why deferred — the meter does not exist.** Four candidate trigger signals
  are available in principle and are not interchangeable: host slots full,
  daemon offline, token/credit exhaustion, queue latency. **Token and credit
  exhaustion — the trigger named explicitly in the original framing — has no
  representation anywhere in the capacity model.** Nothing on a pool, a host, or
  a route reads a token or credit budget. Choosing that trigger does not
  configure a feature; it commissions a meter that does not exist, on a schedule
  nobody has estimated. That is the whole of the deferral: not doubt about
  whether burst is wanted, but absence of the telemetry any predictive form of
  it would consume.
- **Why not "defer everything".** Routing around a *failure* needs no meter. A
  dispatch that fails on one pool is an observed fact, not a prediction.
- **So the first iteration is failure-triggered routing-around.** When a
  dispatch fails against the chosen pool, the capacity profile (D6.2) is
  permitted to route around the failure to the next pool in its order. This is
  reactive, bounded by the profile the org already authored, and requires no
  new telemetry — the profile *is* the fallback policy, so the mechanism is
  "honour the order on failure", not "invent a new lever".
- **What is still not decided:** what a *predictive* burst is — which
  exhaustion signal fires it, against which budget, and under whose spend
  authorization. Overflow to metered capacity spends money unattended, so a
  predictive burst design is coupled to a spend-authorization decision. This ADR
  invents neither, and a later ADR authoring predictive burst is expected and is
  not blocked by this one.

Two traps for whoever implements failure-triggered routing-around, both of which
have already misled a reader in this program:

- **Do not treat host-level fall-through as the mechanism.** Within the
  persistent lane the scheduler already skips a full host and falls through to a
  lower-ranked pool's host — but every candidate must still be
  persistent-capable, so it can never cross into an ephemeral cloud pool. It is
  overflow *within* one lane and is not the routing-around this decision names.
- **A load-ratio ordering policy is currently the inverse of what is wanted.**
  Because pool capacity is derived by summing over enrolled machines, a pool
  with no enrolled machines scores as maximally idle and would be ranked
  **first, always** — not on failure. Any profile policy that orders by load
  must fix that before it is offered, or failure-triggered routing-around
  becomes unconditional routing-to-metered-capacity.

### D8 — Per-pool permission restrictions are NOT enforced yet, deliberately

**R3 (product-owner ruling):** *per-pool permission restrictions are deferred
until the policy engine and the org-admin interface mature — today they would
only add friction for new users.*

The facts this rests on:

- The mechanism **already exists** in the closed schema: a pool carries an
  allowed-project list, and the resolver already consults it (null =
  unrestricted, empty = quarantined, list = whitelist). It is exactly the
  "onboarded at org, granted per project" shape the framing asked for.
- It is set on **zero** live pools in production. So the org→project grant is
  advisory today, and a project member can re-point their project's work at any
  pool in the org.

**Decision: leave it advisory. Do not turn the grant into an enforced
permission in the accepting work.** The reasoning, recorded so it is not
mistaken for an oversight:

1. **Enforcement without a mature admin surface is pure friction.** Turning the
   grant on means every new pool starts unusable until someone finds the screen
   that grants it. The org-admin interface that would make that a two-click
   operation is not mature. The net effect on a new user is a capacity model
   that fails closed for reasons they cannot see or fix — the exact class of
   interruption the onboarding invariant
   (`ADR-2026-08-07-onboarding-is-the-only-user-action.md`) rules out.
2. **The policy engine is where this belongs.** A per-pool restriction is a
   policy statement, and the policy engine is the thing that will eventually own
   policy statements. Hard-coding enforcement into the resolver now builds a
   second policy site that would have to be dismantled.
3. **Nothing is lost by waiting.** The field stays, the resolver keeps
   consulting it, and D6.2 creates the grantable object. When the policy engine
   and the admin surface mature, enforcement is a switch plus a backfill, not a
   redesign.

**Revisit trigger, stated so this has an exit condition rather than drifting:**
when *both* the policy engine and the org-admin interface are mature enough that
granting a pool to a project is a first-class, discoverable operation. Enforcing
before then is out of order, not merely early.

The backfill that a future enforcement must perform is already knowable: every
live pool is set to its current *effective* grant (i.e. what it can serve today)
so that flipping enforcement on changes nothing observable, and only then is the
default for new pools tightened.

### D9 — Authors name pools, never hosts; pools ARE the placement mechanism

**R4 (product-owner ruling):** *authors name pools, never hosts. Real usage
already proves it — pools named after individual machines today, and geographic
pool names at scale so execution lands on geo-local machines.*

This closes what the first draft deferred as Q4 ("may an author ever pin an
exact placement?"). The answer is **no, and the reason is not restriction — it
is that the pool is already the right instrument.**

- **A capacity node in a composition is a requirement/lane selector, not an
  exact-host pin.** It says *what kind of place this work needs*, and the
  resolver picks the concrete execution context at claim time. In `PlacementRef`
  terms an author writes `kind: 'pool'`, `resolution: 'claim_bound'`.
- **Pool naming is the targeting mechanism, and it already works.** Pools named
  after specific machines direct work at those machines today. At scale the same
  mechanism expresses geography — one pool per office, so execution lands on
  geo-local machines — with no new axis, no new node, and no host-pinning
  vocabulary. This is why D6.2 insists profiles and pools are *named*: naming is
  the affordance that makes lane selection expressive.
- **Exact placement stays real, and stays out of authoring.** It remains
  legitimate at the connections layer (a host-bound subscription must pin an
  exact host) and for operators. What is ruled out is an *authoring* surface that
  names a machine.

The practical consequence for the accepting work: no "pin a host" authoring
affordance is to be built, and any existing surface that lets an author reach a
machine directly is a defect to be routed through a pool instead. The
corresponding gap to close is the reverse one — a pool must be nameable and
renameable well enough to carry this weight, since it is now load-bearing for
targeting.

### D10 — "Sandbox provider" is the ambiguity R5 names; the refactor is authorized in principle and gated on sizing

**R5 (product-owner ruling):** *"sandbox provider" today means the flavor of the
sandbox instance. Paying the refactor cost now is preferred to paying it later —
but only once it is SIZED.*

The ambiguity is real and this ADR names it precisely: the phrase **"sandbox
provider"** is used for the *substrate flavor* of an execution context, while
D1 narrows `sandbox` to the *ephemeral kind* of execution context. Those are two
different things wearing one phrase, and the same value vocabulary appears under
several different field names across surfaces — which is why the axis reads as
several axes.

**Decided now:**

1. **The ambiguity is acknowledged as a defect, not as acceptable shorthand.**
   Under D1, "sandbox provider" applied to a persistently-enrolled machine is
   simply wrong: that machine is an execution context of the *other* kind.
2. **A refactor is authorized in principle, and deliberately not scheduled
   here.** The stated preference is to pay the cost now rather than later, and
   the cost curve supports it — the execution-cell and harness-connection tables
   hold no production rows, so shape changes today rewrite nothing, and that
   window closes the moment the first admission receipt is written.
3. **It is gated on a sizing pass, which is a separate deliverable.** The sizing
   must separate what is *wording-only* (prose, help text, docs — cheap) from
   what needs a *schema or wire change* (lock-step, needs a plan and a migration).
   No renaming work starts before that separation exists on paper.
4. **The OSS contract's `PlacementRef.kind: 'sandbox'` literal is the CORRECT
   usage and is explicitly excluded from any such refactor.** It is precisely
   D1's ephemeral-kind meaning. A rename sweep that catches it has caught the
   one place the word is already right.
5. **The `SandboxProvider` family name is not renamed by this ADR** (D1), and
   any deeper sandbox-vocabulary work waits for the SDK axis freeze.
6. **Any surface rename ships under the declared-removal-version alias
   discipline** of `ADR-2026-08-03` D5.4 — an alias with no removal version is a
   defect, and that rule exists because an earlier alias generation outlived its
   promise by 84 releases.
7. **The sizing pass inherits a written inventory, not a fresh search.** D2.3
   renamed referent 3 in `003`, `004`, `011` and `013`; it left the same
   referent standing in `005`, `006`, `007`, `008` and `014`. Those sites are
   enumerated by line and phrase in § "Not edited — and exactly how far that
   goes", already split into the two buckets the sizing pass must produce:
   prose (`005`, `006`, `007`, `008`, plus `014:14`) versus surface (`014`'s
   `WorkareaPoolPanel` primitive and its `"Warming pool"` rendered label). The
   sizing pass starts from that table. Whoever runs it should re-scan rather
   than trust the line numbers, which drift.

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
| D6.1 pools stay single-provider | **Records an undecided given as a decision** | No change. Closes the question. |
| D6.2 route → named capacity profile | **Shape change** | A new named, org-authored, project-granted object with list/create/update/delete + a grant edge, replacing a per-project singleton. Migration + surface work. **Not wording-only.** |
| D7 burst | **Removal of false claims + a scoped first iteration** | Two documents and one help string corrected; failure-triggered routing-around named as the first form; predictive burst still undesigned. |
| D8 grant enforcement | **Explicit non-change, with an exit condition** | Nothing. The field stays advisory; the revisit trigger is recorded. |
| D9 authors name pools, never hosts | **Closes a question; forbids a surface** | No host-pinning authoring affordance is to be built. Raises the bar on pool naming/renaming. |
| D10 "sandbox provider" ambiguity | **Names a defect; authorizes a refactor gated on sizing** | Nothing yet. The sizing pass is the next artifact; `PlacementRef.kind: 'sandbox'` is excluded from any sweep. |

### Harness is retained — deliberately, and this is not reopenable

`harness` stays the word for the agent program that drives a session. It is
**convergent with where the industry is going**, not divergent from it: the
prevailing pattern is a product presented as "an agent" whose own documentation
describes it as an agent harness, and that pattern holds across several
independent coding-agent projects.

Recorded here because an earlier assessment *in this same program* claimed
`harness` was largely eval-tooling vocabulary and carried divergence risk. **That
assessment was based on stale usage, was wrong, and has been formally
withdrawn.** Do not propose renaming `harness`, and do not treat the withdrawn
assessment as an open question if it resurfaces in an older document — it is
closed.

This matters beyond vocabulary: `harness` is a load-bearing axis of the
executable unit (`ADR-2026-08-05` D2), the subject of the adaptation contract
(`ADR-2026-08-06-harness-adaptation-plan-and-receipt.md`), and the axis that
determines whether a capability is real machinery or a prompt partial. Renaming
it would churn an accepted, contract-bearing noun for no gain.

## What this ADR does not decide

The first draft deferred five questions (Q1–Q5). **Four are now answered by the
product-owner rulings and have moved into the decisions above.** For anyone
returning with the old list:

| First draft | Now |
|---|---|
| Q1 — the unit noun | **Answered.** `execution context`, wire noun `instance` (D1). |
| Q2 — promote the route? | **Answered: yes**, to a named capacity profile (D6.2). The draft's "keep it as-is" default is void. |
| Q3 — what triggers a burst | **Still open**, but scoped: failure-triggered routing-around is the first iteration (D7/R2); *predictive* burst remains undesigned. |
| Q4 — may an author pin an exact placement? | **Answered: no.** Authors name pools; pools are the placement mechanism (D9). |
| Q5 — enforce the grant as a permission? | **Answered: not yet**, with a recorded exit condition (D8). |

What genuinely remains open:

1. **What a predictive burst is** — which exhaustion signal fires it, against
   which budget, under whose spend authorization. Deferred with cause (D7): the
   named candidate trigger has no meter anywhere in the model, and overflow to
   metered capacity spends money unattended. A later ADR is expected.
2. **The sizing of the naming refactor** (D10). Authorized in principle,
   unscheduled until the wording-only work and the schema/wire work have been
   separated on paper. That separation is a deliverable, not a decision.
3. **The shape of the capacity-profile surface** (D6.2) — what the object's
   fields and verbs are exactly, and how the migration preserves the
   never-required invariant. The decision to promote is made; the design is
   accepting-commit work.

Also explicitly out of scope and unchanged: cross-org pool sharing; open-ended
substrate capability kinds; provider-honoured serving; and whether the OSS
daemon may ever advertise capability — that last needs its own OSS-canonical
ADR and is not pre-approved by anything here.

## What the accepting commit carried

**This ADR stayed `Proposed` until a single commit carried both the status flip
and every reference-doc edit below.** That is this corpus's rule, and it is why
the status was not flipped when R1–R5 landed: those rulings settled the
*decisions*, not the *documents*. This section is now the **record** of what the
accepting commit carried, retained in the shape of the original checklist so a
reader can audit the acceptance against it.

### The three acceptance rulings (R-A, R-B, R-C)

Three further product-owner rulings arrived at acceptance time and shaped what
the accepting commit did. They are recorded here for the same reason R1–R5 are:
so a later reader inherits the reasoning, not just the outcome.

- **R-A — the platform-side ADR on org-provisions/project-consumes is accepted,
  in the D6.2/D8 shape.** The capacity profile (D6.2) is the grantable object it
  was waiting for; the grant edge exists but is **advisory, not enforced** (D8).
  Accepting records that as the intended end state rather than leaving the ADR
  `Proposed` for a fourth month by default. Platform-side; the edit is
  enumerated in the mirrored stub.
- **R-B — `004`'s cross-provider scheduler section is RECONCILED, not stamped
  historical and not deleted.** It is rewritten to describe routing via capacity
  profiles (composition one level up, pools single-provider). **The reasoning for
  why per-session cross-provider routing was rejected must survive the rewrite** —
  deleting it invites someone to re-propose it. It survives as § "Why routing does
  not pick a provider per session".
- **R-C — `011`'s wire break ships doc-and-code together.** The accepting commit
  lands alongside the real rename and its aliases in `donmai` and the composing
  binary, so the corpus never describes something the code does not do. That
  makes acceptance a coordinated multi-repo change, not a docs commit; the
  corpus PR merges in lock-step with the code PRs.

### The reference-doc edits, as landed

| Document | Edit carried |
|---|---|
| `004-sandbox-capability-matrix.md` | **Largest single edit.** Removed the `Capacity-aware burst routing` row and corrected the "cloud-burst" premise at § "Why this exists" (D7); **reconciled** the cross-provider scheduler section per R-B — it now describes capacity-profile routing over single-provider pools and retains the rejection reasoning; renamed the "worker pool" usages (D2.2); refreshed the stale `Last updated:` header. Second pass: the referent-3 usages the first pass left behind — the daemon-mode diagram's `WorkareaProvider local pool` / `warm pool members` box (now the **workarea cache**, with a renamed-from banner) — plus two regime-table cells that read `pool` for something that is not one (`Local pool` → `Local`, since that column names *providers*; "paused pools" → "paused **sandboxes**", since pause/resume is a sandbox primitive). One stray `rensei-daemon` label inside the same diagram — the corpus's only occurrence — corrected to `donmai daemon`. |
| `003-workarea-provider.md` | § `The local-pool implementation` → § "**The workarea cache**"; member/eviction vocabulary swept to cache vocabulary (D2.3). Its unrelated § "Capability profile by sandbox" is per-sandbox capability data, **not** this ADR's `capacity profile` noun, and was correctly left alone. |
| `011-local-daemon-fleet.md` | Daemon control paths → `/api/daemon/workarea/*`; `--pool` flag → `--workarea`; `capacity.poolMaxDiskGb` → `capacity.workareaMaxDiskGb` — **each with an alias carrying the declared removal version `v0.59.0`** per `ADR-2026-08-03` D5.4. This is the only genuine OSS wire break in the ADR, and per R-C the doc landed in lock-step with the code. |
| `013-orchestrator-and-governor.md` | "registers as a worker pool" → registers as a **host** (D2.2). Second pass: the `Cross-machine fleet aggregation` row's `(cloud-burst)` qualifier and the `cloud-burst aggregation` extension-list item removed (D7), with the measured-absence evidence recorded inline. The first pass edited this file for D2.2 and did **not** sweep it for D7 — a same-file miss, and the reason the D7 bullet list now enumerates its artifacts by name. |
| `001-layered-execution-model.md` | Added the building blocks (R1) to § "Layer 3 — Execution": the unit word, the sandbox-is-a-kind statement, the pool-is-a-source definition, and **capacity profile** as a new noun. Refreshed the stale `Last updated:` header. *(`001` carries no standalone noun table; Layer 3 is where the execution nouns are already defined, so that is where they landed.)* |
| `ADR-2026-06-01-code-survival-pool-execution.md` | "the user-configured capacity pool / sandbox" → names one noun. A clarification to an `Accepted` ADR that changes no decision, so it lands as a direct edit under this corpus's clarification carve-out. |
| `ADR-2026-08-03-cli-noun-tree-fleet-retirement.md` | Recorded `pool` and `sandbox` as the **third and fourth** applications of its own D4 rule 1. Refreshed its status prose: the OSS `host` factory **has** merged and shipped, so "not yet merged" was stale. |
| `README.md` / `AGENTS.md` | Updated this ADR's index entry to `Accepted`. The generated `ADR-INDEX` block was regenerated with `scripts/gen-adr-index.sh`, not hand-edited. |

### Not edited — and exactly how far that goes

An earlier revision of this section read *"Not touched by this ADR, confirmed:
`002`, `005`, `006`, `007`, `008`, `014`, `015`, `016`."* **That certification
was false, and not narrowly so.** Re-run at acceptance review as a full scan of
all eight for the *renamed* referent — referent 3, the warm workarea cache —
five of the eight carry it. A certification's only value is that a reader can
trust it, so it is replaced here with the scan's actual output.

**Genuinely clean — no `pool` token for any renamed referent:**

| Document | Finding |
|---|---|
| `002-provider-base-contract.md` | Four occurrences, none renamed. `:662` "claim-bound pool" and `:692` "binds the pool/reservation" are **referent 1** and are correct as written. `:633` and `:750` say "HTTP keep-alive pools" / "HTTP client pools" — the ordinary connection-pool term, a referent this ADR does not claim and should not. |
| `015-plugin-spec.md` | Zero occurrences. |
| `016-workflow-engine.md` | Zero occurrences. |

**Still carrying referent 3 — enumerated, and deliberately not edited here:**

| Document | Sites (line numbers as of this commit) |
|---|---|
| `005-kit-manifest-spec.md` | `:198` "not pre-warmed in the pool". `:195`'s `# cache that survives release-to-pool` paraphrases the unchanged `ReleaseMode` literal. |
| `006-cross-provider-interactions.md` | `:38` "the same pool member", `:41` "cross-session leakage in pool reuse", `:63` "should have been pool-warmed", `:211` "wasted-warm-pool members", `:229` "during pool clean". Its `:18` `release(return-to-pool)` is the unchanged type literal, and `:14`/`:130` `pool_cost_events` is referent 1. `:217` "a transient detect-sandbox pool" is a fourth thing again — a short-lived set of detection sandboxes, neither referent 1 nor referent 3. |
| `007-intelligence-services.md` | `:16` "running on a local pool", `:114` and `:116` "pool reuse", `:169` "what makes the OSS local pool fast", `:170` "locally-pooled workareas". |
| `008-version-control-providers.md` | `:325` "the local-pool warm cache … pool members are keyed on `(vcsProviderId, repository, toolchain)`" — the clearest single case in the corpus, since the sentence uses *pool* and *cache* for the same object in the same breath. |
| `014-tui-operator-surfaces.md` | `:14` "local workarea pool" (prose). `:74`'s `WorkareaPoolPanel` and `:19`'s reference to it are **typed primitive names**, and `:169`'s `Label: "Warming pool"` is a **rendered UI string** — both are surfaces, not prose. `:15`'s "pools, live instances … project→pool routing" is referent 1 and correct. |

**Why they are not edited in this commit, stated as a decision.** These are not
on this ADR's edit checklist, and adding them would widen the edit list of the
very commit whose discipline is that its list is closed and enumerated. More to
the point, D10.3 gates renaming — **prose included** — on the sizing pass, and
`014`'s three sites are not prose at all: `WorkareaPoolPanel` is a typed
primitive and `"Warming pool"` is a string a user reads, which puts them on the
schema-and-wire side of exactly the line D10 exists to draw. The D2 renames
landed because D2 enumerates them individually with named targets and an alias
discipline; this residue has neither.

**What that costs, said plainly.** Until the sizing pass, a reader moving
between `003`'s cache vocabulary and `007`/`008`'s pool vocabulary cannot tell
from the text alone that they are the same object. `003` § "The workarea cache"
carries the renamed-from banner that resolves it, and `004`'s diagram now
carries one too — those two are the entry points a reader is most likely to
arrive through. The remaining five documents are recorded here so the debt has
a name and an inventory rather than being discovered a third time.

**No `BOUNDARY-SYNC` region was touched.** Verified at acceptance against all
four currently tracked marker pairs — the boundary-contract region in `001`
(lines 254-270, safely below this ADR's Layer 3 insertion), plus
`adr-2026-06-06-narrow-only-invariant`,
`adr-2026-07-12-interactive-outbound-mandate`, and
`adr-2026-07-18-terminal-claim-clock`. None of the edited regions falls inside a
pair; `scripts/check-boundary-sync.sh` was green before and after. If a later
amendment reaches `ADR-2026-06-06-two-axis-provider-model.md` (which does carry a
live synchronized marker and names the sandbox axis), the paired byte-identical
commit rule applies, OSS side first.

Platform-side documents are enumerated in the mirrored stub, and the
paired-commit rule applies: **OSS side first.**

### Two things the accepting commit deliberately did NOT do

Recorded so their absence reads as a decision rather than an omission.

- **It did not correct `011`'s unrelated 2026-08-03 "Command surface note".**
  That note asserts the OSS binary exposes no `host` command, which shipped code
  has since falsified. It is `ADR-2026-08-03`'s own cleanup debt, not this ADR's,
  and folding it in would have put an unauthorized edit inside an accepting
  commit whose whole discipline is that its edit list is closed. *(This ADR does
  correct the same staleness where `ADR-2026-08-03` itself asserts it, because
  that document is on this ADR's own edit list.)*
- **It did not begin the D10 naming refactor.** D10.3 gates every rename —
  prose included — on the wording-only / schema-or-wire separation existing on
  paper. The D2 renames landed because they are enumerated here with named
  targets and an alias discipline, not because the D10 gate opened.

### One risk carried forward, named rather than resolved

`/api/daemon/workarea/stats` (singular) lands one character away from the
already-shipped `/api/daemon/workareas` (plural), which addresses **individual**
workareas and their archives rather than the cache. That is uncomfortably close
to the two-referents-one-noun defect D4 rule 1 exists to prevent, in the very
ADR that claims to be that rule's third and fourth applications. It is carried
as specified because the target is what this ADR decided and the code ships in
lock-step with it (R-C) — but if a follow-up prefers an unambiguous spelling,
`/api/daemon/workarea-cache/*` is the shape to take, and it must move under the
same declared-removal-version alias discipline.

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
- **The building blocks are written down** (R1), negatively as well as
  positively. The five wrong readings of "pool" that this program produced are
  each named and refuted in one place, so the next reader does not rediscover
  them.
- **The concept that had no word now has one.** The place where unlike capacity
  composes is a named **capacity profile** (D6.2), not an invisible per-project
  singleton.
- **Four deferred questions are closed with reasons, not with silence.** D8 and
  D9 in particular record *why* a deferral is a deferral and, for D8, what would
  end it — so neither reads as an oversight later.
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
- **Predictive burst is still missing.** Deferring it means local exhaustion
  continues to end dispatches until failure-triggered routing-around ships. This
  ADR reduces that from a silent contradiction to a scoped first iteration plus
  a named open question, which is progress but not a fix.
- **D6.2 adds an object.** The capacity profile is a new named entity with a
  grant edge and a migration. This is the one place this ADR is genuinely more
  expensive than a rename, and the accepting work must budget for it.
- **`004` needs real work, not a header bump.** Marking it historical is the
  cheap move; amending it properly is a separate piece of authorship.

### Risks

- **D6.2 could be mis-sized as a rename.** "Route → capacity profile" reads like
  wording and is not: it changes CRUD shape, adds a grant edge, and touches the
  surfaces that name it. Mitigation: it is flagged as a **shape change** in the
  rename-vs-behaviour table, in D6.2 itself, and again in § "What the
  accepting commit carried".
- **D10's refactor could start before it is sized.** The stated preference to
  pay the cost now is easy to read as authorization to begin. It is not:
  D10 gates on the wording-only / schema-or-wire separation existing on paper
  first. Mitigation: stated as a numbered condition rather than as advice.
- **A rename sweep could catch the one correct use of `sandbox`.** The OSS
  contract's `PlacementRef.kind: 'sandbox'` literal is exactly D1's ephemeral
  kind and must be excluded. Mitigation: D10.4 names it explicitly.
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

- **Make pools heterogeneous (multi-provider).** Rejected (D6.1): it rewrites
  the lane split rather than relaxing a field; it re-creates inside the pool the
  two-truth-source conflict that the platform corpus already rejected at org
  level; and the composition point exists one level up, now named (D6.2). A pool
  that mixed providers would also contradict R1 directly — it would be the "bag
  of heterogeneous sandboxes" a pool explicitly is not.
- **Name hosts in a composition instead of pools.** Rejected (D9): pool naming
  already carries targeting — machine-specific pools today, geographic pools at
  scale — so host-pinning would add an authoring axis to express something the
  existing one expresses better, and would bind an author to a machine that can
  go away.
- **Enforce the per-pool project grant now, since the mechanism already
  exists.** Rejected (D8): the mechanism existing is not the same as the admin
  surface existing. Enforcing today makes every new pool unusable until someone
  finds a screen that is not mature, which is friction aimed squarely at new
  users, and it builds a second policy site the policy engine would later have
  to absorb.
- **Rename `harness`.** Rejected: it is convergent with the industry, it is a
  contract-bearing axis in two Accepted ADRs, and the earlier assessment that
  suggested divergence has been withdrawn. See § "Harness is retained".
- **Start the naming refactor immediately, since the cheap window is now.**
  Rejected (D10): the cost curve argument is accepted, the unsized start is not.
  A refactor that has not separated prose from schema is how a wording sweep
  becomes an unplanned migration.
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

Enumerated once, in § "What the accepting commit carried" above, with the exact
edit each document received. Per corpus convention those edits landed **in the
accepting commit**, not in the proposal. Platform-side amendments are enumerated
in the mirrored stub and land in the paired platform commit — **OSS side
first**.

## Affected work items

The corpus edits are done. The remaining tracker work splits into five
deliberately independent lanes:

1. **Corpus renames and the `004` amendment** — the reference-doc edits above.
   **Done in the accepting commit, for the documents on the checklist.** Five
   documents off it still carry referent 3; they are inventoried in § "Not
   edited — and exactly how far that goes" and are D10-gated (D10.7), not
   forgotten. "Done" here means *the checklist is discharged*, which is a
   narrower claim than *the corpus is uniform*.
2. **The OSS daemon workarea-surface alias cycle** (D2.3/D2.4), each alias
   declaring `v0.59.0` as its removal version. Per R-C this ships in lock-step
   with the accepting commit, not after it — `011` describes the aliased end
   state, so the code must carry it before the corpus is true.
3. **Platform-side vocabulary unification** and the stale burst help-string
   deletion (D7).
4. **Harness as an authoring input** (D5) — delivery of `ADR-2026-06-06` /
   `ADR-2026-08-05` and the platform corpus's 2026-08-06 service-composition
   ADR, not new scope, and should be tracked against those.
5. **The capacity-profile promotion** (D6.2) — the one lane that is a shape
   change: a named, org-authored, project-granted object with its own verbs, a
   grant edge, and a migration that preserves the never-required invariant.
   Plan it with D8's future enforcement in mind (shared migration) but do not
   bundle enforcement into it.

The D10 sizing pass is a prerequisite artifact for any renaming work in lanes 1
and 3 that reaches a schema or a wire, and is not itself a lane.

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
  the routing-around mechanism** — see D7's traps. It is host-level overflow
  within one lane and can never cross into an ephemeral pool.
- **Do not re-open R2–R5.** Each is recorded with its rationale precisely so a
  later reader inherits the reasoning rather than the conclusion. If one is to
  change, it changes by a superseding ADR that engages the recorded rationale,
  not by a fresh round of the same question.
- **D7 now has a build gate; D2.3's residue deliberately does not.**
  `scripts/retired-claim-lint.sh` (CI: `retired-claim-lint.yml`) fails the build
  when a retired claim is re-asserted. It exists because the first pass of this
  ADR's accepting commit deleted the `cloud-burst` claim from `004` and left the
  identical claim in `013` — in a file that same commit had already edited for
  D2.2 — where it survived review. **A `✅ owns` cell is a capability assertion,
  and nothing in this corpus was checking them.** Quoting a retired claim stays
  legal: a string inside `backticks` is read as a citation, which is what an
  epitaph or a renamed-from banner is. The D2.3 sites listed in § "Not edited"
  are intentionally *not* rules yet — a gate that fires on documents nobody is
  authorized to edit until the D10 sizing pass is a gate that gets bypassed, and
  a bypassed gate is worse than an absent one. Add those rules in the commit
  that does the sweep. This gate is **not** the D5.4 alias-expiry gate, which
  remains unbuilt and is a separate deliverable.
