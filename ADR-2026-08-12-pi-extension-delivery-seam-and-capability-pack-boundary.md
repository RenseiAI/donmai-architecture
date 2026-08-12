---
status: Proposed
date: 2026-08-12
boundary: shared
split: inline-addenda
---

# ADR-2026-08-12 — The pi extension-delivery seam: operator-injected capability packs, and where the pack boundary falls

**Status:** Proposed
**Date:** 2026-08-12
**Boundary:** shared (the seam contract, the trust rule, the headless-UI
guarantee, the state-isolation defaults and the staging verdict are
OSS-canonical here; the closed pack's inventory, its tenant-facing listing
consequences and the work-item impact live in the mirrored stub)
**Authors:** coordinator-swarm design lane

## Context

The `pi` native adapter already delivers an extension into every session it
spawns. One file, embedded in the OSS binary, materialized into a runner-owned
directory inside the session workarea, loaded by explicit path with all other
extension discovery disabled in the same argv, and verified before the first
prompt by a two-part handshake — the extension reports the digest of its own
on-disk source and echoes a per-session token the runner placed in the child
env; both are compared in constant time and either mismatch fails the session
closed. That extension is the harness's trust boundary: pi ships no permission
system of its own, so checklist row 3's "injected, handshake-verified boundary
where none exists" is not a hypothetical for this harness, it is the only shape
available.

So a delivery mechanism exists, it is load-bearing, and it has exactly one
consumer. The question this ADR answers is what happens when there is a second
one — a **capability pack**: an extension registering a family of tools that
speak a hosted control plane (peer messaging, memory, knowledge graph,
architecture retrieval, code intelligence, issue tracking, kits) so that a
sub-agent has those capabilities natively, with no protocol hop and no second
server to run.

Three sub-questions have to be answered together, because answering any one
alone produces a defensible-looking wrong answer:

1. **Does the mechanism generalize in the open?** One embedded file is not a
   contract; a spawn-spec field is.
2. **Does the pack itself belong in the open?** Its tools are the client half
   of a hosted service. Shipping the tools without the service would ship an
   interface whose only working implementation lives downstream — the one thing
   `001` forbids outright.
3. **What does loading a pack change about what the harness may claim?** A
   harness that gains tools has moved its declared surface, and this corpus has
   just spent two ADRs establishing that a declared surface is a versioned
   deliverable whose claims follow measurement rather than authorship.

## The findings

Every finding is reproducible from OSS source in the `donmai` repository at the
pinned harness version, or from the third-party project's own public
repository and documentation. Findings that rest on the closed control plane
are stated as shapes, with any measurement left in the private run record.

**F1 — the delivery path is already generic in mechanism and singular only in
policy.** The materializer takes a working directory, creates a runner-owned
state directory, writes one embedded blob under one compile-time constant
filename, and returns the path. The loader appends one explicit-path flag. The
verifier compares one digest. Nothing in any of the three is specific to what
the file *contains*; the only thing standing between this and an ordered list
is the singular.

**F2 — the trust bypass is already relied upon, and it is undocumented as a
contract.** An extension named by explicit path loads regardless of whether the
project has been trusted; workspace-resident extension directories load only
after a trust decision that an unattended session has nobody to make. The
adapter depends on the first half (its boundary must load in an autonomous
session) and defends against the second half (it disables all other discovery
so nothing in the workspace can shadow or race the boundary). Both behaviours
are correct. Neither is written down anywhere a second consumer would find it,
which is how a bypass becomes a hazard: the next author reads "explicit paths
bypass trust" as a convenience rather than as a rule with three preconditions.

**F3 — per-session state isolation is asserted by comment and delivered by
guesswork.** The child env exports four *candidate* home-directory variable
names in the hope that one of them is the one the harness honors, with an
in-tree comment saying the exact name is unverified against a real binary and
that the smoke lane will canonicalize it later. The third-party project
documents its agent-directory and session-directory variables by name, and
neither documented name is among the four exported. The session directory is
separately pinned by a CLI flag, which is why the arrangement appears to work.
A shotgun of plausible names is not isolation; it is a hope that no smoke can
distinguish from a working name, because a test asserting that the env was set
proves only that the env was set.

**F4 — spawn does network work it does not need.** The project documents an
offline switch and a version-check switch. The adapter sets neither. Every
spawn therefore may perform a catalog refresh and a version check before the
first turn — startup latency multiplied by fan-out, and a third-party service
placed on the critical path of a spawn whose binary is already pinned.

**F5 — headless mode has no UI, and the one UI round-trip that works is the one
the runner answers.** The RPC lane runs with no interactive surface, so a tool
that awaits a `select`/`confirm`/`input` response waits forever. The shipped
policy extension makes UI round-trips anyway and they succeed, because the
runner recognizes them by a marker and answers them over the RPC stream. That
is an *arrangement between one extension and one runner*, not a property of the
mode. A pack tool that inherits the assumption without inheriting the
arrangement does not fail — it hangs, which is strictly worse: a hang has no
denial code, produces no terminal event, and so never reaches the single
invariant the shared conformance suite actually asserts.

**F6 — the multiplexed hosting surfaces are types, not a host.** The project's
remote stack publishes a session-service contract a host would implement, a
pluggable listener interface, and a durable session-repository model. At the
pinned version: no implementation of the session-service contract exists in the
project's own repository, its CLI entry points for the server and client modes
are argument parsers that are never invoked, exactly one local socket family
ships as a transport, authentication is declared to be the transport's problem
and therefore ours, the higher-level harness abstraction's operations raise
not-implemented, and the project's own documentation marks the whole stack
experimental with minor releases permitted to break. A conformance kit for
hosts does ship — which is the one genuinely encouraging fact, and it certifies
a host that does not yet exist.

**F7 — the harness's declared surface says no tools and no MCP, and a pack
changes exactly one of those.** Tools would arrive by extension registration.
MCP would not arrive at all; the pack exists precisely so that no MCP hop is
needed. A surface that flipped both because tools appeared would be claiming a
delivery channel that does not exist, which
[`ADR-2026-08-06`](ADR-2026-08-06-harness-adaptation-plan-and-receipt.md) D3
forbids in terms: a service's *grant*, its *delivery mechanism*, and its *usage
guidance* are three separate things, and the presence of one never evidences
another.

## Decision

### D1 — The seam: additional extensions on the spawn spec, by absolute path and by inline source

The spawn spec gains an **ordered list of additional extension deliveries**.
Each delivery is one of two forms, and both are supported because each covers a
case the other cannot:

- **By absolute path** — the file already exists at a path the runner can read.
  This is the shape the composing binary uses when it carries the pack as
  embedded bytes and materializes them itself.
- **By inline source** — the caller supplies the source bytes and a basename,
  and the runner materializes them into the per-session state directory. This
  is the shape a pack takes when it is *composed at spawn time*: a tool list
  that varies with the admitted capability grants has no fixed file to point at.

Every delivery, in either form, carries a **required source digest**. Ordering
is the declared order, and the policy extension is always first and cannot be
displaced, reordered, or disabled by a delivery — the boundary loads before
anything that might want to talk past it.

Supporting only paths would push materialization, digesting, ordering and
cleanup into every downstream consumer, which is the per-harness reinvention
`ADR-2026-08-06` exists to stop. Supporting only inline would force a caller
that already holds a verified on-disk artifact to read it back into memory so
the runner can write it out again, and would make the digest a claim about a
buffer rather than about a file.

**D1.1 — delivery is expressed in the existing closed adaptation vocabulary,
and adds no channel name.** An injected pack's tools are
`native_tool_definition` entries and its hooks are `lifecycle_hook` entries,
both delivered as a materialized artifact selected by an explicit load path.
The policy extension keeps its own classification as the injected, verified
boundary, because it alone carries the handshake. No new `AdaptationChannel`
and no new `DeliveryStrategy` is created: the schema is closed, and a seam that
needed a new channel name would be a seam that had smuggled a new capability
past the parity gate.

**D1.2 — a delivery whose capability was granted is `required`, and fails
closed.** If a required delivery cannot be materialized, verified, or loaded,
spawn is denied with a typed pre-spawn denial and zero credential-delivery
side effects. There is no warn-and-strip path, and no path on which a session
starts having silently lost a capability its caller was told it had.

**D1.3 — cleanup is part of the delivery.** Every materialized artifact names
its cleanup entry and is removed by the runner's workarea lifecycle. Cleanup is
idempotent and evidenced; an unevidenced cleanup quarantines the workarea from
reuse rather than assuming it.

### D2 — Operator-injected extensions bypass project trust; workspace extensions never do

**The rule.** An extension the **operator** delivers — bytes the runner itself
carries or generates, materialized by the runner, digested by the runner, and
loaded by explicit path — is exempt from the project-trust gate. An extension
**discovered in the workspace** — the repository the agent is about to edit —
is not, and for an autonomous session it is not merely gated but **disabled**:
the same argv that names the injected extensions turns every other discovery
source off.

**Why the bypass is safe for the first and not the second.** The trust gate
answers exactly one question: *did attacker-influenceable content enter the
execution path?* Workspace content is attacker-influenceable by construction —
a contributor, an untrusted fork, a fetched document, or the agent's own prior
turn can write an extension file into the tree, and `001` § "Security as
defense in depth" places that ingress squarely in the composition layer rather
than in a policy hook. If a file in the workarea could reach the bypass, the
session's blast radius would jump from *the agent can edit this repository* to
*the agent can execute arbitrary code as the operator, with the operator's
credentials, inside the operator's trust boundary*. That is the escalation the
gate exists to prevent.

Operator-injected bytes are the other case entirely. They come from the same
already-executing, already-signed process that is performing the spawn, holds
the credentials, and enforces the boundary. Loading them introduces **no new
trust root** — it exercises the existing one. There is nothing left to gate: a
gate that asks the operator whether it trusts itself has no failure mode it can
prevent and one it can cause (an unattended session parking on a modal).

**Three preconditions make that argument sound, and all three are load-bearing.**

- **(a) Provenance.** The bytes are the runner's own — embedded in the binary
  or generated by it from admitted inputs. They are never read from the
  workarea, and never fetched from the network at spawn time. A pack retrieved
  over the network at spawn is not operator-injected; it is third-party content
  with an operator's file permissions, and it belongs behind the signing and
  trust-mode machinery `015` already specifies, not behind this bypass.
- **(b) Integrity, verified after materialization, with discovery disabled.**
  Each delivery's digest is computed before the write and verified against what
  is loadable, and every other extension source is disabled in the same argv.
  Without both halves the bypass is a time-of-check/time-of-use hole: a file
  the agent can rewrite between the runner's write and the harness's read is
  workspace content that was handed a head start.
- **(c) Runner-owned lifecycle, re-verified on resume.** The materialization
  directory is the runner's, is cleaned by the runner (D1.3), and its contents
  are **re-verified rather than trusted** when a session resumes. A resumed
  session inherits a directory that has been writable by an agent for the whole
  intervening period; treating a prior verification as still valid would make
  the boundary a one-time formality.

**D2.1 — a capability pack never satisfies checklist rows 3 and 4.** The
handshake-verified policy boundary remains mandatory and remains the thing that
must be provably active before the first prompt. A pack rides in the same argv
and adds tools; it never *is* the boundary, never relaxes it, and never
substitutes for it. A session whose pack loaded but whose boundary did not must
not start.

### D3 — Headless-UI guarantee: an injected tool must be safe with no UI attached

Every tool and hook an injected extension registers **must** either complete
without an interactive surface or return a **typed refusal** when none is
attached. Waiting is not an allowed outcome.

An injected tool MAY perform a UI round-trip only where the runner **declares**
that it answers that round-trip — the shipped arrangement in F5, made explicit
instead of assumed. Absent that declaration, a UI call in a headless session is
an immediate typed error.

The reason to be absolute about this is that a hang is the one failure this
architecture cannot see. A denial has a code, appears in the receipt, and is
routable; a hang produces no terminal event and therefore never reaches the
single invariant the shared conformance suite asserts. It converts a fast,
local, typed failure into a session that is indistinguishable from a slow one
until a watchdog fires.

**D3.1 — the fixture is written on its input.** The pack's per-manifest fixture
pack ([`ADR-2026-08-08`](ADR-2026-08-08-harness-as-versioned-deliverable.md)
D4.3) includes, per registered tool, a headless fixture asserting that a tool
which awaits an undeclared UI response is **refused** — watched to fail before
the check exists. A fixture asserting that a well-behaved tool returns a result
proves only that well-behaved tools return results.

**D3.2 — headless and interactive evidence are separate.** Per `ADR-2026-08-06`
D6, a pack proven in the PTY lane may not inherit that evidence into the
headless lane, or the reverse. Where a tool's headless path is a refusal and
its interactive path is a round-trip, that asymmetry is declared, not smoothed.

### D4 — Per-session state isolation: name the variables, and default to offline

**D4.1 — exactly one documented variable per concern.** The runner sets the
harness's **documented** agent-directory and session-directory variables to
per-session paths inside the session workarea. Exporting a set of candidate
names is not a contract and is prohibited: it cannot be falsified by a smoke,
it hides which name is load-bearing, and it leaves the corpus asserting an
isolation property that rests on an untested guess (F3).

**D4.2 — isolation is asserted by observing writes, not by asserting env.** The
smoke lane proves isolation by spawning two sessions and observing that each
one's credential store, model catalog, settings and transcript are written
under its own root, and that neither appears under the invoking user's home.
This is the only assertion that distinguishes a correct variable name from a
redundant one.

**D4.3 — offline and version-check suppression are the default for every
non-interactive spawn.** Two independent reasons, and the second is the
architectural one. Operationally, a spawn that refreshes a catalog and checks
for a new release has put a third-party service on the critical path of a fleet
spawn whose binary is already pinned, and multiplied that cost by fan-out.
Architecturally, `001`'s boundary rule says removing the control plane must
leave a usable single-machine product; a spawn path that reaches the public
internet to start a pinned local binary fails the same test against a different
dependency. The default is a **default**, not a lock: an attended or
interactive session may re-enable either, recorded as an explicit
environment-binding entry rather than acquired by omission.

**D4.4 — the isolation is a correctness property, not a performance one.** The
project's credential store is guarded by a lock file, so a shared state home
serializes credential refresh across every session on the box; its transcripts
are append-only files with **no cross-process writer lock**, so two sessions
sharing a session home can interleave-corrupt a transcript. Per-session state
is therefore not an optimization that a future host may trade away for density.

### D5 — The boundary: the seam is OSS, capability packs are downstream deliverables loaded through it

**D5.1 — the seam is OSS-canonical, and it ships with a working implementation
because it already has one.** The spawn-spec fields, materialization, digesting,
ordering, the trust rule (D2), the headless guarantee (D3), the state defaults
(D4) and cleanup are OSS contract with OSS code behind them. The policy
extension *is* the OSS pack. Generalizing from one delivery to N does not
create an interface whose only working implementation lives downstream — `001`
rule 2 is satisfied by construction, not by promise, which is the test this
split has to pass and the reason it passes cleanly.

**D5.2 — a pack whose tools speak a hosted control plane is not OSS.** Those
tools are the client half of a service the OSS layer does not run. Publishing
them here would ship exactly the type-without-implementation the boundary
forbids, and it would put a hosted plane's request shapes into a corpus that
must remain runnable on one machine. Such a pack ships in the composing binary
and is delivered **through** the seam. This is the existing precedent —
one embedded extension, materialized and loaded through the harness's own
mechanism — generalized from one pack to N, and the generalization adds a
plural to the OSS layer without adding a policy to it.

**D5.3 — the seam never names a pack.** No allowlist of known pack identities,
no pack-specific spec field, no branch in the runner keyed on which pack is
loaded, no marker reserved for a particular downstream. If a pack needs a
runner change, exactly one of two things is true: the change is generic and
lands in this seam for everyone, or the pack is out of contract. This is the
rule that keeps the split from decaying into a closed plugin with an open
loader.

**D5.4 — a pack may not widen the cell's admitted surface.** A pack delivers
tools *within* a capability the admitted cell already carries. It can never make
a cell tool-capable that was admitted without tools. This is `ADR-2026-08-08`
D2.2's narrow-only rule applied one level further down, and it is the direct
consequence of
[`ADR-2026-08-08-harness-authority-admission-plane-parked.md`](ADR-2026-08-08-harness-authority-admission-plane-parked.md)
D3: a declaration that grants what the executor will refuse is worse than no
declaration, because it converts a local, free, immediate failure into a remote,
post-admission, post-charge one.

**D5.5 — the seam is per-harness, and there is no cross-harness "supports
extensions" boolean.** This ADR decides the seam for the one harness whose
native adapter already implements it. Any other harness that wants comparable
delivery declares it in its own adaptation profile, with its own evidence and
its own mechanism. A shared boolean would be a capability claim spanning
delivery mechanisms it cannot name — the precise shape `ADR-2026-08-06` D3
rejects.

### D6 — Matrix implications: what a pack changes, and what it must not

- **`tools` flips true, and only as a computed consequence.** The cell may
  declare tool support once a pack that delivers tools is loaded **and** its
  fixture pack passes. The claim follows the measurement ladder (checklist row
  8; `ADR-2026-08-08` D4.2's computed rung), so `tools: true` is the output of
  a passing gate, never a manifest edit shipped alongside the pack that
  motivated it.
- **`mcp` stays false.** The pack *replaces* MCP for this harness rather than
  enabling it. Flipping an MCP claim because tools appeared would evidence a
  delivery channel by the presence of a different one, which `ADR-2026-08-06`
  D3 forbids.
- **Live delivery is declared per harness, with evidence, and never assumed.**
  Delivering a notice **into a live turn** is a different capability from
  appending it to a durable queue that is read at the start of the next one. A
  harness whose adapter can inject into a running turn declares that; every
  other harness's delivery remains durable-append, and a caller may not read one
  as the other. The declaration is per recipient harness, because the property
  belongs to the recipient's adapter and not to the message.
- **The adapter version moves; the family ABI and the binary pin do not.**
  Loading a pack changes the exact integration that will run and the surface it
  declares, which is precisely what `ADR-2026-08-08` D1 says the **adapter
  version** names. The family ABI is unchanged (the contract with the agent
  package did not move) and the binary pin is unchanged (no upstream release is
  involved). Receipts pinned to the pre-pack adapter version will deny at spawn,
  loudly, and that is the gate working rather than a regression to loosen.

### D7 — Staged execution: subprocess RPC now, multiplexed hosting deferred by ADR

Wave 1 is the shipped lane: one child process per session, driven over the
line-delimited JSON RPC mode, with the seam of D1–D4 layered onto it. The seam
is deliberately **host-agnostic** — an extension registers a tool identically
under a subprocess host or an in-process one — which is exactly why staging
costs nothing: no work done now has to be undone when the host changes.

Any **multiplexed server-hosting mode** — implementing the project's
session-service contract so one process hosts many sessions behind its
protocol — is **deferred by ADR**, in the sense
[`ADR-2026-08-08`](ADR-2026-08-08-harness-as-versioned-deliverable.md) D5
established for the plugin ABI: no design work, no prototype, no roadmap item
citing it, and no re-litigation without the trigger below. F6 is the reason: the
surface is published types with no shipped host, one local transport family,
authentication defined as our problem, an unimplemented higher-level harness
abstraction, and an explicit experimental designation under which a minor
release may break. Building the execution layer's density story on that would
make an unshipped third-party surface a load-bearing dependency of a fleet.

**D7.1 — the re-entry condition, all three together.**

1. **The host contract leaves experimental**, and its transport surface admits
   a listener we can write and certify against the project's own host
   conformance kit.
2. **Subprocess cost is the measured binding constraint** on a real fleet —
   observed, not projected. Density that is wanted rather than needed is bought
   with more machines, which the execution model already knows how to do.
3. **Process-global state is eliminated upstream or bounded by us.** Multiplexing
   is what makes a global HTTP dispatcher, a global stream function and a legacy
   compatibility registry matter, and the project states plainly that tenant
   isolation is the operating system's job and not its own.

**D7.2 — until then, density is bought with processes.** This is not a
placeholder position. Process isolation is what makes the trust boundary of D2
enforceable per session, and a multiplexed host would have to re-establish
every property of D2 and D4 inside one address space before it were an
improvement rather than a trade.

## Consequences

### Positive

- A mechanism with one consumer and no contract becomes a contract with a
  stated trust rule, so the second consumer does not have to infer the first
  one's invariants from its source.
- The closed pack becomes possible without a closed fork of the loader: the
  split falls on the API line, and the OSS side gains a plural rather than a
  policy (D5).
- Three latent defects acquire a written verdict — a guessed state-isolation
  variable set (F3), an unsuppressed network round-trip on every spawn (F4),
  and a headless-UI assumption that hangs instead of denying (F5).
- The staged execution question is closed with reasoning attached, which is the
  only form of closure that survives the next thread that rediscovers the
  session-service contract and finds it elegant (D7).

### Negative

- **The trust bypass is now a documented, reusable property**, which makes it
  easier to reach for. D2's three preconditions are the whole defense, and they
  are cheap to satisfy and easy to forget.
- **Two delivery forms is more contract than one.** Inline source in particular
  needs materialization, digesting and cleanup on a path that path-delivery
  gets for free.
- **The adapter version moves when a pack changes the declared surface** (D6),
  so receipts pinned across a pack change will deny at spawn. That is more
  denial traffic than exists today.
- **Deferring the multiplexed host leaves a real case unserved**: very high
  session density on one machine. D7.2 answers it with more processes, and does
  not pretend that is free.

### Risks

- **Pack laundering** — a pack declaring, in effect, a capability the cell was
  not admitted for. This is the parked ADR's D3 failure one level down and is
  the single most likely way this seam does damage. Mitigation: D5.4, tested on
  its input.
- **Bypass creep** — a future path that materializes bytes read from the
  workarea, or fetched at spawn, and loads them through the same explicit-path
  door. Mitigation: D2(a) states provenance as a precondition rather than as a
  practice, and D2(c) re-verifies on resume.
- **A pack tool ships a UI round-trip the runner does not answer**, and sessions
  hang rather than deny. Mitigation: D3.1's per-tool headless fixture, asserted
  on the refusal.
- **`tools: true` gets hand-authored ahead of the fixture**, restoring the
  authored-claim shape `ADR-2026-08-08` F5 names. Mitigation: D6's first bullet
  binds the flip to the computed rung, which has no literal to set.
- **The offline default is read as an offline requirement** and an attended
  session loses a legitimate catalog refresh. Mitigation: D4.3 states the
  override and the record it leaves.

## Alternatives considered

**Ship the pack as an MCP server instead of an extension.** Rejected on this
harness. It would add a process and a protocol hop per session to reach tools
the extension API registers natively with prompt-level documentation attached,
and it would make an MCP claim true for a harness whose adapter has no MCP
delivery — which is a channel claim, not a convenience (`ADR-2026-08-06` D3).
The general rejection of "make every capability MCP" is that ADR's own.

**Put the seam in the closed composing binary and leave OSS untouched.**
Rejected: it would fork the loader. The composing binary would need its own
materialization, its own digesting, its own argv construction and its own
cleanup, all of which the OSS adapter already performs for the boundary
extension — and the two would drift on the exact path where the trust boundary
lives.

**Publish the capability pack in the open with stubbed transports.** Rejected:
that is the interface-without-a-working-implementation shape `001` rule 2
exists to forbid, and stubs would make the tools' semantics untestable on one
machine, which is the property the OSS layer's contribution gate depends on.

**Path-only delivery.** Rejected: it forces every downstream that composes a
pack at spawn time to reimplement materialization and digesting, which is the
per-harness reinvention `ADR-2026-08-06` closed.

**Inline-only delivery.** Rejected: it forces a caller holding a verified
on-disk artifact to read it back so the runner can write it out again, and it
turns the digest into a claim about a buffer instead of a file.

**A generic cross-harness "supports extensions" capability flag.** Rejected per
D5.5: extension delivery is not one mechanism across harnesses, and a flag that
spans mechanisms it cannot name is a claim the executor may refuse.

**Build the multiplexed host now, since the contract is published and a host
conformance kit ships.** Rejected per D7: a conformance kit certifies a host
that does not exist, against an experimental protocol whose minor releases may
break, over a single local transport family, with authentication left to us.
The kit is the reason the door stays open, not a reason to walk through it.

## Affected documents

This ADR is `Proposed`; the edits below land in the commit that flips it to
`Accepted`, per this corpus's convention.

- `002-provider-base-contract.md` — the harness adaptation surface gains the
  additional-extension delivery list (path and inline forms, required digest,
  deterministic order, required-entry fail-closed semantics).
- `013-orchestrator-and-governor.md` — the runner's pre-spawn sequence gains
  materialization, verification and the workarea-owned cleanup of injected
  artifacts, plus re-verification on resume.
- `ADR-2026-07-24-harness-addition-v2-checklist.md` — a note on rows 3 and 4:
  an injected capability pack never satisfies the policy-injection or
  fail-closed-boundary rows (D2.1).
- `ADR-2026-08-06-harness-adaptation-plan-and-receipt.md` — a note that
  extension delivery is expressed within the existing closed channel and
  delivery vocabularies and adds no names (D1.1).
- `ADR-2026-08-08-harness-as-versioned-deliverable.md` — a note that a pack
  changing a harness's declared surface is an **adapter-version** move, and
  neither a family-ABI nor a binary-pin move (D6).

**Cited but deliberately unamended.** `007-intelligence-services.md` already
states that service activation and usage guidance are separate receipted
channels, which is the rule D5.4 and D6 apply here; and `015-plugin-spec.md`
already specifies the signing, trust modes and two-tier listing that D2(a)
points at for any future network-fetched pack. Editing either to mention this
seam would restate their content without changing their meaning.

This ADR does **not** touch the `BOUNDARY-SYNC` region in
`001-layered-execution-model.md`; `scripts/check-boundary-sync.sh` reports no
drift.

No `scripts/retired-claim-lint.sh` rule is added. Nothing here retires a claim
this corpus asserts; the three defects in F3–F5 are properties of source in the
`donmai` repository, corrected there, and a lint rule in this corpus for a claim
this corpus never made would be a gate that cannot fail.

## Affected work items

Tracked in the platform corpus's mirrored stub, which carries the tenant-scoped
references, and under the coordinator-swarm program
(`runs/2026-08-12-coordinator-swarm/`). No tracker issue is cited inline per
this corpus's brand-neutral discipline.

## Implementation notes

- **Sequence.** D4's state-isolation fix lands before any pack, because a pack
  loaded into a shared state home makes D4.4's corruption mode more likely, not
  less. D3's headless fixtures land with the first pack tool, not after it.
- **D5.4's test is on its input.** Construct a pack delivery declaring a tool
  under a capability the cell was not admitted for, and assert the runner
  **refuses** it — watched to fail before the check exists. Asserting that an
  admitted pack loads tests the path that already worked.
- **F3's variable name is a measurement, not a design question.** The smoke lane
  resolves it by observing where the process writes (D4.2), and the candidate
  set is deleted in the same change that names the real one — not left standing
  beside it.
- Detailed implementation belongs in the `donmai` and `donmai-smokes`
  repositories, not here.
