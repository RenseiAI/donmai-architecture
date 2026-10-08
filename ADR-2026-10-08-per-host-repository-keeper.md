---
status: Proposed
date: 2026-10-08
boundary: shared
split: sibling-extensions
---

# ADR-2026-10-08 — Per-host repository keeper

**Status:** Proposed. Nothing in this ADR is built. It grants no implementation,
release or activation authority until it is accepted.
**Date:** 2026-10-08
**Boundary:** shared. The keeper is execution-layer plumbing and ships working
in the OSS daemon for a single-tenant host: mirror storage, fetch coalescing,
seeding, pinned read-only checkouts, locks, maintenance, budgets and the
credential-scope seam. Three things belong in implementation-specific
extensions:

- how a control plane derives credential scopes on a host that serves more
  than one organization;
- whether it pins context commits at dispatch;
- whether placement prefers hosts that already hold a mirror.

**Authors:** architecture lane (research agent), answering an owner question
about repeated clones on shared seat hosts.

## Context

### The question

Sessions are starting to receive more than one repository: a mutable primary,
plus read-only `context` repositories such as this corpus. Should each host
keep one central copy of each repository and seed work areas from it, instead
of cloning every repository from the git host for every session? What else
should a host do once, rather than once per seat?

### What the code does today

Cited against `donmai` at the time of writing.

1. **In practice there is one strategy: a full network clone per session.**
   - The runner selects `StrategyClone` for every session that has a
     repository, headless or interactive (`runner/loop.go`:
     `worktreeProvisionStrategy`, and the single `Provision` call in
     `runLoop`).
   - The clone runs inside the per-session worker, with that session's own git
     credential.
   - The flat path passes no reference. `provisionLayoutOnce` calls
     `provisionOnceWithReference(..., "", ...)` in `runtime/worktree/manager.go`.
   - So the command is a plain `git clone [--branch <ref>] <remote> <dst>`, with
     no `--reference`, no `--depth` and no `--filter`.
2. **The building blocks exist, but the dispatch path uses none of them.**
   - **`git clone --reference <path> --dissociate`** is wired only to a cache
     seed of a `session-root-v1` declaration (the `seeds.Ensure` branch of
     `provisionLayoutOnce`). The dispatch wire can carry `cacheSeedId`, but no
     dispatcher we found sends one, and the reference host has no seed store.
   - **`StrategyWorktreeAdd`** (`git worktree add` from a parent clone) has a
     coalesced base fetch per (parent, ref) and a parent lock (`refreshBase`,
     `acquireParentWorktreeLock`). The runner never selects it. Its locks are
     in-process only, while each session's worker runs as its own process.
   - **Sparse declarations** use `--filter=blob:none --sparse`.
   - **The workarea cache of `003`** has its `pool`-spelled stats and evict
     surfaces. No stats provider is wired, so the surface always reports an
     empty cache.
   - **`projects[].cloneStrategy`** (`shallow` by default, `full`,
     `reference-clone`) is parsed, defaulted and validated, and `011`
     documents it, but nothing passes it to provisioning. The reference host
     sets `shallow` on every configured repository, yet only one of the 156
     clones on its disk is shallow.
   - **The sibling placement** of `ADR-2026-07-07-sibling-context-repos.md` is
     the only shared copy. It keeps one shallow clone per context repository
     beside the session directories, shared by every session and freshened with
     `git pull --ff-only` under a file lock (`runner/siblings.go`). Any session
     on an unconfined host can write to it, and it goes stale whenever
     freshening fails. On the reference host an operator now refreshes it with
     a scheduled job.
3. **One component already is a keeper.** The code-intelligence host
   (`runtime/codeintelhost/git.go`):
   - keeps one bare mirror per catalog repository, at a path derived from a
     digest of the repository identity;
   - verifies the mirror's origin before reuse, and fails closed on a mismatch;
   - serializes clone and fetch per repository;
   - fetches once when a requested commit is missing;
   - checks out one detached worktree per exact commit;
   - resolves credentials per invocation and never persists them.

   This ADR generalizes that design to session work areas.

### What the corpus already decides

The keeper fits inside decisions that are already Accepted. It must not reopen
them.

- **Seeds live outside session roots.**
  `ADR-2026-08-22-session-owned-multi-repository-workarea.md` D7.8 allows a
  host to retain "a base clone, prepared dependency tree, snapshot, or
  copy-on-write seed outside all session roots". Every acquire still creates a
  fresh root with its own identity.
  - D7.4 charges seed bytes to the seed and private bytes to the session, and
    never charges a byte twice.
  - Its Risks section names reference clones and copy-on-write leaves as the
    mitigation for per-session context clones.
  - D3.2 forbids materialising a `secondary` or `context` leaf "in a
    host-global cache directory reachable by another session's mutation path".
  - D6.6–D6.7 require executor-enforced read-only authority. Same-user `chmod`
    is not enforcement.
- **Lazy materialization (Proposed).**
  `ADR-2026-08-30-workspace-root-and-lazy-repository-materialization.md` lets
  a provider "optimize clone/materialization internally", behind one
  `EnsureRepository` call and one receipt per repository.
  - Its D6 requires that no credential survives in `.git/config`, alternate
    stores or worktree metadata after materialization.
  - Its D7 keeps "warm repository objects" as provider-owned seeds outside
    session roots.
- **Confinement.** `ADR-2026-10-03-executor-os-confinement.md` sets four rules
  that apply here.
  - D2 makes everything outside a closed writable set read-only to a confined
    harness, including the host state home and any shared git common
    directory.
  - D2.2: caches are "seeded, not shared". A warm cache may be exposed
    read-only.
  - D2.3: writable leaves are never hard-linked to inodes outside the set.
  - D2.4: a confined session's mutable leaves are self-contained repositories
    that may borrow objects from a base clone read-only through alternates. A
    worktree-add session is not confinable.
  - Read confinement (`fileRead`) is deferred by its D7. It is not corpus law
    that a seat cannot read daemon-private paths.
- **The clone verb.** `008` requires the workarea provider to clone through the
  configured VCS provider's `clone` verb.
- **Ephemeral clones.** `ADR-2026-06-01-code-survival-pool-execution.md` locks
  an ephemeral-clone posture, never a long-lived clone, for one work type that
  runs in a user's capacity pool.
- **Root-bound liveness.** `ADR-2026-07-18-bounded-terminal-workarea-leases.md`
  and `ADR-2026-10-07-headless-session-shim-adoption.md` keep a root and
  everything it references alive while it is leased, release-pending,
  quarantined or parked for resume. `011` forbids any sweep from using "looks
  orphaned" or "nothing touched this recently" as its criterion.

### What it costs

These measurements come from one shared macOS reference host: 32 cores, one
daemon serving several projects. They cover the 7.4 days ending 2026-10-08 and
are host-local, read from the work-area directory and the daemon's own log.

| Measure | Value |
|---|---|
| Session work areas provisioned | about 265 a day; one TypeScript monorepo accounts for 74% of them |
| Transfer per clone (first pack) | 79 MB (the TS monorepo), 18 MB (a Go module), 116 MB and 9 MB (two smaller repositories) |
| Transfer from the git host | about 18 GB a day, nearly all of it objects the host already held |
| Redundancy | the monorepo's default branch moved 29 times in a day while the host cloned it 113 times; 13 same-day clones still on disk held 6 distinct tips; consecutive tips differ by kilobytes |
| Clone wall time, monorepo | p50 5 s, p90 8 s, max 45 s, which is about a third of the p50 of 15 s from work-area creation to the harness's first event |
| Bursts | up to 9 clones of the same repository in one minute (fan-out waves) |
| Disk | 166 work areas retained, the oldest 40 days old; `.git` is 10 GB of their 227 GB (4–5%); installed dependencies (about 1.6 GB per JS work area) dominate; archived work areas hold another 47 GB |

The same strategies were timed on the same monorepo (about 9,700 files and a
75 MB pack) from a laptop with a slower link than the reference host:

| Strategy | Time | `.git` size |
|---|---|---|
| full network clone (today) | 18.2 s | 88 MB |
| `--filter=blob:none` network clone | 15.5 s | 51 MB |
| `--depth 1` network clone | 12.0 s | 33 MB |
| one-time bare mirror | 16.8 s | 85 MB |
| no-op mirror fetch | 0.6 s | — |
| `clone --reference <mirror> --dissociate <remote>` | 2.5 s | 74 MB |
| `clone --reference <mirror> <remote>` (alternates kept) | 1.7 s | 2.4 MB |
| local clone from the mirror path | 1.5 s | 88 MB (hard links) |
| `worktree add --detach` from the mirror | 1.1 s | — |
| `git archive <commit>` from the mirror into a directory | 2.0 s | — |
| copy-on-write clone of a checkout (`cp -c -R`, APFS) | 1.3 s | — |

Blobless and shallow clones barely help, because the time goes to talking to
the git host, not to the size of the history. Everything seeded from a local
mirror costs 1–3 s, and most of that is checking out files.

### Forces

- **Confinement.** A confined seat cannot write outside its writable set.
  - Shared sibling clones beside the work area stop working for it.
  - A shared writable clone was never safe for an unconfined seat either. That
    is defect class 1–3 of `ADR-2026-08-22`.
- **Per-repository credentials.** A seat's git credential covers only the
  repositories its session declares. A keeper must not become a way around
  that.
- **Hosts that serve more than one organization.** One host may serve several
  organizations, and sometimes the same repository through two different
  grants. A shared copy must never let one grant observe what another grant
  fetched.
- **Context repositories multiply clones.** Once a project binds two corpora
  as read-only `context` repositories, every seat on that project clones them
  too. `provisionLayoutOnce` clones each declared repository.
- **New hosts.** Linux seat hosts are arriving, with mount-namespace
  confinement, read-only binds and per-seat cgroups. A read-only bind is the
  natural way to hand a seat an immutable tree.

## Decision

Each host's daemon owns one **repository keeper**.

- It keeps one bare mirror per (repository, credential scope), and it alone
  fetches into that mirror, at most once per freshness interval.
- Mutable repositories are seeded from the mirror with
  `git clone --reference <mirror> --dissociate <remote>`, under the session's
  own credential.
- Read-only `context` repositories are never cloned per seat. Each becomes an
  immutable **pinned checkout**, one per (mirror, commit), which is exposed to
  the seat read-only.
- When the keeper is unavailable, provisioning is byte-for-byte what it is
  today.

### D1 — A daemon-owned store beneath the clone verb

The keeper is the git implementation of the provider-owned seed class that
`ADR-2026-08-22` D7.8 and `ADR-2026-08-30` D7 already allow. It holds
repository objects and pinned checkouts outside every session root. It sits
beneath the git VCS provider's `clone` verb (`008`) and beneath
`EnsureRepository`. It does not change those contracts, the declaration, the
receipt or the root lifecycle.

- **Storage location.** Its storage lives under the daemon's state directory
  (`<state-dir>/repo-keeper/`, mode `0700`, owned by the daemon's user). It is
  on the same filesystem as the workarea parent, so copy-on-write copies are
  possible.
- **Contents.** It holds `mirrors/`, `checkouts/`, `locks/`, and a secret-free
  catalog.
- **What it never is.** It is never inside a session root, never a harness
  working directory, never adopted as a session, and never bound writable into
  a seat.
- **Not the workarea cache.** It is not the workarea cache of `003`. Cache
  entries are prepared work areas with installed dependencies. The keeper holds
  only git objects and pinned checkouts. A future cache warmer seeds from the
  keeper like any other provisioning.
- **Accounting.** Keeper bytes are charged to the keeper's own identity, never
  to a session (`ADR-2026-08-22` D7.4).

### D2 — Mirror identity is (canonical remote, credential scope)

- **The canonical remote** is the source with userinfo and query removed, the
  same normalization as `RepositorySourceDigest`.
- **The credential scope** is an opaque, secret-free string. The embedding
  binary supplies it through a callback beside the existing `GitAuth` seam:
  `scope(ctx, remote) → (scope, error)`. The OSS default is one host scope,
  which is today's single-tenant behaviour.
- **The mirror directory** is a digest of both values. The mirror records its
  remote and scope, and the keeper verifies both before every use. A mismatch
  fails closed, as the code-intelligence host's origin check does.
- **Mirrors never share objects.** There are no alternates between mirrors, so
  two scopes that reach the same repository get two mirrors. A shared object
  store would answer "does object X exist?" across scopes.

### D3 — One fetcher per mirror, with coalesced fetches

- **Single writer.** Only the keeper writes a mirror.
- **Freshness bounds.** A request names a freshness bound: "fetched no earlier
  than T". Requests are single-flight per mirror, and one fetch satisfies every
  waiter whose bound it meets.
- **Fetch rate.** The keeper fetches a mirror at most once per minimum interval
  (default 30 s). The one exception is a pinned commit that is missing: the
  keeper then fetches once more, with a time limit.
- **What is fetched.** The keeper fetches all branches and tags, with `--prune`.
  Other refs, such as a dispatched pull request's head, are fetched on demand.
- **Credentials.** The fetch credential is resolved per invocation for the
  mirror's scope through the existing `GitAuth` seam. It travels as an
  in-memory `http.extraHeader` and is never written to the mirror.
- **Revocation.** An authentication or authorization refusal (401, 403, or a
  404 for a repository the mirror already holds) marks the mirror `revoked`. A
  revoked mirror seeds and binds nothing until a later authenticated fetch
  succeeds.
- **Transient failures** leave the last state in place. Seeding still works
  (D4). Binding follows D6.

### D4 — Mutable repositories are seeded with `--reference <mirror> --dissociate`

A `primary` or `secondary` repository is provisioned as today, with one
change: the existing `provisionOnceWithReference` path receives the keeper's
mirror as its reference.

```
git clone --reference <mirror> --dissociate [--branch <ref>] <remote> <dst>
```

- **Authorization stays with the git host.** The clone still talks to the real
  remote with the session's own credential. The keeper grants nothing the
  session's credential lacks, and a revoked credential fails exactly as it does
  today.
- **Freshness stays with the git host.** The clone negotiates the true tip from
  the remote. A stale mirror means a larger transfer, never a stale checkout,
  so the keeper's fetch interval does not affect correctness here.
- **The result is self-contained.**
  - `--dissociate` copies the objects the clone needs into the session's own
    `.git` and removes the alternates link. That satisfies `ADR-2026-08-30` D6.
  - The session repository does not depend on the mirror surviving
    maintenance (D9).
  - Nothing the seat writes reaches the mirror.
- **No hard links.** The command names the remote URL, not the mirror's path,
  so git never hard-links objects. A local-path clone of a mirror is never used
  for a writable leaf without `--no-hardlinks` (confinement D2.3).
- **It degrades to today.** A missing, busy, revoked or over-budget mirror
  means a plain clone. The keeper never fails a session.
- **Seeding stays outside the harness's confinement.** It runs in the worker
  before the harness is spawned, as cloning does today. If an executor ever
  confines the worker, or runs it under an identity that cannot read keeper
  storage, the daemon performs the seed into the staged root instead.
- **Sparse checkouts** keep `--filter=blob:none --sparse`, with the mirror as
  the reference.

### D5 — Context repositories are pinned checkouts, never per-seat clones

For a declared repository with role `context` and authority `read-only`:

1. **Pin a commit.**
   - The commit comes from the dispatch when the control plane sends one.
     Otherwise the keeper resolves the declared ref against a mirror fetched
     within the freshness bound.
   - The commit is recorded as the repository's resolved ref in the
     declaration record, which already has that field.
   - Restart adoption and resume reuse the recorded commit and never resolve
     it again (`ADR-2026-08-30` D12 item 5).
2. **Materialize once per (mirror, commit).** A pinned checkout is a
   self-contained repository holding exactly that commit at depth 1. That
   matches the shallow sibling clone of `ADR-2026-07-07`, so `git rev-parse` and
   `git log -1` still work.
   - It has no remote, no alternates, no hooks, and no credential anywhere.
   - The keeper writes a secret-free provenance file: canonical remote, commit,
     tree id and creation time.
   - The keeper builds it in staging, makes it read-only, and publishes it by
     atomic rename to `checkouts/<mirror-digest>/<commit>/`.
   - A published checkout is never modified. A new commit means a new
     checkout, never a freshened one.
   - Concurrent requests for the same checkout are single-flight.
3. **Expose it read-only at the declared leaf under `workareaRoot`.** How
   depends on what the executor attests:
   - **Mount namespace (the Linux backend).** The executor bind-mounts the
     checkout read-only at the leaf, inside the seat's namespace. This costs
     nothing per seat.
   - **No mount namespace, with read-only enforcement attested (macOS
     seatbelt).** The worker makes a per-session copy-on-write clone of the
     checkout at the leaf before spawn (APFS clonefile, reflink where the
     filesystem has it, otherwise a plain copy). The executor's read-only-leaf
     rule then applies. The leaf is never a symlink into keeper storage.
     Because the copy is per session, even a seat that defeats its write-deny
     rule changes only its own bytes.
   - **No read-only enforcement attested.** Nothing changes.
     `ADR-2026-08-22` D8.4 omits the read-only entry, and its sibling-variable
     entry, for that executor. A legacy work item authored only with the
     sibling variable keeps its current behaviour (D8.6).
4. **Agreement with `ADR-2026-08-22` D3.2.**
   - On macOS the leaf is a per-session copy under the root, so it already
     complies.
   - On Linux the leaf is a read-only view of keeper bytes that no session's
     mutation path reaches. The bytes are published immutable, and keeper
     storage is never bound writable anywhere. That is the property D3.2
     protects. The accepting commit should amend D3.2 to say so explicitly.

### D6 — Authorization is checked at bind, per scope

The keeper exposes a pinned checkout to a session only when both of these
hold:

- The session's credential scope equals the mirror's scope. Checkouts are
  keyed by mirror, so they never cross scopes, even when two scopes hold the
  same commit.
- The scope's last successful authenticated contact with the remote for that
  repository is no older than the authorization window (default 10 min).

If the window has lapsed, the keeper runs an authenticated fetch with the
scope's credential before binding.

- **A refused fetch** marks the mirror `revoked` (D3). The context repository
  is then skipped with a warning, under the existing skip rule for read-only
  context repositories.
- **A revoked mirror's checkouts** are never exposed to new sessions. Running
  sessions keep what they were given.

Mutable seeds need no such check, because the remote authenticates them (D4).

### D7 — Interplay with confinement

- **Writes.** Keeper storage is outside every writable class of confinement
  D2, so a confined harness cannot write it. Seeds are dissociated and pinned
  checkouts reach a seat only as a read-only bind or a per-session copy, so a
  seat-writable clone cannot corrupt a mirror.
- **Reads.** This ADR does not decide `fileRead`; confinement D7 defers it. It
  takes one narrow slice: on a host that keeps mirrors for more than one
  credential scope, seats must not be able to read keeper storage. Any one of
  three means satisfies this:
  - the Linux mount-namespace backend builds the seat's view without the
    keeper root;
  - user separation runs seats under their own identities, against
    daemon-owned `0700` storage;
  - the composing binary adds a deny-read rule for the keeper root through the
    deny-only `ConfinementExtraRules` callback (confinement D4).
- **Hosts that cannot do this.** Such a host gains no new exposure from the
  keeper, since other sessions' roots are equally readable there today. But it
  does not meet the bar for serving more than one scope. The extension decides
  whether such a host may hold mirrors for more than one scope.
- **Same-user hosts.** Where an unconfined harness runs under the daemon's own
  user, file modes are the only protection for keeper storage, and same-user
  `chmod` is not enforcement (`ADR-2026-08-22` D6.7). That is no weaker than
  today, when such seats share writable sibling clones. Linux seat hosts close
  the gap with separate seat identities and namespaces. The keeper runs in the
  daemon's cgroup, so a seat is never charged for fetches it did not cause.

### D8 — Locks are cross-process, with three modes

Seeding runs in per-session worker processes. The in-process parent locks in
`runtime/worktree` therefore cannot protect a shared store. Each mirror has
two file locks under `locks/`:

- **The fetch lock** is exclusive among fetchers. With the in-process
  single-flight of D3, it enforces one fetch per mirror at a time. The
  remote-tracking-ref races recorded in `refreshBase` therefore cannot occur.
- **The maintenance lock** is read-write. Seeds, checkout builds and fetches
  hold it shared. A fetch only adds objects and updates refs atomically, so it
  can safely overlap a running `clone --reference`. Maintenance and eviction
  hold it exclusive, so a mirror is never repacked or deleted under a running
  seed.

### D9 — Maintenance, liveness, budget and recovery

- **Mirror maintenance.** The keeper sets `gc.auto=0` and runs maintenance
  itself, under the exclusive lock: incremental repack, commit-graph, and
  pruning with a grace period longer than the longest seed. Seeds are
  dissociated, so maintenance can never break a session.
- **Checkout liveness is positive and root-bound.** A pinned checkout is live
  while any root that references it is not durably `released`. That includes
  roots that are active, release-pending, quarantined, or parked for resume
  (`ADR-2026-07-18`, `ADR-2026-10-07` D8). Liveness is derived from those
  durable records, never kept as a separate count, so the keeper adds no new
  authority over a root's bytes. Idle time only orders eviction among
  checkouts that no root references. It is never the criterion (the `011`
  sweep rule).
- **Budget.**
  - The keeper has its own budget, `repoKeeper.maxDiskGb`, separate from the
    workarea cache's envelope, with `0` meaning no limit.
  - Unreferenced checkouts are evicted first. Then mirrors with no in-flight
    seed are evicted, least recently used first.
  - At the budget, the keeper stops creating entries and callers degrade per
    D4. The cache's warn-at-80% and refuse-at-90% thresholds apply to the
    keeper too.
- **Recovery order.** On daemon start, the keeper reconciles its catalog after
  session and catalog reconciliation and before workarea-cache admission
  (`011` recovery order). A keeper still reconciling degrades to plain clones.
- **Observability.**
  - Keeper state appears in the existing daemon stats: mirrors, last fetch per
    mirror, revoked count, bytes, and live checkouts. It carries no scope
    values and no credential-bearing URLs.
  - The keeper emits events for fetch, seed, bind and evict, with duration and
    bytes. `ADR-2026-08-30` D10's `materialization path` reports a keeper seed
    as `seed`.
  - This ADR adds no new daemon route. In particular it adds no
    `workarea`-spelled path (`ADR-2026-08-07`).

### D10 — What this ADR does not adopt

- **Shared-parent worktrees for seats.** Confinement D2.4 already refuses
  them: a worktree-add session cannot be confined. Shared objects and refs also
  let one session see or damage another's branches, and they need the parent
  locks this ADR replaces. `StrategyWorktreeAdd` remains for operator,
  single-tenant use.
- **Alternates for seats, for now.** Confinement D2.4 permits read-only
  borrowing, and keeping alternates would save about 70 MB per monorepo
  session. It is deferred for three reasons:
  - the seat would need read access to the mirror at run time, which conflicts
    with D7's read slice;
  - mirror maintenance would have to keep every object a seat might still
    need;
  - `.git` is only 4–5% of measured work-area disk.

  Revisit it only when a measured budget is at risk.
- **Shallow or blobless defaults for mutable repositories.**
  - Agents need history for merge-base, rebase, blame and log, and blame needs
    full history (`ADR-2026-06-01`).
  - A shallow clone complicates pushing.
  - A blobless clone moves network fetches to agent run time, under the seat's
    credential.
  - With a local mirror, a full clone costs about what a shallow one does.
- **A warm workarea cache in this decision.**
  - With a mirror, the git step of a cold acquire takes 1–3 s. The measured
    costs that remain are dependency installation and retained work areas.
  - On a busy repository a prepared checkout goes stale within the hour.
  - The `003` cache stays specified and unbuilt. When its warmer is built, it
    seeds from the keeper.
- **The unread `projects[].cloneStrategy` setting** is retired:
  - `shallow` and `full` lose their meaning, because full history from a
    mirror is cheap;
  - `reference-clone` becomes the default behaviour;
  - nothing reads the setting today, so retiring it changes no behaviour.

### D11 — Standalone, opt-out, and the ephemeral posture

- **Standalone runs.** `donmai agent run` without a daemon keeps today's plain
  clone.
- **Opt-out.** A daemon with the keeper disabled provisions byte-for-byte as
  today. The keeper is a fast path with an exact fallback, never a dependency.
- **Ephemeral posture.** Work whose locked posture forbids long-lived clones
  bypasses the keeper entirely, and never creates or reads a mirror. The
  code-survival default in `ADR-2026-06-01` is such work.

### Rollout

| Phase | Where | Scope |
|---|---|---|
| 0 | the macOS reference host, this week | D1–D4, D8, D11, and a minimal D9 (budget, mirror eviction, recovery order), behind a daemon setting, for mutable repositories only. Retire `cloneStrategy`. Measure transfer, clone time and failures against the baseline above |
| 1 | Linux seat hosts | D5–D7 with read-only binds. Context repositories become pinned checkouts there, and the shared sibling clones are no longer needed on those hosts. Keeper storage stays under the daemon's user, with seats under their own identity and cgroup. Prefer a filesystem with reflinks (XFS with `reflink=1`, or btrfs) for the workarea parent and the keeper |
| 2 | macOS | D5 with per-session copy-on-write clones. Stop the operator refresh job for the shared sibling clones. Legacy shared-parent clones are reported as unowned, never deleted automatically (`ADR-2026-08-22` D9.4). Tune maintenance and eviction from Phase 0 data |

### Expected effect

These are estimates from the measurements above, until Phase 0 reports.

- **Transfer from the git host** falls from about 18 GB a day to the deltas
  between fetches, which are kilobytes to a few MB each: more than 95% less.
  Network clones fall from one per session to one fetch per repository per
  interval, plus one negotiation per seed. Bursts no longer multiply transfer.
- **Monorepo provisioning** falls from p50 5 s and p90 8 s to about 2–3 s, most
  of it file checkout. The tail of up to 45 s comes from the git host, so it
  leaves the common path.
- **Context repositories** cost each seat a bind (Linux) or a sub-second
  copy-on-write clone (macOS) instead of a clone. Every seat sees an exact,
  recorded commit, instead of a shared clone that can fall weeks behind.
- **Disk for mutable repositories** does not change, deliberately, because D4
  dissociates. On these hosts the disk levers are dependency installation and
  retention, which need their own decisions.

## Consequences

### Positive

- **Less exposure to the git host.** One fetcher per repository per host
  replaces one clone per session. The host is far less exposed to git-host
  latency, rate limits and outages during fan-out waves.
- **Exact, safe context repositories.** Read-only `context` repositories become
  pinned per session, immutable, and shared without being writable. They work
  with confinement on both operating systems.
- **Authorization and tenancy do not get weaker.**
  - Mutable seeds still authenticate to the git host as the session.
  - Pinned checkouts are exposed only within a matching, recently
    re-authorized scope.
  - Mirrors never share objects across scopes.
- **One store replaces several partial mechanisms:** the per-seed
  `--reference` path, the shared sibling clones, the unread `cloneStrategy`
  setting, and, later, the code-intelligence host's private mirrors.

### Negative

- **A new daemon-owned store.** It brings its own maintenance, budget, locks and
  failure modes. Every failure mode degrades to today's clone, but each one
  still has to be built and tested.
- **Two scopes reaching one repository double its mirror disk.** This is
  accepted for isolation.
- **A pinned checkout holds one commit of history.** This matches the shallow
  sibling clone. A session that needs more history should declare the
  repository as `secondary` and have it seeded per D4.
- **macOS pays a copy-on-write clone per seat** for each context repository,
  where Linux pays only a bind.

### Risks

- **Mirror corruption on same-user hosts.** An unconfined harness under the
  daemon's user could write into keeper storage. Seeds are dissociated and git
  objects are content-addressed, so damage shows up as failed seeds that fall
  back to plain clones, not as a silent substitution. Connectivity checks
  during maintenance bound how long it goes unnoticed.
- **A stale authorization window.** A grant revoked inside the 10-minute window
  can still bind a checkout that the scope already held. The window bounds that
  exposure. A shorter window costs one authenticated round trip per bind.
- **Budget pressure during waves.** Many distinct context commits in one wave
  could crowd the budget. Pinned checkouts are small (a few MB for a corpus)
  and shared per commit, and at the budget callers degrade to clones.

## Alternatives considered

- **Keep cloning per session.** Rejected, because of the measured transfer and
  bursts, and because shared context clones cannot work under confinement.
- **One central non-bare clone on `main`, with work areas made by
  `git worktree add`.** This was the owner's first framing, and it is the
  cheapest option in time (1.1 s). It is rejected for seats, by confinement
  D2.4 and D10 above. The keeper keeps what is good about it (one copy per
  host, refreshed centrally) and moves it to a bare mirror that seats never
  touch.
- **Shallow or blobless clones without a mirror.** Rejected. They saved little
  time in the benchmark (12–15 s against 18 s) and they cost history.
- **Alternates without `--dissociate`.** This is the cheapest option on disk.
  It is deferred (D10).
- **A warm pre-provisioned work area per hot repository.** Deferred (D10).
  Reusing prepared trees across sessions needs the clean-state guarantees of
  `003`, which belong to the cache, not the keeper.
- **One mirror per repository shared across scopes, with authorization checked
  only at checkout.** Rejected. A shared object store leaks object existence
  across scopes and mixes one scope's fetched refs into another's store.
- **A reference-counted shared parent for context clones.** Already rejected by
  `ADR-2026-08-22`. Its contents stay mutable, and the count is "a fifth
  authority over the same bytes". Pinned checkouts are immutable per commit,
  and their liveness is derived from root-bound records (D9), so that
  objection does not apply here.

## Affected documents

To be amended in the commit that accepts this ADR:

- `003-workarea-provider.md`
  - § "The workarea cache": step 1 of the slow path becomes "seed from the
    host's repository keeper".
  - Add a short § "Repository keeper" summarizing D1–D9, and state that cache
    entries seed from the keeper and are distinct from it.
- `011-local-daemon-fleet.md`
  - Retire § "`projects[].cloneStrategy`" (D10).
  - Add the keeper settings: `repoKeeper.enabled`, `repoKeeper.maxDiskGb`, the
    fetch interval and the authorization window.
  - Add the keeper's place in the state-directory layout and in the recovery
    order, and its fields in daemon stats.
- `008-version-control-providers.md` — note that the git provider's `clone`
  verb may seed from the host's repository keeper (D1).
- `004-sandbox-capability-matrix.md` — the pinned-checkout exposure per
  executor class (D5 step 3).
- `ADR-2026-08-22-session-owned-multi-repository-workarea.md`
  - Clarify D3.2 (D5 step 4).
  - Add forward notes on D7.4 and D7.8: the keeper is the git seed class.
- `ADR-2026-08-30-workspace-root-and-lazy-repository-materialization.md` —
  forward note: `EnsureRepository` may seed from the keeper. A context
  repository's resolved ref is the pinned commit.
- `ADR-2026-10-03-executor-os-confinement.md` — forward note: keeper storage is
  outside the writable set, and D7 here is a narrow `fileRead` slice for
  hosts that serve more than one scope.
- `ADR-2026-07-07-sibling-context-repos.md` — forward note: for executors that
  attest read-only enforcement, D5 replaces the shared sibling clone.
- `ADR-2026-06-01-code-survival-pool-execution.md` — forward note: the
  ephemeral posture bypasses the keeper (D11).
- The companion private corpus gets a mirrored stub carrying the platform
  delta:
  - how credential scopes are derived on a host that serves more than one
    organization;
  - an optional dispatch-time commit pin;
  - placement affinity for hosts that already hold a mirror.

## Affected work items

None are cited here. Tracker references live in the companion private corpus.

## Implementation notes

- **Start from the code-intelligence host.** `runtime/codeintelhost/git.go`
  already creates mirrors with an origin check, fetches an exact missing
  commit, serializes per repository, and resolves auth per invocation.
  - Extract it into a keeper package that both the code-intelligence host and
    `runtime/worktree` use.
  - Replace its per-process mutex with the cross-process locks of D8.
- **Phase 0 is a small change in `runtime/worktree`.** `provisionLayoutOnce`
  already threads a reference path into `provisionOnceWithReference`. The
  keeper supplies that path for the flat layout and for each declared mutable
  repository.
- **Building a pinned checkout.** Set `uploadpack.allowAnySHA1InWant` on the
  private mirror. Run `git init`, then `fetch --depth 1 file://<mirror> <commit>`
  and a detached checkout. Remove the remote. Then make the tree read-only and
  rename it into place.
- **Bind-or-copy.** A read-only bind as another identity needs that leaf in the
  seat's `safe.directory`, supplied through the executor's git environment,
  never through a persisted file. The bind-or-copy step belongs where the
  executor builds its confinement spec, beside the read-only leaves it already
  enumerates.
- **Tests that must go red without the mechanism:**
  - two concurrent seeds share one fetch;
  - maintenance does not run under a live seed;
  - a scope mismatch fails closed;
  - a revoked mirror exposes nothing;
  - a pinned checkout is byte-identical across sessions and unwritable from a
    confined seat;
  - a checkout referenced by a parked root survives eviction pressure;
  - with the keeper disabled, provisioning is byte-identical to today's.
