---
status: Accepted
date: 2026-08-08
boundary: shared
split: inline-addenda
---

# ADR-2026-08-08 — The harness-authority admission plane is parked; the vendored capability matrix is the production lane

**Status:** Accepted
**Date:** 2026-08-08
**Boundary:** shared (the invariant and the lane declaration are OSS-canonical here; the control-plane census, schema, and revival mechanics live in the mirrored stub)
**Authors:** platform-native operations lane, WP-09

## Context

Two mechanisms in this architecture answer the same question — *may this
harness, driving this model on this serving endpoint under this auth binding at
this placement, run this session with these capabilities?* Both are built. Only
one carries traffic.

**Mechanism A — the harness-authority admission plane.** Specified by
[`ADR-2026-08-05-versioned-execution-cell-and-session-reference.md`](ADR-2026-08-05-versioned-execution-cell-and-session-reference.md)
and
[`ADR-2026-08-06-harness-adaptation-plan-and-receipt.md`](ADR-2026-08-06-harness-adaptation-plan-and-receipt.md),
and realized downstream in the control plane as a chain: a harness-definition
catalog declaring a compatibility ceiling, versioned harness connections binding
that definition to an endpoint, auth binding and placement, per-project grants,
immutable probe reports, promoted probe heads under a short freshness TTL, and
an immutable admission receipt written before enqueue. It is a genuinely good
subsystem — fail-closed at every hop, digest-bound, redacted by construction,
with a durable revision history.

**Mechanism B — the vendored capability matrix.** Specified by
[`ADR-2026-06-06-two-axis-provider-model.md`](ADR-2026-06-06-two-axis-provider-model.md).
`matrix.json`, `harnesses.json`, and `endpoints.json` are generated in *this*
repo by `go generate ./matrix/...` from per-provider Go `Manifest` literals, then
vendored downstream as committed fixtures and read at resolve time. No probe, no
receipt, no TTL — a static declaration of which cells exist.

Mechanism A was built to do what a static declaration cannot: prove an account
is logged in, prove an endpoint is reachable from a host, prove a model is
present today. That reasoning was and remains correct. It is not why this ADR
exists.

This ADR exists because Mechanism A has been complete and deployed for weeks
and, as measured, governs **no real traffic** — while Mechanism B resolves
**every** session that has ever run. And because of *how* that was discovered:
the admission plane's receipts were about to be accepted as proof that
end-to-end dispatch worked, when in fact the runner refuses to spawn the cells
those receipts admit.

## The findings

Established 2026-08-08. Per this corpus's boundary discipline the counts stay in
the private run record and the mirrored stub; the **shape** of each finding is
the architectural content and is stated here. Findings that rest on OSS source
or on committed generated artifacts are cited exactly, because they are
reproducible from this repository.

**F1 — the definition catalog has no system-scope entry.** Every harness
definition that exists is tenant-scoped, and every one names a smoke-fixture
harness that appears in no manifest, no matrix cell, and no shipped binary. The
catalog that was added to give the admitted cell's compatibility digest a real
declared ceiling has never described a harness that ships.

**F2 — every connection that has ever existed belongs to one smoke tenant,** and
most of those are soft-deleted. No other tenant has ever authored one.

**F3 — no promoted probe head anywhere is fresh.** Against a 90-second
freshness TTL, the youngest promoted head is orders of magnitude past expiry.
Admission is gated on a fresh head, so as it stands the plane would deny every
dispatch even if one were routed to it.

**F4 — admission is not execution.** Every admission receipt ever written
belongs to that same smoke tenant, is `admitted`, and grants exactly one
capability, drawn from two names. **Both of those names land on channels the
runner hard-denies.** In `donmai/agent/tool_adaptation.go:334-345`, every
lifecycle-channel and replay-channel requirement is marked
`ToolDeliveryUnsupported` with `fallbackDenied: true`, so a *required* entry on
either channel returns `ToolDenialDeliveryUnsupported` and denies spawn. The
comment sitting on that branch states the reason plainly — the runner does not
promote admission receipts from actual runtime events, and a declaration alone
is not evidence. **Every receipt the plane has ever written admits a cell the
runner then refuses to spawn.**

**F5 — real sessions do not touch it.** No admission receipt has ever been
written outside the smoke tenant, while every session that has ever run
resolved through the vendored matrix.

An earlier summary of F4 recorded the receipts as uniformly granting one
capability name. That is wrong in detail and the correction is preserved here:
two names are in play. It does not weaken the finding — it strengthens it,
because both names land on hard-denied channels, so the refusal rate is total
rather than partial.

### Every named blocker is closed, and nothing moved

This is the part that decides the question. The prior write-up of Mechanism A
named a specific reason it governed nothing: the promotion principal had no
issuer and no credential, so no route could mint production-eligible evidence.
That blocker is **closed** — the promoter credential is provisioned in the
deployed environment, and the re-promotion loop is registered on a once-a-minute
schedule.

With the credential present and the loop scheduled, F3 is unchanged. The loop is
doing exactly what it was built to do: it sustains a promoted head only while a
live host still corroborates the exact promoted evidence, and no host reports an
inventory containing these fictional harnesses, so there is nothing to sustain.
The subsystem is not waiting on a missing piece. It is waiting on a population
of real connections that nobody has had a reason to create, because the vendored
matrix already answers the question for every harness that actually ships.

A subsystem whose last named blocker was removed without anything moving is not
blocked. It is unused.

## Decision

### D1 — The harness-authority admission plane is PARKED, not deleted

Parked is a real, named state with defined semantics (D4). This ADR does not
supersede `ADR-2026-08-05` or `ADR-2026-08-06`: the execution-cell contract, the
admission receipt, the `SessionRef`, and the adaptation plan and receipt remain
**Accepted architecture**. What is parked is the *authority-store realization* —
the definition catalog, connection store, grant table, probe and promotion
chain, and the receipt ledger built on top of them.

### D2 — The vendored capability matrix is the production lane, and is named as such

Every capability question asked on behalf of a real session is answered by the
matrix generated in this repo, until and unless D5's revival conditions are met.
This is a **statement of where investment goes**, not merely a description of
current traffic. Work that improves capability resolution for real users —
keeping the vendored copy honest against the generated source of truth,
declaring per-harness interactive support truthfully, closing the gap between
what a harness declares and what it can be handed at spawn — belongs on the
matrix lane.

### D3 — The invariant: a capability grant must intersect an executor-attested inventory

**An admission plane that can grant a capability its executor will refuse is
worse than no admission plane.** State it as a general rule, because it is not a
bug report about one subsystem:

> A control plane that admits work converts a *fast, local, free* failure into a
> *late, remote, post-commit, post-quota-charge* one whenever its grant is
> broader than what the executor will actually deliver. The admission step is
> only worth its cost if the set it grants is a **subset** of what the executor
> has attested it can perform.

The admission equation was specified as *declared compatibility ∩ live
inventory*. Both terms describe the **cell** — which harness, endpoint, model
and placement may combine. Neither term describes the **executor's delivery
surface** — which capabilities the runner will actually apply for that exact
harness and version. So the grant was computed from the request: the requested
capabilities were copied into the granted set once the cell resolved, with
nothing anywhere in that path consulting the runner at all.

The invariant, stated so it can be tested:

- **D3.1** — The granted capability set MUST be the intersection of the
  requested set with a capability inventory **attested by the executor** for the
  exact harness and version being admitted. A requested capability with no
  attestation is denied at admission, not granted and refused later.
- **D3.2** — That attestation MUST derive from the same generated artifact the
  executor itself reads (per `ADR-2026-06-06`, the generated matrix), not from a
  hand-maintained list on the admitting side. Two hand-maintained truth sources
  for one capability is the defect, not the cure.
- **D3.3** — The gate MUST be tested on its **input**: assert that the admission
  path refuses a capability the executor's declared surface omits. A test that
  asserts the admission path returns a receipt proves only that the admission
  path returns a receipt — which is exactly the evidence that nearly passed for
  working end-to-end dispatch here.
- **D3.4** — Where an executor's refusal genuinely cannot be known at admission
  time, admission MUST NOT charge quota or write a durable commitment before the
  executor accepts. Cost may follow a grant only when the grant is decisive.

D3 binds any future admission plane in this architecture, parked or otherwise.
It is the durable content of this ADR; the parking is the disposable part.

### D4 — What "parked" means operationally

**Stays as it is:**

- All persisted rows remain. Nothing is dropped, truncated, or migrated away.
  The revision history and the immutable receipts are the record of what the
  subsystem did, and deleting them would destroy the evidence for D3.
- The deployed routes and the re-promotion loop stay deployed and stay
  fail-closed. They already refuse to act without a credential and a
  corroborating live observation, and they report that refusal by name; a loop
  that is honest and idle is cheaper to leave running than to remove and later
  rebuild.
- Existing tests stay in the suite and stay green. The subsystem is correct; its
  tests are not the problem.

**Stops:**

- No new feature work, no new surface, no tenant-facing authoring UI, no new
  probe classes, no expansion of the admission equation.
- It stops being cited as the mechanism behind any roadmap item. An item whose
  plan depends on this plane is, as of this ADR, an item without a plan.
- It stops accruing acceptance criteria. See D6.

**Does not change:**

- `ADR-2026-08-05` and `ADR-2026-08-06` keep their Accepted status. The
  contracts are right; this ADR parks one realization of one of them.

### D5 — What must be true to revive it

Revival is not a judgement call. All four conditions, together:

1. **A real, non-smoke tenant holds a configured connection** naming a harness
   that actually ships in the generated matrix — not a fixture.
2. **A live host corroborates it.** A host reports an inventory containing that
   harness, so a promoted head can stay fresh through ordinary operation rather
   than through a one-shot promotion inside a test.
3. **D3 is satisfied first.** The granted set is an executor-attested
   intersection, with the D3.3 input-side test written and watched to fail
   before it passes. Reviving admission before D3 reproduces exactly the failure
   this ADR records.
4. **A named question the matrix provably cannot answer**, stated concretely
   ("is this tenant's account currently authenticated against this endpoint"),
   with evidence that it is costing real users — not a hypothetical.

Conditions 1 and 2 have never been met. They are also the cheapest to meet,
which is itself the strongest argument that nobody has needed to.

### D6 — Smoke-tenant receipts are not acceptance evidence

A receipt written in a smoke tenant proves the write path works. It does not
prove a session ran. Acceptance for anything in this area requires a non-smoke
tenant **and** a proven spawn. This is a general standard, recorded here because
this subsystem is where it was nearly violated: several work items were about to
be accepted on receipt evidence alone, for cells the runner refuses to spawn.

### D7 — The production lane's own defect is recorded, not laundered

Naming the matrix as the production lane does not certify it healthy.
Established the same day, from committed artifacts in this repository and the
vendored copies downstream:

- The vendored fixtures are **pinned to a release two minor versions behind**
  the current tag of this repo, and both `matrix.json` and `harnesses.json`
  differ byte-for-byte from what `go generate` produces here today.
- The consumer-side parity gate hashes each committed fixture against a
  **release manifest committed beside it in the same repository**. Both inputs
  are vendored together, so the assertion can only detect an edit to one of two
  co-committed files. It cannot detect that the pin is stale, and it has stayed
  green across the entire drift.

`ADR-2026-06-06` specified something stronger: a load-bearing parity gate
blocking merges on *"the JSON being byte-identical to a fresh `go generate`"*.
The shipped consumer-side gate does not implement that. **The corpus is right
and the code needs to align** — the addendum landing with this ADR records the
divergence in `ADR-2026-06-06` itself so it is not rediscovered a third time.

This is the same failure shape as F3's stale probe heads: **evidence that
certifies itself.** A freshness claim whose only witness is committed next to
the thing it witnesses is not freshness. Both lanes produced one; only one of
them was noticed.

## How to read the parked subsystem if you find it

Written for the agent or engineer who discovers this code cold, because that is
the failure mode a parking decision has to defend against.

- **Its existence is not a statement of direction.** It is a complete, correct
  subsystem that was overtaken by a simpler one. Sophistication is not evidence
  of intent, and neither is line count.
- **Do not extend it because it looks unfinished.** It is not unfinished. Every
  named blocker is closed. Adding the next obvious piece will not change any
  finding above.
- **Do not delete it either.** It is the worked example behind D3, and D5 states
  the conditions under which it becomes the right answer. Those conditions are
  plausible; they are just not true yet.
- **If you are here because something needs a capability decision:** that
  decision belongs on the matrix lane (D2). If the matrix genuinely cannot
  answer your question, you have found D5 condition 4 — write it down with
  evidence and reopen this ADR rather than building a second plane beside it.

## Consequences

### Positive

- One lane is named, so capability work stops being split across two truth
  sources that disagree about which harnesses exist.
- The invariant in D3 is stated where it binds future work, rather than living
  as a one-off incident note in a run record.
- The next reader of the parked code inherits the reason it is quiet, which is
  the single most expensive thing to reconstruct from source.
- Acceptance standards tighten (D6) for a class of work item that was about to
  be closed on evidence that proved something else.

### Negative

- The architecture keeps a complete subsystem it does not use, with the ongoing
  cost of a deployed loop, a set of tables, and a maintained test suite.
- Live-inventory questions the matrix cannot answer stay unanswered. Sessions
  will keep failing at the runner for reasons a probe could have caught earlier
  — including the case where a resolved harness does not support interactive
  spawn at all, which is admitted today and dies at the runner.
- The effort spent building the authority plane does not pay off in this cycle.
  This ADR does not pretend otherwise.

### Risks

- **Parking decays into rot.** A subsystem nobody maintains and nobody deletes
  degrades quietly. Mitigation: D4 keeps its tests in the suite, so decay
  surfaces as a failure rather than as silence.
- **A future reader reads "parked" as "nearly ready".** Mitigation: § How to
  read is written directly at that reader, and D5's conditions are falsifiable
  rather than aspirational.
- **The matrix lane inherits the same self-certifying-evidence defect** and
  nobody fixes it because this ADR "already covered it". Mitigation: D7 states
  the defect as a live divergence from `ADR-2026-06-06`, not as background.
- **D3 gets read as applying only to the parked plane.** It does not. Any
  admission, quota, or reservation step that commits before an executor accepts
  is in scope.

## Alternatives considered

**Delete the authority plane outright.** This architecture's normal posture with
no dependent users is hard deletion rather than deprecation, and it was the
default answer here. Rejected on two grounds: the immutable receipts are the
evidence for D3 and would be destroyed with them, and D5's conditions are
genuinely plausible on a horizon where tenant-supplied endpoints and accounts
matter — at which point a correct fail-closed implementation is worth
considerably more than the disk it occupies. This is a deliberate exception to
the hard-delete default, not an oversight of it.

**Finish it — wire the last mile and let it govern production.** Rejected: it is
already finished. The findings show a complete chain with a live credential and
a scheduled loop producing no fresh evidence, because no real connection exists
to probe. "Finishing" means populating it, and populating it means every tenant
authors connection rows for harnesses the matrix already describes statically —
cost with no answered question. D5 condition 4 exists precisely to force that
question to be named before this path reopens.

**Run both, with the authority plane as an advisory overlay.** Rejected as the
worst option available. Two truth sources for one decision, with the advisory
one non-binding, is how a plane that grants what the executor refuses gets built
in the first place — and F4 is what that costs. If admission is worth doing it
must be decisive (D3.4); if it is not decisive it should not run.

**Fix the grant computation and keep going.** Correct, and insufficient. D3
fixes the *class* and is retained as this ADR's durable content; it is sequenced
ahead of any revival (D5 condition 3). But fixing the grant would not have made
a single real session route through the plane, because the reason none does is
population, not correctness.

## Affected documents

The following edits land in the commit that sets this ADR to `Accepted`:

- `001-layered-execution-model.md` § "Capability flags as the abstraction
  technique" — adds D3 as an explicit limit on the capability-flag technique: a
  flag only the admitting side reads is not a capability, and a grant must
  intersect an executor-attested inventory.
- `ADR-2026-06-06-two-axis-provider-model.md` — addendum recording that the
  shipped consumer-side parity gate is a closed loop against a co-committed
  release manifest rather than the specified byte-identity comparison against a
  fresh `go generate`, with the drift it has been hiding (D7).
- `ADR-2026-08-05-versioned-execution-cell-and-session-reference.md` — status
  note: the contract remains Accepted; its authority-store realization is parked
  by this ADR, and D3 constrains its grant computation.
- `README.md` and `AGENTS.md` — index and read-order entries.

This ADR does **not** touch the `BOUNDARY-SYNC` region in
`001-layered-execution-model.md`; `scripts/check-boundary-sync.sh` was run and
reports no drift.

No `scripts/retired-claim-lint.sh` rule is added, deliberately. The claim this
ADR would retire — that the authority plane governs production dispatch — is
asserted nowhere in this corpus: `ADR-2026-08-05` already states in its own
Context that it accepts architecture only and does not claim any artifact
implements it. A lint rule with no possible match is a gate that cannot fail,
which this corpus treats as worse than no gate. The false belief lived in a
work-item acceptance recipe, not in prose, and D6 is the control for it.

## Affected work items

Tracked in the platform corpus stub, which carries the tenant-scoped work-item
references. Several items in the parked area were on the verge of acceptance on
receipt-only evidence; D6 blocks that and re-scopes them.

## Implementation notes

- D3.3's test belongs on the admission path's **input**: construct a request for
  a capability absent from the executor's declared surface for that exact
  harness and version, and assert admission **denies**. Watch it fail before the
  gate exists. Asserting on a mocked admission response tests the mock.
- D7's fix is a change to the consumer-side parity gate so its comparison target
  is the generated artifact rather than a co-committed manifest, plus a resync
  of the vendored fixtures. It is separate delivery work on the matrix lane and
  is not part of this ADR's accepting commit.
- The executor-attested surface D3.1 needs already exists as generated data in
  this repo. D3 is a wiring problem, not a new artifact.
