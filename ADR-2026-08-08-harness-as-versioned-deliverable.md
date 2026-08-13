---
status: Accepted
date: 2026-08-08
boundary: shared
split: inline-addenda
---

# ADR-2026-08-08 — A harness is a versioned deliverable: two tiers, per-adapter versioning, and a deferred plugin ABI

**Status:** Accepted
**Date:** 2026-08-08
**Boundary:** shared (the tier model, the versioning contract, and the conformance ladder are OSS-canonical here; the definition-catalog usage rule, the tenant-facing listing tiers, and the work-item impact live in the mirrored stub)
**Authors:** open-harness strategy lane, WP-17

## Context

The harness roster grows by request. Every request arrives as the same
question — *how much does one more harness cost?* — and this architecture has
never answered it with a number, because the answer depends on a distinction
the contracts do not currently draw: whether the new harness needs **capability
integration** (hooks, tool registration, a native permission grammar, PTY,
delivery of a message into a live session) or only **execution** (spawn, prompt,
read the event stream, tear down).

Two commitments already point at that distinction without naming it.
[`ADR-2026-06-06`](ADR-2026-06-06-two-axis-provider-model.md) D7 says a third
party contributes a harness by **shipping a signed manifest row**, with the
safest path requiring *zero* code.
[`ADR-2026-07-24-acp-posture.md`](ADR-2026-07-24-acp-posture.md) D2 authorizes
exactly one generic breadth adapter so that "new harness" requests convert from
adapter-projects into manifest rows, while D1 keeps native per-harness adapters
as the primary surface because generic protocols lack the fleet primitives the
rich surfaces have. Both decisions describe a two-tier world. Neither says what
the tiers *are*, what each may declare, what versioning means inside them, or
what a contributed harness must pass before anyone routes work to it.

Meanwhile the stated goal for this area — **iterate each harness's support in
its own track** — is, as of today, *inexpressible*. Not difficult: unrepresentable
in the contracts. The findings below establish that precisely, because a decision
about versioning that does not first say what the existing version fields mean
would add a fifth namespace to four that already disagree.

This ADR is filed in the same week as, and must be read alongside,
[`ADR-2026-08-08-harness-authority-admission-plane-parked.md`](ADR-2026-08-08-harness-authority-admission-plane-parked.md).
That ADR parks a runtime *admission* plane. This one commits to a *capability
declaration* plane. § D8 exists because the next reader will otherwise take
those as contradictory, and because the enterprise-private case in D2 is the
most plausible way the parking decision gets undone by accident.

## The findings

Every finding below is reproducible from this repository — from Go source or
from artifacts committed by `go generate ./matrix/...`. Findings that rest on
the closed control plane are stated as shapes and carry their measurements in
the mirrored stub, per this corpus's boundary discipline.

**F1 — `HarnessRef.Version` carries one shared token for every harness.**
`runner/harness_selection.go:524` builds the reference as
`executioncell.HarnessRef{ID: string(manifest.Name), Version: manifest.ContractABI}`,
and all **10** shipped harness manifests declare `ContractABI: "harness/v2"` —
verifiable in the generated `matrix/harnesses.json`, where the `contractAbi`
field has exactly one distinct value across all ten entries.
`agent/harness.go`'s `Base()` projection makes the same choice for the
family-agnostic header (`Version: m.ContractABI`). The wire field named
"version" therefore identifies the *family contract*, not the harness.

**F2 — admission pins that field, and the runner re-asserts it by equality.**
`runner/harness_selection.go:362-364` denies with
`DenialUnsupportedHarnessVersion` when the live registry's harness version
differs from the version the receipt pins, and `:387-389` denies again if the
identity changes after admission. The gate is correct and fail-closed. With one
shared token behind it, it has two degenerate behaviours and no useful middle:
*within* a release it can never fire on a version difference, because every
harness reports the same string; and the moment the token moves, it fires for
**every** harness at once, because they all move together. There is no state in
which it says something about one harness.

**F3 — the contract already expresses per-harness versions; only the producer
does not.** `executioncell/codec.go:276` declares
`HarnessVersions map[string][]string` — a *set of versions per harness id* — and
`assertKnownSelectors` rejects an intent whose `harness.Version` is absent from
that harness's set. The contract tests exercise it with harness-specific values.
So the type system, the denial code, and the validation path for per-adapter
versioning are already built. The only producer in this repository emits one
constant for all ten harnesses. The second producer of this same wire contract,
downstream, populates it with a per-harness release version instead. The two
meanings have never met, because no dispatch bearing a receipt has crossed the
gate in production — which is the parking ADR's F5 seen from the other side.

**F4 — a per-harness *binary* version namespace exists, and covers 2 of 10.**
`matrix/cells.go`'s `harnessBinaryPins` map declares `minVersion` /
`pinnedVersion` / `verifiedAgainst` for `opencode` and `pi` only, read directly
from those packages' exported constants so probe-time enforcement and the
generated `binaryPins` section cannot drift. Those are the two harnesses added
after [`ADR-2026-07-24-harness-addition-v2-checklist.md`](ADR-2026-07-24-harness-addition-v2-checklist.md)
row 1 existed. The other eight ship no pin. And a binary pin describes the
*third-party program*, not our integration of it: a fix to our argv handling has
no upstream version to point at.

**So there are three version namespaces and none of them is the adapter's.**
The family ABI (one value, all harnesses), the upstream binary pin (two of ten),
and the downstream declaration version (a different meaning for the same wire
field). The thing that actually changes when someone fixes one harness — our
integration code and its declared surface — has no representation anywhere.
That, and not tooling, is why per-harness iteration cannot be expressed.

**F5 — the tier fields are hand-authored literals.** `Stability` and `Smoked`
are struct fields set as Go literals in `matrix/cells.go`'s `validCells`.
Nothing derives either from a gate outcome. Checklist row 8 states that
"capability claims follow the measurement ladder, never the manifest"; no
mechanism enforces it, and a `Smoked: true` literal is an author's assertion in
the same file that generates the artifact everything downstream trusts. This is
the *evidence that certifies itself* shape the parking ADR's D7 names, appearing
a third time in the same area in the same week.

**F6 — conformance is a seed, and it is wired per-adapter rather than per-driver.**
`agent/conformance/conformance.go` is 63 lines, encodes one invariant
(`CheckTerminalContract`), and self-describes as "the minimal seed of the
cross-harness conformance suite". Checklist row 6 says the event contract is
"asserted by a reusable conformance test **every adapter runs**". Measured:
**5 of the 10** shipped harness packages import it (`claude`, `codex`,
`opencode`, `pi`, `stub`). The other five do not — and neither do the two shared
drivers, including the one three harnesses ride. `amp` is the clearest case: it
executes entirely through the shared CLI-JSONL driver's `Handle` and decoder, so
it inherits the behaviour the contract describes and asserts none of it. Row 6
states an aspiration in the present tense.

**F7 — registration is a compile-time list, and adding a harness is a lock-step
release.** `afcli/agent_run.go` calls its constructor slice "the single
hand-authored ctor list — **the SoT** for the agent-run provider set", and
`recognizedHarnessToken` (`runner/harness_selection.go:473-505`) is a closed
`switch` over string literals with a `default` that returns *unrecognized*. A
new harness is therefore a Go edit in at least three hand-maintained places, and
because the closed composing binary embeds this module as a library at a pinned
module version, shipping it means tagging this module and bumping that pin. A
one-line fix to one adapter costs a full two-repository release.

There is already a worked precedent for how that gets worse rather than better:
`matrix/registry_gen.go` is a **generated** alias registry whose own header says
it is "NOT YET CONSUMED" because the hand-authored registries kept routing the
old way. We have generated a registry beside a hand-authored one and left both
standing. Any decision here that adds a generated list without deleting the
hand-authored one it replaces will reproduce that outcome.

## Decision

### D1 — A harness is a versioned deliverable; four namespaces, one meaning each

Name all four, give each exactly one producer, and state the precedence rule, so
there is never a second answer to "what version is this harness".

| Namespace | What it identifies | Who declares it | Moves when |
|---|---|---|---|
| **Family ABI** (`contractAbi`, today `harness/v2`) | The contract between the agent package and *any* harness implementation | The agent package; every implementation restates the ABI it implements | Rarely. A move IS lock-step, correctly — the family contract changed |
| **Adapter version** (NEW) | The exact integration that will run: our code plus its declared surface, for one harness | The harness's own manifest | Whenever that harness's integration changes. Independently of every other harness |
| **Binary pin** (`binaryPins`) | Which releases of the third-party program the adapter is built and verified against | The harness package's exported constants (unchanged; F4) | On upstream releases |
| **Conformance rung** (D4) | What has been *proven* about this adapter version | Nobody. It is computed from gate outcomes | When a gate outcome changes |

**D1.1 — `HarnessRef.Version` carries the ADAPTER VERSION.** It is the field
admission pins and the runner re-asserts across the admission→spawn boundary
(F2), and the thing that must not change across that boundary is the exact
integration about to run, not the family contract. The family ABI keeps its home
on the manifest header, where compatibility is negotiated, and stops being
projected into the reference.

**D1.2 — exactly one producer, with a stated precedence.** The adapter version
is declared in the harness manifest and reaches everything else *only* through
the generated matrix. No consumer may re-derive it, default it, or accept it
from a caller. Where any other input claims to carry a harness version, the
generated matrix wins and the disagreement is an error, not a fallback — a
requested version absent from the generated set is refused by the existing
`assertKnownSelectors` path (F3), which needs a real producer, not new code.

**D1.3 — compatibility is negotiated on the ABI and pinned on the adapter
version.** Three rules, all fail-closed, none silent:

- An adapter whose declared family ABI is outside the range the agent package
  accepts is **not registered**, loudly, at startup — and its cells are **absent**
  from the generated matrix rather than present and failing. An unusable cell
  that exists is worse than one that does not, for the same reason a grant the
  executor refuses is worse than no grant.
- A receipt pinning an adapter version that no longer matches the live registry
  denies at spawn via the existing `DenialUnsupportedHarnessVersion`. This is
  the gate F2 describes finally becoming capable of saying something.
- There is **no downgrade path**. An adapter never silently satisfies a request
  pinned to a different version of itself. Where a caller wants
  latest-compatible rather than exact, that is a resolution-time choice recorded
  as a `ResolverDecision` before admission — never a spawn-time substitution.

**D1.3a — a delivered capability pack moves the ADAPTER VERSION, and nothing
else.** Recorded by
[`ADR-2026-08-12-pi-extension-delivery-seam-and-capability-pack-boundary.md`](ADR-2026-08-12-pi-extension-delivery-seam-and-capability-pack-boundary.md)
D6, because it is the first case that exercises D1's namespace split from the
outside. Where a harness loads host-side extensions and an operator-injected
pack changes what that integration registers, the exact integration about to run
has changed and its declared surface with it — which is precisely what the
adapter version names. The **family ABI does not move** (the contract with the
agent package is untouched) and the **binary pin does not move** (no upstream
release is involved). Receipts pinning the pre-pack adapter version therefore
deny at spawn through `DenialUnsupportedHarnessVersion`; per D1.3 that is the
gate becoming capable of saying something and must not be answered by loosening
the comparison. The pack's own arrival does not flip a capability boolean
either: that flip is computed from a passing fixture under D4.2, not authored
alongside the pack.

**D1.4 — this is an additive enrichment on a frozen axis, not a re-freeze.**
[`ADR-2026-06-14-sdk-axis-readiness-and-freeze-sequencing.md`](ADR-2026-06-14-sdk-axis-readiness-and-freeze-sequencing.md)
froze the harness axis on 2026-06-14. Adding a manifest field and giving an
existing wire field a single meaning is exactly the "contract enriches in place
on v1" allowance that ADR records for the pre-production-users window. No axis is
re-opened and no freeze verdict changes.

### D2 — Two tiers, derived from how a harness is built, never self-declared

**Tier 1 — the native adapter (the rich tier).** An in-tree Go package
implementing the provider contract for one harness. It earns the right to
declare real capability integration: hooks, tool registration, native tool and
permission grammar, MCP delivery, PTY/interactive spawn, delivery of a message
into a live session, native child sessions, structured replay. Cost: code, a
smoke lane, and every row of the harness-addition checklist that its declared
capabilities touch.

**Tier 2 — the declared harness (the breadth tier).** A manifest and **no code**,
bound to one shipped **shared driver**. A declared harness may *select and
parameterize* what its driver already implements. It may never introduce a
delivery channel, a transport, or a capability the driver does not have.

**A shared driver** is an in-tree package that implements the event contract for
a whole class of harnesses rather than for one. Two ship today and the tree
already uses this exact phrase for both: `provider/harness/clijsonl` ("the
shared CLI-JSONL execution driver", carrying spawn, the `Handle`, the stream
decoder, and the per-session MCP config writer) and `provider/harness/ptycli`
("the shared interactive PTY spawn-mode driver", carrying `ptyhost` spawn and
the coarse Init/terminal event mapping). The `acp-generic` adapter that
[`ADR-2026-07-24-acp-posture.md`](ADR-2026-07-24-acp-posture.md) D2 authorizes is
the third, and it is hereby reclassified: it is not a one-off breadth
experiment, it is **the first shared driver built to be one**.

*Noun discipline.* `engine` was the obvious word and is **refused** here under
[`ADR-2026-08-03`](ADR-2026-08-03-cli-noun-tree-fleet-retirement.md) D4 rule 1 —
this corpus already spends it on the workflow engine (`016`) and on a gloss for
the harness axis itself. `shared driver` is a compound, so it does not collide
with the bare `driver` that `ADR-2026-06-06` D1 already uses for the harness
family, and it is the term both packages use for themselves. This is that rule's
first *preventive* application; the four recorded before it were all cleanups.

**D2.1 — the tier is derived, not declared.** A harness is Tier 1 iff it ships
an adapter package; Tier 2 iff it is a manifest bound to a shared driver. There
is no tier field, because a self-declared tier is a capability claim by another
name, and F5 is what happens to those.

**D2.2 — the capability ceiling is structural.** A Tier 2 manifest's declared
capabilities MUST be a **subset** of its shared driver's. This is not a new rule:
`ADR-2026-06-06` D1's parity gate already asserts per-cell `caps` narrowings only
*remove* capabilities (`cell.caps ⊆ harness.caps`). D2.2 applies the identical
narrowing one level down, and it is the same **narrow-only, fail-closed**
invariant D5 of that ADR establishes for per-machine narrowing. Three
applications of one rule; no fourth mechanism.

**D2.3 — this is a refactor that is mostly already done, which is why it is
cheap.** The tier boundary is latent in the tree today. Measured non-test source
in `provider/harness/`: `amp` is 356 lines because it rides the shared CLI-JSONL
driver and supplies little beyond its argv, its env probe, and its manifest;
`opencode` and `codex` are an order of magnitude larger because they do not.
`amp` is very nearly a Tier 2 harness that happens to be spelled in Go. Tier 2
is finishing an extraction that is already most of the way there — not a new
architecture, and this ADR should not be read as authorizing one.

### D3 — What a Tier 2 manifest may express (a closed schema, because "no code" must be true)

"No code" is a security property, not a convenience, and it holds only if the
manifest cannot smuggle code through data. The schema is **closed** — unknown
fields are rejected, not ignored.

**MAY declare:** harness id and human label; the shared driver it binds to; the
binary name and its `minVersion`/`pinnedVersion`/`verifiedAgainst` triple; an
argv template composed **only** from a fixed parameter vocabulary the driver
publishes; environment variable **names** it requires; a prompt-delivery profile
and a tool-lifecycle profile chosen from the driver's published enumerations;
`drives` / `drivesHosts`; a notice-delivery mechanism from the driver's supported
set; and capability booleans that are a subset of the driver's (D2.2).

**MUST NOT declare:** an arbitrary shell string or any shell interpreter
invocation; a credential value, token, or secret literal in any field; a new
delivery-channel, transport, or capability *name*; any capability the bound
driver does not implement; or a filesystem path outside the roots the driver
declares.

**Enforcement reuses what exists.** The closed-schema validator is the mechanism
checklist row 9 already names for adaptation manifests; the subset assertion is
the parity gate of `ADR-2026-06-06` D1. Per the parking ADR's D3.3, that
assertion is tested **on its input**: construct a manifest declaring a capability
its bound driver omits and assert the generator **refuses** it, watched to fail
before the check exists. A test asserting that a valid manifest generates a cell
proves only that valid manifests generate cells.

### D4 — Conformance: a computed ladder, asserted at the driver and at the manifest

A contributed harness is worthless without a definition of "works", and F6 shows
the current definition is a 63-line seed that half the roster does not run.

**D4.1 — four rungs, each named by what it proves.**

| Rung | Proves | Needs |
|---|---|---|
| `untested` | Nothing beyond a well-formed declaration | — |
| `contract-conformant` | The event contract holds: exactly one Init, complete (never per-token) assistant texts, exactly one terminal event, then close | The shared suite against a **fake** binary |
| `smoke-validated` | Spawn, prompt, event-stream shape, permission denial, and teardown hold against the **pinned** third-party binary | The per-harness smoke lane (checklist row 7) |
| `adaptation-verified` | Every channel the harness declares is actually delivered, with positive **and** negative applied-receipt fixtures | Checklist rows 9–12 |

**D4.2 — the rung is COMPUTED, never authored.** The generator refuses to emit a
rung it did not derive from a gate outcome, and the rung has no literal in
`cells.go`. This is the fix for F5, and it is the parking ADR's D3.2 one level
down: an attestation must derive from the artifact that produced it, not from a
hand-maintained list beside it.

**D4.3 — conformance is asserted at the shared driver, plus a fixture pack per
manifest.** Running the suite per-adapter (today's shape) means every Tier 2
manifest would need its own Go test package, which is exactly the cost Tier 2
exists to remove — and it is why the harnesses riding a shared driver are among
the five that assert nothing (F6). The suite runs **once per shared driver**,
covering every manifest bound to it, and each manifest additionally ships a
fixture pack exercising its own argv, env, and profile selections.

**D4.4 — `contract-conformant` must be reachable without our infrastructure and
without the third-party binary.** The OSS layer's standing rule is that
everything here is runnable on one machine without the control plane; a
contribution gate that additionally requires a paid third-party account is a
gate only we can pass. Fake-binary fixtures are therefore mandatory at this rung,
not a convenience.

**D4.5 — tier meets rung.** A Tier 1 adapter must reach `adaptation-verified`
for every capability it declares. A Tier 2 manifest must reach
`contract-conformant` to be listed at all and `smoke-validated` before it is
routable as a cascade default — which is checklist row 8's existing rule, now
with a computed input. Cells below their rung stay `experimental`, exactly as
`ADR-2026-07-24-acp-posture.md` D2 already caps `acp-generic`.

### D5 — Out-of-process and wasm plugin ABIs are DEFERRED BY ADR

Not rejected. **Deferred, with the reasoning written down**, so the question
stops being re-opened by each new thread that rediscovers it. The precedent is
explicit: the ACP question was studied twice without a verdict and cost months
before `ADR-2026-07-24-acp-posture.md` closed it. This ADR closes the plugin-ABI
question the same way, before it acquires the same history.

**D5.1 — what deferred means.** No design work, no prototype, no roadmap item
citing it, and — the operative part — **no re-litigation without the trigger
below**. An argument that begins "we should just expose a plugin ABI" and does
not meet D5.2 is answered by this section, not by a new investigation.

**D5.2 — the revisit trigger, all three together.**

1. **A named harness that Tier 2 provably cannot express and Tier 1 cannot
   host.** Concretely: the integration must run code we cannot carry in-tree —
   for licence, secrecy, or a runtime we do not embed. Named, with the harness.
2. **Tier 1's marginal cost is the binding constraint, measured.** Contributed
   adapters queued behind our review for longer than the release cadence — an
   observed queue, not a projection.
3. **The trust cost has a named owner.** Whoever proposes the ABI proposes with
   it the sandbox, the resource limits, the revocation path, and the gate a
   third-party binary passes before it is loadable. `ADR-2026-06-06` D7 already
   makes `binary`-kind entries sandbox-mandatory for non-allowlisted signers, so
   the cost is known and it is large.

**D5.3 — what a would-be plugin author is told today.** Four answers, in order:
(a) a Tier 2 manifest, if a shared driver covers the execution shape; (b) an
upstream contribution of a Tier 1 adapter; (c) `acp-generic`, the breadth driver
reserved for the long tail; or (d) — most often the real request — the **inbound
requester family** ([`ADR-2026-06-19`](ADR-2026-06-19-requester-provider-inbound-agent-family.md)),
if what they want is for their agent to *call in* and participate rather than to
be executed by us. Much of the demand that presents as "let me ship a plugin" is
demand to be a peer, and that family already answers it without putting anyone
else's code in our execution path.

### D6 — Trust, stated per tier, because it differs per tier

- **Tier 1, in-tree.** Our code, our review, our release, our signature (and the
  platform signing rule in `013`). Untrusted code in the execution path: **none**.
- **Tier 2, contributed and merged here.** Data, reviewed and merged, shipped
  inside our binary. Untrusted code: **none**. The entire attack surface is the
  closed schema — which is why D3's MUST-NOT list is a security boundary and not
  a style guide, and why unknown fields are rejected rather than ignored.
- **Tier 2, enterprise-private (authored outside our review, never merged here).**
  Still no untrusted code — the driver remains ours — but the manifest is now
  attacker-influenceable input. It requires: the same closed-schema validator run
  at ingest; a signature under the trust modes `ADR-2026-06-06` D7 and `015`
  already define; the two-tier `verified` / `community` listing those docs
  already specify; and **narrowing only** — a private manifest may subtract from
  its driver's declared surface and never add to it (D2.2). A private manifest
  that could add a capability would be a grant its executor refuses, which the
  parking ADR's D3 rules out as worse than no grant at all.
- **Deferred tier (plugin ABI).** Untrusted **code** in the execution path. That
  is what re-opens sandboxing, resource limits, an ABI as a public compatibility
  promise, revocation, and support for a surface we cannot review. Deferring it
  keeps the untrusted-code surface at exactly zero, which is the property D6 is
  really protecting.

### D7 — Which existing seam each tier plugs into

Requirement, not narrative: none of this may invent a registry that already
exists.

- **Tier 1** plugs into `provider/harness/<name>/`, the generated matrix, and the
  registration path. Registration must become **generated from the same manifest
  source `go generate` already reads**, and — per F7's precedent — the
  hand-authored ctor list and the closed token `switch` must be **deleted in the
  same change** that generates their replacement. A generated list landing beside
  a hand-authored one is how `matrix/registry_gen.go` came to describe itself as
  "NOT YET CONSUMED"; repeating that here would also give the adapter version two
  hand-maintained homes, which is precisely the second-truth-source defect the
  parking ADR's D3.2 names.
- **Tier 2** plugs into the **same** generated matrix, the **same** `go generate`,
  and the **same** parity gate. A declared harness is a row, not a registry. If
  Tier 2 needs its own resolution path, the design is wrong.
- **Contributed and private distribution** plugs into the kit-registry plumbing
  the daemon already ships: sigstore bundle verification with three trust modes
  (`permissive`, `signed-by-allowlist` as the compiled-in default, `attested`), a
  git-source fetcher that resolves identity by package descriptor and fails
  closed on equivocation, install/enable/disable with persisted state, package
  digests, and a trust gate with an audited one-time override. Stated honestly:
  that plumbing exists and is good, and it is **not** wired to the harness axis
  today. Pointing the harness axis at it is work; this ADR records which
  mechanism that work must reuse, so nobody builds a second one.
- **The server half** — the org-scoped harness-definition catalog — is the right
  store for enterprise-private Tier 2 manifests, and *only* for manifests. See
  D8, which is the constraint that makes that sentence safe.

### D8 — Relationship to the parking decision (read this before touching either)

**Declaration and admission are different planes.** A capability *declaration*
says what an integration can do: build-time, versioned, static, generated,
identical for every tenant. An *admission* decision says whether a particular
tenant may run a particular cell right now: runtime, per-session, dependent on
live evidence. The parking ADR parks the second. This ADR commits to the first.

**This ADR is a precondition for that ADR's durable content, not a reversal of
it.** The parking ADR's D3.1 requires a grant to intersect an executor-attested
inventory *for the exact harness and version*. F1 shows "the exact version" is
currently one constant shared by every harness, so that intersection is not
expressible today — D1 is what makes D3.1 implementable at all. D3.2 requires
the attestation to derive from the same generated artifact the executor reads;
D7 puts **both** tiers on that single artifact. Building the declaration plane
properly is how the parked plane's invariant gets a real input.

**The trap, named, because it is how this parking gets undone by accident.**
Enterprise-private Tier 2 creates *tenant-scoped harness declarations*, and the
parked definition catalog is the obvious place to put them. Reading that as "the
authority plane is back" would be wrong, and the rule is:

> Using the definition catalog as a **manifest store** does not revive the
> probe, promotion, or admission-receipt chain. A Tier 2 manifest is attested
> **statically** — manifest ∩ driver surface — which is computable with no probe,
> no freshness TTL, and no receipt. If you find yourself adding a probe to make a
> declared harness work, stop: you have either hit the parking ADR's D5 condition
> 4 (a question the matrix provably cannot answer) or mis-scoped the manifest.

**And one condition is not four.** The parking ADR's D5 condition 1 requires a
real tenant connection naming a harness that actually ships in the generated
matrix. Tier 2 is, by construction, a way to make a tenant-named harness ship in
that matrix — so Tier 2 makes D5.1 *satisfiable*. Conditions 2, 3 and 4 remain
independently unmet, and revival requires all four. Satisfying the cheapest one
is not a revival argument; it was already the cheapest one before this ADR
existed.

## Consequences

### Positive

- The stated goal — iterate each harness in its own track — becomes expressible,
  because the thing that changes finally has a version (D1).
- The cost of one more harness becomes a number that depends on a stated
  question: does it need capability integration, or only execution?
- The parked plane's D3.1 acquires an implementable input; the two decisions
  compose instead of colliding (D8).
- Three claims that were aspirations in the present tense — every adapter runs
  conformance (F6), capability claims follow the measurement ladder (F5), adding
  a harness is a manifest row (F7) — are replaced by either a mechanism or an
  honest status.
- The plugin-ABI question is closed with reasoning attached, which is the only
  form of closure that survives the next thread (D5).

### Negative

- **Per-adapter versioning adds a real combinatorial axis** — (adapter version ×
  family ABI) compatibility, plus receipts that pin an adapter version and go
  stale when it moves. Expect `DenialUnsupportedHarnessVersion` to start firing
  where nothing fired before. That is the F2 gate becoming capable of saying
  something, not a regression, and it should not be "fixed" by loosening the
  comparison.
- **Tier 2 will attract requests its drivers cannot serve.** Saying no becomes an
  architectural act with a written reason rather than a capacity excuse — which
  is more work per refusal, not less.
- **The deferred tier leaves a real case unserved:** an enterprise wanting a
  private harness whose integration needs *code*. D5.3 gives four answers, and
  none of them is that one. This ADR does not pretend otherwise.
- **D7's deletion requirement makes the Tier 1 registration change larger** than
  a purely additive one would be. That is deliberate; the additive version is how
  `registry_gen.go` happened.

### Risks

- **Tier laundering** — a Tier 2 manifest declaring a capability its driver
  cannot deliver. This is the parking ADR's D3 failure one level down, and it is
  the single most likely way Tier 2 does damage. Mitigation: D2.2's subset
  assertion, tested on its input per D3, watched to fail first.
- **The rung ladder gets hand-authored anyway**, regressing to F5. Mitigation:
  D4.2 — the generator refuses to emit a rung it did not compute, and the field
  has no literal to set.
- **Deferral is read as rejection**, and the plugin-ABI question is re-opened as
  a "new" idea. Mitigation: D5.1 states what deferral means and D5.3 gives the
  four answers a would-be author receives today.
- **`contract-conformant` quietly acquires a dependency on a third-party binary
  or on our infrastructure**, making contribution possible only for us.
  Mitigation: D4.4 makes fake-binary reachability a requirement of the rung, not
  a property of its current implementation.
- **D8 is read as a partial revival of the parked plane** by an agent who finds
  the definition catalog and a Tier 2 manifest in the same week. Mitigation: the
  block-quoted rule in D8 and the explicit "one condition is not four".

## Alternatives considered

**Keep one shared ABI token and do nothing about versioning.** Rejected on two
independent grounds: the stated iteration goal stays inexpressible (F1–F3), and
the parking ADR's D3.1 stays unimplementable because "the exact harness and
version" cannot name one harness.

**Version a harness by its third-party binary version — promote `binaryPins` to
the wire version.** The most tempting alternative, and rejected: it conflates
*which upstream release* with *which integration of it*. A fix to our argv
handling, our event mapping, or our declared surface has no upstream version to
point at, and would either be invisible or would force a lie about the upstream
pin. The two namespaces stay separate (D1) precisely because they answer
different questions.

**Version per cell rather than per adapter.** Rejected: a cell is a *product* of
two axes and has no author and no changelog. Version the thing somebody edits.

**Ship the plugin ABI now.** Rejected: no named harness requires it (D5.2
condition 1 is unmet), the trust cost is large and unowned, and the ACP thread is
the precedent for what an unresolved protocol question costs when it is neither
built nor closed.

**Tier 1 only — no breadth tier.** Rejected: it contradicts already-Accepted
decisions (`ADR-2026-06-06` D7's zero-code contribution path,
`ADR-2026-07-24-acp-posture.md` D2's breadth adapter), and it makes every
long-tail request an adapter project.

**Tier 2 only — deprecate native adapters in favour of a generic surface.**
Rejected, and already rejected twice: `ADR-2026-05-10` (native-rich providers,
never lowest-common-denominator) and `ADR-2026-07-24-acp-posture.md` D1, which
found every native surface strictly richer than the generic one on the
fleet-control axes. Nothing about a tier model reopens that.

**Let a Tier 2 manifest add capabilities its driver lacks, with a runtime probe
to confirm.** Rejected as the worst option available: it is exactly the shape the
parking ADR was written about — a declaration granting what the executor refuses,
plus a probe chain to paper over it — and it would revive the parked plane
sideways, without meeting any of its four revival conditions.

## Affected documents

The following edits land in the commit that sets this ADR to `Accepted`:

- `001-layered-execution-model.md` § "Layer 3 — Execution" — the execution-cell
  paragraph gains D1.1: the harness reference's version field identifies the
  adapter, not the family contract.
- `001-layered-execution-model.md` § "The ten plugin families" — the harness
  family gains the two-tier distinction and the shared-driver noun.
- `ADR-2026-06-06-two-axis-provider-model.md` — addendum: D3's generated matrix
  gains a per-harness adapter version and a computed conformance rung; D7's
  contribution path resolves into the two tiers of this ADR.
- `ADR-2026-07-24-harness-addition-v2-checklist.md` — amendment: the twelve rows
  become tier-scoped, and row 6's "every adapter runs" is corrected to the
  measured state with the per-driver fix (F6, D4.3).
- `ADR-2026-07-24-acp-posture.md` — note: `acp-generic` is reclassified as the
  first purpose-built shared driver (D2).
- `ADR-2026-08-03-cli-noun-tree-fleet-retirement.md` — D4 rule 1's applications
  table gains row 5, `engine`, as the rule's first preventive application.
- `README.md` and `AGENTS.md` — index and read-order entries.

This ADR does **not** touch the `BOUNDARY-SYNC` region in
`001-layered-execution-model.md`; `scripts/check-boundary-sync.sh` was run and
reports no drift.

**Cited but deliberately unamended.** `015-plugin-spec.md`'s third-party
onboarding note and `ADR-2026-06-14-sdk-axis-readiness-and-freeze-sequencing.md`'s
readiness verdict both stand exactly as written: the first already specifies the
trust modes, entry kinds and two-tier listing that D6 reuses, and the second's
freeze verdict is unchanged by D1.4's additive enrichment. Editing either to
mention the tiers would restate their content without changing their meaning.

No `scripts/retired-claim-lint.sh` rule is added. The false claim this ADR
corrects — checklist row 6's "every adapter runs" — is asserted in exactly one
place in this corpus and is corrected *in place* by this commit. A lint rule for
a single-site claim that no longer exists is a gate that cannot fail, which this
corpus treats as worse than no gate; the general control for claims of this shape
is D4.2's computed rung, which removes the ability to author one.

## Affected work items

Tracked in the platform corpus stub, which carries the tenant-scoped work-item
references, and under the open-harness strategy program
(`runs/2026-07-21-open-harness-strategy/`). No tracker issue is cited inline per
this corpus's brand-neutral discipline.

## Implementation notes

- **Sequence matters.** D1 (the adapter-version producer) lands before D4's
  computed rung, which lands before any Tier 2 manifest, because a rung computed
  for a harness with no distinguishable version is a rung about the whole roster.
- **D2.2's test is on the input** (parking ADR D3.3): a manifest declaring a
  capability its bound driver omits must be **refused by the generator**, and that
  refusal must be watched to fail before the check exists. Asserting that a valid
  manifest produces a valid cell tests the happy path of the thing you already
  had.
- **D4.3's move is mechanical and small**: the existing 63-line suite gains an
  entry point that takes a driver plus the manifests bound to it, and the five
  harness packages that call it today keep calling it. The five that do not, and
  the two shared drivers, are the actual gap.
- **D7's deletion is part of the change, not a follow-up.** If the generated
  registration lands and the hand-authored list survives the same commit, the
  outcome is `registry_gen.go` a second time.
- Detailed implementation belongs in the `donmai` and `donmai-smokes` repos, not
  here.

## Addendum 2026-08-13 — the registered realization set is part of what the adapter version names

[`ADR-2026-08-13-capability-realization-registry-and-viability-of-absence.md`](ADR-2026-08-13-capability-realization-registry-and-viability-of-absence.md) adds a second population to D1's **adapter version**: alongside
the exact integration that will run and the surface it declares, the adapter
version names the set of **capability realizations** registered against it.
Registering, changing, or removing a realization is therefore an adapter-version
move, and neither a family-ABI nor a binary-pin move.

That ADR's D1.6 makes explicit a consequence D1 already implies. Because the
realization registry is keyed on adapter version, a bump produces a **new key
with no entries under it**. The bump must therefore either **re-register** each
realization, with its fixture re-run at the new version, or carry an **explicit
inheritance declaration** naming what it inherits and from where. Silent
carry-forward is prohibited: it is precisely the move that lets a realization's
evidence outlive the integration the evidence was measured against — the
authored-claim shape D4 replaced with a computed rung, arriving through a
maintenance path rather than an authoring one. The parity gate refuses an
inheritance declaration whose fixture never ran at the inheriting version.
