---
status: Accepted
date: 2026-05-12
boundary: shared
split: sibling-extensions
---

# ADR-2026-05-12 — Cross-process Layer 6 hook bus bridge for daemon-driven sessions

**Status:** Accepted
**Date:** 2026-05-12
**Boundary:** shared (OSS-canonical contract here; platform-side ingestion and fan-out captured in `rensei-architecture/013-orchestrator-and-governor-platform-extensions.md` § "Cross-process Layer 6 ingestion")
**Authors:** Mark Kropf (Rensei) + Donmai Agent

## Context

Layer 6 (`001-layered-execution-model.md` § Layer 6, `002-provider-base-contract.md` § "Lifecycle hooks") is the canonical surface where policy, security, observability, and intelligence services attach to provider activity. The current spec scopes the hook bus to **in-process providers**: `globalHookBus` is a TypeScript pub/sub bus in `agentfactory/packages/core/src/observability/hooks.ts`, and emissions are produced by `InstrumentedProvider` wrappers around in-process provider methods.

Production reality has moved past that scope. The OSS Go daemon shipped in `agentfactory-tui/runtime/` is the AgentRuntime provider that executes every SDLC session for platform users today. It posts agent activity (`ToolUseEvent`, `ToolResultEvent`, `AssistantTextEvent`, …) to the platform's `/api/sessions/[id]/activity` HTTP endpoint, which stores them in a ring buffer + Postgres but does not emit anything on Layer 6. The consequence is that every Layer 6 subscriber written for tool-call-grained events is dark for production sessions:

- **InSessionMemoryInjector** defines `subscribeToVerbBus()` to inject memory mid-session when an agent touches relevant files, but the subscription is never wired and the bus has no daemon events anyway.
- **Graph extraction** runs cron-driven over the observations table; real-time graph-aware retrieval and feedback weighting are unreachable because the events that would trigger them aren't on the bus.
- **The Context satellite** on the topology overlay consumes `contextKey`/`contextValue` activities that no producer emits. The platform wire was completed in 2026-05-12 (commit `ddf0770`) but workers don't fill it.
- **`af_code_*` and `af_memory_*` MCP tools** that constitute product differentiation never surface as Layer 6 events.

The boundary discipline in `001-layered-execution-model.md` § "The OSS↔Platform contract" historically read the seam as **library composition, not subprocess RPC**. The Go daemon falsifies that read: the daemon is itself an OSS-shipped binary that runs as a long-lived subprocess, communicating with the platform over HTTP. This is not a violation — it is a new mode the corpus needs to admit.

## Decision

This ADR makes three connected changes:

### D1 — Extend `ProviderHookEvent` with agent-tool-use variants

The existing `pre-verb` / `post-verb` / `verb-error` events are at the provider-method level (`provision`, `acquire`, `runSession`). Agent-level tool calls (`Read`, `Bash`, `mcp__af_code_search_symbols`) are a different layer that the memory injector and the Context satellite both need. Add three new kinds to the `ProviderHookEvent` discriminated union in `002-provider-base-contract.md`:

```ts
| { kind: 'pre-tool-use'
  ; provider: ProviderRef
  ; sessionId: string
  ; toolUseId: string
  ; toolName: string
  ; toolInput: unknown
  ; toolCategory?: string
  }
| { kind: 'post-tool-use'
  ; provider: ProviderRef
  ; sessionId: string
  ; toolUseId: string
  ; toolName: string
  ; toolOutput: string
  ; durationMs: number
  ; isError: boolean
  }
| { kind: 'tool-use-error'
  ; provider: ProviderRef
  ; sessionId: string
  ; toolUseId: string
  ; toolName: string
  ; error: string
  }
```

These are session-scoped (`sessionId` is non-optional, unlike on provider-level events) and correlation-keyed (`toolUseId` pairs pre/post). The bus contract and subscriber-filter shape are unchanged; subscribers filter on `kinds` to select.

### D2 — Cross-process providers participate in Layer 6 via a wire bridge

A provider may be in-process (TypeScript, instrumented via `InstrumentedProvider`) or cross-process (Go daemon, future RPC providers). Cross-process providers emit equivalent hook events through a bridge owned by the platform's ingest route for that provider's transport. From a subscriber's view, an event emitted by a cross-process provider is indistinguishable from one emitted in-process.

For the Go daemon specifically, the bridge surface IS the `/api/sessions/[id]/activity` HTTP endpoint:

- **Daemon-side wire payload** carries the canonical fields needed to reconstruct a hook event: `toolUseId`, `toolName`, `toolInput`, `toolOutput`, `isError`, `durationMs`, `providerName` (plus existing `type`, `content`, `timestamp`).
- **Platform-side ingest route** translates each inbound `action` activity into the appropriate `pre-tool-use` / `post-tool-use` / `tool-use-error` event and calls `globalHookBus.emit()`.

This is not a violation of the library-composition seam (`001` § "The OSS↔Platform contract") — that seam describes how OSS code and platform code compose **at build time**. The daemon-platform bridge describes how the OSS daemon binary and the platform service compose **at runtime**, which is a separate axis. Both must hold.

### D3 — Cross-replica fan-out reuses the platform Redis session-event channel

The platform's `globalHookBus` is per-process. The platform already serves Vercel concurrent serverless invocations and ships a Redis pub/sub fan-out for SSE session events (`publishSessionEvent` in the platform event-bus module). The hook-bus bridge layers onto that existing infrastructure:

- A new `SessionEvent.type = 'provider_hook_event'` carries a serialized `ProviderHookEvent` payload.
- The platform-side ingest route both emits to its local `globalHookBus` AND publishes to Redis via `publishSessionEvent`.
- Each platform replica's bootstrap subscribes to the org channel and re-emits each `provider_hook_event` onto its own local `globalHookBus`. (Net effect: every subscriber on every replica sees every event exactly once; dedup is on the publishing side.)
- The new event type is filtered out of consumer-facing SSE streams; only Layer 6 subscribers should observe it.

## Consequences

### Positive

- Proactive memory injection lights up for production (Go-daemon-driven) sessions. The injector's existing `subscribeToVerbBus` interface gains a real producer.
- The Context satellite populates with derived entries (`currentFile`, `lastEditedFile`, `lastGitOp`, `lastSearch`, `lastTestRun`, …) on real sessions, with no Go-daemon-side changes beyond the wire payload extension.
- A future event-driven graph extraction pipeline can subscribe to the same bus and replace the cron-based polling without restructuring its consumers.
- The contract is symmetric across in-process and cross-process providers, so future RPC providers (A2A bridges, remote AgentRuntime providers) plug into the same bus through their own ingest routes without re-opening this question.
- `af_code_*` / `af_memory_*` MCP tools become Layer 6 events alongside platform-differentiating analytics.

### Negative

- One more place to keep in sync when the hook taxonomy changes: the daemon's wire payload must carry the fields the new event kinds reference. The wire schema is now a load-bearing cross-language contract.
- The Redis fan-out adds a network hop between platform replicas. Latency budget for memory injection (≤100ms) holds locally — the bridge fires after `storeActivity` returns and is best-effort — but cross-replica subscribers see events with Redis-round-trip latency added.
- `provider_hook_event` is now a privileged event type that consumer-facing SSE streams must explicitly filter. Forgetting to filter exposes raw hook payloads through public-ish endpoints.

### Risks

- **Event ordering across replicas** — Redis pub/sub is fire-and-forget with no ordering guarantees across channels. `pre-tool-use` and `post-tool-use` for the same `toolUseId` may arrive in either order on a subscriber. Consumers MUST be idempotent and tolerant of out-of-order pairing. The derive-context subscriber is naturally idempotent (it derives from `post-tool-use` only). The memory injector ranks by `paths` and is also order-tolerant. Document this in subscriber-author guidance.
- **Bridge silently dropping events** — if the platform route emits-and-forgets on the bus and any subscriber throws, the bus's per-subscriber try/catch already crash-isolates. The bridge itself must wrap `globalHookBus.emit` in `.catch(noop)` so a bus failure doesn't fail the activity-ingest HTTP response (which is on the daemon's critical path).
- **Wire-format drift** — if the daemon's `payload` struct drifts ahead of the platform ingest schema (or vice versa), events lose fidelity. The OSS-canonical `payload` shape is part of this ADR and replicated in `002-provider-base-contract.md` (canonical) and the daemon's `runtime/activity/poster.go` (implementation). A contract test in the daemon repo asserts the JSON-marshaled `payload` matches the documented JSON shape.

## Alternatives considered

- **Dedicated `/api/observability/hooks` endpoint, parallel to activity ingest** — cleaner separation but doubles the daemon's network traffic and creates two arrival surfaces the platform must reconcile. Rejected: activity-as-bridge reuses the existing battle-tested route and the duplication isn't worth it.
- **Per-replica in-memory bus only (no Redis fan-out)** — simpler but means subscribers on replica B miss events that arrived at replica A. Memory injection would silently miss any session whose activity post landed on a different replica than the consumer's subscription. Rejected: cross-replica visibility is non-negotiable for Vercel concurrent invocations.
- **Push the daemon to subscribe directly to a TypeScript hook bus via WebSocket** — keeps the bus authoritative but couples the daemon to the platform's Node runtime and introduces a long-lived bidirectional channel where activity ingest is one-shot HTTP. Rejected: the daemon's transport simplicity is a feature.
- **Keep `pre-verb` / `post-verb` as the tool-call-level kind and add a separate provider-method-level kind** — semantically inverse to D1. Rejected: the existing `VerbBusEvent` already conflates these, and the existing emitters in `InstrumentedProvider` are at the provider-method level. Adding new kinds for tool calls is the smaller delta.

## Affected documents

- `002-provider-base-contract.md` § "Lifecycle hooks" — extend `ProviderHookEvent` union with `pre-tool-use` / `post-tool-use` / `tool-use-error` per D1. Document that out-of-process providers emit equivalent events via a platform-side bridge per D2.
- `006-cross-provider-interactions.md` — add **Seam 10: Cross-process provider hook bridge**, describing the wire-format-as-bridge contract.
- `rensei-architecture/013-orchestrator-and-governor-platform-extensions.md` — add § "Cross-process Layer 6 ingestion" describing the platform-side translation, the Redis fan-out via `provider_hook_event`, and the filter rule that keeps the event off public-facing SSE streams.

## Follow-on items

- **Proactive In-Session Memory** — completes the production wire-up scoped against in-process providers. `InSessionMemoryInjector.subscribeToVerbBus` becomes a `globalHookBus` subscriber on `pre-tool-use`/`post-tool-use`.
- **Native Knowledge Graph** — the cron extractor remains operational; a follow-up to make extraction event-driven now has a concrete subscription surface to use.
- **Topology overlay Context satellite** — the producer side requested in the 2026-05-12 overlay UX work (commit `ddf0770`) lands via the derive-context subscriber on this bus.

## Implementation notes

Implementation lives across four repos in this order: corpus updates (this ADR + cited docs), `agentfactory` (taxonomy + subscriber stubs for the new kinds), `agentfactory-tui` (wire-format extension in `runtime/activity/poster.go`), then `platform` (bridge + Redis fan-out + consumer subscribers). The contract test that pins the wire shape lives in `agentfactory-tui` so the Go binary is the canary that catches drift first.
