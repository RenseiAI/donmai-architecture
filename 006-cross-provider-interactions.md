# 006 — Cross-Provider Interactions

**Status:** Reference (initial draft)
**Last updated:** 2026-05-06
**Boundary:** shared (OSS-canonical; platform extensions live at `rensei-architecture/006-cross-provider-interactions-platform-extensions.md`)
**Related:** All other docs in this corpus.

## Why this exists

The individual layers are designed to be independent — that's what makes them composable. But independence at the type level doesn't prevent subtle bugs at the *seams*: places where two layers must cooperate to maintain a system-level property. This doc enumerates the seams, names the cooperation, and captures the small contract details that prevent each class of bug.

If the other docs describe what each layer does, this one describes what each pair of layers must do *together*. Read this once you understand the individual layers; this is where most production-impact bugs live.

Two seams have platform-side extensions: Seam 4's concrete platform implementation (`pool_cost_events` table, `cost_aware` policy) and Seam 6 (VCS attestation → audit chain) are platform-aggregated by design. Both are summarized here in OSS-substance form; full platform implementation lives in `rensei-architecture/006-cross-provider-interactions-platform-extensions.md`.

## Seam 1 — Workarea ↔ Memory: the observation cursor

**Problem:** Memory's observation capture and AST-driven file-op extraction read FS events during sessions. When `WorkareaProvider.release(pause)` and a later `resume()` happen, naive replay would double-emit observations into the knowledge graph. When `release(return-to-pool)` happens and a *different* session reuses the workarea, observation events from the prior session would leak into the new one.

**Cooperation:** the workarea handle carries an opaque `observationCursor`.

```ts
interface Workarea {
  // ... other fields from 003
  readonly observationCursor: ObservationCursor
}

interface ObservationCursor {
  readonly streamId: string         // unique per workarea instance
  readonly position: string         // opaque, monotonic
}
```

Contract:
- The Memory layer's observation writer keys events on `(streamId, position)`. It dedupes idempotently.
- `WorkareaProvider.snapshot()` MUST capture the cursor in the snapshot ref.
- `WorkareaProvider.resume()` MUST restore the cursor; observation events resume from `position`, not from zero.
- `WorkareaProvider.release(return-to-pool)` MUST mint a fresh `streamId` for the next acquire of the same pool member. Prior observations don't leak.
- Sub-agents in `mode: 'shared'` inherit the parent's `streamId` but emit with their own session-tagged events; the writer attributes correctly.

**Bug class prevented:** double-emission of observations in eval replay, false memory inflation in long-running sessions, cross-session leakage in pool reuse.

## Seam 2 — Kit toolchain demand → Workarea/Sandbox supply

**Problem:** A kit's `provide.toolchain = { java: "17", node: "20" }` is meaningless unless something installs Java and Node before the agent runs. If kits each shipped their own toolchain installer, every session would start with multiple installers fighting over `~/.mise/`.

**Cooperation:** the toolchain spec is the contract between kits and the workarea/sandbox layer.

```
Kit detect              → returns { applies: true, toolchain: { java: "17" } }
Scheduler               → reads toolchain demand from all selected kits
                         → unions demands; resolves to concrete pinned versions
                         → calls WorkareaProvider.acquire({ ..., toolchain: resolved })
WorkareaProvider        → returns workarea where toolchain is installed
Kit provide()           → runs against acquired workarea; toolchain is pre-set
```

Contract details:
- Demand resolution is **conjunctive across kits**: if Kit A demands `java >= 17` and Kit B demands `java >= 21`, the union is `java >= 21`. Conflicts (`java = 17` exact, plus `java = 21` exact) are errors.
- The workarea provider returns `Workarea.toolchain` with the *resolved* concrete versions (e.g., `"java": "21.0.5"`), not the requested ranges. Kit `provide()` reads these for any version-sensitive logic.
- A kit's `provide()` MAY run installation steps for its specific framework (e.g., `pip install -r requirements.txt`), but MUST NOT install base toolchains. That's the workarea provider's job.

**Bug class prevented:** install conflicts, wrong-toolchain false negatives, slow per-session installs that should have been pool-warmed.

## Seam 3 — A2A as Sandbox transport flavor

**Problem:** A2A is agent↔agent at the protocol layer. SandboxProvider's `transportModel` is harness↔sandbox at the runtime layer. They look similar enough to conflate, and conflation breaks both.

**Cooperation:** A2A is *not* a separate plugin family. A remote A2A peer is a `SandboxProvider` implementation declaring `isA2ARemote: true`. The orchestrator dispatches work to it via the A2A protocol; from the scheduler's perspective, it's a sandbox like any other.

```ts
// A2ASandboxProvider implementation summary:
{
  capabilities: {
    isA2ARemote: true,
    transportModel: 'dial-in',
    // capacity is delegated; declare null
    maxConcurrent: null,
    // billing is the remote's concern
    billingModel: 'fixed',
    // ... other flags as the remote agent supports
  },
  async provision(spec) {
    // No-op: the remote already exists. Return a handle whose
    // execUrl points at the A2A peer's endpoint, with auth bound.
  }
}
```

Kits and Workareas don't change shape because the work runs on a remote A2A peer. The kit-toolchain demand (Seam 2) is delegated to the remote — the A2A peer satisfies it inside its own infra, or rejects the request.

**Bug class prevented:** double-implementing transport in two layers, treating A2A as a separate scheduling axis when it's actually one provider type.

## Seam 4 — Sandbox cost emission → Scoring (cost-per-issue)

**Problem:** Cost-per-issue accounting needs to attribute compute cost to issues. Naive accounting (LLM tokens only) misses sandbox compute, which dominates for long-running coding-agent sessions. Worse, billing models differ per provider (wall-clock vs active-CPU vs invocation), and idle vs paused state matters (E2B paused = $0; Modal idle warm = billed).

**Cooperation:** `SandboxProvider` MUST emit cost events through the Layer 6 observability hook surface, with normalized fields.

```ts
type CostEvent = {
  kind: 'sandbox-cost'
  sessionId: string
  providerId: string
  // Time periods
  activeMs: number          // CPU active (when billingModel = 'active-cpu')
  wallClockMs: number       // wall-clock time (when billingModel = 'wall-clock')
  invocations: number       // count (when billingModel = 'invocation')
  // Resource usage
  vCpuSeconds: number
  memoryGbSeconds: number
  diskGbSeconds: number
  // State
  inState: 'running' | 'paused' | 'idle'  // emit per-state, not aggregate
  // Cost (provider-attributed)
  estimatedCents: number
  rateCard: string          // identifier for the rate card used
  capturedAt: Date
}
```

Contract:
- Emit at session-end (mandatory) and optionally periodically during long sessions.
- The scoring layer aggregates by `sessionId → issueId` (via session metadata).
- Paused sandboxes emit `inState: 'paused'` events with `estimatedCents` reflecting the storage-only cost; scoring distinguishes "you ran a $5 session" from "you have a $0.05/day paused workarea sitting around."
- A2A providers (Seam 3) emit `kind: 'sandbox-cost'` events with `providerId: 'a2a:<remote-id>'`; cost may be opaque (`estimatedCents: null`) when the remote doesn't expose accounting.

**Bug class prevented:** under-attributing compute cost, double-counting paused-state expense, missing the cost difference between providers when comparing fleets.

The platform-side concrete implementation (the `pool_cost_events` table, `cost_aware` policy ranking, the session-status terminal-state emission point, idempotency keying) is documented in `rensei-architecture/006-cross-provider-interactions-platform-extensions.md` § "Seam 4 — Concrete contract".

## Seam 5 — Workarea snapshot → Eval replay

**Problem:** Eval/guardrails need deterministic re-execution to score agent decisions. Re-running an agent against `main` two days later doesn't reproduce the original input — the codebase has moved.

**Cooperation:** eval datasets reference workarea snapshots, not commit SHAs alone.

```ts
interface EvalRun {
  evalId: string
  inputSnapshotRef: WorkareaSnapshotRef   // pinned filesystem state
  inputModel: ModelRef
  inputPrompt: string
  expectedOutputs: ExpectedOutput[]
  // ... rubric, etc.
}

// Replay procedure:
async function replay(run: EvalRun) {
  const wa = await workareaProvider.acquire({
    fromSnapshot: run.inputSnapshotRef,
    sessionId: `eval-${run.evalId}-${Date.now()}`,
    scope: ...
  })
  // Run the model against wa with the original prompt.
  // Score the output against expectedOutputs.
  await workareaProvider.release(wa, { kind: 'destroy' })
}
```

Contract details:
- Snapshots referenced by eval runs MUST NOT be garbage-collected. The eval system tags snapshots with `retain: 'eval-permanent'`; workarea providers honor the tag.
- Snapshots include the `cleanStateChecksum` and `toolchain` from `Workarea`; replay validates these match before running, to catch silent provider drift.
- Cross-provider replay (e.g., a snapshot captured on E2B replayed on Vercel) is NOT supported — snapshots are provider-internal opaque refs. Eval cross-provider comparison runs through `archive` + `acquire(source: <archive>)` paths, not snapshot-portability hacks.

**Bug class prevented:** silently broken eval reproducibility, false confidence in agent improvements that were actually environmental drift.

## Seam 6 — VCS attestation → audit chain (platform-aggregated)

**Problem:** Provenance (who/what/when produced this change) is needed for compliance and post-hoc forensics. Atomic VCS makes attestation a first-class verb (Ed25519 + session metadata). Git fakes it via commit trailers. Either way, the attestation is per-change; the compliance use case is *aggregated* across many changes.

**OSS-side contract:** Layer 2 VCS providers emit attestations as structured per-change records. The OSS layer ships:
- VCS providers SHOULD declare `provenanceNative: true` (Atomic, signed-git-with-trailers) or `false` (vanilla git).
- The attestation primitive is a per-change structured record (signature + session metadata).
- The Layer 6 hook surface emits `kind: 'vcs-attestation'` events with `sessionId, agentId, modelId, kitIds, workareaSnapshotRef, changeRef`.

**Platform-side aggregation (audit chain):** Aggregating per-change attestations into a tenant-visible Merkle log, federating across providers, building tenant-facing audit views, and the SecurityProvider plugin shape that fronts these — all live platform-side. See `rensei-architecture/006-cross-provider-interactions-platform-extensions.md` § "Seam 6 — Audit chain (platform-aggregated)".

The OSS layer ships the per-change primitive (this is sufficient for OSS users to have local provenance for their own changes); the platform extends with cross-tenant audit chain assembly and aggregation.

**Bug class prevented (OSS-side):** missing the provider-level attestation primitive that makes any later chain real.

## Seam 7 — Worker registration: Sandbox transport + Workarea acquire

**Problem:** A session needs *both* a worker process registered with the orchestrator (`SandboxProvider`) *and* a deterministic filesystem (`WorkareaProvider`). These have to be synchronized — a worker that boots before its workarea is ready, or a workarea acquired without a worker to use it, is wasted compute.

**Cooperation:** the scheduler orchestrates them as a single transaction.

```
SchedulerSession lifecycle:
  1. resolve kits (detect across applicable kits)
  2. union toolchain demands
  3. select sandbox provider (capability filter + cost/latency score)
  4. select workarea provider (capability filter, paired with sandbox)
  5. provision sandbox (parallel with #6)
  6. acquire workarea (parallel with #5)
  7. wait for both ready
  8. dispatch worker bootstrap (dial-in) OR await registration (dial-out)
  9. session runs
  10. on session end: release workarea (mode dependent on policy)
                      terminate / pause sandbox
                      emit cost event
                      emit attestation
```

Contract details:
- Steps 5 and 6 may run in parallel; the workarea must not begin its acquire before the sandbox-provider declares which workarea provider it's paired with (some sandboxes bundle their own workarea — e.g., E2B sandboxes are workareas).
- If the sandbox is `isA2ARemote: true`, step 6 is a no-op locally; the workarea is the remote's concern. The scheduler still tracks "workarea was demanded" so kits' `provide()` can validate.
- On any partial failure (workarea acquired, sandbox provision failed), the scheduler MUST roll back the workarea (release + destroy). Half-provisioned sessions must not occupy resources.

**Bug class prevented:** wasted-warm-pool members on sandbox failures, half-state sessions that consume budgets without producing work.

## Seam 8 — Kit detect parallelism ↔ scheduler latency budget

**Problem:** Detection runs declarative phase against many kits in parallel; executable detect can spawn sandboxes per kit. If a tenant has 50 kits installed and 20 declare executable detect, naive scheduling could spawn 20 detect sandboxes per session start.

**Cooperation:** the scheduler caps detect concurrency and shares a transient detect-sandbox pool.

Contract details:
- Phase 1 declarative is unbounded parallel (it's I/O against a file index).
- Phase 2 executable detect is gated to a per-tenant concurrency limit (default 4) and shares a single detect-sandbox per workarea-toolchain key when possible.
- Detect timeouts are bounded (default 5s declarative, 30s executable) with provider-level emit of `detect-timeout` events to identify slow kits.
- Tenants may declare `detect_skip_until: <timestamp>` for kits known to be slow on their codebase, to defer them past initial session start.

**Bug class prevented:** session-start latency cliff at 50+ kits, slow kit detect blocking the entire fleet.

## Seam 9 — Memory + Code Intelligence reading from workarea

**Problem:** Code Intelligence indexes the workarea filesystem (BM25, vectors, AST). Memory writes observations from FS events on the workarea. Both layers read state that the workarea provider owns. If they read at the wrong time (mid-acquire, during pool clean), they capture invalid state.

**Cooperation:** Intelligence Services subscribe to workarea lifecycle events and only read in `state: 'ready'`.

Contract details:
- Workarea events are emitted via the Layer 6 hook surface: `workarea-acquired`, `workarea-releasing`, `workarea-resumed`, etc.
- Code Intelligence treats `workarea-acquired` as the trigger to (re-)index. It uses `cleanStateChecksum` to skip indexing if the state matches a cached index.
- Memory writers treat `workarea-releasing` as the boundary for flushing pending observations to the graph.
- Indexes are keyed on `(workareaProviderId, repository, ref, cleanStateChecksum)`. Reuses across sessions are valid when the key matches.

**Bug class prevented:** stale or partial indexes, lost observations on session crash, "did the index get rebuilt" debugging churn.

## Seam 10 — Cross-process provider hook bridge

**Problem:** Layer 6 hook events (`pre-verb`/`post-verb`/`pre-tool-use`/`post-tool-use`, etc.) are emitted on an in-process TypeScript bus (`globalHookBus`). The Go `af agent run` daemon — the AgentRuntime provider that executes real SDLC sessions today — is a separate OS process and so cannot emit on the bus directly. Without a bridge, every Layer 6 subscriber that targets tool-call-grained events (REN-1184 in-session memory injector, REN-1166 graph-extraction-event-trigger, the Context-satellite derive subscriber, future security/cost subscribers) is dark for production sessions.

**Cooperation:** Cross-process providers participate in Layer 6 through a **wire-format-as-bridge** owned by the platform-side ingest route for that provider's transport. Per `ADR-2026-05-12-cross-process-hook-bus-bridge`:

1. **Daemon-side wire payload** is the canonical bridge schema. For AgentRuntime providers via the activity-ingest route (`POST /api/sessions/<id>/activity`), the wire `payload` carries the fields needed to reconstruct an agent-tool-use event: `type`, `toolName`, `toolInput`, `toolOutput`, `toolUseId`, `isError`, `durationMs`, `toolCategory`, `providerName`, `timestamp`. The OSS contract requires every cross-process AgentRuntime provider to populate these fields when emitting `action`-type activities for tool calls; downstream subscribers fail open when fields are absent but lose fidelity.

2. **Platform-side translation** is the bridge's runtime half. The ingest route reconstructs the appropriate `ProviderHookEvent` (`pre-tool-use` when `toolOutput`/`isError` are absent and `toolUseId` is set; `post-tool-use` on completion; `tool-use-error` when `isError === true`) and calls `globalHookBus.emit()`. Bus emission is fire-and-forget — the activity-route HTTP response does not block on subscriber latency.

3. **Cross-replica fan-out** reuses the existing platform Redis session-event channel. A new `SessionEvent.type = 'provider_hook_event'` carries a serialized `ProviderHookEvent`; each platform replica's bootstrap subscribes and re-emits inbound `provider_hook_event` payloads onto its own `globalHookBus`. The new event type is filtered out of consumer-facing SSE feeds (Topology session-activity stream, public `/api/public/session-activities`); only Layer 6 subscribers observe it.

4. **Subscriber idempotency requirement.** Redis pub/sub is fire-and-forget with no cross-channel ordering guarantee, so a `pre-tool-use` and `post-tool-use` for the same `toolUseId` may arrive at a subscriber in either order. Subscribers MUST be tolerant of out-of-order pairing and tolerant of replays. The derive-context subscriber acts on `post-tool-use` only and is naturally idempotent; the in-session memory injector ranks by `paths` and is order-tolerant.

5. **The bridge does not violate the OSS↔platform library-composition seam** described in `001-layered-execution-model.md` § "The agentfactory ↔ Rensei Platform contract." That seam describes **build-time** composition (OSS code is consumed as a library by platform code). This seam describes **runtime** composition (an OSS-built binary running as a long-lived subprocess that communicates with the platform service via HTTP). Both seams hold simultaneously; the Go daemon participates only in the runtime axis.

**Bug class prevented:** "Layer 6 subscriber works in unit tests but does nothing in production" — the bug where the subscription wires up correctly, the bus is healthy, and no events ever arrive because the active provider is in a different process. Also prevents the inverse bug where a producer-side wire-format change silently breaks event reconstruction on the platform side; the daemon emits a contract test fixture that pins the JSON shape.

**Future cross-process providers** (A2A bridges, remote AgentRuntime peers, hosted sandbox providers) plug into Layer 6 through the same pattern: define a wire payload that carries the canonical fields the relevant event kinds reference, own the platform-side ingest route that translates, and emit on `globalHookBus`. The contract above does not depend on the daemon being Go — it depends on the ingest route owning the translation.

## How to add a new seam to this doc

When implementation experience reveals a cross-layer cooperation that isn't captured here:

1. Open an ADR proposing the seam.
2. State which layers cooperate, what bug class is prevented, and the minimum contract.
3. Append to this doc with a new "Seam N" section, in the same shape as above.
4. Declare the ADR's `boundary:` field — most seams are OSS (cooperation contracts apply at the OSS execution layer); seams whose primary aggregation lives in the SaaS control plane (like Seam 6) split, with the OSS half declaring the per-change primitive and the platform extensions doc declaring the aggregated form.

Seams are discovered, not designed. Expect this doc to grow.
