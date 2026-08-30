---
status: Proposed
date: 2026-08-30
boundary: shared
split: sibling-extensions
---

# ADR-2026-08-30 — Workspace root and lazy repository materialization

**Status:** Proposed — draft only. This architecture is not Accepted,
implemented, shipped, released, migrated, or activated.
**Date:** 2026-08-30
**Boundary:** shared (OSS-canonical contract here; downstream mapping remains in
the private sibling corpus)
**Authors:** execution-layer workspace lane

## Context

`ADR-2026-08-22-session-owned-multi-repository-workarea.md` established the
right ownership boundary: one session-owned root, explicit repository roles and
authorities, and whole-root lease, archive, accounting, adoption, and cleanup.
It also separated the root from the selected repository working directory.

That Accepted target still leaves three bootstrap questions unresolved:

1. Repository leaves sit directly under the root, so the root has no structural
   namespace separating checkouts from session metadata and harness-owned state.
2. A repository declaration describes a fully materialized set. It has no
   explicit, idempotent operation for obtaining one declared secondary or
   context repository only when work first needs it.
3. Exact-harness config, cache, extension, and continuation state has no
   session-root namespace. It can drift into a checkout or an ambient host home,
   making authority, cleanup, and resume depend on path convention.

Eagerly cloning every declared repository is simple but expensive. It also
requires every repository credential to be available before the session starts,
even when the agent never reads that repository. Conversely, making path access
implicitly clone a repository hides network and credential side effects behind
`stat`, `chdir`, or a filesystem hook. That is not an auditable bootstrap
contract.

This proposal refines the Accepted ownership model; it does not replace it.
The root remains the single lifecycle object, `repositoryWorktreePath` remains
the selected checkout and harness working directory, authority remains explicit
and executor-enforced, and no leaf receives its own lease or cleanup authority.

## Decision

Adopt a negotiated `workspace-bootstrap-v2` protocol. A v2 workspace root is
structurally not a repository checkout: repository materializations live under
`repos/`, exact-harness mutable state lives under `state/<harness>/`, and
runner-owned declarations, receipts, locks, and staging live under the reserved
`.workspace/` namespace.

The primary repository is materialized by an explicit eager call to the same
idempotent `EnsureRepository` operation used for every repository. Secondary
and context repositories remain declaration-only until an explicit caller
ensures them. Constructing or accessing a path never materializes a repository.

### D0 — Proposal posture and relationship to Accepted architecture

This ADR is **Proposed**. Until a later accepting commit updates the affected
reference documents, all current descriptions and implementations remain
authoritative for their shipped behavior.

If Accepted, this ADR would amend only the on-disk layout, bootstrap protocol,
and materialization lifecycle of the Accepted session-owned workarea:

- `workareaRoot` continues to carry the absolute path of the session-owned root
  on existing provider and daemon wires. This ADR calls that structural object
  the **workspace root**; it does not require a wire-field rename.
- `repositoryWorktreePath` remains the exact selected repository and harness
  working directory.
- one root still owns every repository and harness-state leaf; leases, archive,
  accounting, adoption, sharing, and cleanup remain root-bound.
- no reference document changes in this proposal. They land only with a future
  status flip to `Accepted`.

### D1 — The root is a namespace, never a checkout

The v2 layout is:

```text
<worktree-root>/
  <root-owner-session-id>/                 workspace root (`workareaRoot` on current wires)
    .workspace/                            runner-owned metadata; never a repository
      manifest.json
      receipts/repositories/<repository-key>.json
      locks/repositories/<repository-key>.lock
      staging/repositories/
    repos/
      <repository-key>/                    one materialized checkout
      <repository-key>/
    state/
      <harness-key>/                       exact-harness mutable state
```

The workspace root itself MUST NOT contain `.git`, source files, a repository
remote, or a harness working tree. A v2 `repositoryWorktreePath` is always
`<workspaceRoot>/repos/<repository-key>`. A consumer that treats the root as a
checkout fails a structural fixture before activation.

Every materialized repository is therefore a sibling of every other one under
`repos/`. D2 makes the repository key the validated declared repository name,
so from any selected repository working directory the existing `../<name>`
contract resolves byte-for-byte to `../<repository-key>`. V2 changes the common
parent from the root to `repos/`; it does not change the relative sibling path
an agent observes.

The root's top-level `repos`, `state`, and `.workspace` names are reserved.
Repository and harness keys cannot name or escape those namespaces. Ownership
decisions read `manifest.json` and receipts; they never infer content from a
directory listing.

The `<root-owner-session-id>` and shared-participant rules remain those of
`ADR-2026-08-22` D2/D7: an exclusive session owns its root, while a shared
participant reaches the parent's root through its durable descriptor rather
than substituting its own id or searching the filesystem.

### D2 — RepositoryDeclaration carries role, authority, and a stable key

The producer normalizes authoring input into one closed, versioned declaration:

```ts
type RepositoryRole = 'primary' | 'secondary' | 'context'
type RepositoryAuthority = 'read-only' | 'mutable'
type RepositoryKey = string

interface RepositoryDeclarationV2 {
  protocol: 'workspace-bootstrap-v2'
  declarationId: string
  revision: string
  repositories: DeclaredRepositoryV2[]
  select?: RepositoryFilter // absent means { kind: 'primary' }
}

interface DeclaredRepositoryV2 {
  key: RepositoryKey            // normalized declared name and path key
  sourceRef: string             // stable, non-secret resolver identity
  sourceFingerprint: string     // digest of credential-free source identity
  requestedRef: string
  role: RepositoryRole
  authority: RepositoryAuthority
}
```

Exactly one declaration entry has role `primary`. Roles and authority remain
orthogonal:

- `primary` means eager bootstrap and default selection, not write authority or
  a different lifetime;
- `secondary` means an additional work repository, lazy by default;
- `context` means reference material, lazy by default;
- authoring defaults normalize primary to `mutable` and secondary/context to
  `read-only`, but the executor wire always carries authority explicitly;
- selection never grants authority, and materialization never widens it.

`RepositoryFilter` retains the closed grammar and fail-closed resolution rules
of `ADR-2026-08-22` D4. Selection is resolved against the declaration, never the
filesystem. Selecting a lazy secondary or context repository causes the
orchestrator to call `EnsureRepository` explicitly before spawn; it does not
make path lookup magical.

`RepositoryKey` is both the stable logical name and the path key. The default
OSS producer derives it deterministically from the explicitly declared name or,
when absent, the credential-free source basename with any `.git` suffix
stripped — the existing sibling-context derivation. The v2
`RepositoryFilter` `{ kind: 'named', name }` compares `name` byte-for-byte with
this key. The key preserves the declared name's bytes and case; the producer
does not lowercase, Unicode-normalize, slugify, digest, or otherwise rewrite it.
It must pass the Accepted D5 validator unchanged: non-empty, length-bounded,
within the restricted character set, path-separator-free, neither `.` nor `..`,
not dot-prefixed, and outside every reserved namespace. A caller-supplied key
passes the same validator.

Collision safety is by early refusal, not by an opaque digest or automatic
rename. Duplicate keys, case-fold collisions on a case-insensitive filesystem,
or one key reused for incompatible source fingerprints are typed declaration
errors naming both entries. An author who declares two repositories with the
same basename supplies two different names, and those names become the stable
relative paths. No runtime appends `-2`, uses declaration order as a tie-breaker,
or silently reuses another repository's path. `sourceFingerprint`, not the path,
provides credential-free source-identity evidence.

### D3 — EnsureRepository is the only materialization operation

The execution layer exposes one operation:

```ts
interface RepositoryEnsurer {
  ensureRepository(input: {
    workspaceId: string
    declarationId: string
    declarationRevision: string
    repositoryKey: RepositoryKey
    reason: 'primary-bootstrap' | 'selected-working-directory' | 'explicit-request'
  }): Promise<RepositoryHandle>
}

interface RepositoryHandle {
  repositoryKey: RepositoryKey
  repositoryWorktreePath: string
  resolvedRef: string
  authority: RepositoryAuthority
  materializationReceiptId: string
}
```

The operation has these invariants:

1. **Declared only.** The key must exist in the exact declaration revision.
   An undeclared key is a typed refusal with zero filesystem or credential side
   effects.
2. **Idempotent.** The idempotency identity is
   `(workspaceId, declarationId, declarationRevision, repositoryKey)`. An exact
   repeat returns the same completed materialization receipt and path.
3. **Conflict detecting.** A different ref, authority, source fingerprint, or
   declaration revision targeting an existing key is a typed conflict, never a
   freshen, reset, or implicit replacement.
4. **Serialized per key.** Equivalent concurrent calls use the runner-owned
   `.workspace/locks/repositories/<repository-key>.lock`. The lock coordinates
   one workspace generation only; it is not a distributed lease and grants no
   repository authority.
5. **Atomic publication.** Materialization occurs under a unique
   `.workspace/staging/repositories/` child. The executor verifies source,
   resolved ref, credential hygiene, and authority enforcement, writes and
   fsyncs the receipt, and atomically publishes to `repos/<repository-key>`.
   A half-populated destination is never a repository handle.
6. **Crash replay.** On adoption, an incomplete staging attempt is quarantined
   or removed according to its journal; it is never inferred complete from a
   `.git` directory. A completed receipt plus matching destination returns the
   original handle without network access.
7. **No path-triggered side effects.** `stat`, `open`, `chdir`, path rendering,
   shell completion, and directory listing never call this operation. An absent
   lazy path stays absent until an explicit ensure call succeeds.

Workspace bootstrap invokes `EnsureRepository(reason='primary-bootstrap')` for
the primary before returning a ready workspace. Secondary and context entries
remain absent. A pre-spawn non-primary selection invokes
`EnsureRepository(reason='selected-working-directory')` as its own visible
step. Later materialization uses an explicit execution-layer tool or callable
interface and records `explicit-request`.

### D4 — Read-only and mutable authority are structural

`EnsureRepository` consumes authority from the declaration and has no override
parameter. Before publishing a `read-only` handle, the exact bound executor must
prove a filesystem boundary that the harness cannot widen: mount, sandbox
policy, or an equivalent executor-owned primitive. Same-identity `chmod`, prompt
instructions, post-run dirty checks, and exclusion from completion are not
enforcement.

The v2 execution cell positively attests the workspace protocol and the exact
repository-authority enforcement revision. No enforcement means the candidate
is excluded at viability before declaration emission. The empty set is loud and
typed. A read-only repository is outside mutation and completion contracts but
inside root ownership, accounting, archive, and cleanup.

A `mutable` declaration is also exact: an executor may not silently present it
read-only, omit it, or substitute the primary. If mutable authority cannot be
represented, the ensure or earlier viability decision fails closed.

### D5 — Harness state has its own exact namespace

Every execution-layer-spawned harness receives a session-local state directory
at:

```text
<workspaceRoot>/state/<harness-key>/
```

`<harness-key>` is a deterministic, collision-safe encoding of the exact
`HarnessRef` id and adapter version, not an unsanitized display label. A
different adapter version cannot accidentally inherit the same mutable state.
The manifest binds the key to the harness reference and applied-adaptation
receipt digest.

Config home, cache home, continuation data, runner-injected extensions, and
other harness-owned mutable files are projected beneath this directory where
the adapter supports them. The adaptation plan declares each projection; the
runner does not guess environment-variable names. The directory is writable to
the harness but does not widen any `read-only` repository leaf.

This session-local directory does not replace the injectable host state home of
`ADR-2026-06-03-injectable-state-dir.md`. Host identity, daemon configuration,
and cross-session host records remain outside the workspace. `state/<harness>`
contains only data owned by this workspace generation.

On resume, the executor loads the recorded exact harness key, re-verifies every
runner-injected artifact and adaptation digest, and either resumes that state or
returns a typed incompatibility. It never points a different harness version at
the old directory. Multiple exact harness keys may coexist when a session graph
legitimately uses more than one harness, but every directory remains under the
same root lifecycle.

### D6 — Credentials never persist in manifests or repository remotes

Repository sources and credentials are separate. A declaration persists only a
stable resolver identity, credential-free fingerprint, requested/resolved refs,
role, authority, and key. The workspace manifest, repository receipt, adoption
record, archive metadata, logs, and events MUST NOT contain a credential-bearing
URL, token, header, credential-helper payload, or environment value.

At ensure time a source resolver returns a short-lived fetch target and an
`AuthBindingRef`. Secret delivery occurs after declaration and immediately
before the fetch through a broker, credential helper, or equivalent channel
that keeps bytes out of process arguments and durable files. After
materialization, the executor either removes the repository remote or rewrites
it to a verified credential-free locator. A credential in `.git/config`, any
alternate remote store, submodule config, or worktree metadata is a failed
materialization and quarantines the staging tree.

The same scan runs after provider tooling and submodule setup, not only after
the first clone command. Receipts carry stable refs and digests only. Future
freshen and push operations reacquire an authorized binding; they never recover
a secret from the checkout.

### D7 — Lifecycle, resume, archive, sharing, and cleanup remain root-bound

The workspace root is the single lifecycle object:

- one workarea id, lease, release disposition, accounting record, archive, and
  adoption record cover `.workspace/`, `repos/`, and `state/` together;
- a lazy declaration that was never materialized owns no repository bytes, but
  its declaration and absence remain in the manifest and archive;
- archive captures the manifest, completed receipts, realized repositories,
  and exact-harness state. Restore does not eagerly ensure an absent lazy entry;
- resume reads the manifest and receipts before any repository path. It
  validates every realized destination and leaves every declared-but-absent
  repository absent;
- a future ensure after resume re-resolves source and auth. An unavailable
  resolver or credential is a typed, visible failure for that repository, not a
  reason to corrupt or terminate an otherwise resumable root;
- shared participants join the same root and the same ensure receipts. Per-key
  serialization makes concurrent equivalent ensures coalesce; authority and
  declaration revision are never participant-local;
- release is one idempotent root operation. No repository or harness-state leaf
  transfers to a later session, becomes a cache seed, or outlives root cleanup.

Warm repository objects and dependency snapshots remain provider-owned seeds
outside session roots. An ensure may materialize from a seed, but it still
creates a new destination, receipt, authority boundary, accounting generation,
and observation cursor for the current root.

### D8 — Standalone OSS has a complete producer and default

The protocol is not an interface whose only producer lives downstream. The OSS
binary ships all of:

1. a local declaration producer that converts CLI/config repository inputs into
   `RepositoryDeclarationV2`, including deterministic keys and explicit
   authority normalization;
2. a default source resolver for local paths and ordinary Git remotes, with
   credentials supplied independently through existing Git credential
   mechanisms;
3. a local `EnsureRepository` implementation with per-key locking, staging,
   receipt replay, and credential-hygiene verification;
4. a default single-repository declaration: one primary mutable repository,
   eagerly ensured, with no secondary or context entries; and
5. a standalone explicit command/callable interface for ensuring a declared
   lazy repository and inspecting its receipt.

Removing any downstream control plane still leaves a working producer,
resolver, bootstrap, resume, and cleanup path. Alternate producers may supply
declarations and source bindings, but they cannot widen the v2 schema or bypass
the executor's checks.

### D9 — Version negotiation and legacy compatibility are explicit

`workspace-bootstrap-v2` is a protocol version, not a feature hint. The exact
executor and paired workarea provider advertise it; the producer evaluates it
during viability and re-checks it at bind/claim before emitting a v2 declaration
or creating a v2 root. Absence means unsupported.

Compatibility rules:

1. Existing singular/flat and `session-root-v1` payloads keep their meanings.
   A v2 decoder consumes them only through explicit version adapters.
2. A retained flat workspace is read and resumed in place. Its root may equal
   its checkout path, and it gains neither `repos/` nor `state/`. It is never
   rewritten to look v2 while live.
3. A retained `session-root-v1` workspace keeps top-level repository leaves. It
   is adopted from its recorded version and never reinterpreted from directory
   shape.
4. New v2 roots always use D1. Resume requires an executor that advertises the
   root's recorded protocol; there is no downgrade-on-resume.
5. A default single-primary request may project to an older executor only when
   its producer records that legacy projection as permitted and lossless. A
   request depending on lazy materialization, non-primary selection, v2 harness
   state, or v2 authority proof is not representable and excludes that
   candidate before admission.
6. Secondary/context entries are never silently dropped merely to reach an old
   executor. A producer may declare a read-only entry explicitly droppable for
   a legacy projection only when no selection, capability, completion, or
   adaptation depends on it; the decision record names the omission. Mutable is
   never droppable.
7. Migration is natural turnover. No live root is moved or re-shaped. Retirement
   of flat or v1 readers requires a separate accepting change backed by zero
   retained roots on supported hosts and an explicit rollback plan.

### D10 — Typed failures and secret-free observability

The closed failure family includes at least:

```ts
type WorkspaceBootstrapFailureCode =
  | 'unsupported_workspace_protocol'
  | 'invalid_repository_declaration'
  | 'repository_undeclared'
  | 'repository_key_collision'
  | 'repository_materialization_conflict'
  | 'repository_source_unavailable'
  | 'repository_credentials_unavailable'
  | 'repository_ref_unavailable'
  | 'repository_authority_unavailable'
  | 'repository_credential_persistence_detected'
  | 'repository_materialization_corrupt'
  | 'harness_state_incompatible'
  | 'workspace_resume_inconsistent'
```

Every failure carries a stable rule id and display-only detail. Consumers branch
only on the code and rule id. A failure identifies the workspace, declaration
revision, repository key, role, authority, protocol, and phase where safe; it
never includes a source URL or credential detail.

Minimum events are `workspace.bootstrap.started|ready|failed`,
`repository.ensure.requested|started|reused|completed|failed`,
`workspace.resumed`, and `workspace.released`. Events include reason,
idempotency identity digest, lock wait, source kind, requested/resolved ref
digests, materialization path (`cold | seed | existing`), duration, bytes
charged, and receipt id. A skipped or merely declared repository is never
reported as materialized. An ensure request with no completion event remains a
visible incomplete operation for adoption.

### D11 — Adoption sequence

Adoption is deliberately staged:

1. Land the v2 schema, key encoder, typed failures, secret scanners, and
   normative fixtures without changing default provisioning.
2. Ship the standalone declaration producer, source resolver, and default
   single-primary implementation behind exact protocol negotiation.
3. Ship idempotent lazy ensure with crash replay, concurrent-call fixtures, and
   structural read-only negative proof through the real executor.
4. Ship harness-state projection plus resume/re-verification and whole-root
   archive/release/adoption proofs.
5. Enable v2 only for new roots on explicitly capable executors; retain flat and
   v1 readers. Compare materialization, credential, disk, and resume signals.
6. Make v2 the default for new roots only after the standalone path and every
   supported executor pass the same conformance suite.
7. Retire older creation or read paths only by a separate decision satisfying
   D9.7. This proposal authorizes no retirement or activation.

Required RED/GREEN proof includes: root `.git` rejection; no network access from
path lookup; equivalent concurrent ensure returning one receipt; conflicting
ensure refusing; crash between stage and publication; credential-bearing clone
inputs leaving no secret in manifest, receipts, remote/config, argv capture, or
events; read-only writes failing while a mutable sibling succeeds; exact-version
resume; and old-executor projection/refusal in both directions.

### D12 — Unresolved decisions

The proposal intentionally leaves these for review before acceptance:

1. The exact repository-key restricted character set, maximum length, total
   path-length budget on the shortest supported filesystem, and portable
   handling of case-fold collisions. The name remains byte- and case-preserving;
   none of these choices may rewrite it.
2. Whether a selected lazy non-primary repository is ensured during admission
   or in the post-admission/pre-spawn adaptation phase. It must remain an
   explicit recorded call either way.
3. Per-repository and per-harness-state quota allocation within the root's one
   accounting envelope, including behavior when an ensure would exceed it.
4. Whether safe credential-free remotes are retained by default or all remotes
   are removed and reconstructed for every network operation.
5. Freshen policy for an already materialized read-only context repository. An
   exact idempotent replay must never move its ref; a separately requested
   update needs its own typed operation and receipt.
6. Toolchain composition when a lazy repository adds demands that conflict with
   the already-running root.

None permits magical path access, secret persistence, authority widening,
leaf-level ownership, or implicit protocol downgrade.

## Consequences

### Positive

- The workspace root cannot be mistaken for a checkout by structure.
- Sessions pay repository/network/credential cost only for declared repositories
  they actually need, while primary startup remains deterministic.
- One explicit operation makes lazy behavior testable, idempotent, observable,
  and recoverable.
- Repository authority and harness mutable state occupy disjoint executor-owned
  namespaces.
- Standalone operation remains complete and is the first conformance target.

### Negative

- Consumers must understand three root namespaces and may not derive checkout
  paths from prior layouts.
- The declaration producer and source resolver must remain available later in a
  session, not only at bootstrap.
- First access to a lazy repository can add visible latency or fail for a
  credential that primary bootstrap never needed.
- Flat, v1, and v2 roots coexist during migration.

### Risks

- A caller bypasses `EnsureRepository` by cloning into `repos/`; manifest and
  receipt validation must treat that leaf as undeclared inventory, never adopt
  it silently.
- A source tool rewrites credentials into a submodule or alternate config after
  the initial scan; the post-materialization whole-tree Git-config scan is
  therefore mandatory.
- Harness state grows without repository-visible disk usage; root accounting
  must include `state/` before activation.
- An old executor appears usable because the primary path works but silently
  loses a lazy dependency. Exact protocol negotiation and D9 refusal fixtures
  make that state unrepresentable.

## Alternatives considered

- **Eagerly materialize every declaration entry.** Rejected: pays unused
  latency, disk, and credential cost and makes repository availability a session
  start dependency even when the session never references it.
- **Clone on filesystem path access.** Rejected: hides network, credential, and
  authority side effects behind ordinary filesystem operations and has no
  explicit receipt or failure boundary.
- **Place harness state inside the selected repository.** Rejected: dirty-check
  and completion semantics become harness-dependent, read-only repositories
  become unusable as CWDs, and switching the selected repository moves session
  state by accident.
- **Give each repository its own lifecycle.** Rejected: multiplies leases,
  archives, adoption, accounting, and cleanup authorities inside one session,
  reversing the ownership decision already Accepted.
- **Rewrite legacy roots in place.** Rejected: layout conformance is not a reason
  to move or mutate a live session's filesystem.

## Affected documents

If this proposal is Accepted, the accepting commit must update:

- `003-workarea-provider.md` — v2 declaration, root layout, ensure operation,
  capabilities, and lazy lifecycle;
- `013-orchestrator-and-governor.md` — explicit pre-spawn ensure, harness-state
  projection, completion, and observability;
- `ADR-2026-08-22-session-owned-multi-repository-workarea.md` — D2 layout and
  materialization amendments while preserving root ownership and authority;
- `ADR-2026-07-07-sibling-context-repos.md` — context becomes a declared lazy
  repository under `repos/` while its compatibility projection remains explicit;
- `ADR-2026-08-05-versioned-execution-cell-and-session-reference.md` — exact v2
  protocol and authority attestations on the resolved cell and receipts;
- `ADR-2026-06-03-injectable-state-dir.md` — clarify that session-local harness
  state under the workspace does not replace the injectable host state home;
- `ADR-2026-08-06-harness-adaptation-plan-and-receipt.md` — exact-harness state
  projection and selected-repository ensure placement;
- `ADR-2026-08-17-session-shim-adoption.md` — versioned root adoption and
  incomplete-ensure recovery; and
- `README.md` and `AGENTS.md` — accepted-status summaries.

No affected reference document is edited by this Proposed draft.

## Affected work items

Downstream tracker linkage and implementation sequencing belong in the private
mirror. This public corpus carries no internal tracker identifiers.

## Implementation notes

Begin with the standalone producer and a filesystem fixture, not a downstream
adapter. The same fixture corpus must be reusable by alternate producers and
executors. A provider may optimize clone/materialization internally, but the
observable contract stays one declaration, one explicit ensure operation, one
receipt per repository key, and one root lifecycle.
