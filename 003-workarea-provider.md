# 003 — WorkareaProvider

**Status:** Reference (initial draft)
**Last updated:** 2026-07-22
**Related:** `001-layered-execution-model.md`, `002-provider-base-contract.md`, `004-sandbox-capability-matrix.md`, `ADR-2026-05-06-tui-noun-consolidation.md`, `ADR-2026-07-18-bounded-terminal-workarea-leases.md`

## Why this exists

The QA coordinator runs in a worktree it inherited with whatever residual state the previous agent left behind — stale `.next/`, partial pnpm symlinks, leftover Turbopack caches. That residue causes deterministic-looking false negatives on `pnpm build`: `WORK_RESULT:failed` while every CI check is green and every AC passes. Per-bug mitigations each buy time, not correctness.

The architectural fix is to stop treating "the worktree the coordinator happens to be in" as the workarea, and start treating workarea provisioning as a first-class provider contract — the same shape we'd give any sandbox provider. If the workarea is in a known initial state when `acquire` returns, then a non-zero exit from validation means the code is broken, not the environment was. The coordinator's existing hard-fail rule becomes meaningful instead of fragile.

This contract also handles the cost-vs-determinism tension at fleet scale. A naive "git clean -fdx + pnpm install on every acquire" makes 1000-concurrent-agents mathematically impossible (pnpm install on the Supaku monorepo is multi-minute). The interface below is designed so providers can choose the fastest path that satisfies the determinism guarantee — pool, snapshot clone, pause-resume — without each scheduler having to know which one.

## The interface

```ts
interface WorkareaProvider extends Provider<'workarea'> {
  /**
   * Returns a workarea in a known-deterministic state.
   * Implementation chooses fastest path that satisfies the determinism
   * guarantee declared in capabilities. Caller MUST NOT assume anything
   * about how the state was achieved (clean, pool reuse, snapshot, resume).
   */
  acquire(spec: WorkareaSpec): Promise<Workarea>

  /**
   * Returns the workarea to the provider. The caller declares intent;
   * the provider chooses what to do with it (destroy, return to pool,
   * pause and retain, archive to cold storage).
   *
   * ADR-2026-07-18-bounded-terminal-workarea-leases.md accepts the following
   * architecture obligation, but does not claim current implementation or
   * release: a conforming release() MUST be idempotent when invoked more than
   * once for the same Workarea.id and equivalent ReleaseMode. A crash-recovered
   * caller MAY repeat the callback; a different disposition is a conflict.
   */
  release(workarea: Workarea, mode: ReleaseMode): Promise<void>

  /**
   * Resume a previously paused/archived workarea by ID.
   * Only valid when capabilities.supportsResume is true.
   */
  resume?(workareaId: WorkareaId): Promise<Workarea>

  /**
   * Snapshot a workarea without releasing it. Returns an opaque ref
   * that resume() / acquire(fromSnapshot) can use later.
   * Only valid when capabilities.supportsSnapshot is true.
   */
  snapshot?(workarea: Workarea, label?: string): Promise<WorkareaSnapshotRef>
}

interface WorkareaSpec {
  // Source — what code does the workarea contain?
  source: {
    repository: string                 // git URL, atomic remote, etc.
    ref: string                        // branch/tag/commit/patch-set
    paths?: string[]                   // sparse-checkout if supported
  }

  // Platform — required OS/arch (kits may demand specific platforms,
  // e.g., an iOS kit only applies on macos/arm64)
  os?: 'linux' | 'macos' | 'windows'
  arch?: 'x86_64' | 'arm64' | 'wasm32'

  // Toolchain demand — kits and templates declare what they need
  toolchain?: ToolchainDemand

  // Snapshot reuse — fastest acquire path when available
  fromSnapshot?: WorkareaSnapshotRef

  // Sharing model — sub-agents joining a coordinator's workarea
  mode?: 'exclusive' | 'shared'
  parentWorkareaId?: WorkareaId

  // Identity — the session this workarea is for (for observability/audit)
  sessionId: string
  scope: ProviderScope
}

interface ToolchainDemand {
  // Kits declare these; provider satisfies them
  java?: string                        // semver range or pinned version
  node?: string
  python?: string
  rust?: string
  go?: string
  ruby?: string
  // ... extension via provider-specific keys allowed
  [key: string]: string | undefined
}

interface Workarea {
  readonly id: WorkareaId
  readonly path: string                // absolute filesystem path
  readonly providerId: string          // which provider gave us this
  readonly ref: string                 // commit/patch-set actually checked out
  readonly cleanStateChecksum: string  // sha256 of declared-clean files
  readonly toolchain: Record<string, string>
                                       // resolved toolchain (e.g., "node":"20.18.1")
  readonly acquired: Date
  readonly mode: 'exclusive' | 'shared'
  readonly parent?: WorkareaId         // when mode === 'shared'
}

type WorkareaId = string                // provider-namespaced

type ReleaseMode =
  | { kind: 'destroy' }                  // tear down completely
  | { kind: 'return-to-pool' }           // available for reuse, scoped clean
  | { kind: 'pause' }                    // memory + fs preserved (E2B-style)
  | { kind: 'archive'; label?: string }  // cold storage (Daytona-style)

type WorkareaSnapshotRef = {
  providerId: string
  snapshotId: string
  capturedAt: Date
}
```

## Capabilities

```ts
interface WorkareaProviderCapabilities {
  // What state guarantees does this provider make on acquire?
  cleanGuarantee: 'full' | 'scoped' | 'best-effort'
                                       // full: byte-equivalent to ref + clean install
                                       // scoped: known-artifact dirs cleaned, deps cached
                                       // best-effort: no guarantee, fastest acquire

  // Snapshot/restore primitives
  supportsSnapshot: boolean             // FS-level snapshot
  supportsPauseResume: boolean          // memory+FS preserved
  supportsResume: boolean               // resume from prior pause/archive

  // Sharing model
  supportsSharedMode: boolean           // multiple sessions in one workarea
  maxSharedConcurrency: number | null   // null = unbounded

  // Toolchain provisioning
  supportedToolchains: string[]         // e.g., ['java', 'node', 'python']
  supportsToolchainOnDemand: boolean    // can provision new toolchain at acquire
                                       // vs only pre-baked options

  // Platform — which OS/arch combinations this workarea provider serves
  // Inherited from the underlying sandbox capability when bundled (E2B is
  // linux/x86_64 today; Local matches host machine; K8s matches cluster).
  os: ('linux' | 'macos' | 'windows')[]
  arch: ('x86_64' | 'arm64' | 'wasm32')[]

  // Performance characteristics — informs scheduler choice
  expectedAcquireMs: { p50: number; p95: number }
  expectedReleaseMs: { p50: number; p95: number }

  // Observation cooperation (see "Memory cursor" below)
  emitsObservationEvents: boolean       // does FS-event capture cooperate
                                       // with the Intelligence Services layer
}
```

The scheduler uses this struct to pick a provider for a given `WorkareaSpec`. Example: a session declaring `toolchain.java = "17"` and `mode: 'exclusive'` is routed to a provider where `supportedToolchains.includes('java')` and `supportsSharedMode` is irrelevant. If two providers qualify, the one with lower `expectedAcquireMs.p95` wins.

## Terminal settlement lease (Accepted architecture; implementation and release pending)

`ADR-2026-07-18-bounded-terminal-workarea-leases.md` accepts a bounded,
crash-recoverable lease on the exact `Workarea.id` for a terminal exchange that
requires workarea-backed verification. Acceptance ratifies the architecture;
implementation and release remain pending, and the contract must not be treated
as an available capability. The lease is an overlay on `acquired`; it is not a
second pool-member state and does not transfer ownership to another session.

A conforming workarea lifecycle owner must enforce these invariants:

1. **Exclusive ownership ends only at durable `released`.** The originating
   session remains the exclusive owner through verification, acknowledgement or
   expiry eligibility, `release-pending`, provider disposition, and the final
   durable `released` save. A non-released workarea cannot be joined in shared
   mode or selected for another acquire.
2. **Exact identity is preserved.** Verification addresses the existing
   `Workarea.id` and host-local path through a path-free lease projection. A
   different workarea is not an acceptable substitute even when its source
   metadata matches.
3. **The local execution claim is the sole claim-clock origin and precedes
   access.** Before a verifier accesses the workarea, the lifecycle owner durably
   binds one invocation and claim to the lease, session, terminal result, and
   workarea. The commit's canonical claim bytes, `claimNowMs`, and `claimedAt`
   form one immutable replay tuple; byte-identical retry returns that tuple
   without resampling, while any changed stable value conflicts. No command may
   start and no result may be accepted until the consumer durably retains the
   exact successful downstream claim-acknowledgement receipt.
4. **Acknowledgement and expiry/reaping are separate.** An exact semantic
   acknowledgement for the durable claim moves `active -> release-pending`.
   Expiry merely makes `active` eligible for the reaper, which separately records
   its reason and moves it to `release-pending`. Neither event makes the workarea
   reusable; only successful provider release followed by durable `released`
   does so.
5. **Recovery and acquisition failure fail closed.** Every `active` and
   `release-pending` lease is loaded before pool admission. A separate durable
   quarantine guard is written before lease acquisition; guard or lease failure
   excludes the exact workarea at boot and during bounded cleanup.
6. **Lease time is exact and replay-coherent.** `acquiredAtMs` is the
   acquisition transaction's single persisted nondecreasing UTC millisecond
   sample; `expiresAtMs = acquiredAtMs + leaseDurationMs`; and the immutable
   maximum is `acquiredAtMs + maxLeaseDurationMs`. Enqueue and claim each sample
   once and compute signed `remainingMs = expiresAtMs - nowMs`, with no second
   rounding step. `settlementBudgetMs` is `977000 ms`; the `60000 ms` safety
   margin is separate, so claim requires `remainingMs > 1037000`. The optional
   separate `60000 ms` queue window requires `remainingMs > 1097000`. Clock
   rollback is clamped by the persisted high-water mark; a forward jump may make
   the lease immediately reapable. Renewal may extend the same active lease only
   up to the acquisition-fixed maximum and only before the first durable
   terminal-status body; before that save it updates the authoritative descriptor,
   and after that save it is forbidden.
7. **Reclamation uses a proved actionable bound.** A scan snapshot of `N`
   records is partitioned into serial batches: every non-final batch contains
   exactly `B` records and the final batch contains the remainder. Each admitted
   batch executes work-conservingly up to `K` concurrent attempts, filling a free
   slot immediately while an unstarted record remains. With maximum
   initial/inter-batch delay `I`, hard attempt timeout `R`,
   `M = ceil(N/B)`, and `Q = ceil(B/K)`, every snapshot attempt responds or times
   out within `M * (I + Q * R)`. The theorem assumes continuous host, scheduler,
   durable-authority, attempt-slot, and provider-call-path availability. An outage
   has no bounded wall-clock duration; after reconciliation the runtime captures a
   new recovery snapshot whose first batch is admitted within a new `I`, then
   applies the same exact partition, work-conserving rule, and bound.
8. **Provider release is idempotent and at least once.** Every durable
   `release-pending` record MUST cause at least one `release(workarea, mode)`
   attempt. The caller MAY repeat it after a crash, and the provider MUST make an
   equivalent repeated callback safe. Failure leaves `release-pending`, retains
   the workarea, and remains operator-visible.

A duplicate terminal submission reuses the lease keyed by its stable terminal
result identity only when its bytes and invariants are equivalent. Expiry is
never a successful acknowledgement or a terminal-verdict change. A requested
lease is independent of `PreserveWorktreeAlways`; ordinary preservation cannot
suppress the descriptor or the lease state machine.

## The local-pool implementation (OSS-shipped reference)

The OSS execution layer must ship a working `WorkareaProvider` for the local-machine case. The fast path is a warm pool of pre-built workareas, keyed by `(repository, toolchain-set)`.

```
Pool member states:
  warming    — git clone + pnpm install in progress
  ready      — clean, deps installed, available for acquire
  acquired   — currently in use by a session
  releasing  — scoped clean in progress
  invalid    — lockfile changed or staleness exceeded; pending rebuild
  retired    — slated for destruction
```

This pool-state contract is consumed by the user-facing `host workarea` TUI subcommand (`rensei host workarea list / inspect / restore`) per `ADR-2026-05-06-tui-noun-consolidation.md`, which folded the previous top-level `workarea` namespace into `host` alongside daemon lifecycle and capacity. The state names in this section are the canonical labels the TUI renders on each pool member; clients using the older top-level `workarea` command see the same labels through the deprecated alias for one release.

### `acquire(spec)` — fast path

1. Find a `ready` pool member matching `(spec.source.repository, spec.toolchain)`.
2. Validate its `ref` is reachable from `spec.source.ref`; if not, `git fetch` and `git checkout`.
3. Run scoped clean: `rm -rf .next .turbo node_modules/.cache dist coverage` (configurable per project).
4. Verify lockfile hasn't drifted; if it has, mark member `invalid`, fall through to slow path.
5. Compute `cleanStateChecksum` over a set of canonical files (lockfile + selected configs); store in `Workarea`.
6. Mark member `acquired`, return.

P95 target: < 5 seconds when a warm member exists.

### `acquire(spec)` — slow path (cold or no match)

1. `git worktree add` from a base clone, or `git clone` if no base.
2. Detect toolchain (kit-driven, see `005`); install via `mise`/`asdf`/equivalent.
3. `pnpm install --frozen-lockfile` (or family equivalent).
4. Run any kit-declared post-install steps.
5. Mark `acquired`, return.

P95 target: < 90 seconds for typical TS monorepo. Background warmer creates additional pool members in anticipation.

### `release(workarea, mode)`

- `destroy` — `git worktree remove`, delete pool entry.
- `return-to-pool` — scoped clean, mark `ready`. The default for most sessions.
- `pause` — local provider has no memory-pause primitive; degrades to `return-to-pool` and emits a warning.
- `archive` — tar to a configurable location, mark pool member `retired`. Useful for forensic preservation.

### Pool management

- **Lockfile invalidation** — file watcher on `pnpm-lock.yaml` / `package-lock.json` / `Cargo.lock` etc. Any change marks all members `invalid` for that repo+toolchain key. Background rebuilder repopulates.
- **Staleness** — pool members exceeding configured age (default 24h) are invalidated even without lockfile changes, to catch out-of-band dependency drift.
- **Eviction** — LRU when pool capacity exceeded; configurable capacity per (repo, toolchain) key.
- **Concurrency** — pool operations are serialized per (repo, toolchain) key via per-key mutex; multiple keys parallelize.

### Observability

Every acquire/release emits a structured event consumed by Layer 6. Minimum fields:

```
workarea_id
session_id
provider_id
ref_requested
ref_actual
toolchain_requested
toolchain_resolved
clean_state_checksum
acquire_path: 'pool-warm' | 'pool-fresh' | 'cold'
acquire_duration_ms
```

The `acquire_path` field is the operational hook for "are we missing pool warmth?" alerts.

## Snapshot-aware implementations

For sandbox providers that ship native snapshot/pause-resume primitives (E2B, Vercel Sandbox, Modal, Daytona), the workarea provider implementation is much thinner — `acquire` becomes "resume from a labeled snapshot" or "clone from a template snapshot," and `release(pause)` is genuinely free.

### E2B-shaped (memory + FS, ~1s resume)

- `acquire(spec)` — find a paused E2B sandbox tagged with the right toolchain. If none, create from a template snapshot. If template doesn't exist, do a cold install + snapshot for next time.
- `release(workarea, pause)` — call E2B's pause API. Workarea is now `paused`, costs storage only.
- `resume(id)` — the headline operation. ~1s, FS + memory + processes restored.
- `snapshot(workarea, label)` — call E2B's pause-then-fork pattern; original returns to `acquired`.

### Vercel-shaped (FS-only snapshot, p75 < 1s restore)

- `acquire(spec)` — boot a sandbox `from: { type: 'snapshot', snapshotId: <toolchain-template> }`.
- `release(workarea, pause)` — Vercel has no idle/paused tier; degrade to `archive` (snapshot) + destroy.
- `snapshot` — first-class.

### Daytona-shaped (FS archive, slower restore)

- `acquire(spec)` — restore archived workspace by ID, or create new from image template.
- `release(workarea, archive)` — `daytona archive`, paid as object storage.

## Observation cursor cooperation with memory

The Intelligence Services layer (`007`) captures FS events during sessions to populate the knowledge graph. Two specific sources matter:

Two specific sources matter: the observation capture stream (real-time FS event matching) and AST-driven file-op extraction.

When `release(pause)` and a later `resume()` happen, naive replay would double-emit observations. The contract:

1. Workarea capabilities declare `emitsObservationEvents: true` if the provider integrates with the FS event capture stream.
2. The `Workarea` handle carries an opaque `observationCursor` that represents "all events up to this point have been delivered to the memory writer."
3. `snapshot()` MUST capture the cursor; `resume()` MUST restore it. Replays from a snapshot start delivering events from the cursor forward, not from the beginning.
4. When a workarea is reused (`return-to-pool`), the cursor is RESET — a returned pool member starts fresh on its next acquire, because the prior session is logically over.

This is one of the seams (`006-cross-provider-interactions.md`) where a small contract detail prevents a class of cross-layer bugs. If we miss it, eval reproducibility and proactive memory both surface duplicate observations.

## Toolchain matching to sandbox image selection

The composition seam: a Kit's `provide.toolchain = { java = "17", node = "20" }` propagates into `WorkareaSpec.toolchain`. The workarea provider then matches against:

- **Local pool**: pool members tagged by toolchain set; warmer maintains members for declared toolchain combinations.
- **Snapshot-capable providers**: snapshot template lookup (`template:java-17+node-20`); if missing, cold-install once and tag.
- **K8s**: image selector (`workarea-image: 'rensei/wa-java17-node20:v1'`); pod chosen from a warm replica set.

The Kit doesn't know which sandbox/workarea provider satisfied its demand. The workarea provider doesn't know which Kit caused the demand. The toolchain spec is the contract.

Detail: `006-cross-provider-interactions.md` covers the kit↔workarea↔sandbox composition end-to-end.

## Sharing model (sub-agent coordination)

Today's shared-worktree convention exists because pnpm install is slow; sub-agents in coordination workflows share a worktree to amortize the install cost. The workarea provider keeps that option but moves it from "implicit convention" to "declared in `WorkareaSpec.mode`":

```ts
// Coordinator acquires:
const coord = await provider.acquire({ ..., mode: 'exclusive', sessionId: 'coord-123' })

// Sub-agent joins:
const sub = await provider.acquire({ ..., mode: 'shared', parentWorkareaId: coord.id, sessionId: 'sub-1' })
```

Provider responsibilities in shared mode:
- The same filesystem path is returned to both parents and sub-agents.
- Reference counting on `release` — actual teardown only when all participants release.
- The cleanStateChecksum is captured once, on coordinator acquire; sub-agents inherit and don't re-validate.
- Locking semantics are NOT enforced at this layer — sub-agents are still expected to respect "only modify files relevant to your sub-issue" (existing rule in `CLAUDE.md`). The provider doesn't try to be a filesystem multiplexer.

A provider that doesn't support shared mode (`capabilities.supportsSharedMode: false`) returns an error if a shared spec is requested; the scheduler falls through to a provider that does, or rejects the spec.

## Capability profile by sandbox

Mapping the seven sandbox providers to expected workarea capability shapes (informs `004` scheduler design):

| Sandbox | cleanGuarantee | snapshot | pauseResume | sharedMode | resume | acquire-p95 |
|---|---|---|---|---|---|---|
| Local pool | scoped | ❌ | ❌ | ✅ | ❌ | ~5s warm / ~90s cold |
| Vercel Sandbox | scoped | ✅ | ❌ | ❌ | from snap | ~5s warm / ~10s cold |
| E2B | scoped | ✅ | ✅ | ❌ | ✅ | ~1s warm / ~10s cold |
| Modal | scoped | ✅ (preview) | ✅ (preview) | ❌ | ✅ | seconds |
| Daytona | scoped | ✅ (FS archive) | ❌ | ❌ | from archive | seconds-tens |
| Docker | scoped | ❌ | ❌ | ✅ | ❌ | ~10s |
| K8s | scoped | ❌ (volume snap optional) | ❌ | ❌ | ❌ | tens of seconds |

These are first-cut declarations; each provider's implementation owns its declared capabilities.

## Open questions

1. **Cleanup configuration scope.** Should "what counts as a known artifact dir" be project-level (in `.rensei/config.yaml`) or kit-declared (kits know what they emit)? Probably both: kit declares, project overrides. Concrete schema in `005-kit-manifest-spec.md`.
2. **Shared-mode lifecycle on parent crash.** If a coordinator workarea is force-released while sub-agents are still attached, what happens? Default: sub-agent operations fail with a clear error; the workarea is destroyed. Alternative: sub-agents continue and the *last* one out triggers cleanup. The first is simpler and probably right; revisit if real coordinator-crash flows demand otherwise.
3. **Cross-provider snapshot portability.** Can an E2B-captured snapshot be resumed in Vercel Sandbox? No. Snapshots are provider-internal opaque refs. Cross-provider migration requires explicit `archive` + `acquire(source)` — reads as a fresh acquire on the target provider.
4. **Identity in `cleanStateChecksum`.** The checksum is over which files? Default: lockfile(s) + the kit's declared "canonical files" list. Tenants may extend. Risk: too few files → false equivalence; too many → checksum churn defeats the purpose.

These ship as `// TODO` or default-and-document in the OSS reference impl; ADRs lock answers as we get implementation experience.
