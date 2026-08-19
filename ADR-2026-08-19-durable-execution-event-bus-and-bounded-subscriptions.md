---
status: Proposed
date: 2026-08-19
boundary: shared
split: synchronized-mirror
---

# ADR-2026-08-19 — Durable execution-event bus and bounded subscriptions

**Status:** Proposed — contract review required before implementation or wire
freeze.
**Date:** 2026-08-19
**Boundary:** shared (the strict execution-event envelope, topic/schema law,
durable append/replay rules, bounded predicate language, subscription delivery,
idempotent target admission, coordinator observation, and coordination-store
separation are OSS-canonical here; multi-tenant tables, routes, concrete wire
namespace, hosted workflow admission, and rollout live in the platform mirror)
**Authors:** execution-event design lane

## Context

The accepted one-session-substrate ADR establishes one strict typed event spine
for session, project, and workflow subjects. It deliberately leaves exact table
names and composing-platform wire namespaces to implementations. The first
implementation slice now needs enough contract precision that the OSS event
source, a hosted durable log, workflow reactions, and coordinator observation
cannot each invent a subtly different envelope or acknowledgement model.

Three existing seams make that precision urgent.

1. The normalized runtime source is a closed event union. The reference runner
   persists `init`, `system`, `assistant_text`, `llm_call`, `tool_use`,
   `tool_result`, `tool_progress`, `result`, and `error` records to the session
   event journal. Raw provider payloads remain opaque evidence, not a public
   filtering vocabulary.
2. Current live session streaming is a cache projection. Redis absence may turn
   publication into a no-op, so that stream cannot be correctness, replay, or
   subscription authority.
3. Workflow trigger routing already resolves visible targets and dispatches
   durable workflow instances for external events. Building a second routing
   engine for internal execution events would duplicate target authority and
   drift on publication, tenant, project, and idempotency rules.

The wake failure that motivated this ADR also fixes the difference between
state and transport. A parked session with no usable wake rail is `waiting`; a
session unable to proceed on a durable external dependency is `blocked`. A
missing nudge must not erase either fact, and it must not turn every waiting
session into a blocked one.

This ADR refines the shared contract before any composing platform freezes its
wire or ships subscription tables. It does not activate producers, migrate
readers, or change lifecycle authority.

## Decision

### Shared contract synopsis

<!-- BOUNDARY-SYNC-START: adr-2026-08-19-execution-event-bus-core-contract -->
**Execution-event bus core contract.**

1. **One strict envelope:** every durable execution event is a closed,
   versioned envelope with event identity, tenant and optional project scope,
   a session/project/workflow subject, topic, channel, observed and recorded
   times, persistence policy, native cursor positions,
   bounded causation, schema digests, and a strict topic payload.
2. **One schema source:** envelope validators, topic payload validators,
   canonical encoders, up-converters, filterable-field catalogues, and digests
   are generated from the same source. Unknown versions, topics, fields,
   evidence kinds, or invalid payloads fail closed.
3. **Durable before live:** a source fact and its outbox record commit together.
   The append-only event log is written idempotently before Redis, SSE, relay,
   PTY, or message nudges. Live transport failure never changes replay or target
   admission correctness.
4. **Native positions stay native:** the bus has an exclusive durable position
   for tenant/project consumption, while ledger, structured-execution, and
   terminal-byte channels keep independent native cursors. No API invents a
   total order among those per-session channels.
5. **Storage and delivery are distinct:** `durable`, `coalesced`, `live-only`,
   and `raw-pointer` describe persistence. Append and per-consumer receipts use
   `durable`, `nudged`, and `live` as delivery evidence. Only acknowledged
   handling may claim `live`; immutable event bytes never acquire a later
   consumer's delivery state.
6. **Predicates are bounded data:** the v1 language is a closed, typed,
   deterministic, secret-free AST over catalogue-allowlisted immutable fields.
   Regex, glob, functions, arithmetic, mutable lookups, cross-field comparison,
   coercion, and per-event templates are absent.
7. **Subscriptions run after append:** a leased durable consumer evaluates
   predicates only after the source event commits. Nonmatches advance an
   exclusive cursor. Matches advance only after idempotent durable target
   admission.
8. **At least once, one durable admission:** delivery may repeat. A receipt
   unique on consumer and event plus deterministic target identity collapses
   retries to one admitted target. No implementation claims exactly-once
   external effects.
9. **Backpressure is contractual:** consumers have bounded batches, bounded
   leases, one active delivery per subscription in v1, capped retry, visible
   dead-letter/pause state, and explicit operator retry/skip actions.
10. **Loops are explicit:** bounded causation carries a root, parent,
    subscription path, and depth. Re-entry and depth overflow are durably
    suppressed, never left to probabilistic deduplication.
11. **Observation is not reaction:** delivering an event to an already-running
    coordinator is observation of authorized work, not a hidden direct-agent
    subscription sink. User-authored reactions still target visible workflows.
12. **Coordination remains separate:** agent-to-agent messages retain their own
    identity, body, retention, cursor, and acknowledgement store. A coordination
    or PTY message may carry an opaque event nudge, but cannot copy the event
    body or advance an execution-event cursor.
<!-- BOUNDARY-SYNC-END: adr-2026-08-19-execution-event-bus-core-contract -->

### D1 — The envelope is closed and generated

`ExecutionEventEnvelope` contains:

- one event id;
- mandatory tenant scope and optional project scope;
- a closed subject `{kind: session|project|workflow, id, graphId?,
  sessionClass?}`;
- an exact topic and channel;
- observed and recorded timestamps;
- an exclusive bus position and optional ledger, structured, and terminal-byte
  positions;
- one persistence policy;
- a strict versioned payload;
- payload, envelope, and filter-catalogue digests; and
- bounded evidence, completeness, causation, and replay metadata.

The schema identifier is namespaced by the composing serializer. The shared
contract fixes the fields and semantics, not one composing implementation's
namespace. The canonical encoder produces stable bytes and a SHA-256 digest. Implementations
persist and forward those exact bytes rather than decode/re-encode at each
transport hop.

The initial topic registry is the full revision-2 taxonomy accepted by the
one-session-substrate ADR. The session-source normalization contract includes at least
`step.started`, `step.completed`, `tool.called`, `error.raised`, `pr.opened`,
`session.status.changed`, `session.waiting`, `session.blocked`,
`credential.refreshed`, and `session.ended`. `session.status.changed` is the
source for a latest-value status projection, not a second status namespace.

Raw provider bodies, prompts, unrestricted tool input/output, and secrets are
never filterable payload fields. An unknown native event becomes a bounded
`provider.event.unmapped` record with discriminator/schema, length, digest,
redacted summary, and an optional access-controlled raw pointer.

### D2 — Source facts use an outbox; audit is a projection

Every normalized producer commits its local fact and strict outbox record in one
transaction. The drain appends the canonical envelope idempotently to the
durable log. Only after append may it acknowledge the source row and publish a
live nudge.

Audit consumes the durable event log with an independent checkpoint. Audit
failure may create projection lag and an alert, but it never prevents the event
record from existing or redefines the source outbox as undelivered. This keeps
audit independently recoverable without making audit availability part of
execution correctness.

### D3 — Replay is exclusive and retention is honest

Tenant/project consumers resume with exclusive `afterBusSeq`. Session replay
may carry a cursor tuple containing ledger sequence, structured sequence, and
terminal byte offset. A bus position orders envelopes for a tenant/project
consumer; it does not order independent session evidence channels against one
another.

A cursor below the retained floor returns `cursor_expired` and an archive or
rehydration path. No consumer silently resets to the current head. Archive
precedes prune, and lifecycle/key-outcome headers remain sufficient to
interpret terminal, cancellation, delivery, and cost evidence.

### D4 — The predicate language is deliberately small

The v1 predicate is exactly one of `all`, `any`, `not`, or a typed leaf
`{field, op, value?}`. Operators are `eq | neq | in | contains | prefix |
suffix | lt | lte | gt | gte | exists`, with strict types and no coercion.

Validation caps:

- AST depth: 5;
- leaves: 32;
- `in` members: 32;
- one string: 256 bytes; and
- canonical predicate JSON: 16 KiB.

Topic catalogues allowlist fields and their legal operators. Activation
resolves authoring references to literals and pins canonical predicate and
catalogue digests. Evaluation errors fail closed.

### D5 — Subscription delivery is serial, bounded, and idempotent

A subscription stores exact topic and scope, schema/predicate digests and
revision, exclusive cursor, lifecycle/operator state, and a renewable lease.
An edit pauses at a durable high-water mark, catches up to it, increments the
revision, and resumes. Discarding backlog is an explicit audited action.

A v1 poll reads at most 100 events or runs for 500 ms. One delivery is active
per subscription. Nonmatches advance. A match inserts or finds a unique
consumer/event receipt and admits a target whose identity is derived from
`(subscriptionId,eventId)`. Receipt, target admission, and cursor advance settle
atomically; execution begins after commit.

Eight capped-backoff failures end in visible dead-letter and paused state. The
cursor remains before that event until an audited retry or skip. The default
limit is 100 active subscriptions per tenant/project-or-null/topic, enforced at
creation rather than by runtime truncation.

`subscriptionPath` rejects re-entry and depth above eight. A suppressed loop is
a durable receipt state.

### D6 — Reuse target authority, not provider-specific matching

External events and internal execution events use separate candidate and
predicate adapters:

- external adapters keep provider-specific mapping and compatibility filters;
- internal adapters use exact topic lookup and the bounded predicate evaluator.

Both call one resolved-target core for publication, policy, tenant/project
scope, executable-definition resolution, and transaction-aware deterministic
admission. An implementation must not copy an existing router or force the
strict internal envelope through a provider-specific external-event mapper.

### D7 — Coordinators observe through a durable consumer

An already-running coordinator may bind an authorized graph/child/project event
view. That binding uses the same durable lease/cursor/receipt primitives but is
not an authorable workflow reaction and does not admit an agent.

Delivery to a coordinator carries event identity, bus position, topic, subject,
consumer identity, attempt, and schema digests. A boundary acknowledgement
records receipt without moving the cursor. A handled acknowledgement advances
the cursor and may claim `live`. Crash after delivery but before handled
acknowledgement redelivers the same event.

Push, PTY, or agent-to-agent nudges may wake the coordinator, but the durable
consumer remains authoritative. Reading a coordination message never advances
the event cursor.

### D8 — Runtime-source normalization preserves evidence

The reference normalized runtime source maps as follows:

- `init` -> `session.identity.resolved`;
- typed `system` subtypes -> compaction, provider-status, rate-limit, retry, or
  transport topics;
- `assistant_text` -> policy-bounded `message.delta`, with synthesized
  completion only at a known boundary;
- `llm_call` -> `usage.recorded`;
- `tool_use` -> `tool.called`;
- `tool_result` -> `tool.completed` or `tool.failed`;
- `tool_progress` -> `tool.progressed`;
- `error` -> `error.raised`; and
- `result` -> evidence into the canonical terminal transaction.

A provider result may not independently terminalize a session. The committed
lifecycle transition emits `session.ended` through its outbox. Native ids,
trace/span correlation, evidence kind, partial/replay flags, and completeness
are preserved; missing fidelity is represented rather than guessed.

### D9 — Migration and proof are additive

The first slice adds schemas, append-only storage, outboxes, replay, bounded
consumers, deterministic target admission, and one routable vertical. It does
not cut over legacy readers or all producers.

Required proof includes source-transaction rollback; append-only enforcement
under the production-equivalent role; tenant/project isolation; schema and
predicate rejection; append/ack crash recovery; deterministic duplicate target
admission; Redis-outage replay and admission; cursor continuity/expiry;
100-event/500-ms bounds; eight-attempt dead letter; loop suppression; and
coordinator receipt-versus-handled redelivery.

Producer normalization, reader cutover, status projection, search, and data
lifecycle remain separately staged. Direct writers retire only after the
accepted zero-drift window.

## Consequences

### Positive

- Session, project, and workflow events share one strict replayable contract.
- Workflow reactions reuse existing target authority without reusing unsafe
  provider-specific matching.
- Coordinators can react to waiting/blocked/terminal child state without
  treating the coordination mailbox as an event log.
- Redis and wake rails leave the correctness path.
- Predicate and retry bounds make fan-out capacity planable.

### Negative

- The durable event log, source outboxes, consumer leases, delivery receipts,
  dead letters, and audit lag all require operations and support surfaces.
- Strict catalogues add schema-generation and versioning work.
- Deterministic admission requires a transaction-aware workflow-instance seam
  rather than the current random-id insert.

### Risks

- Sharing too much of a legacy external router could import fail-open scope or
  mutable evaluator behavior. Share only target resolution, authorization, and
  admission.
- Filterable payloads could leak raw provider content. Generate the catalogue
  from strict secret-free topic schemas and store raw content by pointer only.
- A nudge could be reported as delivery. Only handled acknowledgement claims
  `live`; Redis, PTY, and coordination messages claim at most `nudged`.
- A stalled poison event could starve later events. Visible dead-letter/pause
  plus audited retry/skip is deliberate; silent skip is forbidden.

## Alternatives considered

- **Use Redis or SSE as the bus.** Rejected: unavailable consumers lose events,
  and Redis absence currently produces a silent no-op.
- **Build a second internal dispatch engine.** Rejected: publication, policy,
  project scope, executable resolution, and workflow admission would drift.
- **Send event bodies through agent-to-agent messages.** Rejected: message and
  event identity, retention, acknowledgement, and replay semantics differ.
- **Evaluate predicates in the producer transaction.** Rejected: consumer
  failure and fan-out would enter source correctness.
- **Allow general expressions or regex.** Rejected: unbounded CPU, secret
  lookup, non-determinism, and cross-version evaluator drift.
- **Claim exactly-once delivery.** Rejected: at-least-once delivery with one
  durable idempotent admission is precise and testable.

## Affected documents

- `001-layered-execution-model.md` — typed event spine and coordination-store
  separation remain Layer-3/Layer-6 invariants.
- `013-orchestrator-and-governor.md` — normalized runtime-source mapping,
  outbox-before-live delivery, and coordinator observation.
- `016-workflow-engine.md` — visible event triggers reuse one resolved-target
  and deterministic admission core.
- `ADR-2026-08-16-one-session-substrate-and-typed-event-spine.md` — this ADR
  refines D3 and D5 without changing their accepted laws.

Reference-doc edits land with acceptance, not while this ADR remains Proposed.

## Affected work items

- Event-spine and dynamic-subscription implementation.
- Session-source normalization and reader cutover.
- Latest-value status projection.
- Richer-topic search.
- Archive-before-prune lifecycle.

## Implementation notes

- Keep schema generation in the OSS contract layer and composing-platform
  storage/route generation in the platform layer.
- The first routable fixture is a project-scoped failed public-repository CI
  event whose change domains include OSS licensing, admitting one visible legal
  review workflow. Redis-disabled replay must admit the same workflow identity.
- New hosted token routes belong under a CLI/daemon surface, never an org-only
  machine route.
