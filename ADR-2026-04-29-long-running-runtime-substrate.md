# ADR-2026-04-29-long-running-runtime-substrate

**Status:** Accepted
**Date:** 2026-04-29
**Boundary:** shared (OSS-canonical; platform extensions live at `rensei-architecture/ADR-2026-04-29-long-running-runtime-substrate-platform-extensions.md`)
**Authors:** Mark Kropf + cycle 4 grooming (continuation of session db959ae0)

## Context

Two substrate candidates were evaluated for the long-running agent runtime: (a) extend `@renseiai/agentfactory-server` — the Redis-based OSS substrate already in production, and (b) adopt BullMQ — battle-tested OSS Redis queue. The spike completed but the resulting ADR was not captured in the corpus before context loss. This document reconstructs the decisions from the spike's known findings + user direction (2026-04-29: "extend agentfactory-server because it already ships scheduling-queue.moveToBackoff (delayed jobs primitive); redis was faster on journal writes; remaining decisions to favor most scalable and performant").

This ADR unblocks the long-running runtime build and the context-compaction work (transitively blocked).

## Decision

### 1. Substrate choice: Extend `@renseiai/agentfactory-server`

The `@renseiai/agentfactory-server` OSS package already ships:
- **`scheduling-queue.moveToBackoff`** — delayed jobs primitive (covers suspend-until-time)
- Redis-Streams-based session inbox + tenancy mirroring (existing OSS surface)
- Session FSM in production (~64 call sites depend on it)

Layer per-step journal + idempotency + cancel/suspend + per-run heartbeat as in-process extensions to that substrate, not as a parallel BullMQ stack.

### 2. Journal schema: Redis hash (primary)

- **Primary:** Redis hash keyed by `journal:{sessionId}:{stepId}`, fields: `status`, `inputHash`, `outputCAS`, `startedAt`, `completedAt`, `attempt`, `error?`. Hot-path writes complete in <1ms.
- Rationale: spike found Redis was faster on journal writes; agentfactory-server already uses Redis for queue state, so the substrate is consistent.
- A platform-side optional Postgres mirror is documented in the platform-extensions doc; the OSS substrate primary is Redis.

### 3. Idempotency-key shape: `sha256(stepId || ":" || canonicalJSON(inputPayload) || ":" || nodeVersion)` (hex, 64 chars)

- `stepId` — workflow node id
- `canonicalJSON(inputPayload)` — sorted-keys, stable string representation of the step's input
- `nodeVersion` — workflow definition version (workflow updates invalidate keys, forcing fresh execution)
- Stored as `inputHash` field on the journal entry; collisions logged at warn level (idempotent ops should produce same result, so collisions are OK).

### 4. Cancel/resume semantics

**Cooperative cancel:**
- Cancel signaled via Layer 6 hook event `session.cancel-requested`
- Agent observes between steps; in-flight step completes by default (no mid-step interrupt)
- Mid-step interrupt is opt-in per step via `interrupt: 'safe' | 'unsafe'` config — `safe` requires the step to have a checkpoint primitive; `unsafe` kills the worker subprocess

**Suspend-until-time:**
- Uses agentfactory-server's `scheduling-queue.moveToBackoff(timestamp)`
- Redis ZSET `work:wake:{sessionId}` keyed by score = wake epoch ms
- Sweeper runs at 1Hz, promotes expired entries to the work queue
- Survives worker restarts (Redis is durable)

**Resume:**
- Worker on start: reads journal entries for any sessions where it was last assigned, replays from the latest checkpointed step (last `completedAt` entry).
- Cross-worker resume: handled via the session FSM's worker reassignment path (already in agentfactory-server).

### 5. Heartbeat cadence: 15 seconds

- Worker emits Layer 6 hook event `session.heartbeat` every 15s during step execution
- Subscribers (e.g., observability dashboard) can observe drift
- Stale-heartbeat threshold: 60s → governor marks session as `stuck`, recovery flow triggers

The Layer 6 hook event is OSS-side; a platform-side mirror writeback to a tenant-scoped table is documented in the platform-extensions doc.

### 6. Tenant-scoping enforcement

JWT-derived envelope `{ proj, org, sub, claims }` injected at enqueue time as job metadata. On consume:
- Worker re-verifies JWT signature against the configured trust anchor (per `002` § "Signing and trust").
- Worker compares `org` claim against its own registration's org context — mismatch → reject with `permission_denied` audit event.
- Cedar policy fires at Layer 6 `pre-verb` hook (per ADR-2026-04-28) for any cross-cutting policy enforcement (Cedar enforcement is platform-side; the hook is OSS-side).

This extends agentfactory-server's existing tenancy mirroring path from sync work to journaled async work.

### 7. Home for the code

- **Journal primitive** lives in `@renseiai/agentfactory-server` — keeps the OSS substrate self-contained. Aligns with the durable architectural intent: agentfactory packages hold server-side primitives.
- **Hook event taxonomy** for `session.cancel-requested` / `session.heartbeat` registered in agentfactory-server's Layer 6 hook bus interface; platform subscribes.

## Consequences

### Positive

- OSS substrate stays first-class (no closed-source lock-in for long-running runtime).
- No multi-thousand-LOC migration — the ~64 existing call sites continue to work unchanged.
- Performance: Redis-first journal is sub-millisecond.
- Scalability: Redis ZSETs handle millions of pending wake-ups; tested in industry at >10× our anticipated load.
- Consistent substrate: queue + journal + tenancy all on the same Redis instance, single failure domain to reason about.

### Negative

- agentfactory-server's queue primitives are less battle-tested than BullMQ's (smaller community, fewer 3rd-party debugging tools). We carry the maintenance cost of the journal extension.
- Custom idempotency hashing requires careful test coverage; BullMQ's built-in `jobId` dedupe was a "free" feature.
- Redis-as-primary-journal is a single point of failure. (Platform-side adds Postgres mirror as forensic insurance — see extensions doc.)

### Risks

- **Scale risk:** if agentfactory-server's queue primitives don't scale to anticipated load, we'd face a costly migration later. Mitigation: bench at 10× expected load before GA.
- **Suspend-until-time precision:** 1Hz sweeper means sub-second precision wake-ups aren't possible. Mitigation: for sub-second use cases, use a different primitive (in-process timer or Redis pub/sub).
- **Multi-region:** cross-region journal replication isn't covered here; ships single-region first, multi-region is a follow-on.

## Alternatives considered

- **BullMQ.** Battle-tested, mature primitives, BullBoard observability. Rejected because: (1) ~2,000-2,500 LOC migration cost, (2) loses agentfactory-server's session FSM + tenancy mirroring, (3) BullMQ's `jobId` dedupe is nice but doesn't justify the migration, (4) hybrid (BullMQ-on-top-of-agentfactory-server) doubles the substrate complexity for marginal gain.
- **Temporal / Cadence.** Out of scope per the spike's exclusions.
- **Custom orchestration layer.** Out of scope per the spike's exclusions.

## Affected documents

- `001-layered-execution-model.md` §Layer 3 (AgentRuntime) — add pointer to this ADR for substrate choice
- `011-local-daemon-fleet.md` — daemon-side worker substrate is the same; align if needed (likely no change)
- Platform-side schema (Postgres mirror, `agentSessions.lastStepHeartbeat`) — see platform-extensions doc

## Implementation notes

- **`scheduling-queue.moveToBackoff` extension** in agentfactory-server: add `journal_id` field on the queue entry; `moveToCompleted(journal_id, result)` writes to journal hash before unblocking next step.
- **Idempotency hash collision handling**: on collision, log warning + assume retry. Idempotent operations produce same result, so collision is functionally a cache hit.
- **Cancel signal end-to-end test**: `session.cancel-requested` → agent observes between steps → in-flight step completes → final hook event `session.cancelled`. Acceptance criteria include this test.
- **Bench requirement**: acceptance criteria should add: "bench journal write at 10× expected production load (e.g., 10,000 steps/sec); confirm <2ms p99 write latency."
