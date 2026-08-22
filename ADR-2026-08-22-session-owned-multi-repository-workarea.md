---
status: Accepted
date: 2026-08-22
boundary: OSS-only
---

# ADR-2026-08-22 — Session-owned multi-repository workarea

**Status:** Accepted — architecture decision; implementation, release, and
migration remain pending behind the proof obligations below.
**Date:** 2026-08-22
**Boundary:** OSS-only
**Authors:** execution-layer workarea lane

> **Accepted 2026-08-22.** Acceptance fixes the ownership boundary, the two path
> names, the on-disk layout, the role/authority/filter semantics, the
> root-bound lifecycle, the mixed-version compatibility law, and the migration
> posture. The accepting correction also fixes the executor-negotiation gate,
> the cache-seed/session-generation split, and the executor-owned read-only
> enforcement boundary. It does **not** claim a shipped multi-repository provisioner, a
> shipped declaration record, or an activated migration. The rest of the corpus
> continues to describe the current single-repository provisioning truthfully
> wherever it is described; this ADR is the target contract, not a report of
> current state.
>
> **No `retired-claim-lint.sh` rule is added by this ADR, deliberately.** The
> shared-parent sibling placement of `ADR-2026-07-07-sibling-context-repos.md`
> is *current shipped behaviour*, not a retired claim. Retiring a description of
> what the runner does today, on the strength of architecture that has not
> shipped, would make the linter enforce a fiction — the exact failure mode the
> linter exists to catch. The rule is added by the change that implements D2,
> not by this one.

## Context

A session's workspace is one repository. `runtime/worktree.Manager.Provision`
clones a single repo and hands the runner one path; the daemon's
`SessionHandle` carries one `worktreePath`
(`ADR-2026-06-13-daemon-sessionhandle-enrichment.md`); the completion contract
in `013-orchestrator-and-governor.md` speaks of "commits on branch, branch
pushed, PR created" in the singular; and `003-workarea-provider.md`'s
`WorkareaSpec.source` names exactly one `repository` and one `ref`.

That single-repository assumption has already been outgrown once, and the
workaround is where the trouble is.
`ADR-2026-07-07-sibling-context-repos.md` needed a second repository on disk —
the governing architecture corpus, so that a dispatched agent finds it at
`../<name>` exactly as every repo's `AGENTS.md` promises. Having nowhere
session-owned to put it, that ADR put it **beside** the session worktree, in
whatever directory happens to be the worktree's parent. Its own text records the
consequence: provisioning is "guarded by a per-target-directory mutex
(concurrent sessions may share a parent directory)". The mutex serialises
*provisioning*. It does not make the directory owned.

Four defects follow from that one missing owner, and they are not independent:

1. **Nothing cleans a context clone up.** Release, archive, and destroy all act
   on the repository worktree. A context clone in the shared parent is reachable
   by no session's release path, so it persists until an operator notices it.
2. **Nothing charges it to anyone.** The daemon's disk envelope
   (`capacity.poolMaxDiskGb`) accounts for workarea-cache entries. A clone in
   the shared parent is invisible to that accounting while being just as real on
   the disk that fills.
3. **Two sessions share one mutable directory.** Session A's best-effort
   `pull --ff-only` moves bytes under session B's feet mid-read. The mutex does
   not cover use, only provisioning, and no amount of locking fixes it while the
   directory has two claimants and one copy.
4. **A second *writable* repository is unrepresentable.** Sibling repos are
   read-only by contract. Work that legitimately spans two repositories — a
   contract change in this corpus and the change that implements it downstream,
   a schema and its generated client — has no session-owned shape at all. The
   agent's only option is to clone by hand into a directory nothing owns, which
   is defect 1 with extra steps.

One further pressure is structural rather than operational. `worktreePath` is a
single field answering two different questions — *where does this session's
state live?* and *what directory does the harness run in?* Those answers are the
same string only while there is exactly one repository. Adding a second
repository without separating them would silently change the meaning of a
shipped wire field, which is the compatibility failure this ADR most wants to
avoid.

Three accepted contracts constrain any fix:

- `ADR-2026-07-18-bounded-terminal-workarea-leases.md` binds exclusive ownership
  and the terminal lease to an *exact* workarea identity and host-local path. A
  multi-repository workarea must present one identity to that lease, not N.
- `ADR-2026-08-17-session-shim-adoption.md` makes `(org_id, session_id)` the
  sole lifecycle identity and requires adoption before capacity is advertised,
  from a discovery record that contains no secrets. Adoption must therefore find
  a session's filesystem state without a search and without persisting a
  credential.
- `ADR-2026-06-03-injectable-state-dir.md` makes the host state directory
  injectable by the embedding binary. Nothing here may hard-code a state home.

## Decision

The workarea becomes a **session-owned directory that may contain more than one
repository**. Ownership — cleanup, lease, archive, disk accounting, restart
adoption — binds that directory. Repository selection becomes an explicit,
typed, non-degrading choice inside it.

### D1 — Two names, two jobs

Two names replace the one overloaded path, and the corpus uses them exactly:

- **`workareaRoot`** — the absolute path of the **session-owned directory**.
  Exactly one associated root per session. An exclusive session owns its root;
  a shared participant associates to the parent's root through the durable
  `parentWorkareaId` mapping (D7.6), so one root may have multiple participants
  without acquiring multiple owners. It is the unit of ownership: what a lease holds, what
  a release disposes of, what an archive captures, what disk accounting charges,
  and what a replacement daemon adopts. It is not a repository and is never a
  working directory.
- **`repositoryWorktreePath`** — the absolute path of the **selected
  repository**, and the directory the harness is spawned in. It is always a leaf
  inside `workareaRoot` (with one degenerate legacy exception, D9).

**D1.1** — A caller that needs "where the session's state is" reads
`workareaRoot`. A caller that needs "where the agent is working" reads
`repositoryWorktreePath`. No consumer may derive one from the other by string
manipulation: the leaf name is a declaration output, not a computable function
of the session, and the degenerate legacy case (D9) makes them equal.

**D1.2** — `workareaRoot` is provider-independent. A workarea provider that
mints an execution context elsewhere (`003` § "Snapshot-aware implementations")
still returns exactly one root path in the address space the session executes
in. "Session-owned directory" is a contract about ownership and containment, not
about which machine holds the bytes.

### D2 — The layout is `worktree-root/session-id/repo-leaf`

```
<worktree-root>/                     host-owned, pre-existing, unchanged
  <session-id>/                      = workareaRoot        (session-owned)
    .workarea/                       reserved metadata leaf
    <repo-leaf>/                     one repository        (= repositoryWorktreePath when selected)
    <repo-leaf>/
    ...
```

- `<worktree-root>` is the host's existing worktrees directory under the
  injectable state home (`ADR-2026-06-03`). This ADR neither renames nor moves
  it. Where a host serves more than one scope, the scope qualifies
  `<worktree-root>`; it never becomes a fourth segment, so the three-segment
  shape above is invariant.
- `<session-id>` is the **root-owner session's** lifecycle identity under an
  injective, filesystem-safe encoding. For an exclusive acquire that is the
  acquiring session; for shared mode it remains the parent's identity. A shared
  participant resolves the same root through its durable `parentWorkareaId`
  descriptor, never by substituting the child id and never by searching the
  filesystem.
- `<repo-leaf>` is one repository. Leaf names live in a namespace that is
  **per session**, which is the whole substance of the change: two sessions
  materialising the same repository get two leaves that cannot alias.

**D2.1 — The `../<name>` promise is preserved byte-for-byte.** Under
`ADR-2026-07-07` a context repo sat at `<parent>/<name>`, beside the session
worktree at `<parent>/<worktree>`. Under this layout it sits at
`<workareaRoot>/<name>`, beside the selected repository at
`<workareaRoot>/<leaf>`. From the harness CWD the relative path is `../<name>`
in both cases. **No downstream repository's `AGENTS.md` changes, and no agent
instruction changes.** Only the owner of the directory changes.

**D2.2 — `.workarea/` is reserved.** The root carries a durable **declaration
record** under a reserved leaf: the declared repositories, their leaf names,
roles, authorities, requested and resolved refs, and the selected repository.
Every ownership decision in D7 reads that record. **No ownership decision reads
a directory listing.** A directory that is present but undeclared is an
inventory finding, not a repository; a repository that is declared but absent is
a provisioning failure, not a silent omission. Reserved leaf names are refused
to declared repositories (D5).

**D2.3 — The record holds no credential.** `ADR-2026-07-07` explicitly permits a
repository URL to carry whatever auth the dispatcher embedded in it. A URL of
that shape is a bearer secret. The declaration record and the shim discovery
record therefore persist **leaf names, roles, authorities, and resolved refs —
never repository URLs**. URLs are re-supplied at provision and freshen time from
the place credentials already live. This is what keeps `ADR-2026-08-17` D6
("discovery records contain no secrets") true once adoption needs to know about
repositories at all; persisting the convenient thing would have quietly written
credentials into a registry that had been proved secret-free.

### D3 — Three roles, and `primary` is a default selection only

Every declared repository carries exactly one role:

| Role | Materialised | Default authority | Meaning |
|---|---|---|---|
| `primary` | always | `mutable` | The default selection. Exactly one per workarea. |
| `secondary` | per session, under the root | `read-only` | An additional repository the session may be granted authority over. |
| `context` | per session, under the root | `read-only` | Reference material. The destination `DONMAI_SIBLING_REPOS` entries now land in. |

**D3.1 — `primary` confers nothing but a default.** It names which leaf
`repositoryWorktreePath` points at when the work item selects no repository. It
does **not** confer a longer lifetime, a different lease, priority in cleanup, a
larger disk allowance, or exemption from any rule in D7. Every rule in this ADR
that speaks of "a repository" speaks of all three roles identically unless it
names a role.

**D3.2 — `secondary` and `context` are per-session leaves.** Both are
materialised under `workareaRoot`, never in a shared parent, never in a
host-global cache directory reachable by another session's mutation path. This
is the clause that closes context-clone defects 1–3.

**D3.3 — Role does not imply authority.** The default-authority column above is
a default at declaration time, not an inference rule at use time. See D6.

### D4 — Repository filter semantics are explicit and never degrade

Everywhere the execution layer needs to answer "which repository?", it uses one
closed filter grammar:

```ts
type RepositoryFilter =
  | { kind: 'primary' }                                        // the default selection
  | { kind: 'named'; name: string }                            // one declared repository, by declared name
  | { kind: 'role'; role: 'primary' | 'secondary' | 'context' }
  | { kind: 'all' }
```

Six resolution rules, all fail-closed:

1. **Resolution is against the declaration record, never the filesystem.** A
   filter names declared repositories. A leaf that exists on disk without a
   declaration resolves to nothing.
2. **An absent filter means `{ kind: 'primary' }`.** That is the only implicit
   rule in this ADR, and it is a default *selection* — never a default
   *authority* (D6) and never a fallback (rule 4).
3. **A filter naming an undeclared repository is a typed error.** It is not an
   empty result and it is not a fallback to `primary`. The distinction matters
   because the failure it prevents — a caller believing it addressed repository
   B while the runtime silently addressed A — is invisible in every log that
   only records what ran.
4. **Zero matches is a typed error, never an empty success.** `{ kind: 'role',
   role: 'secondary' }` against a workarea with no secondary is an error at any
   site that requires a repository, and an explicitly empty set only at a site
   whose contract admits one (freshening, inventory).
5. **More than one match where exactly one is required is a typed error, never
   "first wins".** `repositoryWorktreePath` selection requires exactly one.
   Ordering in the declaration is a rendering convenience and confers no
   tie-break authority.
6. **A `context` repository is excluded from any filter feeding a mutation
   site** — commit, push, branch creation, completion-contract evaluation —
   unless it is named explicitly by `{ kind: 'named' }` *and* declares `mutable`
   authority. `{ kind: 'all' }` never reaches a mutation site through a role it
   did not name.

Every typed error above carries a closed reason code plus a stable rule id, with
human-readable detail display-only and no consumer branching on it — the
exclusion shape ratified in
`ADR-2026-08-13-capability-realization-registry-and-viability-of-absence.md`
D4.1. This ADR reuses that shape rather than inventing a second one.

### D5 — Leaf names are collision-safe by refusal, not by disambiguation

1. A leaf name is the repository's declared `name` when one is declared;
   otherwise it is derived from the URL basename with any `.git` suffix
   stripped — the derivation `ADR-2026-07-07` already uses, unchanged.
2. A leaf name must be non-empty, contain no path separator, be neither `.` nor
   `..`, not begin with `.`, fall within a declared length bound, and match a
   restricted character set. A name failing validation is a declaration error.
3. Reserved names (`.workarea` and any future reserved leaf) are refused to
   declared repositories. Rule 2's no-leading-dot requirement makes the reserved
   namespace unreachable by construction rather than by an exclusion list that
   must be maintained.
4. **Two declared repositories deriving the same leaf name is a declaration
   error naming both entries — never an automatic rename.** Silent
   disambiguation (`corpus`, `corpus-2`) would make the path unpredictable, and
   an unpredictable path breaks the `../<name>` promise of D2.1 for whichever
   repository lost the coin flip. Refusing at declaration time is loud, early,
   and fixable by the author; renaming is quiet, late, and fixable by nobody.
5. Cross-session collision is structurally impossible: the namespace is scoped
   by `<session-id>` (D2). `ADR-2026-07-07`'s "collision with the session
   worktree itself" rejection is subsumed by rules 2–4 and needs no separate
   check.

### D6 — Mutable authority is declared per repository and defaults closed

Each declared repository carries an explicit `authority` of `read-only` or
`mutable`.

1. **Authority is declared per repository, never inferred from role.** The
   defaults in D3's table apply at declaration; absence of a declaration is
   `read-only`. A `secondary` repository does **not** become writable by being
   secondary.
2. **Authority is a property of the repository, not of the CWD.** Selecting a
   `read-only` repository as `repositoryWorktreePath` is legal — an agent may
   need to run tooling there — and grants no write. This is the reason authority
   and selection are separate concepts rather than one flag.
3. **A `read-only` repository is outside the completion contract.** Commits,
   branches, and pull requests are required, checked, and backstopped only on
   `mutable` repositories. A `read-only` repository is never a reason for a
   session to fail its contract, and its state is never backstopped.
4. **Freshening is a read-only-repository affordance and stays non-fatal.** The
   best-effort `pull --ff-only` posture of `ADR-2026-07-07` is preserved
   verbatim for `context` repositories: failure keeps the stale copy, logs a
   warning, and never fails the session.
5. **Authority is fixed for the life of the workarea.** It is set at
   declaration and not escalated mid-session. A session that needs write access
   it was not granted fails closed with the D4 typed error, paired with a
   signal — never silently, per
   `ADR-2026-08-07-onboarding-is-the-only-user-action.md` D5.
6. **The executor enforces authority at the filesystem boundary.** The selected
   execution cell must attest `repositoryAuthorityEnforcement:
   'isolated-read-only-v1'` before any declared `read-only` leaf is
   materialised. That attestation means the harness process cannot write,
   rename, remove, change permissions on, or remount the leaf while a declared
   `mutable` sibling remains writable. The typed mutation filters in D4 are
   defense in depth; they are not the permission boundary for arbitrary shell
   and file-edit tools.
7. **Same-identity permissions are not enforcement.** A writable checkout made
   superficially read-only with `chmod` while the harness runs as the owning uid
   does not satisfy rule 6: the process can undo it. Prompt instructions,
   post-hoc dirty checks, and completion-contract exclusion likewise do not
   qualify. The boundary must be an executor-owned mount, sandbox policy, or
   equivalent isolation primitive the harness cannot widen.
8. **No enforcement means no viable candidate.** A cell unable to attest rule 6
   is excluded with a closed reason code and stable rule id before admission. It
   never receives a read-only declaration and never "degrades" by cloning the
   repository writable. This is a stage-2 viability exclusion under
   `ADR-2026-08-12-placement-composition-law-and-single-fallback-rule.md`.

### D7 — Cleanup, leases, archives, disk accounting, and restart adoption all bind the session root

This is the clause the rest of the ADR exists to support. Every lifecycle
authority binds `workareaRoot`; none binds a leaf.

1. **Cleanup is one operation on the root.** `release(workarea, mode)` applies
   one disposition to the root and every leaf inside it. `destroy` and
   `return-to-pool` end and remove the session generation; `pause` and `archive`
   may preserve it only for resume/restore under the **same** session identity.
   No leaf is removed independently while the session lives, no live leaf
   transfers to another session, and no leaf can outlive its owning generation
   as reusable workspace state. This is what makes the orphaned-context-clone
   class unreachable rather than merely discouraged.
2. **The terminal lease holds the root.**
   `ADR-2026-07-18-bounded-terminal-workarea-leases.md` invariant 2 ("exact
   identity is preserved") reads on `workareaRoot`: the lease binds one root
   identity and host-local path, and holding it holds every leaf. Invariant 1's
   "cannot be joined in shared mode or selected for another acquire" likewise
   applies at the root. A per-leaf lease is not defined and must not be
   introduced — N leases over one directory tree reintroduce exactly the
   split-ownership defect this ADR removes.
3. **Archive and restore are whole-root operations.** `release(archive)`
   captures the root, every leaf, and the declaration record; restore restores
   the root. A capture of one leaf is not a workarea archive and must not be
   presented as one, because restoring it would produce a workarea whose
   declaration record and filesystem disagree.
4. **Disk accounting separates seeds from generations.** A session's charge is
   the physical storage attributable to `workareaRoot`, every leaf included.
   A reusable cache seed has its own cache identity and charge and is never
   charged as a session. For a full copy, seed bytes and copied bytes are two
   physical allocations and are charged to their respective owners; for
   copy-on-write materialisation, shared base blocks are charged to the seed and
   private blocks to the session generation. The same physical allocation is
   never charged twice. Context clones move from charged-to-nobody to a named
   seed or exactly one session generation, which is the point.
5. **Restart adoption adopts a root, not a search.** For an owning session the
   root is computed from its lifecycle identity (D2). For a shared participant
   the adopting daemon follows the already-durable `parentWorkareaId` descriptor
   to that same root. Neither path performs a filesystem walk or leaf-level
   reconciliation; the declaration record answers what the root held. Each
   participant's lifecycle identity remains its own `(org_id, session_id)` —
   `parentWorkareaId` and `workareaRoot` are correlations and can never create,
   release, terminalise, or re-key a session.
6. **Shared mode joins the root.** `003`'s `mode: 'shared'` with
   `parentWorkareaId` joins the parent's `workareaRoot` and inherits its whole
   leaf set. A sub-agent may select a different `repositoryWorktreePath` within
   that shared root. The durable participant descriptor records
   `parentWorkareaId`; the root path continues to use the owner/parent session
   id, never the child id. Reference counting on release is at the root,
   unchanged in substance from `003` § "Sharing model".
7. **Ownership decisions are ordered.** At boot the daemon reads the
   acquisition-quarantine journal, then leases, then the declaration record —
   the order `011` already prescribes — and only then classifies the root. A
   quarantined, leased, or unreconciled root is never partially reclaimed leaf
   by leaf.
8. **A cache seed is not a workarea.** The local warm cache may retain a base
   clone, prepared dependency tree, snapshot, or copy-on-write seed outside all
   session roots. `acquire` materialises that seed into a fresh
   `<session-id>` root with a new `Workarea.id`, declaration record, lease
   generation, accounting record, and observation cursor. `return-to-pool` may
   validate/update or publish a separate seed, then removes the session root; it
   never marks that root `ready` for another session. A seed is never a harness
   CWD, never adopted by a daemon as a session, and never carries a session
   cursor. The `return-to-pool` wire literal keeps its intent — retain reusable
   prepared state — without transferring filesystem identity across sessions.

### D8 — Mixed-version compatibility is additive, and droppable iff read-only

1. **Every field this ADR adds is optional and additive.** No wire field is
   renamed and no field's meaning changes. Where a new noun is needed, a new
   optional field is added beside the old one.
2. **`worktreePath` keeps its meaning *and* its value.** The
   `ADR-2026-06-13-daemon-sessionhandle-enrichment.md` field continues to carry
   the harness working directory — which is now `repositoryWorktreePath`. New
   readers read a new optional `workareaRoot` beside it. Repurposing
   `worktreePath` to mean the root would silently change what every shipped
   reader displays, and derived values like `projectName` are computed from it.
3. **The producer negotiates before it emits.** The orchestrator/work-item
   assembler is the declaration producer; the exact bound executor/runner is the
   consumer. Executor registration attests a versioned workarea protocol, and
   the paired workarea provider advertises
   `multiRepositoryWorkareaProtocols`. The producer emits a
   `repositoryDeclaration` or non-default `RepositoryFilter` only after the
   selected execution cell attests the exact `session-root-v1` protocol. The
   attestation is re-checked at bind/claim; it is never inferred from binary
   version, pool membership, or a remembered host capability.
4. **An old peer receives only representable legacy intent.** A request whose
   effective intent is the default mutable primary may be encoded using the
   existing singular source fields. Droppable `read-only` context is omitted
   entirely for that executor, including removal of the corresponding
   `DONMAI_SIBLING_REPOS` entry; the producer never asks an old runner to clone
   a new authority-constrained repository writable. A non-default selection,
   any non-primary `mutable` repository, or any non-droppable declaration whose
   read-only authority requires rule D6.6 is not sent to an old/unsupported
   executor: that candidate is excluded and, when no candidate survives,
   admission fails with a typed reason. An old runner is never asked to inspect
   a field it does not understand, so silent primary fallback is structurally
   unavailable.
5. **Concrete additive surfaces**, each optional, each with the old field
   retained:
   - `003`'s `WorkareaSpec` gains an optional versioned
     `repositoryDeclaration` beside its existing singular `source`; the primary
     entry must match `source`, and mismatch is typed rather than precedence;
   - `SessionHandle` gains optional `workareaRoot` beside `worktreePath` (rule 2);
   - `GET /api/daemon/sessions` / `…/<id>` and `GET /api/daemon/workareas` /
     `…/<id>` gain optional root and leaf detail; `<id>` addresses a root;
   - the `ADR-2026-08-17` D3 shim discovery record gains an optional, secret-free
     `workarea_root` (D2.3);
   - the turn-result manifest (`ADR-2026-06-15-turn-result-manifest.md`) gains an
     optional per-repository member; absent means the selected repository, so
     `schemaVersion` stays `1`.
6. **`DONMAI_SIBLING_REPOS` is unchanged on the wire.** Same variable, same
   comma-separated `<git-url>[#ref]` grammar, same never-fatal posture. Only the
   destination directory and its owner change. An old runner honouring it puts
   the clone in the shared parent; a new runner puts it in a `context` leaf; the
   agent sees `../<name>` either way (D2.1). A legacy work item authored solely
   with this env retains current behavior before activation; that behavior is
   not an `isolated-read-only-v1` attestation and cannot satisfy a new
   authority-constrained declaration. When rule 4 drops such context for an old
   executor, the producer omits the env entry as well.

### D9 — Retained legacy flat workareas are adopted degenerately, never rewritten

A **legacy flat workarea** is the shipped shape: a repository checkout directly
at `<worktree-root>/<leaf>`, with context clones, if any, beside it in the
shared parent.

1. **Read in place; never rewrite.** A retained legacy workarea is recognised by
   shape and adopted as a one-repository workarea whose `workareaRoot` **is** the
   legacy directory and whose single `primary` leaf is that same directory. This
   is the one permitted case where `workareaRoot == repositoryWorktreePath`, and
   D1.1 forbids any consumer from assuming it never happens. Moving a live
   session's directory to satisfy a layout is a destructive migration performed
   for tidiness; it is refused.
2. **New workareas always use the D2 layout.** Migration is by natural turnover.
   There is no in-place conversion step, no migration window, and no flag day.
3. **A legacy workarea is never extended.** It has no session-owned directory
   into which a second leaf could go. A multi-repository work item arriving where
   a legacy flat workarea would otherwise be reused provisions a **new-layout
   root** instead; the legacy one is left alone and ages out.
4. **Pre-existing shared-parent context clones are not adopted, not charged, and
   not deleted by this ADR.** They are precisely the unowned class D3.2 removes
   going forward, and a session release that deleted one could delete another
   live session's context. They are reported as an **unowned-legacy** condition
   in host disk accounting and reclaimed by an explicit operator action or by
   ordinary host maintenance — never automatically by a session release. Per
   `ADR-2026-08-07-onboarding-is-the-only-user-action.md` D7 that condition rides
   the host-status signal outward rather than living only in a log file.
5. **Exit condition.** When no retained legacy flat workarea remains on any
   supported host, rule 1's degenerate case is deleted from this contract and
   `workareaRoot == repositoryWorktreePath` becomes unrepresentable. Recording
   the exit condition is what keeps the degenerate case from becoming permanent
   by default.

### D10 — What this ADR does not decide

Named so they are not read in by implication:

- **Cross-repository atomic landing.** Coordinating one logical change across
  two pull requests in two repositories is a completion-contract and
  merge-ordering question. `ADR-2026-06-15-deterministic-merge-landing.md` owns
  that seam; this ADR only makes the second repository *exist* and *be
  writable*.
- **Per-repository toolchain composition.** `WorkareaSpec.toolchain` and the kit
  detect/provide lifecycle (`005`) are unchanged. Whether two leaves may demand
  conflicting toolchain versions in one root is deferred to the change that
  implements D2, with the fail-closed default: a conflict is a typed
  provisioning error, not a last-writer-wins resolution.
- **Renaming the `pool`-spelled daemon surface.** `ADR-2026-08-07` D2.3/D2.4
  authorises that rename and it remains unimplemented. This ADR adds no
  `workarea`-spelled endpoint, flag, or config key, and `capacity.poolMaxDiskGb`
  is named here at face value as the current key.
- **Multi-repository code-intelligence indexing.** The in-box server's explicit
  `--root` contract (`ADR-2026-07-05`) is unchanged; which leaf it indexes is an
  implementation choice recorded when D2 ships.

## Acceptance and proof obligations

Acceptance ratifies the contract. Activation requires all of:

1. A provisioner that consumes `003`'s versioned declaration carrier,
   materialises the D2 layout, writes the D2.2 declaration record, and refuses
   D5 duplicates with both offending entries named.
2. A fixture proving D2.1: from `repositoryWorktreePath`, a declared `context`
   leaf resolves at `../<name>`, for a declaration whose entries arrived via
   `DONMAI_SIBLING_REPOS` unchanged.
3. A fixture proving D2.3: neither the declaration record nor the shim discovery
   record contains a repository URL, asserted against a declaration whose URL
   carries embedded auth.
4. A fixture proving D4 rules 3–5: an undeclared name, a zero-match filter, and
   a multi-match single-selection filter each produce a typed error with a
   closed reason code and stable rule id — not a fallback to `primary`.
5. A fixture proving D6.3: a session whose only failure is an untouched
   `read-only` repository passes its completion contract.
6. A release/adoption test proving D7.1, D7.5, and D7.6: one release disposes of
   every leaf; a restarted daemon computes an owner's root from identity; and a
   shared participant reaches the same root through its durable
   `parentWorkareaId` descriptor, all with no filesystem walk.
7. A mixed-version matrix proving D8.3 and D8.4 in both directions: an old
   executor sees no declaration field; default-primary intent still runs; a
   non-default or non-primary-mutable request is refused before admission; and
   removing the executor's `session-root-v1` attestation makes that refusal RED
   for the exact reason.
8. A migration test proving D9.1 and D9.3: a legacy flat workarea is adopted
   degenerately, and a multi-repository item provisions a new root beside it
   rather than extending it.
9. A cache-generation test proving D7.8: two sessions materialised from one seed
   have different root paths, `Workarea.id` values, declarations, leases,
   accounting records, and observation cursors; `return-to-pool` removes the
   first root and never makes it adoptable by the second.
10. A read-only authority negative proof: from the real harness, write, rename,
    remove, permission-change, and remount attempts fail on a read-only leaf
    while a mutable sibling accepts a write. Replacing the executor enforcement
    with same-uid `chmod` or `none` must make viability or the fixture fail. The
    test must run through the production executor binding, not a helper that
    re-implements the policy.

Until 1–10 pass against the exact released artefacts, no consumer capability may
be advertised as depending on a multi-repository workarea.

## Consequences

### Positive

- The orphaned-context-clone class becomes unreachable rather than discouraged:
  one owner, one release, one charge.
- Cross-repository work becomes expressible for the first time, with authority
  declared per repository and defaulting closed.
- Old executors cannot silently erase non-default or mutable intent: the
  versioned protocol gate runs before admission and before declaration emission.
- Warm-cache performance remains available without reusing a prior session's
  root, lease, or observation cursor.
- Disk accounting stops lying by omission — every byte a session put on disk is
  charged to that session.
- Restart adoption gets simpler, not harder: one root computed from identity
  replaces a search that never existed and would have been needed.
- Nothing an agent reads changes. The `../<name>` promise every `AGENTS.md`
  makes is preserved exactly (D2.1).

### Negative

- One more concept. "Workarea" now has an inside, and two path names must be
  used precisely where one sloppy one used to do.
- Two legitimate on-disk shapes coexist for the whole migration window (D9),
  including a degenerate case where the two path names are equal.
- Deeper paths. Adding a `<session-id>` segment costs path budget on hosts with
  short limits, and deeply nested toolchain directories already sit near them.
- Per-session context clones trade shared-copy disk savings for correctness. A
  host running N sessions against the same corpus now stores N copies.
- Cells without a genuine filesystem isolation primitive cannot host declared
  read-only leaves, including unsandboxed same-uid local execution. That reduces
  eligible capacity until the executor ships and proves the boundary.

### Risks

- **A consumer derives one path from the other.** D1.1 forbids it and the
  degenerate legacy case (D9.1) makes it wrong rather than merely fragile, but
  the two strings are equal on exactly the hosts most likely to be used for
  testing — so the bug reproduces nowhere it would be caught.
- **A leaf-level lease gets introduced for a plausible local reason.** D7.2
  forbids it explicitly because the argument for it ("this leaf is only
  reference material") is always locally reasonable and globally wrong.
- **The disk cost of per-session context clones bites a dense host first.**
  Mitigation is a provider concern (reference clones, copy-on-write leaves), not
  a reason to re-share a mutable directory.
- **Migration never finishes** because D9's turnover has no forcing function.
  D9.5's exit condition is the countermeasure; without it the degenerate case
  becomes permanent by inattention.
- **A producer trusts a stale capability snapshot.** D8.3 requires an exact
  bind/claim re-check. Without it, a host can lose the protocol or enforcement
  capability after placement and still receive a declaration it cannot honor.

## Alternatives considered

- **Keep siblings in the shared parent and add a reference count.** Rejected: it
  makes the shared directory's lifetime correct without making its *contents*
  safe. Defect 3 — one session freshening while another reads — survives
  untouched, and a reference count over a directory no session owns is a fifth
  authority over the same bytes.
- **Give every repository its own workarea, and give a session N workareas.**
  Rejected: it multiplies the lease, archive, accounting, and adoption
  identities by N, directly against `ADR-2026-07-18`'s exact-identity invariant
  and `ADR-2026-08-17`'s single-identity rule. It also has no place to record
  which of the N is the CWD.
- **Repurpose `worktreePath` to mean the root and add a new field for the CWD.**
  Rejected: it changes the meaning of a shipped field's existing value. Every
  old reader keeps working, displays a path, and is wrong — the worst
  compatibility outcome, and precisely what D8.2 is written to prevent.
- **Auto-disambiguate colliding leaf names (`corpus`, `corpus-2`).** Rejected:
  it converts a loud, early, author-fixable declaration error into a quiet,
  late, unpredictable path — breaking D2.1 for whichever repository lost.
- **Migrate live legacy workareas in place at daemon start.** Rejected: moving a
  running session's directory for tidiness is a destructive migration with no
  forcing need. Natural turnover costs a migration window and no data.

## Affected documents

Updated in the accepting commit:

- `003-workarea-provider.md` — § "The interface": `Workarea.path` is fixed as
  `repositoryWorktreePath`, an optional `workareaRoot` and the versioned
  declaration carrier are added, and the local cache becomes seed material
  rather than reusable session identity; § "Sharing model" gains the root-join
  rule (D7.6).
- `004-sandbox-capability-matrix.md` — executor-owned read-only enforcement is a
  typed viability capability; current providers truthfully attest `none` until
  the negative proof passes.
- `011-local-daemon-fleet.md` — new § "Session-owned multi-repository workarea",
  plus root-bound amendments to § "Recovery from crash" and the disk-full
  remediation.
- `013-orchestrator-and-governor.md` — § "Sibling context repos" reconciled to
  the `context`-leaf destination; § "Completion contracts and backstop" gains
  per-mutable-repository evaluation.
- `ADR-2026-07-07-sibling-context-repos.md` — amendment note: destination and
  owner change, wire and non-fatal posture preserved.
- `ADR-2026-08-17-session-shim-adoption.md` — amendment note outside the
  synchronized region: the optional secret-free `workarea_root` correlation
  field and root-bound adoption. The `BOUNDARY-SYNC` region is untouched, so no
  paired PR against the sibling corpus is required.
- `README.md`, `AGENTS.md` — ADR index entries.

## Affected work items

None recorded here. This corpus is public; per `AGENTS.md` § Boundary and
`BOUNDARY.md`, cross-references to the organisation's internal tracker belong in
the sibling `rensei-architecture` extension docs, never in OSS-canonical text.

## Implementation notes

The producer/executor handshake and provisioner are the load-bearing changes.
The producer retains repository intent before placement, filters for a cell
that attests `session-root-v1` plus any required read-only enforcement, and only
then emits `003`'s declaration carrier. The provisioner grows from "clone one
repo to a path" into "materialise a declared set under a root and write the
declaration record". `ADR-2026-07-07`'s sibling loop becomes the `context`-role
branch of that provisioner rather than a separate post-provision step, which is
what lets its per-target-directory mutex disappear — the leaf namespace is
per-session, so there is no shared target to serialise on.

The local provider's warm object is a seed/base, not an acquired workarea. Every
acquire creates a new session generation; every terminal return ends that
generation. The executor applies repository authority while binding the
generation, before the harness starts, and refuses the cell if it cannot make a
read-only leaf non-widenable by that harness.

The change that implements D2 adds the `retired-claim-lint.sh` rule this ADR
deliberately withholds, retiring the shared-parent sibling placement at the
moment it stops being true.
