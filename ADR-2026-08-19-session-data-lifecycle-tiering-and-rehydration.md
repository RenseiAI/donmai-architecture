---
status: Proposed
date: 2026-08-19
boundary: shared
split: synchronized-mirror
---

# ADR-2026-08-19 — Session data lifecycle tiering and rehydration

**Status:** Proposed
**Date:** 2026-08-19
**Boundary:** shared (the decay-aware tiering law, archive manifest, transition
invariants, rehydration contract, and independent-audit rule are canonical
here; concrete multi-tenant stores, routes, migrations, and rollout gates live
in the platform mirror)
**Authors:** data-lifecycle architecture lane

## Context

Session-stream data does not keep one value profile for its whole lifetime.
During a run, freshness and filtering are the value: an operator needs the
latest status, searchable activity, and push updates. Immediately after a run,
the value moves to cross-session analysis: cost, latency, quality, and outcome
rollups. Later, full-fidelity terminal bytes, structured events, and traces are
valuable mainly as inspectable evidence. Eventually most product reads need
only identity, outcome, cost, key links, and an honest way to recover archived
detail.

A single forever-hot store fights that decay curve. It makes the highest-volume
payloads dictate the cost and indexes of the operational database, while a
single retention delete destroys detail without leaving a recovery path. A
collection of independent per-table sweep jobs is not a lifecycle either: it
cannot prove that analytics and archive completed before source bytes were
pruned, and it makes one logical session appear to have unrelated retention
clocks.

`ADR-2026-08-16-one-session-substrate-and-typed-event-spine.md` already fixes
the governing laws: one tenant-scoped lifecycle identity, durable events before
live nudges, independent channel cursors, artifact manifests, honest
`cursor_expired`, and archive-before-prune. It deliberately leaves physical
tiering and general analytics to a separate decision. This ADR supplies that
data-plane decision without turning an analytics store, archive object, live
cache, or rehydration cache into a second session authority.

## Decision

### Shared contract synopsis

The following region is mirrored byte-for-byte in the platform stub. It is the
minimum contract every implementation must preserve.

<!-- BOUNDARY-SYNC-START: adr-2026-08-19-session-data-lifecycle-core -->
**Session-data lifecycle core contract.**

1. **Value-decay tiers are explicit:** session data moves through
   `live_fresh → post_run_analytics → durable_archive → warm_ui → skeleton`.
   A channel may occupy several tiers at once during hand-off, but every copy
   declares its role and availability; no store is called canonical merely
   because it still has bytes.
2. **Lifecycle authority does not move:** `(org_id, session_id)` and the
   canonical session ledger remain authoritative through every tier. Redis,
   search indexes, analytics rows, archive objects, manifests, signed links,
   and rehydration caches are projections or artifacts only.
3. **Terminal events start post-run work:** a durable `session.ended` event
   creates idempotent analytics, archive, warm-compaction, and future-prune
   obligations. Where this event exists, implementations do not add a second
   source-table cron scan to rediscover completion.
4. **Analytics is derived, never enforcement authority:** the analytics tier
   may serve insights, aggregates, and analytical cost views. Billing,
   authorization, lifecycle, and audit decisions continue to read their own
   authoritative ledgers; an analytics copy may lag or be rebuilt.
5. **Archive is channel-complete and manifest-led:** structured events,
   terminal bytes, traces, and other full-fidelity channels archive as immutable
   objects under one content-addressed session manifest. Each object records
   schema/version, byte length, digest, native cursor bounds, compression,
   encryption/storage policy, and availability.
6. **Archive-before-prune is a proof, not an ordering suggestion:** source
   content may be pruned only after object upload, read-back/digest verification,
   durable manifest commit, and an idempotent `archive.completed` receipt.
   Failure leaves source bytes and cursors intact.
7. **Warm UI data is closed and curated:** identity, class, title, owner,
   normalized and raw terminal status, outcome/evidence, timestamps, key events,
   cost summary and source, tracker/workflow links, artifact availability, and
   stable application link-backs may remain warm. Raw deltas, unrestricted tool
   bodies, prompts, secrets, and full terminal streams do not enter the warm
   subset by convenience.
8. **Skeleton rows keep meaning and recovery:** long-term rows retain tenant and
   session identity, project/graph correlations, terminal outcome/evidence,
   cost commitment, receipt/audit references, archive-manifest digest, channel
   availability, legal-hold/deletion state, and stable rehydration link-backs.
9. **Rehydration never rewrites history:** archived data materializes into a
   bounded read cache keyed by tenant, session, channel, manifest digest, and
   requested cursor/range. It does not reinsert old events into the canonical
   bus, advance subscriptions, rerun analytics, change lifecycle, or fabricate
   continuity.
10. **Cursor expiry is actionable:** a read behind the retained hot floor
    returns `cursor_expired` with the retained floor, channel availability,
    archive-manifest reference, and an authorized rehydration link when one
    exists. It never returns an empty page that looks continuous.
11. **Retention policy is per channel and tenant scope:** policy resolves before
    transition scheduling, supports explicit legal hold, and is recorded on the
    manifest/obligation. A later policy change does not silently reinterpret a
    completed archive or prune receipt.
12. **Audit and coordination keep independent laws:** audit facts, credential-
    audit handoffs, and agent-to-agent messages are not session payload channels.
    Session tiering may link to them but never archives, prunes, rehydrates, or
    acknowledges them on their behalf.
<!-- BOUNDARY-SYNC-END: adr-2026-08-19-session-data-lifecycle-core -->

### D1 — The five serving tiers

The tiers name serving purpose, not one mandatory product:

| Tier | Purpose | Required posture |
|---|---|---|
| `live_fresh` | Current run state, filtered search, replay tail, push/wakeup | Low-latency cache/pub-sub plus indexed durable projection; live transport is never replay authority |
| `post_run_analytics` | Completion-time insights, trace/cost/quality aggregates, cross-session analysis | Columnar or equivalent analytics store; derived, idempotent, rebuildable, tenant-scoped |
| `durable_archive` | Full-fidelity channel preservation | Immutable object storage plus verified manifest and archive receipts |
| `warm_ui` | Normal product list/detail pages after high-volume content cools | Closed relational summary/key-event projection with stable artifact links |
| `skeleton` | Long-term identity, outcomes, evidence links, retention/deletion state | Minimal durable relational authority and archive locator; no high-volume content |

The state is per **channel**, not a single session enum. A terminal-byte archive
may be complete while trace analytics is retrying and the structured-event hot
window remains open. The artifact manifest is the joined view of those channel
states. Session lifecycle phase remains terminal throughout; tier transitions
never reopen or re-terminalize it.

### D2 — Event-driven obligations and durable timers

The first durable `session.ended` event creates one obligation set for the
session under a deterministic identity such as
`(org_id, session_id, terminal_event_id, policy_revision)`. The set contains
separate idempotent tasks for:

- final analytics projection and completion rollups;
- channel archive and manifest finalization;
- warm-summary/key-event finalization;
- due-time hot projection pruning; and
- due-time warm-to-skeleton compaction.

The event consumer persists obligations before doing external I/O. Retries,
leases, backoff, dead-letter state, and operator disposition are durable.
Completion redelivery finds the same task identities. A second terminal event
with conflicting terminal evidence is an integrity conflict, not another
archive generation.

Elapsed retention windows use durable delayed work or an indexed obligations
queue whose rows were created from the terminal event. A periodic wakeup may
claim due obligation rows; it does not scan every session/event/activity table
to infer that a session ended. Recovery reconciliation is permitted only over
the obligations store and manifest state, because those are the explicit
handoff authorities.

### D3 — Analytics projection

Post-run analytics consumes the terminal event and durable source records. It
uses stable tenant/session/event/span identities and deterministic projection
versions. Identical replay produces identical rows; conflicting content is
quarantined. Analytics success records source high-water marks and projection
digests so lag is measurable and a rebuild can prove its inputs.

The analytics tier may contain:

- trace/span trees and latency distributions;
- token, cache-use, tool, error, retry, and outcome aggregates;
- analytical cost dimensions copied from the billing ledger;
- session/agent/harness/model/pool/project rollups; and
- insight-ready features derived from closed, authorized fields.

The phrase **analytical cost** is deliberate. A columnar copy may serve charts
and insights, but spend caps, invoices, charge allocation, and financial
reconciliation read the billing ledger. Analytics lag cannot grant budget or
erase cost.

### D4 — Immutable archive bundle

One archive generation contains a manifest and zero or one object per retained
channel. The recommended logical layout is:

```text
session-archive/v1
  manifest.json
  ledger.ndjson.zst
  structured-events.ndjson.zst
  terminal.cast
  traces.ndjson.zst
  results.ndjson.zst
```

Absence is explicit (`never_recorded | redacted | expired | excluded_by_policy`),
never inferred from a missing object. The manifest includes:

- manifest version, tenant/session/project/graph identity, terminal event id,
  policy revision, created/completed times, and manifest digest;
- for each channel: logical name, contract/schema version and digest, object
  locator, content type, compression, byte length, SHA-256, record count,
  first/last native cursor, and availability;
- archive provider and region/residency class, encryption/key-reference policy,
  retention/hold disposition, and verification time; and
- predecessor manifest digest if a later generation adds a channel without
  rewriting the prior one.

Object locators are opaque and secret-free. User-facing links target an
authorized application route, not a raw bucket URL. Archive generations are
immutable; correction creates a successor manifest rather than modifying a
verified object in place.

Upload is bounded and resumable per channel. The writer streams rather than
materializing an unbounded session in memory. It verifies every object by
provider read-back or an equivalent strong checksum/metadata proof before the
manifest becomes complete. The manifest commits before prune eligibility.

### D5 — Warm UI subset and key events

The warm summary is the product-facing contract after raw detail cools. Its
closed v1 shape contains:

- canonical tenant/session identity and session class;
- project, graph, workflow, tracker, parent/child, and artifact correlations;
- display title and authorized owner/principal reference;
- normalized status, raw terminal status, outcome, terminal-evidence kind, and
  final failure category;
- created/started/latest-progress/completed timestamps and duration;
- committed cost/tokens plus the named authoritative source;
- a bounded ordered list of key-event headers; and
- per-channel `hot | archived | rehydratable | redacted | expired |
  never_recorded` availability with stable application links.

Key events are headers from an allowlisted set: lifecycle/adaptation,
waiting/blocked/input, cancellation, terminal outcome, tool/error summary,
artifact, pull-request, CI, and archive transitions. A header may carry ids,
timestamps, result class, bounded redacted summary, and content digest. It may
not carry raw message/reasoning deltas, unrestricted tool input/output, prompt
or context bodies, terminal bytes, credentials, or unknown provider payloads.

The subset is independently versioned and rebuilt from durable authority. It is
not an excuse to keep compatibility JSON bags as permanent untyped truth.

### D6 — Skeleton and link-back durability

Warm-to-skeleton compaction removes key-event detail and nonessential display
data only after the warm window. The skeleton retains enough to answer:

- what session was this and which tenant/project/graph owned it;
- what terminal outcome and evidence were committed;
- what cost/token commitment remains authoritative;
- which receipts, audit facts, artifacts, and parent/workflow/tracker records
  correlate; and
- which archived channels can be inspected, rehydrated, redacted, or no longer
  exist.

Stable link-backs derive from canonical identity, never from provider object
URLs. A moved archive object updates an internal locator authority while the
application link remains unchanged. A skeleton without a resolvable manifest
is a visible integrity failure, not an archive-only empty state.

### D7 — Rehydration is an isolated read path

An authorized read requests one channel and an optional cursor/range. The
rehydrator:

1. loads the current skeleton and manifest under tenant/project authorization;
2. validates channel availability, policy/hold/redaction state, manifest
   digest, object metadata, and requested cursor bounds;
3. streams and verifies the immutable object;
4. materializes only the bounded requested range into an ephemeral read cache;
5. returns content plus exact archive/native cursors and completeness; and
6. records an idempotent `archive.rehydrated` receipt and access audit when
   policy requires it.

Cache identity includes tenant, session, channel, manifest digest, range, and
projection version. Entries have bounded bytes and TTL, are tenant-isolated,
and may be evicted without correctness loss. Rehydrated data never enters the
canonical execution-event log: reinsertion would allocate new bus positions,
retrigger subscriptions, and misrepresent old observations as new facts.

Concurrent identical requests share one leased materialization or independently
produce byte-identical cache entries. A checksum/schema/policy failure publishes
no partial cache and returns a typed unavailable/integrity response. Range
pagination remains on native archived cursors; a cache cursor is never promoted
to durable replay authority.

### D8 — Retention, holds, deletion, and audit independence

Retention resolves per tenant and channel before obligations are scheduled.
The resolved policy and revision are committed with each task/manifest. An
explicit legal hold blocks prune and object deletion, not archive creation or
analytics projection. A policy change creates new future obligations or an
audited explicit reschedule; it does not silently rewrite completed receipts.

Tenant retirement and data-subject deletion use a separate, audited retirement
workflow. Deleting relational locators before object-store deletion is complete
creates unaddressable bytes and is forbidden. Cross-store deletion is a durable
outbox/state machine with bounded leases, retries, and terminal operator state;
it never claims atomicity across stores.

Audit facts have their own append, chain, archive, minimum-retained-prefix,
legal-hold, and deletion law. Session archive receipts may reference audit event
ids/digests, but session lifecycle tasks never export or delete audit rows.
Credential-audit and similar mutation outboxes likewise drain and retain under
their own contracts; pending or failed handoffs are never session-prune inputs.
Agent-to-agent coordination remains outside the session artifact manifest.

### D9 — Transition and observability invariants

Every stage exposes tenant-scoped counts and oldest-age lag for pending,
claimed, retrying, dead-lettered, completed, and prune-blocked work. Alerts cover
missing terminal-event production, obligation backlog, analytics lag, archive
failure, manifest/object disagreement, prune without archive proof,
rehydration integrity failures, cache saturation, and skeletons with broken
link-backs.

One tenant's archive provider or oversized session cannot block another tenant.
Batches never cross tenant scope. Claim leases are fenced; stale workers cannot
complete or prune a successor's task. Attempt ceilings end in visible operator
state, not an infinite retry or silent skip. Archive/prune/rehydrate receipts are
strict execution events; audit-worthy transitions also project independently to
the audit chain.

### D10 — Migration and activation proof

The implementation order is:

1. inventory every current session store, projector, reader, and deletion
   authority and classify each field/channel;
2. make `session.ended` production complete and prove one terminal event per
   canonical session before enabling consumers;
3. add obligation/manifest/skeleton authorities default-off;
4. project analytics and warm summaries, measuring lag against source cursors;
5. dual-write and verify full-fidelity archives without pruning;
6. enable rehydration and stable link-backs, including `cursor_expired` paths;
7. move existing deletion authorities behind archive/manifest eligibility; and
8. compact to skeleton only after two retention windows at zero reconciliation
   drift and a rollback drill.

Required proof includes crash after each external/database boundary;
redelivery/idempotency/conflict; cross-tenant denial; archive read-back and
digest mismatch; partial/oversized channels; legal hold; policy revision race;
analytics rebuild; billing-authority separation; Redis loss; cursor expiry;
rehydration without subscription/projector side effects; cache eviction;
existing-retention interlock; audit-retention independence; credential-audit
outbox independence; tenant retirement; and stable link-backs after object
relocation.

No source prune, global retention scan replacement, migration, runtime flag,
store provisioning, release, or activation is authorized by Proposed status.

## Consequences

### Positive

- Serving architecture matches the value decay of session data instead of
  forcing all bytes into one cost/performance profile.
- Completion drives deterministic analytics/archive work without source-table
  rediscovery scans.
- Full fidelity can cool out of operational stores while the UI remains useful
  and archived detail stays reachable.
- Rehydration is honest about cursors and cannot replay historical data as new
  execution events.
- Audit, billing, lifecycle, and coordination authorities stay independent.

### Negative

- Multiple projections and stores require explicit lag, manifests, and repair
  tooling.
- Archive verification delays prune eligibility and temporarily duplicates
  data across tiers.
- Rehydration adds user-visible latency and typed unavailable states.
- Policy revision, legal hold, and cross-store deletion become durable state
  machines rather than simple TTLs.

### Risks

- A projector or archive may be mistaken for authority. Mitigation: every
  schema/receipt names its role; lifecycle and billing reads remain pinned to
  their ledgers.
- A terminal event may be absent or duplicated. Mitigation: activation blocks
  on producer completeness and deterministic obligation identity.
- Existing cron deletion may race the new archive writer. Mitigation: interlock
  or hold every destructive path before archive consumers activate.
- Archive links may rot after provider migration. Mitigation: stable application
  links plus an internal locator authority and manifest digest.
- Analytics and warm projections may expose sensitive content. Mitigation:
  closed allowlists, content-by-digest, tenant authorization, and no wildcard
  body/attribute projection.

## Alternatives considered

- **Keep all session streams hot in the operational database.** Rejected:
  session value decays, while high-volume indexes and storage costs do not.
- **Use independent per-table TTL or cron deletes.** Rejected: no joined proof
  that analytics/archive/link-backs exist before deletion.
- **Archive only when a user opens an old session.** Rejected: source retention
  could expire before the first read, and request latency would own durability.
- **Restore archived rows into the canonical event log.** Rejected: new bus
  positions and subscription replay would falsify event time and causation.
- **Make the analytics store the canonical session/billing store.** Rejected:
  columnar lag/rebuild semantics conflict with lifecycle and enforcement.
- **Use raw object-store URLs as links.** Rejected: credentials, provider moves,
  retention changes, and tenancy cannot be safely hidden behind a permanent raw
  URL.
- **One monolithic session archive object.** Rejected: independent channel
  policy, partial recording, bounded retries, and range rehydration require
  channel objects under one manifest.

## Affected documents

On acceptance this ADR amends:

- `ADR-2026-08-16-one-session-substrate-and-typed-event-spine.md` D6 — refines
  archive-before-prune into explicit serving tiers, obligations, manifests, and
  rehydration isolation.
- `013-orchestrator-and-governor.md` — terminal session processing creates
  durable lifecycle obligations rather than detached cleanup.
- `014-tui-operator-surfaces.md` — old-session surfaces display channel
  availability and stable rehydration links rather than implying hot detail.

The platform mirror records the current data/retention census, concrete stores,
interlocks, routes, and rollout sequence. No synchronized section outside this
ADR changes while its status is Proposed.

## Implementation notes

- The archive interface belongs at the session-artifact/channel boundary, above
  any one object-storage provider.
- The analytics interface is append/idempotency/query oriented and never exposes
  lifecycle mutation or budget authorization.
- Event, terminal-byte, and trace codecs retain their own schema versions and
  native cursors inside the manifest.
- Fixed lifecycle consumers use the same durable event record as dynamic
  subscriptions but have separate bounded obligation/receipt state; they are not
  hidden workflows.
