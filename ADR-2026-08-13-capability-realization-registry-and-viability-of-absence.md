---
status: Proposed
date: 2026-08-13
boundary: shared
split: inline-addenda
---

# ADR-2026-08-13 — User-facing capabilities compile to per-harness realizations: the registry, the attested surface, and the viability of absence

**Status:** Proposed
**Date:** 2026-08-13
**Boundary:** shared (the realization object, the registry shape and its declaration
rule, the delivered-surface attestation, the viability rule, the authoring
contract and the matrix-derivation rule are OSS-canonical here; the tenant-facing
capability catalog, entitlement, and the recipes whose tools speak a hosted
control plane live downstream and are summarized in the mirrored stub)
**Authors:** coordinator-swarm design lane

## Context

A user asks for **Memory**. Or **A2A**, or **Code Intelligence**, or
**Architectural Intelligence**. That is the whole of the user's intent, and it is
harness-neutral: the user is asking for a faculty the agent will have, not for a
mechanism by which the agent acquires it.

The mechanism, however, is different on every harness. On `claude-code` the same
capability arrives as a prompt partial appended to the system prompt plus an MCP
server named in a config file passed by flag. On `pi` it arrives as tools
registered by an operator-injected extension loaded through the seam
[`ADR-2026-08-12`](ADR-2026-08-12-pi-extension-delivery-seam-and-capability-pack-boundary.md)
just opened — with no MCP hop at all, because the whole point of the pack is that
there is no second server to run. On `codex` it arrives as an entry written into
a private `config.toml` under a runner-owned config home, activated and then
verified against the harness's own server inventory. Three harnesses, one
capability, three completely different sets of bytes moving to completely
different places.

Somebody has to perform that translation. Today the translation is real, it runs
on every spawn, and it has **no name and no single owner** — which means it also
has no registry, no version, no evidence, and no answer to the one question that
matters when it cannot be performed: *what happens to a capability on a harness
where it does not exist?*

The answer today, at least once, was: nothing visible. The session spawned. The
capability was not there. The agent, told in prose that it had a faculty it did
not have, behaved accordingly. That is the bug class this ADR closes at the root,
and it is worth being precise about why it is a bug class rather than a bug: a
capability that silently degrades is indistinguishable, from every surface a
human or a resolver can see, from a capability that works. It produces no denial
code, no exclusion record, and no failed gate. It is the placement-law failure
mode — a silent downgrade — arriving one layer below placement, where the law
does not yet reach.

The corpus is not short of the *rule*. It states it three times, once per
special case, and never names the object the rule is about — which is why each
statement has had to be rediscovered by the next author.

## The findings

Every finding is reproducible from OSS source in the `donmai` repository at the
current pin, or from this corpus. Findings touching the closed control plane are
stated as shapes, with any measurement left in the private run record.

**F1 — the compile step already exists in code, is already per-harness, and does
not know what it is compiling.** The harness preparation entry point takes a
harness-neutral spec plus the exact harness manifest and produces per-harness
deliveries; the delivery kinds are already literal realization names — a
CLI MCP-config flag on one harness, an app-server MCP call on another, a
project-scoped MCP config file on a third, a handshake-verified extension on a
fourth. The per-harness profile declares which **channels** it can deliver and
at what evidence tier. What neither the plan nor the profile carries is the
**capability a delivery realizes**. The binding from a user-facing capability to
the channel set that realizes it therefore lives in whatever code assembled the
spec — which is the textbook shape of a fact with more than one producer, the
defect [`ADR-2026-08-08`](ADR-2026-08-08-harness-as-versioned-deliverable.md)
D1.2 rules out one axis over.

**F2 — the per-harness capability bits are authored literals validated against a
manifest authored beside them.** The matrix is genuinely generated and its parity
gate is genuinely load-bearing — it byte-compares the committed artifact against
a fresh generation and asserts the cell's capabilities are a subset of the
harness's. But the cells it renders are hand-written literals checked against
harvested manifests that ship in the same change. This is exactly the defect
`ADR-2026-08-08` D7 named in the winning lane: a gate that compares a fixture to
a manifest committed with it cannot see a claim that was never measured. A bit
**derived from realization presence** has no literal to author, which is the only
durable fix.

**F3 — the harness with the richest tool realization has a matrix row saying it
supports neither tools nor MCP.** That row is truthful about **channels**: the
harness accepts no MCP server spec and no allowed-tools list, and it says so. It
is silent about **capabilities**, because the matrix has no capability axis. A
reader — or a resolver, or a future author — who reads a channel bit as
capability availability concludes that the one harness carrying an
operator-injected tool surface can carry no tools. Channels and capabilities are
two axes and only one of them is in the artifact.

**F4 — the stage-2 viability exclusion is a prose string.** The decision record
carries per-candidate exclusions with a stage and a rule id, and the contract for
that record states the rule id is a stable name and never only prose. The filter
that actually produces them composes its reason as a formatted sentence, and
neither field is a closed type on either side of the wire. An exclusion no
consumer can switch on is an exclusion every consumer re-derives, and a re-derived
exclusion is precisely where a silent downgrade re-enters after being evicted
from the resolver.

**F5 — the receipt attests the runner's action, not the harness's resulting
surface.** An `installed` outcome on a delivery entry is a true statement that
the runner wrote the file, passed the flag, or materialized the artifact. It is
not a statement that the harness ended up with the tools the capability promised.
The generic tool-lifecycle registration seam that would supply the observation
side does not exist yet — the contract has a plan half and a receipt half and no
observation half. This ADR states the contract that work must satisfy; it does
not claim it ships.

**F6 — the corpus already states the rule, three times, each time for one case,
and never names the object.** `007` § "Intelligence activation at harness
adaptation" says granting a service and telling an agent how to use it are
separate operations, and that a prompt-only substitute is not a downgrade. `002`
§ "Capabilities — the abstraction technique applied" says a discrepancy detected
at activation must fail rather than silently degrade. `001` § "Capability flags
as the abstraction technique" names the limit exactly: *a flag only the admitting
side reads is not a capability*. Three statements of one rule. None of them names
the **realization** — the thing that either exists on this harness or does not,
and whose absence is the fact all three are circling.

## Decision

### D1 — The realization is a first-class named object, and the registry is keyed on capability × adapter version

Four nouns, one meaning each:

- A **capability** is the user-facing faculty. It is what a user selects, what a
  grant admits, and what a receipt is ultimately about. It is harness-neutral by
  construction: if a capability's definition mentions a harness, it is not a
  capability.
- A **realization** is the binding of one capability to one **harness adapter
  version**. It either exists or it does not. Its absence is a fact about the
  world, not a condition to be worked around.
- A **recipe** is a realization's content: an ordered list of adaptation entry
  templates drawn **only** from the closed channel and delivery vocabularies of
  [`ADR-2026-08-06`](ADR-2026-08-06-harness-adaptation-plan-and-receipt.md) D2,
  plus the **declared surface** — the tool, server, and partial identities the
  recipe asserts will exist after application.
- The **delivered surface** is what was observed to exist after application. D3
  is about the gap between it and the declared surface.

**D1.1 — the key is the adapter version, never the harness family.** A
realization is a property of the exact integration that will run, which is what
`ADR-2026-08-08` D1 says the adapter version names. Two adapter versions of one
harness may realize a capability differently, or one of them not at all, and the
registry must be able to say so. A registry keyed on family would be unable to
express the thing it exists to express.

**D1.2 — recipes add no channel and no delivery name.** A recipe composes
existing entries; it never introduces a vocabulary. This is
[`ADR-2026-08-12`](ADR-2026-08-12-pi-extension-delivery-seam-and-capability-pack-boundary.md)
D1.1 applied one level up: a capability whose realization needed a new channel
name would be a capability arriving without passing the parity gate.

**D1.3 — the registry is versioned and content-addressed.** Each recipe carries a
digest over its canonical serialization. The digest enters the compiled plan on
the entries the recipe produced and is echoed in the receipt, so "which
realization ran" is answerable from evidence rather than from the registry's
current state. A registry read at incident time is a statement about now; a
digest in a receipt is a statement about then.

**D1.4 — one producer.** The capability-to-channel binding lives **only** in the
registry. Code that assembles channel entries for a capability by hand is out of
contract, whether it sits in the OSS layer or downstream. This is the fix for F1
and it is the whole reason the object needs a name.

**D1.5 — there is no cross-harness "realizes capability X" boolean.** Realization
is per adapter version with its own evidence, exactly as extension delivery is
per harness under `ADR-2026-08-12` D5.5, and for the same reason: a flag spanning
mechanisms it cannot name is a claim the executor may refuse.

### D2 — OSS declares realizations for OSS surfaces; downstream supplies the rest through the same interface

**D2.1 — the registry, the compiler, and the OSS realizations are OSS, and the
layering rule holds by construction rather than by promise.** The registry shape,
the compile step, the digest discipline, the attestation contract (D3), the
viability rule (D4), the authoring contract (D5) and the derivation rule (D6) are
OSS contract with OSS code behind them, and the OSS layer already ships
capabilities with per-harness realizations: the in-box stdio MCP pattern of
[`ADR-2026-07-05`](ADR-2026-07-05-self-referential-stdio-mcp-in-box-capability.md)
*is* a capability realized differently per harness, shipped, running, and usable
on one machine with no control plane. `001` rule 2 is therefore satisfied by an
existing implementation, which is the same test `ADR-2026-08-12` D5.1 passed and
the same way it passed it.

**D2.2 — a recipe whose tools speak a hosted control plane is a downstream
deliverable registered through the interface.** Those tools are the client half
of a service the OSS layer does not run; publishing them here would ship the
type-without-implementation the boundary forbids. They are supplied at
composition time by the composing binary through the same registration interface
the OSS realizations use, and delivered through the existing seam. The seam ADR
generalized one embedded pack to N packs on one harness; this generalizes N packs
on one harness to N capabilities across M harnesses, and — like its predecessor —
it adds a plural to the OSS layer without adding a policy to it.

**D2.3 — the registry never names a downstream capability or realization.** No
allowlist of known capability identities, no capability-specific field, no branch
in the compiler keyed on which capability is being realized, no reserved marker.
If a downstream recipe needs a compiler change, exactly one of two things is
true: the change is generic and lands in the registry contract for everyone, or
the recipe is out of contract. This is `ADR-2026-08-12` D5.3 at the next level up,
and it is the rule that keeps the split from decaying into a closed capability
system with an open loader.

**D2.4 — a realization may never widen the admitted surface.** A recipe delivers
**within** a capability the admitted cell already carries. Registering a
realization can never make a cell capable of something it was not admitted for.
This is `ADR-2026-08-12` D5.4 restated for the object one level up, and it
inherits that rule's justification from
[`ADR-2026-08-08-harness-authority-admission-plane-parked.md`](ADR-2026-08-08-harness-authority-admission-plane-parked.md)
D3: a declaration that grants what the executor will refuse converts a local,
free, immediate failure into a remote, post-admission, post-charge one.

### D3 — The receipt attests the delivered surface, not the delivery action

`installed` on a realization entry is upgraded from a claim about the runner to a
claim about the harness. An entry produced by a recipe may record `installed`
only when the **observed** post-application surface contains every identity in the
recipe's declared surface.

**D3.1 — the observation is executor-attested and comes from the artifact the
executor reads.** Not from the runner's own record of what it wrote, and not from
a re-parse of the config the runner authored — both of those are the runner
checking its own homework. This is `001` § "Capability flags as the abstraction
technique"'s limit paragraph applied at **delivery** time, where the parked
admission plane's D3 applied it at **admission** time; it is the same rule and
the same failure it prevents.

**D3.2 — a short surface is a denial, never a downgrade.** An entry whose
observed surface is missing a declared identity records the existing
`required_entry_denied` code (or its optional-entry equivalent) and, for a
required entry, produces a denied receipt with zero credential-delivery and spawn
side effects. `downgraded` remains valid only where `ADR-2026-08-06` D4 already
permits it: a **pre-authorized, named** alternative present in the plan. There is
no path on which a realization delivers less than it declared and the session
starts anyway. This is the single sentence that closes the bug class.

**D3.3 — headless and interactive attestation do not cross.** A realization
proven in one session mode may not inherit that evidence into the other, per
`ADR-2026-08-06` D6 and `ADR-2026-08-12` D3.2. Where a capability's realization
differs by mode — and on at least one harness it does — that asymmetry is
declared in the registry as two realizations, not smoothed into one.

**D3.4 — no new receipt type and no new channel.** The attestation is additional
**evidence** on existing entries, carrying the recipe digest and an evidence
digest over the observed surface. `ADR-2026-08-06` D2's schema is closed and
stays closed.

**D3.5 — the observation side is the tool-lifecycle registration seam, and it is
work in flight.** This ADR specifies the contract that seam must satisfy: a
single producer of the observed-identity inventory, read by the receipt (D3.1)
and by the matrix generator (D6.5), and by nothing that re-derives it. Stating
the contract now is what keeps the seam from shipping an inventory the receipt
cannot use.

### D4 — No realization is a typed viability exclusion, and it is the only permitted outcome of absence

When a dispatch demands capability C and a candidate's adapter version carries no
registered realization for C at a production-eligible evidence tier, **the
candidate is not viable**. It is excluded at stage 2 of the placement composition
law with a per-candidate exclusion record.

**D4.1 — the exclusion reason is a closed, named type.** Not a formatted
sentence. The resolver that emits it, the CLI that displays it, the operator who
reads it and the test that asserts it must all be naming the same value. This
closes F4, and it is the precondition for every other clause in this decision
being testable rather than aspirational.

**D4.2 — it is a hard filter, and it may empty the set.** Realization demand
enters at stage 2 and nowhere else: never as a stage-3 preference that a ranker
could trade away, never as a stage-4 score. Per
[`ADR-2026-08-12`](ADR-2026-08-12-placement-composition-law-and-single-fallback-rule.md)
D1.2, an empty surviving set is loud and typed, carrying every candidate
considered and the named rule that removed it. A dispatch demanding a capability
no available harness realizes **fails, visibly, at placement** — which is the
correct and useful outcome, and the one an operator can act on.

**D4.3 — prompt guidance is not a realization.** A recipe consisting only of
prompt contributions realizes a capability only where that capability's own
contract is advisory. Where the contract is a **callable surface**, a
partial-only recipe is a **non-realization** and produces the exclusion of this
decision rather than a plan. This is the specific mechanism by which the bug
class operated: text describing a faculty is indistinguishable, to the agent, from
the faculty — right up to the first call. `007` and `ADR-2026-08-06` D3 both
already say prompt guidance never evidences a service; this states the
consequence for the resolver.

**D4.4 — the only alternative to exclusion is a named, pre-authorized alternative
realization.** Registered in advance, admitted in advance, and recorded as a
`downgraded` outcome naming both entries. "Closest available realization",
"best-effort", and "partial capability" are not outcomes this architecture has.

**D4.5 — the demand is evaluated against the adapter version on the candidate.**
Not the harness name and not the family, per D1.1. A candidate running an adapter
version that predates a realization is excluded by the same rule that excludes one
which never had it, and the exclusion record says which.

### D5 — The authoring contract: the user selects a capability, and the realization appears nowhere

A user selects **Memory**. Never "Memory (MCP)", never "Memory (extension pack)",
never a partial to pair with it, never a per-harness variant.

**D5.1 — a falsifiable test for the boundary.** Changing the harness reference in
an authoring surface must not change the option set of the capability picker. If
it does, the compile step has leaked into authoring and the surface is out of
contract. This is stated as a test rather than a principle because "the user
selects one capability" is the kind of rule that erodes one reasonable-looking
dropdown at a time.

**D5.2 — companion partials attach automatically.** `ADR-2026-08-06` D3 and `007`
already require this; it is restated here because it is the same rule, and because
the failure it prevents — a user selecting a capability and separately selecting
the magic partial that makes it work — is authoring-surface-shaped.

**D5.3 — operators see a derived, read-only realization matrix.** Which
capability realizes on which adapter version, at what evidence tier, with what
declared surface. It is a **view** over the registry crossed with the evidence
ladder. It is never an authoring surface: an authored realization is an authored
capability claim, which is the shape `ADR-2026-08-08` D4 replaced with a computed
rung.

**D5.4 — the capability is the unit of grant; the realization is the unit of
delivery.** Admission grants capabilities and never realizations; adaptation
delivers realizations and never grants. `ADR-2026-08-06` D5's orchestration order
is unchanged by this ADR — the registry is consulted by the plan compiler, which
already sits between admission and spawn, and the compiler still cannot change
anything admission decided.

### D6 — Capability bits are computed from realization presence and passing evidence, on an axis distinct from channel bits

**D6.1 — a capability bit is derived, never authored.** The bit for capability C
on adapter version V is true when a realization for C is registered at V **and**
its fixture pack passes. This extends `ADR-2026-08-12` D6's first bullet from the
single `tools` bit to every capability, and it is the durable fix for F2 because a
derived bit has no literal to hand-author ahead of its evidence.

**D6.2 — capability bits and channel bits are separate axes and neither derives
from the other.** A channel bit says a delivery mechanism exists on this adapter.
A capability bit says a capability has a passing realization here. A capability
can be realized on a harness whose MCP channel bit is false — that is not an
anomaly, it is the pi case and it is the normal case for any harness with a
host-side extension API. Deriving either from the other is the channel-claim
error `ADR-2026-08-06` D3 forbids in terms, and F3 is what it looks like when the
capability axis is simply absent.

**D6.3 — enforcement is the matrix generator's parity gate, tested on its input.**
The gate must refuse a manifest that hand-declares a capability bit, and must
refuse a capability bit whose realization has no passing fixture. That is Go in
the source repository. Deliberately **not** a lint rule in this corpus, for the
reason `ADR-2026-08-12` D5.5 gave and `ADR-2026-08-08` gave before it: a
corpus-side gate for a claim the corpus never makes is a gate that cannot fail.

**D6.4 — registering, changing, or removing a realization moves the adapter
version.** The family ABI does not move (the contract with the agent package is
unchanged) and the binary pin does not move (no upstream release is involved).
Receipts pinned across a realization change will deny at spawn, loudly; that is
the gate working, per `ADR-2026-08-12` D6's last bullet.

**D6.5 — one producer for the observed surface.** The tool-lifecycle registration
seam (D3.5) produces the inventory; the receipt consumes it as attestation and the
generator consumes it as the fixture's assertion. Nothing else re-derives it.
`ADR-2026-08-08` D1.2's rule applied to a second fact.

## Consequences

### Positive

- The translation that already runs on every spawn acquires a name, a single
  producer, a version, and a digest — so "which realization ran" becomes a
  question evidence answers rather than a question a reader reconstructs from
  three call sites.
- The silent-downgrade bug class is closed at the root rather than at each site:
  absence becomes a typed stage-2 exclusion (D4.1) and a short surface becomes a
  denial (D3.2), so there is no remaining path on which a capability is quietly
  not there.
- The pack stops being a special case. It is one harness's realization backend of
  a capability that also realizes as prompt-partial-plus-MCP elsewhere, which is
  what makes the seam ADR's boundary generalize instead of accumulating a second
  one.
- Capability bits gain the same measurement discipline `ADR-2026-08-08` gave
  conformance rungs and `ADR-2026-08-12` gave the `tools` bit, on an axis the
  matrix does not currently have at all.
- The authoring surface gets a falsifiable rule (D5.1) rather than a principle,
  which is the difference between a contract and an intention.

### Negative

- **More dispatches fail at placement.** A capability demand that previously
  produced a degraded session now produces a typed unsatisfiable decision. That
  is the correct behavior and it is still a loss of apparent availability; the
  operator's compensation is that the record names the missing realization.
- **The registry is a new artifact to keep true.** A realization registered but
  never exercised is a claim, and D6.1's fixture requirement is the only thing
  standing between the registry and the authored-claim shape it exists to
  replace.
- **Per-mode realizations double some entries** (D3.3). Declaring the asymmetry is
  more surface than smoothing it, and smoothing it is how evidence leaks between
  lanes.
- **The attestation depends on unshipped work** (D3.5, F5). Until the
  registration seam produces an observed inventory, D3's strongest clause is a
  contract rather than a gate — and an ADR whose central check is pending is an
  ADR that can be believed prematurely.

### Risks

- **Recipe drift** — a registered recipe whose declared surface no longer matches
  what the harness produces, passing because the fixture was written against the
  declaration. Mitigation: D3.1's executor-attested observation and D6.3's
  input-tested gate; the fixture must be watched to fail before the check exists.
- **Exclusion-reason erosion** — the typed reason of D4.1 acquiring a free-text
  detail field that consumers start parsing, restoring F4 underneath a type.
  Mitigation: the named value is the contract; detail is display-only and no
  consumer may branch on it.
- **Advisory-capability laundering** — a capability declared advisory (D4.3) so
  that a partial-only recipe counts as a realization, converting the fix back
  into the bug. Mitigation: advisory is a property of the capability's own
  contract in `007`-family docs, fixed at capability definition, never asserted by
  a recipe.
- **Registry-as-allowlist creep** — a compiler branch keyed on a capability
  identity, arriving as one reasonable special case. Mitigation: D2.3 states it
  as a rule with a binary consequence rather than as a preference.
- **A capability bit computed from a realization whose fixture only proves the
  happy path.** Mitigation: same discipline as `ADR-2026-08-12` D3.1 — the
  fixture is written on the refusal and the short surface, not on the success.

## Alternatives considered

**Leave the binding implicit and let each caller assemble channel entries.** The
status quo. Rejected: it is a fact with more than one producer (F1), it cannot be
versioned or attested, and it has no place to put the absence case — which is
exactly why absence became silence.

**Model the realization as a new adaptation channel.** Rejected per D1.2: the
channel vocabulary describes *how bytes move*, and a realization describes *what
faculty the bytes deliver*. Adding it as a channel would make every capability
look like a delivery mechanism and would reopen the channel-claim confusion
`ADR-2026-08-06` D3 closed.

**Key the registry on harness family with per-version overrides.** Rejected per
D1.1: it makes the common case (a realization that arrived in one adapter
version) the exceptional path, and it reintroduces the family-level boolean D1.5
rejects.

**Make every capability MCP, so one realization covers all harnesses.** Rejected,
as `ADR-2026-08-06` and `ADR-2026-08-12` rejected it before: it adds a process and
a protocol hop per session on harnesses whose extension API registers tools
natively, and it asserts an MCP channel on adapters that have none. Uniformity
bought by claiming a channel that does not exist is not uniformity.

**Treat a missing realization as a preference-stage penalty rather than a
viability exclusion**, so a capability demand degrades gracefully under load.
Rejected: this is the silent downgrade wearing a ranking function. Per the
placement law, stage 4 orders and never gates; a capability demand that a ranker
can trade away is a capability demand the caller cannot rely on, and reliability
is the entire content of the request.

**Warn on capability drop and spawn anyway.** Rejected: a warning is not a
denial. It has no code, no receipt entry, and no consumer obliged to act on it,
and the session that follows it is exactly the session this ADR exists to
prevent. There is no warn-and-strip path for a required entry
(`ADR-2026-08-06` D4) and this is that rule's natural extension.

**Ship the capability catalog and its recipes in the open.** Rejected for the
recipes whose tools speak a hosted control plane, per D2.2 and `001` rule 2 —
the same verdict, for the same reason, as `ADR-2026-08-12` D5.2. The registry
*shape* is open; a recipe that could not run on one machine is not.

## Affected documents

**Not applied in this commit.** This ADR is `Proposed`; per this corpus's
convention the reference-doc edits below land in the commit that flips it to
`Accepted`. They are enumerated here so the accepting change is a mechanical
application rather than a rediscovery.

- `001-layered-execution-model.md` § "Capability flags as the abstraction
  technique" — the limit paragraph gains its delivery-time application: a flag
  whose realization the executing side cannot attest is not a capability either
  (D3.1). The realization is named as the object the flag is about.
- `001-layered-execution-model.md` § "Layer 4 — Composition" — the kit-toolchain
  demand's viability slot gains its sibling: a capability's realization demand
  occupies its own slot in the tuple, with the same hard-filter and
  loud-and-typed treatment (D4.2).
- `001-layered-execution-model.md` § "Layer 5 — Intelligence Services" — the
  services are named as user-facing capabilities whose per-harness realizations
  are compiled, not selected (D5).
- `002-provider-base-contract.md` § "Capabilities — the abstraction technique
  applied" — the existing fail-at-activation-never-silently-degrade rule is
  extended from declared flags to the delivered surface (D3.2).
- `002-provider-base-contract.md` § "E. Harness adaptation surface" — the channel
  list gains the capability→recipe compile step, the registry reference, the
  recipe digest, and the statement that a channel set for a capability is a
  registry lookup rather than a caller assembly (D1.4).
- `004-sandbox-capability-matrix.md` § "Routing: capability filtering, then the
  capacity profile" and § "The routing algorithm" — the eligibility filter's
  stage-2 mapping gains the realization-demand term and the typed exclusion
  reason (D4.1). Note that `004` is sandbox-scoped and gains the *shape* of the
  rule, not a harness table.
- `007-intelligence-services.md` § "Intelligence activation at harness
  adaptation" — the receipt's three independent questions gain a fourth (*which
  surface was delivered*), and the service→entry linkage is stated as a registry
  lookup (D1.4, D3).
- `013-orchestrator-and-governor.md` § "AgentRuntime dispatch" — the
  declared-compatibility ceiling gains realization presence as an input, and the
  per-candidate exclusion trace gains the typed reason (D4.1).
- `ADR-2026-06-06-two-axis-provider-model.md` — note that a manifest may not
  hand-declare a capability bit; the bit is computed from realization presence
  plus passing evidence, enforced at the generator's parity gate (D6.1, D6.3).
- `ADR-2026-08-06-harness-adaptation-plan-and-receipt.md` — note that the
  capability→channel binding is a registry lookup adding no channel name (D1.2),
  and that realization attestation is additional evidence on existing entries
  rather than a schema addition (D3.4).
- `ADR-2026-08-08-harness-as-versioned-deliverable.md` — note that the registered
  realization set is part of what the adapter version names, and that a
  realization change is an adapter-version move (D6.4).
- `ADR-2026-08-12-placement-composition-law-and-single-fallback-rule.md` — note
  the realization demand as a named stage-2 viability term with a closed
  exclusion-reason type (D4).
- `ADR-2026-08-12-pi-extension-delivery-seam-and-capability-pack-boundary.md` —
  note that a capability pack is one harness's realization backend of a shared
  capability, generalizing D5 and D6 from one pack on one harness to N
  capabilities across M harnesses.
- `README.md` and `AGENTS.md` — generated index row and read-order entry. **These
  two land in the proposing commit**, per the precedent for a `Proposed` ADR in
  this corpus.

This ADR does **not** touch the `BOUNDARY-SYNC` region in
`001-layered-execution-model.md`; `scripts/check-boundary-sync.sh` reports no
drift.

No `scripts/retired-claim-lint.sh` rule is added. Nothing here retires a claim
this corpus currently asserts — the defects in F1–F5 are properties of source in
the `donmai` repository and of an artifact generated there, corrected there. A
rule in this corpus for a claim the corpus never made would be a gate that cannot
fail, which this corpus has now declined twice for the same reason.

## Affected work items

Tracked in the platform corpus's mirrored stub, which carries the tenant-scoped
references, and under the coordinator-swarm program
(`runs/2026-08-12-coordinator-swarm/`, § 1a ruling R6). No tracker issue is cited
inline per this corpus's brand-neutral discipline.

## Implementation notes

- **Sequence.** D4's typed exclusion reason lands first and independently: it is
  small, it is the precondition for every other clause being testable, and it has
  value on its own the moment a demand goes unsatisfied. D1's registry lands
  second, populated by lifting the bindings that exist today in caller code —
  a move, not a new mechanism, and the callers are deleted in the same change
  that lifts them (`ADR-2026-08-08` D7's rule).
- **D3 waits for its producer.** The attestation clause cannot be enforced before
  the tool-lifecycle registration seam supplies an observed inventory (D3.5).
  Until then D3.2's denial fires on the evidence available, and the ADR should not
  be read as claiming the strong form is gated.
- **D6.1's test is on its input.** Construct a manifest hand-declaring a
  capability bit, and a realization with a failing fixture, and assert the
  generator **refuses** both — watched to fail before the checks exist. Asserting
  that a well-formed matrix generates tests the path that already worked.
- **D4.3's test is on the non-realization.** Register a partial-only recipe for a
  capability whose contract is a callable surface and assert the candidate is
  **excluded**, with the named reason. A test that a well-formed recipe compiles
  proves nothing about the case that produced the bug class.
- **The three realizations shipped tonight are the first registry entries**, and
  registering them is the migration: the prompt-partial-plus-MCP shape on one
  harness, the extension-pack shape on another, and the config-file MCP shape on
  a third. If all three do not express cleanly as recipes over the existing
  channel vocabulary, that is evidence against D1.2 and should be surfaced before
  acceptance rather than absorbed by widening the vocabulary.
- Detailed implementation belongs in the `donmai` repository and the composing
  binary, not here.
