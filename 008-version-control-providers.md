# 008 — Version Control Providers

**Status:** Reference (initial draft)
**Last updated:** 2026-04-27
**Related:** `001-layered-execution-model.md`, `002-provider-base-contract.md`, `006-cross-provider-interactions.md`

## Why this exists

Today the platform assumes git everywhere — `git clone`, `git push`, GitHub PRs, merge queues serialize against unstable trunks. That assumption holds for 95%+ of code today, but two pressures push us off it:

1. **Agent-native VCS is real.** Atomic (Pijul-derived patch theory) handles concurrent agent edits with token-granularity auto-merge — eliminating a class of "merge queue against unstable trunk" pain that we currently spend orchestration cycles solving. The investor relationship makes Atomic a credible "first-class second VCS" target rather than a research project.

2. **What counts as "code" is expanding.** Marketing kits manage spreadsheet rows. Ops kits manage runbooks in Notion. Some workflows want versioned S3 objects (datasets, model weights). Treating "version control" as exclusively git forecloses on these.

This doc defines `VersionControlProvider` so the merge queue, the workarea provider, and the orchestrator's commit/push/merge logic can branch on declared capabilities rather than assume git semantics. It's anchored on the Atomic research findings and the recommendation from that report: design the abstraction around capability flags + optional verbs, not a least-common-denominator API.

## The interface

```ts
interface VersionControlProvider extends Provider<'vcs'> {
  // ─── Required verbs (every provider) ─────────────────────────────
  /**
   * Materialize a working copy at a path. The workarea provider may
   * call this during acquire(); orchestrator code rarely calls it directly.
   */
  clone(uri: string, dst: string, opts?: CloneOpts): Promise<Workspace>

  /**
   * Record a change. Wraps "stage + commit" for git, "record" for Atomic,
   * "PUT object" for S3-versioned, "row update" for structured content.
   */
  recordChange(ws: Workspace, change: ChangeRequest): Promise<ChangeRef>

  /**
   * Push local changes to a remote. For commutative VCS (Atomic), pushes
   * always succeed against an unstable trunk; for git, push may fail and
   * the caller falls back to merge-queue or rebase.
   */
  push(ws: Workspace, target: PushTarget): Promise<PushResult>

  /**
   * Pull remote changes into the local working copy.
   */
  pull(ws: Workspace, source: PullSource): Promise<MergeResult>

  // ─── Optional verbs (gated by capabilities) ──────────────────────
  /**
   * Open a proposal for review/merge. "PR" on git, "view-share" on
   * future Atomic, n/a on S3.
   */
  openProposal?(ws: Workspace, opts: ProposalOpts): Promise<ProposalRef>

  /**
   * Merge a proposal. Strategy depends on provider capabilities and
   * proposal-level options.
   */
  mergeProposal?(ref: ProposalRef, strategy: MergeStrategy): Promise<MergeResult>

  /**
   * Enqueue a proposal for serialized merge. Only meaningful for providers
   * where simultaneous merges to trunk can conflict — i.e., NOT for
   * commutative VCS (Atomic) where concurrent pushes commute by construction.
   */
  enqueueForMerge?(ref: ProposalRef, opts: MergeQueueOpts): Promise<QueueTicket>

  /**
   * Resolve a conflict raised by a prior merge attempt.
   */
  resolveConflict?(c: Conflict, resolution: Resolution): Promise<void>

  /**
   * Attest a change with provenance metadata (model, agent, session, kit set).
   * Atomic supports this natively (Ed25519 + session); git fakes it via
   * commit trailers; S3 stores attestation as object metadata.
   */
  attest?(ws: Workspace, sessionMetadata: SessionAttestation): Promise<AttestationRef>
}

// ─── Discriminated unions for results ──────────────────────────────
type PushResult =
  | { kind: 'pushed'; ref: ChangeRef }
  | { kind: 'rejected'; reason: 'non-fast-forward' | 'auth' | 'policy'; details?: string }

type MergeResult =
  | { kind: 'clean' }                                  // no overlap
  | { kind: 'auto-resolved'; resolutions: AutoResolution[] }
                                                       // Atomic's headline path
  | { kind: 'conflict'; conflicts: Conflict[] }        // human/agent intervention required

// ─── Type aliases ──────────────────────────────────────────────────
interface Workspace {
  readonly id: string
  readonly providerId: string
  readonly path: string                                // local working-copy path
  readonly headRef: string                             // commit / patch-set / object version
}

interface ChangeRequest {
  message: string
  paths: string[]                                      // for content-based VCS (git, atomic, s3)
  cells?: CellChange[]                                 // for structured content (sheet rows)
  attestation?: SessionAttestation                     // attached to the change
}

interface SessionAttestation {
  agentId: string
  modelRef: { provider: string; model: string }
  sessionId: string
  kitIds: KitProviderId[]
  workareaSnapshotRef?: WorkareaSnapshotRef
  reviewerHints?: string[]
  startedAt: Date
  signedBy?: string                                    // identity, when supported
}

interface ProposalOpts {
  title: string
  body: string
  baseRef: string
  reviewers?: string[]
  labels?: string[]
}

type MergeStrategy =
  | 'auto'                                              // provider-default
  | 'three-way-text'                                   // git-style merge
  | 'rebase'
  | 'squash'
  | 'patch-theory'                                     // Atomic
  | 'last-write-wins'                                  // S3-style
  | 'cell-merge'                                       // structured content
```

## Capabilities

```ts
interface VersionControlProviderCapabilities {
  // Merge model
  mergeStrategy: 'three-way-text' | 'patch-theory' | 'crdt' | 'last-write-wins' | 'object-version' | 'cell-merge'
  conflictGranularity: 'line' | 'token' | 'object' | 'cell' | 'none'

  // Proposal/review concepts
  hasPullRequests: boolean              // git: true; Atomic today: false
  hasReviewWorkflow: boolean            // human-or-agent review gate
  hasMergeQueue: boolean                // serialization-against-trunk needed

  // Branching
  supportsBranches: boolean
  supportsRebase: boolean

  // Identity & trust
  identityScheme: 'email' | 'ed25519' | 'oauth' | 'iam' | 'workspace-token'
  remoteProtocol: 'git-smart-http' | 'atomic-merkle' | 's3' | 'http-api'
  provenanceNative: boolean             // attestation as first-class verb (Atomic)
                                       // vs. faked via trailers (git)

  // Content shape
  supportsBinary: boolean
  supportsStructuredContent: boolean    // cells/rows/objects beyond text
  supportsLargeFiles: boolean           // multi-GB datasets
}
```

## Capability profile by provider

| Capability | Git (GitHub/GitLab) | Atomic | S3 versioned | Sheets/Notion |
|---|---|---|---|---|
| `mergeStrategy` | three-way-text | patch-theory | last-write-wins | cell-merge |
| `conflictGranularity` | line | token | object | cell |
| `hasPullRequests` | ✅ | ❌ (today) | ❌ | ❌ |
| `hasReviewWorkflow` | ✅ | ❌ | ❌ | ✅ (Notion comments) |
| `hasMergeQueue` | ✅ | ❌ (commutative) | ❌ | ❌ |
| `supportsBranches` | ✅ | ✅ (views) | ❌ | ❌ |
| `supportsRebase` | ✅ | ❌ (different model) | ❌ | ❌ |
| `identityScheme` | email / oauth | ed25519 | iam | oauth |
| `remoteProtocol` | git-smart-http | atomic-merkle | s3 | http-api |
| `provenanceNative` | ❌ (trailers) | ✅ | ❌ (object metadata) | ❌ |
| `supportsBinary` | ✅ (LFS) | ✅ | ✅ | ❌ |
| `supportsStructuredContent` | ❌ | ❌ | ✅ (objects) | ✅ |
| `supportsLargeFiles` | LFS only | ❌ | ✅ | ❌ |

## Provider-by-provider notes

### Git (GitHub / GitLab / Bitbucket) — OSS-shipped reference

The default. Three concrete adapters share most code:

- `GitHubVCSProvider` — uses `gh` CLI for PR-shaped operations, plain `git` for the rest.
- `GitLabVCSProvider` — uses `glab` or REST.
- `BitbucketVCSProvider` — REST.

All three declare identical capabilities except per-host quirks (e.g., GitHub merge-queue vs GitLab's; PR template URL formats). The abstraction puts the differences in the impl, not in the consumer.

Provenance via commit trailers:
```
Co-Authored-By: <agent-name> <agent@rensei.dev>
X-Rensei-Session-Id: <sessionId>
X-Rensei-Kit-Set: spring/java@1.0.0,docker-compose@2.1.0
X-Rensei-Workarea-Snapshot: <ref>
X-Rensei-Model: anthropic/claude-opus-4-7
```

Tagged session SHAs are signed via configured GPG/Sigstore key when `provenanceNative: true` is requested by tenant policy.

### Atomic VCS — first-class second

Per the Atomic research findings:

- v0.5.1 today, ~29 GitHub stars, $2.5M pre-seed (Slow Ventures, Irregular Expressions, Vermilion Cliffs).
- Pijul-derived patch theory; token-granularity auto-merge via dual-layer (graph + semantic) diffs.
- CLI-first today (`atomic init/add/record/push/pull`); no SDK, no MCP server, no PR concept.
- First-class agent attestation: Ed25519 identity + session metadata is native, not faked.
- No public SaaS for hosting; remote protocol exists (`atomic-merkle`) but no documented multi-tenant hosting service yet.

`AtomicVCSProvider` declarations:

```ts
{
  mergeStrategy: 'patch-theory',
  conflictGranularity: 'token',
  hasPullRequests: false,           // genuinely missing today
  hasReviewWorkflow: false,         // ditto
  hasMergeQueue: false,             // commutative — pushes always commute
  supportsBranches: true,           // "views"
  supportsRebase: false,            // different model
  identityScheme: 'ed25519',
  remoteProtocol: 'atomic-merkle',
  provenanceNative: true,           // the headline differentiator
  supportsBinary: true,
  supportsStructuredContent: false,
  supportsLargeFiles: false,
}
```

Implementation gaps to plan around (from research):

- **No PR equivalent yet.** `openProposal` returns an unsupported-operation error. Tenants using Atomic must run review through external means (Slack thread, Linear comment) until Atomic ships an analogue.
- **No hosting story.** Tenants self-host the Atomic remote; no SaaS exists today. Worth tracking for our enterprise pitch.
- **CLI-only API.** Our adapter shells out to `atomic`. Acceptable for v1; we can co-design a library binding with the founder if useful.

### S3 versioned — for non-code workloads

```ts
{
  mergeStrategy: 'last-write-wins',
  conflictGranularity: 'object',
  hasPullRequests: false,
  hasReviewWorkflow: false,
  hasMergeQueue: false,
  supportsBranches: false,
  identityScheme: 'iam',
  remoteProtocol: 's3',
  provenanceNative: false,          // attestation in object metadata
  supportsBinary: true,
  supportsStructuredContent: true,
  supportsLargeFiles: true,
}
```

Use cases: dataset versioning, model weights, generated assets (marketing renders, video outputs from Remotion). The "workarea" for an S3-backed session is a local cache directory mirroring the configured prefix; `recordChange` PUTs new versions; `push` is a no-op (S3 versioning is server-side).

`attest()` writes provenance into object metadata (`x-amz-meta-rensei-session`, `x-amz-meta-rensei-model`, etc.) — searchable post-hoc via Inventory/Athena.

### Sheets / Notion — for non-code workflows

```ts
{
  mergeStrategy: 'cell-merge',
  conflictGranularity: 'cell',
  hasPullRequests: false,
  hasReviewWorkflow: true,          // Notion comments
  hasMergeQueue: false,
  supportsBranches: false,
  identityScheme: 'oauth',
  remoteProtocol: 'http-api',
  provenanceNative: false,
  supportsBinary: false,
  supportsStructuredContent: true,
  supportsLargeFiles: false,
}
```

`Workspace` is a Notion page or Sheets workbook ID. `clone()` snapshots into a local cache. `ChangeRequest.cells` carries cell-level updates; `recordChange` PATCHes the cells. `push` is a no-op (changes hit the live document). Useful for kits that produce non-code artifacts (campaign plans, content calendars, decision logs).

## Merge queue logic — gated, not hard-wired

The platform's `packages/core/src/merge-queue/...` logic exists today to serialize git pushes against an unstable trunk. With the abstraction, the merge queue becomes **conditional**:

```ts
async function mergeProposalSafely(provider: VersionControlProvider, ref: ProposalRef) {
  if (!provider.capabilities.hasMergeQueue) {
    // Commutative VCS — pushes commute by construction. Atomic.
    return await provider.mergeProposal!(ref, 'auto')
  }
  // Git-shaped — serialize against trunk
  const ticket = await provider.enqueueForMerge!(ref, { ... })
  return await waitForQueue(ticket)
}
```

Two important properties:

1. **The merge queue is not obsolete on Atomic.** It does more than conflict-avoidance: gates on CI green, deployment safety, dependency ordering, rollback windows. None of these are solved by commutative merge; they remain valuable. The capability flag controls whether *push serialization* is needed; the surrounding gates are still relevant.

2. **`MergeResult.auto-resolved` must be surfaced, not silently swallowed.** Atomic's headline value is the auto-resolution path. Logging "merged with N auto-resolutions" gives the audit chain real evidence; treating it as a clean merge throws away the differentiation.

## VCS attestation → audit chain

Detail in `006` Seam 6. Summary:

- VCS providers declare `provenanceNative: true` (Atomic, signed-git-trailers) or `false`.
- The `attest()` verb is optional but supported by every adapter — git fakes it via trailers, S3 via metadata, Notion via custom property fields. The shape is the same.
- Layer 6 observability ingests attestations as `vcs-attestation` events and assembles per-tenant audit chains.

For tenants in regulated industries, configure `provenanceNative: true` providers as policy. The base contract refuses to activate tenants' VCS providers that don't satisfy declared trust requirements.

## Workarea provider pairing

The workarea provider's `acquire(spec)` includes `spec.source.repository` and `spec.source.ref`. The workarea provider chooses *how* to clone, but it MUST use the configured VCS provider's `clone` verb. This means:

- A git repo configured at `github.com/foo/bar` clones via `GitHubVCSProvider.clone()`.
- An Atomic repo at `atomic://atomicremote.example.com/foo` clones via `AtomicVCSProvider.clone()`.
- An S3 prefix at `s3://bucket/path` clones via `S3VersionedVCSProvider.clone()` (mirrors to local cache).

The workarea provider doesn't assume any of these; it asks the right VCS provider to do it. This is what makes the local-pool warm cache work across VCS types — pool members are keyed on `(vcsProviderId, repository, toolchain)`, not on git-specific assumptions.

## OSS vs SaaS responsibilities

| Concern | OSS | SaaS |
|---|---|---|
| `VersionControlProvider` interface | ✅ owns | consumes |
| Capability struct | ✅ owns | consumes |
| `GitHubVCSProvider` | ✅ ships | inherits |
| `GitLabVCSProvider` / `BitbucketVCSProvider` | optional contrib | ✅ ships |
| `AtomicVCSProvider` | ✅ ships (CLI shell-out) | inherits |
| `S3VersionedVCSProvider` | ✅ ships | inherits |
| `NotionVCSProvider` / `SheetsVCSProvider` | ❌ (oauth ceremony) | ✅ ships |
| Merge queue logic (capability-gated) | ✅ ships | inherits |
| Audit chain aggregation | ❌ | ✅ owns |
| Per-tenant trust policy | ❌ | ✅ owns |

OSS users get git + Atomic + S3 working; SaaS adds the more-credentialed providers (GitLab/Bitbucket if not contributed back) and the multi-tenant audit chain.

## Linear realignment hooks

- Per the icebox parse (`009`), nothing in the existing backlog covers VCS abstraction. This is greenfield. Net-new issue to author:
  > **`VCS provider abstraction with Atomic + git + S3 implementations`** — Defines `VersionControlProvider` per `008`, ships GitHub adapter (rename existing merge-queue logic to consume it), Atomic adapter (CLI shell-out), S3 adapter. Closes the assumption-of-git in core code paths.
- **REN-148** (Vercel Integration / DeploymentProvider) — DeploymentProvider is a sibling family, not VCS. Co-design timing only — no scope shift.

## Open questions

1. **Conflict resolution UX for Atomic auto-resolved cases.** When Atomic auto-resolves 5 token-level conflicts, the agent's working copy may differ from what the agent itself wrote. Should we surface a "review the auto-resolution" step? Default: log + continue; flag surfaces for tenant policy.
2. **Cross-VCS migration.** Can a workarea backed by git be migrated to Atomic mid-session? No (different content models). But "open this Atomic project from a git remote that mirrors the same content" is a valid pattern; covered by tenant configuring two providers and choosing per-project.
3. **Agent identity for Atomic Ed25519.** Per-agent keys vs per-session keys vs per-tenant key. Probably per-session: each session boots with a fresh keypair, public key registered in attestation, private key destroyed at session end. Audit verifies via public key in attestation chain.
4. **PR-equivalent for Atomic when it ships.** Once Atomic adds a proposal/review concept, our adapter declares `hasPullRequests: true` and exposes the matching verb. Until then, tenants using Atomic for production work need a parallel review system (Linear thread, Slack channel) — fine for early adopters, friction for broader use.
5. **Sheets/Notion as VCS — is the abstraction overstretched?** Maybe. The "structured content as VCS" path may want a sibling abstraction (`StructuredContentProvider`?) once there are real customer use cases. For now, treating it as a VCS variant with `cell-merge` keeps the surface small. Revisit when a non-code customer actually drives requirements.

These are intentional gaps for ADRs after implementation experience.
