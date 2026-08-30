---
status: Proposed
date: 2026-08-30
boundary: shared
split: sibling-extensions
---

# ADR-2026-08-30 — Recovery semantics for stateful links

**Status:** Proposed
**Date:** 2026-08-30
**Boundary:** shared (the link identity, evidence, recovery, rebind,
supersession, terminal-proof, condition, and observability laws are canonical
here; concrete authority stores, policy, routes, and rollout sequencing belong
in implementation-specific extensions)
**Authors:** stateful-link architecture lane

## Context

A long-lived session may depend on a stateful relationship whose transport is
replaceable: a remote peer route, an external reply path, an interactive
carrier, a provider continuation, or a durable observation binding. The
relationship outlives any one socket, credential, process epoch, cache entry,
or discovery response. Treating one of those replaceable projections as the
relationship itself makes recovery destructive.

The motivating failure had that shape. A still-live session temporarily lost
the projection used to locate its peer. One recovery lane observed the missing
projection through stale or incomplete evidence, classified the relationship
as terminal, and removed state needed to reconnect. A later authoritative read
could establish that the session and peer relationship were still recoverable,
but the eager cleanup had already converted a transient loss of reachability
into a permanent break.

Several accepted contracts already constrain parts of this problem:

- one canonical session identity survives transport, process, room, bridge,
  and provider aliases;
- durable facts precede live transport, while coordination messages retain a
  separate acknowledgement and replay store;
- transient failures retry under a bound and surface a clearing condition;
- interactive carrier takeover uses a prepared candidate, durable evidence,
  and explicit activation rather than treating socket acceptance as authority;
  and
- controller loss, missing contact, elapsed time, or an unavailable authority
  is not terminal proof.

Those precedents are deliberately specific to their layers. They do not yet
state one recovery law for every session-bound stateful link. Without that law,
each adapter can still interpret `not found`, timeout, credential expiry,
connection close, cache absence, or a failed refresh as permission to unlink,
tombstone, release, requeue, or terminalize.

This ADR defines the shared law. It does not make a stateful link a second
session, merge coordination messages into the execution-event spine, or change
an existing wire protocol while Proposed.

## Decision

Stateful-link recovery is conservative and evidence-driven. Ambiguous evidence
never produces a terminal verdict. An independently fenced recovery owner
rechecks ground truth through freshly resolved authority and executes the
closed recovery profile registered for that link kind. A rebindable profile is
phased through non-active candidate installation, required evidence, adoption,
publication, and explicit activation; a non-rebindable profile refuses
takeover rather than inventing one. Until genuine supersession or registered
terminal proof commits, the system degrades the link and preserves its durable
evidence.

### D1 — A stateful link is a durable relationship, not a transport leg

A stateful link has one stable logical identity under a canonical session:

```text
SessionLinkRef = {
  sessionRef,
  linkId,
  linkKind,
  authorityRef,
  registrationId,
  registrationRevision,
  registrationDigest
}
```

`sessionRef` is the canonical lifecycle identity from the one-session
substrate. `linkId` is stable for the logical relationship. `linkKind` is a
closed implementation-defined discriminator. `authorityRef` identifies the
authority that can describe, bind, supersede, or terminalize the link without
carrying a secret. The registration tuple identifies the exact immutable
`StatefulLinkKindRegistration` whose semantics govern this link.

Each physical realization additionally carries a monotonic `generation` and
typed correlations such as process epoch, connection id, conversation id,
route id, credential revision, or native cursor. Those values fence or
correlate one realization. None may replace `sessionRef`, mint another session,
or become the logical link identity.

One session may own several links. Failure of one link is scoped to that link
unless the canonical lifecycle authority independently proves that the session
cannot continue. A link observer cannot terminalize a session merely because
its own projection disappeared.

One authenticated **recovery owner** is responsible for each `SessionLinkRef`
at a time. Its `RecoveryOwnerFence` has an owner identity, independent
monotonic owner epoch, lease/fence revision, and validity bound. It is separate
from the link generation: advancing a transport generation cannot grant
recovery ownership, and renewing recovery ownership cannot rebind a transport.
Other components may report evidence or request recovery, but every operation
must reject a stale or mismatched owner fence before reading sensitive state or
mutating the link.

Fence acquire, renew, transfer, and release are themselves authenticated and
authorized authority mutations with canonical operation ids/digests and
receipts under D3. Transfer advances `ownerEpoch` atomically; process identity,
link generation, credential continuity, elapsed lease time, or a literal
fallback can never synthesize recovery ownership.

One-shot messages, stateless requests, and best-effort notifications are not
stateful links. A protocol implementation must not opt into this contract only
after failure; whether a relationship is stateful is declared when it is
created.

Every stateful link kind is admitted through a **closed registry**. One
`StatefulLinkKindRegistration` declares:

- the closed `linkKind` and schema/version;
- its authority resolver and independent recovery-owner fence schema;
- its rebind profile: `non_rebindable` or a closed phased profile under D5;
- every permitted terminal-evidence schema, producer authority, validator, and
  irreversible postcondition under D7;
- per-attempt, per-episode, per-link, and per-authority recovery budgets;
- reservation disposition and scarce-resource reclamation rules;
- immutable evidence-retention requirements, active conditions, outcome
  transitions, metrics policy, and conformance-suite identity; and
- its activation version and compatibility range.

Registration is data reviewed with the adapter, not a runtime self-assertion.
An unknown link kind, missing field, unknown profile phase, unregistered
terminal schema, or absent conformance result fails link activation. There is
no generic fallback profile and no “best effort” unregistered link.

The registration is strict canonical data. Its stable id names the semantic
family, its positive revision names one immutable version, and its lowercase
SHA-256 digest covers the complete canonical registration bytes. Link
activation binds the exact `{registrationId, registrationRevision,
registrationDigest}` into `SessionLinkRef` before the first realization may
become active. A digest mismatch or missing revision fails activation.

Registration evolution creates a new immutable successor revision. The
successor declares its predecessor, compatibility posture, and an explicit
migration operation with authorization, owner fencing, exact old/new digests,
postconditions, and receipt. Existing links remain governed by their pinned
revision until that migration commits; a registry update never reinterprets
their evidence or phases in place. Migration atomically creates the successor
registration binding for the same stable session/link identity and retains the
predecessor `SessionLinkRef` plus migration receipt as immutable evidence. In
particular, adding a terminal schema or producer in a successor revision never
retroactively widens terminal authority for links pinned to an earlier
revision.

### D2 — Evidence is classified before it can change lifecycle

Every recovery observation is classified as exactly one of:

| Evidence class | Meaning | Permitted consequence |
|---|---|---|
| `healthy` | Current authority confirms the expected binding and generation | Clear recovery conditions; continue or reconnect the same realization |
| `recoverable_absence` | Canonical session is nonterminal and current authority confirms no usable binding | Run the registered phased successor profile, or degrade as non-rebindable |
| `superseded` | Current authority returns a durable supersession receipt satisfying D6 | Conserve predecessor evidence; follow the committed successor |
| `terminal` | Current authority returns terminal proof satisfying D7 | Settle the link according to the terminal receipt |
| `ambiguous` | Evidence is missing, stale, conflicting, unreachable, unverifiable, or short of another class | Preserve; recheck and retry; then degrade visibly |

The following observations are always `ambiguous` by themselves:

- timeout, cancellation, connection reset, clean or unclean socket close;
- one discovery or cache lookup returning absent;
- credential expiry, refresh failure, authorization failure, or an unavailable
  authority;
- process disappearance without an authority-scoped tombstone;
- an elapsed lease, heartbeat, fence, or retry deadline;
- a lower generation observing a higher number without the successor receipt;
- a transport-level acknowledgement without the durable post-condition; and
- conflicting projections, including one that says active and one that says
  absent.

Ambiguous evidence may narrow behavior for safety. It may stop writes, stop new
delivery, or make a link temporarily ineligible. It may not unlink, tombstone,
release an external claim, discard queued work or replies, requeue a possibly
live session, lower a generation floor, or emit a terminal session outcome.

### D3 — Recovery rechecks ground truth with fresh authority

Recovery never asks a suspected link to prove its own health. For each attempt,
the recovery owner authenticates independently of the failing transport,
resolves authorization against the registry-named policy, verifies its current
`RecoveryOwnerFence`, and obtains a new `AuthoritySnapshot` after the
observation that started the attempt. Inspection is not public metadata: it
requires the same explicit session/link scope and policy decision discipline as
mutation, with a read-only action.

A snapshot records at least:

- the exact `SessionLinkRef` and requested generation;
- the exact registration id, revision, and digest resolved from that ref;
- authority identity and monotonic revision or equivalent fence;
- canonical session lifecycle state;
- current binding, candidate, supersession, and terminal disposition when
  present;
- observation time, expiry or validity bound, and evidence digest;
- actor reference, authentication-context digest, authorization policy id and
  revision, authorization decision digest, and recovery-owner fence; and
- whether authentication was newly resolved, refreshed, or could not be
  established.

“Fresh” means the read did not come from a cache populated before the recovery
observation, did not reuse an authentication result whose failure triggered the
attempt, and did not travel only through the link being diagnosed. A refresh is
not assumed to succeed: failure to obtain fresh authority leaves the result
`ambiguous`.

The authoritative read and any live probe are different evidence. The read
answers what binding and lifecycle the authority has committed. A probe answers
whether a committed realization is currently reachable. A probe cannot invent
or terminalize authority state, and a committed row cannot prove a live data
path. Recovery joins both without collapsing their meanings.

Before every state-changing phase, the owner re-authenticates when the
authentication context expired or changed, re-resolves authorization under the
current policy revision, rechecks its independent owner fence, and rechecks the
link authority revision and expected generation. A decision derived from
revision `R` cannot commit against revision `R+1` by silently accepting drift.
An authorization decision from policy revision `P` cannot mutate under `P+1`
without re-evaluation. Either case retries from authenticated inspection.

Every inspection and mutation request has a canonical operation id and SHA-256
digest over its strict canonical bytes. The first committed result stores the
request digest and immutable receipt. Exact replay returns that receipt;
changed bytes under the same operation id conflict before side effects. Every
receipt and audit record carries the actor reference, authentication-context
digest, authorization policy id/revision, decision digest, recovery-owner
fence, operation id, request digest, exact registration id/revision/digest, and
resulting authority revision. A request or receipt whose registration tuple
does not equal the active `SessionLinkRef` is a contract conflict, never a
request to use the latest registry entry. Raw credentials and policy inputs
never enter receipts.

### D4 — Recovery load is bounded across attempts, episodes, links, and authorities

One detected loss starts a durable recovery episode with a stable idempotency
key, attempt counter, start time, deadline, backoff policy, last authority
revision, and last classified evidence. Its registry entry supplies strictly
positive values for minimum attempt spacing and hard per-attempt timeout, plus
maximum attempts and elapsed time per episode. Backoff is capped and jittered;
a successful ground-truth read resets only the transport backoff it actually
proves healthy.

Episode bounds do not permit infinite episode churn. The same registration
also supplies:

- a per-link rolling-window attempt and episode rate;
- a per-authority rolling-window rate shared by every link using that
  authority;
- positive per-link and per-authority concurrency ceilings;
- a circuit-open cooldown after an exhausted or authority-saturated episode;
- a maximum circuit-open/reopen count before durable dead-letter; and
- the operator-escalation target and required disposition for dead-lettered
  work.

Admission acquires both link and authority budget before starting an attempt.
One authority outage therefore cannot create unbounded synchronized recovery
traffic, and one damaged link cannot monopolize the authority's concurrency.
Waiting for budget is a durable scheduled state, not a busy loop and not an
attempt. Every external call inherits the remaining hard attempt deadline;
timeout cancellation is mandatory.

Mandatory reservation disposition/reclamation has a registered reserved slice
inside the same absolute per-authority rate and concurrency ceilings. Ordinary
rebind attempts cannot consume that slice, and a rebind circuit or dead letter
cannot suppress it. Disposition has its own bounded retries, circuit, and
operator escalation, so cleanup remains mandatory without becoming unbounded.

Each attempt performs this order:

1. persist or load the recovery episode;
2. place destructive side effects on hold;
3. resolve fresh authority and inspect the exact session/link/generation;
4. classify the joined authority and live-probe evidence under D2;
5. restore the same realization, run D5 rebind, accept D6 supersession, or
   accept D7 terminal proof; and
6. commit the attempt receipt, reservation disposition, budget accounting, and
   condition transition before any live nudge.

A crash after any step replays the same attempt or begins the next bounded
attempt from durable state. Exact request replay returns the first committed
receipt. Changed bytes under the same idempotency key conflict.

Exhausting an episode does not reinterpret ambiguity as terminal. The owner
enters `degraded` and opens the circuit. A later episode may begin only after
the positive cooldown and both rolling-window budgets admit it. Exhausting the
registered reopen count durably dead-letters recovery and emits operator
escalation; an explicit retry must still pass fresh authentication,
authorization, owner fencing, and budgets. Dead-letter is not terminal proof.

Every attempt that created or inherited an uncommitted reservation ends with
one durable disposition before its lease is released: exact retained resume,
explicit abandonment and scarce-resource reclamation, or successful carry into
the next named phase. A timed-out process may not leave an unclassified
candidate. Recovery startup scans undisposed reservations before admitting new
ones for the same link. If the session cannot make progress, the canonical
lifecycle may independently enter `waiting` or `blocked`; neither state means
`ended`.

### D5 — Rebind is a registered phased profile, not one universal transaction

A link kind is either `non_rebindable` or registers an ordered rebind profile
from this closed semantic phase vocabulary:

1. **`inspect`** — authenticated, authorized, fenced read of D3 ground truth;
2. **`reserve_candidate`** — allocate a generation strictly above active,
   pending, and all-time floors, then install a non-active candidate. The
   profile declares whether this phase also fences predecessor mutation;
3. **`acquire_evidence`** — obtain and durably receipt every profile-required
   native snapshot, cursor, readiness, proof, or other handoff fact;
4. **`adopt`** — commit the candidate into each declared session/link authority
   without activating its data plane;
5. **`publish`** — durably publish every declared scope/read model and prove
   those postconditions without making the candidate active;
6. **`activate`** — perform an explicit request/acknowledgement exchange or
   equivalent atomic operation that makes the exact candidate authoritative,
   enables its data plane, and emits the D6 supersession receipt; and
7. **`abandon`** — dispose of an uncommitted, pre-consume candidate only,
   retaining evidence and floors while reclaiming scarce reservations.

The registry entry declares the exact ordered phase graph, link-native
operation bindings, request and receipt schemas, required evidence, authority
rechecks, legal exact-replay edges, crash-resume edges, and mandatory
abandonment edge from every uncommitted/pre-consume state. The profile marks
the exact operation that **consumes/commits the candidate**. Every state at or
after that boundary registers exact-resume and reconciliation-only edges; it
has no abandonment or replacement-successor edge. A profile may have several
ordered evidence, adoption, or publication operations. It may omit an
inapplicable phase only by registering that absence and proving the next phase
cannot acquire the omitted phase's authority. No transport acceptance,
candidate row, adoption commit, publication, or socket write is activation.

Every phase operation is scoped to one exact session, link, candidate
generation, and phase. It applies D3 authentication, authorization,
independent owner fencing, operation id/digest, exact replay, changed-request
conflict, and mutation-time rechecks. Explicit operations are required, but
this ADR does not force one route or four generic verbs onto protocols whose
authority boundaries differ.

A newly reserved candidate is always non-active. Where the registered profile
fences the predecessor during `reserve_candidate`, that fence removes mutation
authority but does not erase the predecessor, publish the candidate, discard
replay state, or prove supersession. Only successful `activate` changes the
current binding. Activation failure preserves the candidate's exact phase and
follows the registered edge for that phase. Before consumption it must
exact-resume or `abandon` before a successor is reserved. At or after
consumption it must exact-resume/reconcile the same candidate through
activation or registered terminal proof; it cannot abandon or replace that
candidate.

A new recovery owner cannot inherit an uncommitted candidate merely because it
can see the candidate id. The profile must authorize exact retained resume
under the new owner fence. If the candidate is still uncommitted/pre-consume,
the profile may instead authorize durable abandonment followed by a higher
successor. A consumed candidate permits exact-resume/reconciliation only.
Abandonment never lowers a generation floor or reactivates a fenced
predecessor.

A same-generation reconnect is not a rebind. It is allowed only when exact
binding identity, credential lineage, authority revision, recovery-owner
lineage, and retained replay cursor prove continuation of the current
realization. Changed ownership, changed credential lineage, or uncertain
retained state requires the registered successor profile when one exists.

**Existing interactive mappings are explicit.** The second-generation attach
protocol registers a phased profile whose state mapping remains exact:

```text
preparing
  = proof reservation + RecheckAndFence of a strictly higher non-active candidate
  -> receipt-stored
     = mandatory authoritative Snapshot appended durably + strict receipt committed
  -> adoption-committed
     = exact per-session adoption consumes the receipt and reserved proof
  -> batch-committed/local-published
     = every authority-scope batch commits, then local adoption publishes
  -> active
     = carrier_activate commits and carrier_active acknowledges the exact candidate
```

The candidate remains non-active through receipt, adoption, batches, and local
publication. Only `carrier_active` confirms activation. The profile retains the
protocol's exact retained-candidate abandonment and consumed-adoption recovery
rules; this ADR does not collapse them into prepare/commit.

For that profile, `receipt-stored` is still unconsumed. A changed controller may
commit the exact authenticated abandonment, preserve staged high-water and the
all-time floor, clear active/pending without incumbent rebind, and reserve a
higher successor through the recorded predecessor. The per-session adoption
commit is the consume boundary. From `adoption-committed` onward, the candidate
is non-abandonable and non-replaceable. Replacement recovery server-resolves
the original consumed candidate and its still-valid credential/epoch, boundary
N, high-water H, and `ResumeFrom=H+1`; it requires the old transport absent or
closed, exact-replays adoption/batches/local publication, and activates that
same candidate without allocating a new proof, receipt, Snapshot, cursor, or
successor. After `batch-committed/local-published`, activation failure retries
the exact `carrier_activate` for that candidate until `carrier_active` or
registered terminal proof. It never reserves a replacement.

Credential validity is gated before consumption; insufficient remaining margin
uses the pre-consume abandonment path. After consumption, credential loss or
expiry reconciles without reminting or replacing the candidate. A still-live
old same-credential transport returns a retryable refusal and is never evicted
by replay.

The frozen first-generation attach protocol registers `non_rebindable`. Its
exact same-binding reconnect behavior remains valid continuation, but it cannot
perform authenticated same-session carrier takeover through this recovery
contract. Recovery conserves, drains, or reports degraded/unsupported state; it
does not synthesize candidate, adoption, publication, or activation operations
that the protocol cannot express.

### D6 — Supersession requires a genuine committed successor

A predecessor is `superseded` only when one durable receipt proves all of:

1. the exact canonical session and logical link;
2. the exact registration id/revision/digest pinned by `SessionLinkRef`;
3. predecessor and strictly higher successor generations;
4. the registered rebind profile and every required phase receipt through
   explicit activation;
5. the activation operation id/request digest, actor, authentication-context
   digest, authorization policy id/revision and decision digest, plus the
   independent recovery-owner fence;
6. fresh authority and authorization revisions rechecked at activation;
7. predecessor mutation fencing, successor activation, and the registered
   irreversible activation postconditions;
8. preservation or explicit disposition of queued data, replay cursors,
   acknowledgements, and external claims; and
9. the committed time, resulting authority revision, and joined evidence
   digest.

Seeing a higher generation, accepting a socket, minting a credential, writing
a candidate row, storing evidence, adopting, publishing, or losing contact with
the predecessor proves none of these alone. An equal-generation binding under
changed ownership is never supersession and never gains mutation authority by
retry.

Supersession ends one realization, not the logical link or session. The
predecessor record remains as immutable evidence until the retention law allows
it to cool; cleanup consumes the supersession receipt rather than inferring the
result again.

### D7 — Terminal evidence is closed per link kind and proves irreversible fact

There is no corpus-wide open union of plausible terminal evidence. Each
`StatefulLinkKindRegistration` lists a closed set of terminal-evidence entries.
Every entry declares:

- terminal schema id/version and canonical codec;
- exact registration id/revision/digest the evidence claims;
- the sole producer authority and its authentication/verification method;
- exact session, link, generation, and native-resource correlation;
- closed terminal reason and native terminal fact;
- the irreversible postconditions the producer must have committed, such as
  process reaping, native conversation closure, writer revocation, or a
  terminal tombstone that forbids later mutation for that generation;
- authority revision, operation id/request digest, evidence digest, committed
  time, and exact replay/conflict rules; and
- the cleanup actions this evidence authorizes.

A terminal consumer authenticates and authorizes its inspection, verifies the
exact registration id/revision/digest pinned by `SessionLinkRef`, registered
producer, schema, exact generation, native fact, irreversible postconditions,
authority revision, and evidence digest, then records its own
actor/authz-bearing acceptance receipt with that same registration tuple before
cleanup. A successor registry revision cannot validate terminal evidence for an
unmigrated older link. Evidence for a predecessor does not terminalize a
successor. A canonical session terminal event settles a link only when that
link's pinned registration revision names the event's exact schema/producer and
the event includes the required link-native terminal fact and postconditions.

An authorized terminate, stop, cancel, reap, or expiry action is an instruction,
not terminal evidence. Its result becomes terminal proof only when the
registered producer commits the native terminal fact and irreversible
postconditions above. Elapsed time may schedule or make such an action eligible;
it never authorizes a tombstone, release, or terminal verdict by itself.

Unknown or unregistered terminal schemas, wrong producers, invalid native
facts, missing irreversible postconditions, revision drift, generation
mismatch, missing receipts, unverifiable signatures or digests, and unavailable
authority are `ambiguous`. Cleanup remains held.

### D8 — Degrade, do not destroy

While evidence is `ambiguous`, `recovering`, or `degraded`, the implementation
preserves:

- the logical link record and its canonical session edge;
- active and prepared realization evidence plus the all-time generation floor;
- replay cursors, queued work/replies, acknowledgement floors, and dedupe keys;
- claims, leases, and capacity charges whose separate owners have not released
  them; and
- every receipt needed to resume, rebind, supersede, or settle exactly.

The data plane may fail closed: no unproven peer receives writes, no stale
credential widens access, and no candidate becomes active by reachability
alone. Read-only inspection and safe local progress may continue when the link
kind permits it. That is degradation: reduced capability with conserved state,
not pretend success.

**Evidence retention and scarce reservations are different concerns.** Phase
requests, receipts, native evidence, generation floors, predecessor lineage,
and disposition records are immutable evidence retained under the registry's
evidence policy. A socket, capacity slot, candidate lease, credential
reservation, or other scarce resource need not remain allocated merely to keep
that evidence.

Every uncommitted reservation follows the registry's disposition state machine.
Authenticated and authorized `abandon` rechecks owner fence, authority revision,
candidate phase, and non-activation; it then durably records abandonment before
idempotently reclaiming the scarce resource. The evidence record remains. If
reclamation fails, the reservation is `reclaim_pending`, stays capacity-charged
where applicable, and retries within the reserved disposition slice under the
same absolute per-authority ceiling. An elapsed reservation deadline makes
abandonment eligible but does not itself abandon, activate, supersede, or
terminalize anything.

A committed/consumed pre-active candidate is not an uncommitted reservation and
never enters this abandonment path. Its registered exact-resume/reconciliation
edge retains whatever scarce resources are necessary to complete activation;
resources proven independently unnecessary may be reclaimed only by a
registered non-abandoning reconciliation disposition that preserves candidate
identity and activation authority. Circuit, dead-letter, operator action, and
elapsed time cannot replace the consumed candidate.

Destructive logical-link cleanup consumes D6 or D7 proof and is idempotent. A
cleanup worker that cannot read or validate the proof records a condition and
retries; it does not reconstruct proof from absence. Provider-specific release
remains bounded and may repeat only under the same immutable disposition.

### D9 — Conditions and observability are part of correctness

Every recovery transition commits a strict, secret-free record before live
publication. At minimum it carries:

- canonical session and link identity, link kind, and generation;
- exact registration id, revision, and digest pinned by `SessionLinkRef`;
- recovery episode and attempt identities;
- canonical operation id/request digest, actor reference, authentication-context
  digest, authorization policy id/revision and decision digest, plus the
  independent recovery-owner fence;
- prior and next state;
- evidence class, stable reason code, authority revision, and evidence digest;
- attempt hard deadline, positive spacing, link/authority budget disposition,
  retry count, episode deadline, circuit state, next reconciliation time, and
  last successful ground-truth time;
- phase, reservation disposition, reclaim state, and phase/supersession/terminal
  receipt reference when applicable; and
- observed and recorded timestamps.

Human-readable detail is display-only. Consumers branch on closed reason codes,
never free text. Tokens, credentials, message bodies, terminal bytes, prompts,
raw provider payloads, and unrestricted endpoint data never enter conditions,
logs, metrics labels, or receipts.

The closed active-condition set is:

- `session_link_recovering` — bounded active recovery;
- `session_link_rebind_pending` — one candidate is in a registered pre-active
  phase;
- `session_link_reclaim_pending` — an abandoned candidate retains scarce
  resources awaiting idempotent reclamation;
- `session_link_reclaim_dead_lettered` — disposition/reclamation exhausted its
  reserved budget and requires operator disposition;
- `session_link_degraded` — the active episode exhausted without proof;
- `session_link_circuit_open` — recovery awaits its positive cooldown/budget;
  and
- `session_link_recovery_dead_lettered` — automatic reopen exhausted and an
  operator disposition is required.

The corresponding append-only outcome transitions are
`session_link_rebound`, `session_link_superseded`, and
`session_link_terminal_confirmed`. They are history, not active conditions.

Conditions are current-state projections, not sticky fault ledgers. Recovery,
rebind, reclamation, circuit close, or operator disposition clears its active
condition through an explicit resolved transition. History remains in
append-only receipts. The same condition projection appears wherever session
health is exposed; a local-only warning is insufficient.

Durable recovery facts may project onto the typed execution-event spine through
strict registered topics. Live transport and agent-to-agent messages may carry
only an opaque nudge to those facts. They do not copy the durable body, advance
its cursor, or become link authority.

Metrics include recovery episodes and attempts by closed reason, time to fresh
authority, phase outcomes, activation/abandonment/reclamation, per-authority
budget saturation, circuit opens, dead letters, ambiguous-to-recovered latency,
degraded age, stale condition age, and destructive actions by proof kind. The
cardinality excludes session, link, endpoint, credential, actor, and raw error
values.

### D10 — Migration and proof are additive

Adoption proceeds in this order:

1. inventory every stateful link kind, its current authority, every observer,
   every destructive path, and every value currently mistaken for terminal;
2. register every kind's authority resolver, independent owner fence, rebind
   profile, terminal schemas/producers/postconditions, budgets, reservation
   disposition, evidence retention, observability, conformance identity, and
   immutable registration id/revision/digest;
3. fail activation for unregistered kinds while keeping their existing lane
   behind the migration flag;
4. add stable link identity, authenticated inspection, evidence classification,
   operation digests/receipts, conditions, and budget accounting without
   changing destructive behavior;
5. run the classifier in shadow and reconcile every destructive legacy verdict
   against fresh authority and registered terminal evidence;
6. switch ambiguous evidence to preserve-and-degrade, disposition every
   uncommitted reservation, and enforce total-load circuits before enabling
   automatic rebind;
7. enable one phased rebind profile only after crash/race/authz proof; register
   non-rebindable kinds explicitly rather than synthesizing phases;
8. migrate remaining link kinds independently;
9. enter an instrumented observation window without retiring legacy guards; and
10. retire absence-based cleanup only after the acceptance gate below passes.

The acceptance gate has a configured `minimumObservationWindow > 0`. For every
activated link kind, the window must be long enough to cover and exercise one
full authority/recovery cycle: authentication or authority/fence refresh,
ground-truth inspection, a bounded recovery episode including its positive
spacing and any circuit cooldown/reopen, and the ending required by the exact
registered profile: uncommitted reservation disposition/reclamation;
committed-candidate reconciliation through explicit activation; or, for a
`non_rebindable` kind, fresh `recoverable_absence` producing typed
degraded/unsupported state with no candidate creation and no destructive
cleanup. A multi-kind rollout uses at least the maximum of those positive
per-kind minima. An instantaneous scan, a duration of zero, or a window that
does not cross the slowest registered cycle cannot satisfy acceptance.

Across that entire window all three counters remain exactly zero:

1. legacy destructive verdicts that disagree with fresh classification under
   the exact pinned registration revision;
2. legacy destructive verdicts that lack registered supersession or terminal
   proof; and
3. unregistered destructive paths, established by the complete mechanical path
   inventory plus runtime destructive-action instrumentation.

Any hit resets the observation window after repair. Acceptance therefore proves
both agreement and path completeness for a positive duration; “no discrepancy
in the final scan” is insufficient.

Required proof includes registration canonicalization/digest stability;
registration-digest mismatch; explicit successor-revision compatibility and
migration; no retroactive terminal-authority widening; unregistered-kind
activation refusal; stale-cache
absence; unauthorized inspect; stale owner fence; expired and refreshing
credentials; authorization-policy drift at every mutation; exact operation
replay and changed-digest conflict; authority timeout; conflicting projections;
same-generation exact reconnect; changed-owner equal-generation refusal; two
concurrent reservations; crash and response loss at every registered phase;
non-active behavior through evidence/adoption/publication; explicit activation;
first-generation attach takeover refusal; second-generation attach exact phase
mapping; pre-consume abandonment; consumed-candidate abandonment/replacement
refusal; exact consumed-candidate recovery after activation failure; mandatory
pre-active disposition; non-rebindable `recoverable_absence` yielding typed
degraded/unsupported state with zero candidate creation and zero destructive
cleanup; reclamation with immutable evidence retained; positive
attempt spacing and hard timeout; per-link and per-authority
rate/concurrency saturation; circuit/dead-letter/operator disposition; strictly
higher successor activation; unregistered/wrong-producer terminal evidence;
missing irreversible terminal postcondition; elapsed time without native
terminal fact; terminal proof for the wrong generation; later reconciliation
from degraded; full-cycle positive observation window; zero disagreeing legacy
destructive verdicts; zero unregistered destructive paths; condition clearing;
no secret projection; and one damaged link leaving unrelated links intact.

Every behavioral coverage claim must demonstrate the discriminating red state
with the production seam disabled, then green after restoration. A fixture that
asserts only its own evidence table or bypasses the authority/rebind subject is
not proof.

Proposed status authorizes no reference-doc edit, protocol change, migration,
release, or activation.

## Consequences

### Positive

- Transient loss of reachability can no longer destroy a recoverable logical
  relationship.
- Every adapter shares one testable boundary between ambiguity,
  recoverable absence, supersession, and terminal proof.
- A registered phased rebind repairs one link without restarting a process or
  disturbing unrelated sessions and links, while non-rebindable protocols fail
  honestly.
- Authentication, authorization, owner fencing, and canonical operation replay
  are consistent at every recovery boundary.
- Content-addressed registration binding prevents a registry update from
  changing recovery or terminal authority for an existing link retroactively.
- Total-load budgets and reservation disposition prevent recovery storms and
  scarce-resource leaks without deleting forensic evidence.
- Durable conditions make recovery visible and self-clearing without turning
  live transport into authority.
- Existing session identity, event, coordination, and carrier-adoption laws
  remain intact.

### Negative

- Link implementations need closed registrations, durable episodes, phase
  receipts, generation/owner fences, budgets, and condition projection instead
  of a simple delete-on-error branch.
- Bounded preservation retains state and capacity longer during authority
  outages.
- Fresh authority reads add latency and load to recovery.
- Multi-phase candidate handoff and explicit activation add protocol work for
  adapters that previously treated reconnect or publication as authority.
- A consumed pre-active candidate may retain scarce resources longer because
  it must reconcile to activation or terminal proof and cannot be abandoned.

### Risks

- **Preservation may become indefinite limbo.** Mitigation: bounded active
  episodes and rolling windows, visible degraded age, circuits/dead letters,
  operator disposition, and native terminal proof rather than silent deletion.
- **Two authorities may both appear current.** Mitigation: one declared recovery
  owner with an independent fence, monotonic authority revisions, generation
  floors, and explicit activation.
- **A permissive adapter may call a transport close terminal.** Mitigation: D7
  permits only registered schemas/producers/native facts/postconditions and
  conformance includes close-without-proof.
- **Fresh reads may still traverse shared stale infrastructure.** Mitigation:
  each link kind documents its independent authority path and proves cache
  invalidation plus post-observation revision.
- **Conditions may expose sensitive routing data.** Mitigation: closed reason
  codes, digest/reference-only evidence, bounded display text, and low-
  cardinality metrics.
- **A platform extension may weaken the shared contract.** Mitigation:
  extensions name concrete authorities and policy but cannot add an
  absence-as-terminal proof class, bypass authentication/authorization, or
  replace a registered phased/non-rebindable profile.
- **A registry update may appear to repair an old link by changing its rules.**
  Mitigation: immutable revision/digest pinning and explicit migration; no
  latest-entry lookup and no retroactive terminal authority.

## Alternatives considered

- **Treat missing discovery state as terminal.** Rejected: discovery is a
  projection and can be stale, partitioned, or read under expired authority.
- **Retry forever on the same connection.** Rejected: it is unbounded, can hide
  permanent failure, and asks the suspected link to prove itself.
- **Recreate the whole session.** Rejected: transport replacement is not a new
  lifecycle identity and may duplicate work or release still-owned resources.
- **Restart or globally re-register the process.** Rejected: it disrupts
  unrelated links, freezes recovery into process lifecycle, and supplies no
  supersession proof.
- **Allow each adapter to define terminal evidence.** Rejected: the weakest
  adapter would reintroduce absence-based destruction and make cross-link
  observability incomparable.
- **Immediately promote a reachable replacement.** Rejected: reachability is
  not authority; without phased evidence/adoption/publication and explicit
  activation it can create two writers and lose queued or replay state.
- **Require one inspect/prepare/commit/abort API for every link kind.** Rejected:
  it collapses protocols with several authority boundaries and falsely makes a
  frozen non-rebindable protocol appear takeover-capable. The registry fixes
  semantics and phases while each adapter binds only operations it can prove.
- **Allow abandonment until activation.** Rejected: after candidate consumption,
  adoption authority and retained evidence bind the original candidate. A
  replacement would fork authority; only exact resume/reconciliation is valid.
- **Edit a link-kind registration in place.** Rejected: prior receipts and
  terminal evidence would silently change meaning. Evolution creates an
  immutable successor revision and an explicit migration receipt.
- **Retain every candidate resource with its evidence.** Rejected: immutable
  evidence is necessary, but retaining scarce sockets, slots, credentials, and
  leases after authenticated abandonment creates a capacity leak. D8 separates
  evidence retention from reclamation.
- **Keep the link forever without conditions or reconciliation.** Rejected:
  conservation without bounded attempts and visible state is an invisible
  leak, not recovery.

## Affected documents

On acceptance this ADR amends:

- `001-layered-execution-model.md` — Layer 3 gains the stateful-link identity,
  conservative recovery, and no-parallel-session-authority invariants.
- `002-provider-base-contract.md` — provider lifecycle and health contracts gain
  evidence classification and explicit session-link rebind semantics.
- `006-cross-provider-interactions.md` — the inbound/outbound remote-peer seams
  gain a shared stateful-link recovery seam.
- `011-local-daemon-fleet.md` — crash recovery and operator status gain
  preserve-and-degrade behavior plus clearing link conditions.
- `013-orchestrator-and-governor.md` — unreachable-session handling gains fresh
  authority recheck, bounded episodes, and exact supersession/terminal gates.
- `ADR-2026-08-16-one-session-substrate-and-typed-event-spine.md` — link aliases
  remain non-authoritative and recovery receipts may project as strict events.
- `ADR-2026-08-19-durable-execution-event-bus-and-bounded-subscriptions.md` —
  link-recovery records use durable-before-live publication while coordination
  nudges remain separate.
- `ADR-2026-07-12-interactive-pty-session-host.md` — annotate the frozen first-
  generation attach profile as non-rebindable and the second generation as the
  exact phased precedent.
- `ADR-2026-08-17-session-shim-adoption.md` — cross-reference the generic
  registry, ownership fence, load bounds, and terminal-proof law without
  changing the accepted adoption sequence.

`protocol/interactive-attach-v1.md`, `protocol/interactive-attach-v2.md`, and
`protocol/session-shim-v3.md` remain normative precedents for candidate
preparation, explicit activation, durable acknowledgement, generation floors,
and no terminal verdict from missing contact. D5 maps the second-generation
protocol exactly and classifies the frozen first-generation protocol as
non-rebindable. This ADR does not alter their wire bytes or closed control
vocabularies while Proposed.

Before publication, the canonical corpus must add this ADR to its descriptive
ADR list, complete ADR index, and agent ADR read order. The companion corpus
must add a thin mirrored stub with the same ADR filename and canonical pointer,
plus its corresponding indexes; concrete implementation-specific content
belongs in a separate extension if it outgrows the stub. Those publication
companions are required for merge but are not evidence that this Proposed
contract is accepted.

## Affected work items

- Closed link-kind registry, contract types, canonical operation/receipt
  encoding, and conformance fixtures.
- A standalone execution-layer authority and rebind implementation.
- Authentication, authorization-policy, and independent recovery-owner fencing
  at every phase.
- Per-link-kind authority inventory and destructive-path migration.
- Cross-episode budgets, circuit/dead-letter handling, reservation disposition,
  and evidence-preserving reclamation.
- Condition/event projection and low-cardinality recovery metrics.
- Crash, race, stale-evidence, and installed-artifact compatibility proof.

No private tracker references belong in this public ADR.

## Implementation notes

- Generate strict phase request/receipt validators from each closed registry
  entry while allowing transport-specific bindings. A provider callback and a
  local control API can implement the same semantic phase without sharing route
  names.
- Resolve registrations by exact id/revision/digest from `SessionLinkRef`; a
  “latest registration” helper is forbidden on recovery, supersession,
  terminal acceptance, cleanup, and audit paths.
- Reuse the canonical session identity, existing durable outbox/event spine,
  and link-kind-native cursor or generation. Do not create a recovery session,
  recovery mailbox, or generic global epoch.
- Keep `RecoveryOwnerFence.ownerEpoch` independent from transport generation
  and authority revision; comparing or copying among them is a contract error.
- Canonicalize and digest every inspect/phase/abandon/supersession/terminal
  request and receipt so exact replay and changed-request conflicts are
  mechanical.
- Store actor/authentication-context digests and authorization policy
  decisions, never bearer material or unrestricted policy inputs.
- A standalone implementation must be usable without an external control
  plane. Implementations may extend authority, policy, storage, and operator
  surfaces but may not be the only working realization of the interface.
- Add any strict execution-event topics through the event schema source; do not
  publish an unversioned attributes bag.
- Reference-doc amendments, companion extensions, and any protocol additions
  land only with acceptance and their own boundary checks.
