---
status: Accepted
date: 2026-08-16
boundary: shared
split: synchronized-mirror
revision: 2
---

# ADR-2026-08-16 — One session substrate and a typed execution-event spine

**Status:** Accepted — architecture decision; implementation, migration,
release, and activation remain pending.
**Date:** 2026-08-16
**Boundary:** shared (identity, admission, projection, event, bridge, replay,
subscription, and retention laws are canonical here; multi-tenant tables,
wire namespaces, routes, policy, product projections, and rollout sequencing
live in the platform mirror)
**Revision:** 2

## Context

Session lifecycle is easy to fragment accidentally. A workflow run, an
interactive terminal, a headless agent, a remote bridge, and a delegated child
may each acquire a convenient local id, status field, event stream, or cache.
When those convenience surfaces can independently create or terminalize work,
the system has several session authorities rather than several views of one
session.

The same split appears in observability. Lifecycle rows, terminal bytes,
structured harness events, activity feeds, workflow events, and coordination
messages have different fidelity and retention needs. Treating an ephemeral
stream as the record loses events; forcing every fact into a session invents
fake sessions for project/workflow events; merging coordination messages with
lifecycle confuses acknowledgement and authority.

This ADR establishes one substrate for admitted sessions and one strict typed
event spine for session, project, and workflow subjects. It is additive: legacy
tables and streams remain compatibility projections until a proven cutover.

## Decision

### Shared contract synopsis

The following region is mirrored byte-for-byte in the platform stub. It is the
minimum contract every composing control plane and execution-layer adapter must
preserve.

<!-- BOUNDARY-SYNC-START: adr-2026-08-16-session-substrate-core-contract -->
**One-session-substrate core contract.**

1. **One lifecycle identity:** `(org_id, session_id)` is the sole durable
   lifecycle identity. Organization scope is mandatory; `session_id` alone is
   not a cross-tenant key.
2. **Aliases never become authority:** graph, workflow, room, relay, shim,
   process, public-hash, tracker, provider-run, conversation, database-surrogate,
   and transport ids are typed correlation or fencing values only. None may
   create, re-key, merge, split, release, or terminalize a session.
3. **One admission boundary:** every new session class commits one canonical
   `SessionRef`, its truthful typed admission evidence, the initial lifecycle
   event, and the outbox record atomically before enqueue or spawn. A legacy
   import records provenance and never counterfeits an admission receipt.
4. **Class tables are projections:** workflow, agent, interactive, bridge, and
   provider-specific rows may retain class detail, but their status fields do
   not own canonical lifecycle. New lifecycle writes advance the session
   authority first and project outward idempotently.
5. **One typed event spine:** a strict versioned execution-event envelope carries
   session, project, and workflow subjects. Topic payloads are closed and
   versioned; unknown versions, topics, fields, and invalid evidence fail closed.
6. **Durable before live:** the append-only event log and transactional outbox
   are the record. Redis, SSE, relay state, and other live transports may carry
   byte-identical wakeups or projections, but never correctness or replay
   authority.
7. **Cursor honesty:** durable replay uses exclusive cursors and explicit channel
   positions. A cursor behind retention returns `cursor_expired`; no consumer
   silently skips, fabricates continuity, or treats a wakeup as durable delivery.
8. **External identity separation:** an external principal, bridge-runtime
   epoch, provider conversation, inbound message, and resulting work are
   distinct identities with explicit edges. A principal or conversation id is
   never stamped into `session_id`.
9. **Subscriptions evaluate after append:** predicates are bounded, typed,
   deterministic, secret-free, and evaluated by a durable consumer after the
   source event commits. At-least-once delivery plus idempotent receipts yields
   one durable target admission, not an exactly-once side-effect claim.
10. **Coordination remains separate:** agent-to-agent messages keep their own
    identity, retention, delivery, and acknowledgement store. They may share
    delivery-tier vocabulary with the execution spine but are not session
    lifecycle events.
<!-- BOUNDARY-SYNC-END: adr-2026-08-16-session-substrate-core-contract -->

### D1 — One tenant-scoped SessionRef authority

Every admitted execution has one canonical `SessionRef` under
`(org_id, session_id)`. Authorization supplies `org_id` on every lookup and
mutation; project scope narrows access but never replaces tenant scope.

Four identity lifetimes are deliberately distinct:

| Identity | Lifetime | Rule |
|---|---|---|
| External principal | Registration/account identity across process restarts | Authorizes requests; never a session |
| Bridge runtime | One authenticated gateway process epoch or connection lease | Separately admitted session class |
| External conversation | Provider/account/chat/thread context across messages | Typed alias; never automatically coalesced across providers |
| Work session | One workflow, interactive, headless, or delegated execution | Separately admitted canonical `SessionRef` |

Admission is a transaction-aware boundary used by every launch path. Its closed
kind union distinguishes typed dispatch, workflow run, interactive work, bridge
runtime, headless work, and legacy import. Each kind records only evidence that
actually exists. Failure to commit the node, first event, and outbox fails a new
launch before work becomes claimable.

### D2 — Compatibility projections never mint a second session

Class-specific tables add an explicit mapping to the canonical session key.
New rows use the canonical id in their compatibility id column where possible.
Historical public, tracker, workflow, provider, and room ids remain typed aliases
until their consumers migrate.

Backfill is conservative:

- an exact same-organization match maps only when project and creation evidence
  agree;
- an unmatched row becomes a truthful `legacy_import` node;
- an ambiguous/conflicting row is quarantined for explicit reconciliation;
- an existing canonical node is never rewritten to fit a projection; and
- no join by hash, room, agent, or timestamp may invent identity.

After validation, canonical lifecycle transitions write the session authority
and event/outbox first. Idempotent projectors update compatibility rows. Direct
multi-writer lifecycle updates retire only after reconciliation remains at zero
for the required migration window.

### D3 — A strict execution-event envelope

`ExecutionEventEnvelope` is a versioned closed document with:

- event id, tenant and optional project scope;
- a closed subject `{kind: session|project|workflow, id, graphId?, sessionClass?}`;
- topic/event type;
- observed and recorded times;
- a cursor containing a durable total-order position plus optional native
  channel positions; and
- a strict, versioned, secret-free payload.

Compatibility top-level session fields may survive one version, but new
consumers reason from `subject`. Session replay keeps independent channel
positions for ledger facts, structured harness events, and terminal bytes rather
than inventing a false total order inside one session. The durable bus position
orders envelopes for tenant/project consumers.

Payloads carry native correlation when known: provider event/run/turn/thread/
message/item/tool ids and sequence/cursor values; parent/root causation; evidence
kind (`native|inferred|synthesized`); bounded derivation/confidence; and explicit
partial, replay, truncation, terminal, and completeness flags. Missing native
fidelity is represented, never guessed.

The initial closed topic families and literals are:

- **Session lifecycle/control:** `session.admitted`,
  `session.identity.resolved`, `session.phase.changed`,
  `session.status.changed`, `session.heartbeat`, `session.waiting`,
  `session.suspended`, `session.resumed`, `session.blocked`,
  `session.cancellation.requested`, `session.cancellation.acknowledged`,
  `session.cancelled`, `session.adaptation.recorded`, `session.ended`.
- **Hierarchical execution/content:** `turn.started`, `turn.completed`,
  `message.started`, `message.completed`, `item.started`, `item.completed`,
  `step.started`, `step.completed`, `message.delta`, `reasoning.delta`.
- **Tools, permissions, hooks:** `tool.requested`, `tool.called`,
  `tool.progressed`, `tool.completed`, `tool.failed`,
  `permission.requested`, `permission.resolved`, `hook.started`,
  `hook.completed`, `hook.failed`.
- **Input/continuation:** `input.requested`, `input.resolved`, `input.queued`,
  `input.applied`, with applied mode `follow_up | steer | resume`.
- **Retry, compaction, provider health:** `retry.started`, `retry.completed`,
  `retry.exhausted`, `compaction.started`, `compaction.completed`,
  `compaction.failed`, `provider.status.changed`, `rate_limit.updated`,
  `transport.failed`, `error.raised`.
- **Plans, work, measurement:** `plan.updated`, `task.updated`, `diff.updated`,
  `context.updated`, `usage.recorded`, `subagent.started`,
  `subagent.completed`, `subagent.failed`.
- **External ingress/egress:** `external.message.received`,
  `external.work.requested`, `external.work.accepted`,
  `external.work.rejected`, `session.input.requested`,
  `session.input.accepted`, `session.input.rejected`,
  `external.reply.requested`, `external.delivery.attempted`,
  `external.delivery.accepted`, `external.delivery.delivered`,
  `external.delivery.failed`, `external.delivery.suppressed`.
- **Project/workflow outcomes:** `ci.run.completed`, `artifact.recorded`,
  `pr.opened`, `credential.refreshed`.
- **Data lifecycle:** `archive.started`, `archive.completed`, `archive.failed`,
  `archive.rehydrated`, `archive.pruned`.
- **Forward visibility:** `provider.event.unmapped`, carrying only bounded
  provider/discriminator/schema, byte length, digest, redacted summary, and an
  optional access-controlled raw pointer—never unrestricted unknown payload.

`session.ended` has the closed outcomes `succeeded | failed | cancelled |
interrupted | expired | terminated | lost` and records whether the evidence is
native, graceful, forced, inferred, or model-authored. `usage.recorded` declares
`scope = call | turn | session` plus completeness. Bounded causation carries
`rootEventId`, `parentEventId`, `subscriptionPath`, and depth at most eight.

Persistence policy is orthogonal to topic vocabulary: `durable`, `coalesced`,
`live-only`, and `raw-pointer` describe storage; `durable`, `nudged`, and `live`
describe delivery evidence. A live-only event is never called replayable, and a
Redis publish is never called durable or delivered.

Audit is an independently checkpointed projection of the audit-worthy subset.
Audit outage does not redefine or block the execution-event record.

### D4 — External bridge sessions and work remain separate

A bridge runtime is admitted at an authenticated create/resume handshake with a
bounded lease, capability snapshot, and runtime idempotency key. Inbound provider
messages append against that bridge before routing, including when project scope
is not yet resolved. Policy then either rejects durably or atomically binds a
project and admits a distinct work session with immutable bridge/source/
conversation correlations.

Replies are durable requests, not callback invocations. A reply request names
the originating bridge/work/source and a secret-free route reference. The bridge
adapter resolves provider/account/conversation/thread/reply-to locally, adapts
content to channel capability, and emits attempted/accepted/delivered/failed/
suppressed receipts. Bridge acceptance is not provider delivery. Cross-system
delivery is at least once with one logical reply; no exactly-once provider claim
is made.

Bridge, conversation, work, and principal lifetimes end independently. External
user traffic never enters the agent-to-agent message store.

### D5 — Dynamic subscriptions are bounded durable consumers

The v1 predicate is a closed AST: exactly one of `all`, `any`, `not`, or a typed
leaf `{field, op, value?}`. The initial operators are equality/inequality,
membership/containment, prefix/suffix, ordered comparisons, and existence:
`eq | neq | in | contains | prefix | suffix | lt | lte | gt | gte | exists`,
with strict types and no coercion. Topic catalogues allowlist immutable
secret-free fields and their legal operators.

Validation caps depth at five, leaves and `in` members at 32, strings at 256
bytes, and canonical predicate JSON at 16 KiB. Regex, glob, functions,
arithmetic, mutable lookups,
cross-field comparisons, and per-event templates are absent. An edit pauses the
subscription, catches up to a durable high-water mark, increments revision, and
resumes after that boundary; discarding backlog is an explicit audited action.

Evaluation happens after append in a leased serial consumer. Nonmatches advance
the exclusive cursor. A match inserts or finds an idempotent delivery receipt
and admits a deterministic target workflow from the byte-identical envelope.
Only durable target admission advances beyond the event. A poll reads at most
100 events or runs for 500 ms; one delivery is active per subscription. Eight
capped-backoff failures end in visible dead-letter/pause state without skipping
the source event. `subscriptionPath` rejects re-entry and depth above eight.
Creation enforces the configured plan limit without runtime truncation; the
reference default is 100 active subscriptions per tenant/project-or-null/topic.

### D6 — Retention is archive-before-prune

Lifecycle/key-outcome headers remain warm for the configured audit window;
searchable/progress content follows recording policy. Content moves through
explicit archive start/completion/failure/rehydration/prune transitions with
receipts. Identity, terminal outcome, cost, and archive pointers remain after
hot content leaves. A resume behind the retained floor returns
`cursor_expired` plus a rehydration path.

Topic expressiveness never implies permanent hot storage. Conversely, retention
may not erase the evidence required to interpret lifecycle, cancellation,
delivery, or terminal results.

### D7 — Additive migration and proof

The migration order is:

1. add canonical mappings and widened admission;
2. backfill or quarantine every compatibility row;
3. land the versioned envelope, append-only log, outbox, replay, predicate
   catalogue, subscriptions, and receipts;
4. admit and project interactive and bridge sessions;
5. switch topology/detail/stream readers to the normalized projection; and
6. retire direct writers and overlay reads only after two retention windows at
   zero reconciliation drift.

Required proof includes tenant isolation; atomic rollback; append-only and
terminal immutability under the production-equivalent database role;
crash/retry/dedup; Redis-outage replay; cursor continuity/expiry; one node per
canonical id; distinct bridge/work/conversation ids; strict legacy-detail
up-conversion; no remaining direct lifecycle writer; duplicate inbound messages;
gateway restart after reply commit; status/cancel authorization; attachment
adaptation; revocation; and archive-before-prune/rehydration.

Physical table consolidation, historical high-volume rewrite, general stream
analytics, unbounded query languages, and exactly-once external side effects are
separate decisions.

## Consequences

### Positive

- Every admitted session class has one lifecycle authority and one normalized
  read model.
- Alternate ids remain useful without becoming hidden authority.
- Durable replay and subscriptions no longer depend on live transport uptime.
- Project/workflow facts are routable without manufacturing sessions.
- External bridges can restart and resume without conflating principal,
  conversation, gateway epoch, and work.

### Negative

- The durable event volume and projector/subscription lag must be operated.
- Migration temporarily duplicates compatibility storage and requires explicit
  quarantine for ambiguous legacy rows.
- Strict topic/predicate catalogues add schema and evolution work.
- Archive and cursor-expiry behavior become part of the product contract.

### Risks

- A compatibility writer may remain a hidden second authority. Mitigation:
  enumerate writers mechanically and remove them only after zero-drift windows.
- A producer may smuggle raw/unbounded content into filterable payloads.
  Mitigation: closed topic schemas, field catalogues, byte limits, and digests.
- A bridge may widen access on resume. Mitigation: registration-owned durable
  subscriptions, immutable origin filters, bounded leases, and policy recheck.
- A consumer may call at-least-once delivery exactly once. Mitigation: precise
  receipt vocabulary and deterministic admission ids, never side-effect claims.

## Alternatives considered

- **Make a class projection canonical.** Rejected: it excludes other session
  classes and preserves conflicting identity constraints.
- **Keep identities separate behind heuristic mapping.** Rejected: permanent
  dual authority and ambiguous joins remain.
- **Use a live cache/pubsub as the event bus.** Rejected: unavailable consumers
  lose history and cannot resume honestly.
- **Keep the spine session-only.** Rejected: project/workflow facts would require
  fake sessions.
- **Merge coordination messages into execution events.** Rejected: their
  identity, acknowledgement, and retention semantics differ.
- **Evaluate predicates in the publisher transaction.** Rejected: consumer
  fan-out/failure would enter source correctness and defeat replay.

## Affected documents

- `001-layered-execution-model.md` — one tenant-scoped session identity and
  projection-only aliases become Layer-3 invariants.
- `013-orchestrator-and-governor.md` — every launch shares one admission
  boundary; durable execution events precede live projections.

The platform mirror records concrete schemas, routes, migrations, topic wire
names, implementation units, and rollout gates.

## Implementation notes

- Exact table names and wire namespaces are composing-platform decisions; the
  shared interfaces and invariants above do not require a hosted control plane.
- Event codecs should generate validators and filter catalogues from one schema
  source so admission, replay, and subscription evaluation cannot drift.
- A2A coordination may reuse delivery-tier types but keeps a separate store and
  protocol.
