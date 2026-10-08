---
status: Accepted
date: 2026-10-08
boundary: shared
split: sibling-extensions
---

# ADR-2026-10-08 — Kit-declared dependency stores

**Status:** Accepted 2026-10-08 (founder acceptance as drafted). Architecture
only: nothing is built, and implementation follows the rollout below. The
founder ruled on the draft's open questions the same day (§ "Rulings on the
open questions"). The corpus edits listed under "Affected documents" landed in
the accepting commit, with the clarifications recorded under "Clarified at
acceptance".
**Date:** 2026-10-08
**Boundary:** shared. The mechanism ships working in the OSS daemon for a
single-tenant host: the manifest section, the host's dependency keeper (stores,
generations, the filler, session store views), install snapshots, budgets, a
retention budget for retained work areas, and the events. The official kits'
declarations are OSS too. Three things belong in implementation-specific
extensions:

- how a control plane derives a dependency credential scope on a host that
  serves more than one organization, and how it delivers registry credentials
  to the filler;
- whether placement prefers a host that already holds a warm store or snapshot
  for a session's install key (a ranking input, never a gate);
- fleet-wide aggregation of hit rates and time saved.

**Authors:** architecture lane (research agent), answering a founder question
about dependency installs on shared seat hosts.

## Context

### The question

A founder ruling of 2026-10-08 sets the intent:

- Users run bun, pnpm, npm and other package managers. A kit should make the
  user's own stack efficient on the hosts that run their sessions.
- Dependency caches and stores are kit scope.
- The per-host repository keeper
  (`ADR-2026-10-08-per-host-repository-keeper.md`) deliberately excludes them
  (its D10) and points here.

So the question is: how does a kit declare its package manager's store, how
does a host keep that store warm without breaking tenancy or confinement, and
can a host skip an install entirely when it has already produced the same
installed tree?

### What it costs

The keeper's measurement of one shared macOS reference host (7.4 days ending
2026-10-08) found:

- **Volume.** About 265 work areas are provisioned a day, and one TypeScript
  monorepo accounts for 74% of them.
- **Disk.** 166 work areas are retained, the oldest 40 days old. They hold
  227 GB, of which `.git` is only 10 GB. Installed dependencies, about 1.6 GB
  per JavaScript work area, dominate. Archived work areas hold another 47 GB.
  No retention budget applies to any of it.
- **Time.** `pnpm install` costs minutes per acquire.

### What a warm store buys, measured

To see where those minutes go, the same kind of tree was installed on a
developer laptop (macOS, APFS, pnpm 10.34.1). The workspace is a TypeScript
monorepo with two workspace projects. Its installed tree is 83,541 files and
3,759 symbolic links, 1.5 GB, close to the reference host's 1.6 GB. Every run
used `--ignore-scripts`, so lifecycle scripts are excluded.

| Step | Time | Result |
|---|---|---|
| Offline frozen install from an exactly warm store, clone import | 5.4 s | complete tree |
| The same, with the store's content write-denied, through a per-session view (content linked read-only, the store's `v10/projects/` directory per session) | 5.4 s | complete tree |
| The same, with the whole store write-denied | 0.2 s | **fails**: `EPERM` creating `v10/projects/<hash>` |
| Copy-on-write clone of the installed tree, per file (`cp -c -R`) | 12.6 s | |
| Copy-on-write clone of the installed tree, `copyfile(3)` recursive with clone | 13.8 s | |
| Copy-on-write clone of the installed tree, one `clonefile(2)` per top directory | 1.1–1.2 s | all files and links present; the reconcile below accepts it |
| Reconcile a cloned tree at a new project path, same store path (`pnpm install --offline --frozen-lockfile`) | 0.4 s | "Already up to date"; the absolute `NODE_PATH` in every `.bin` shim is rewritten for the new path |
| The same, with a different store path | 8.1 s | pnpm discards the tree and reinstalls |
| The same, after rewriting the store path recorded in `node_modules/.modules.yaml` | 0.4 s | "Already up to date" |
| Copy-on-write clone of the whole 7.2 GB store (266,959 files), one `clonefile(2)` per top directory | 3.7 s | |

Four facts follow.

1. **Linking from a warm store takes seconds, not minutes.** An acquire that
   takes minutes is paying for what its store lacks (resolution and
   download), for lifecycle scripts, or for contention between concurrent
   installs. The code below shows that an agent's own install in a confined
   seat always pays the first.
2. **pnpm cannot use a plain read-only store.** It records every project it
   installs into a registry inside the store (`v10/projects/`). It does that
   even for a complete offline hit, and even for a no-op reconcile.
3. **An installed tree is portable if the manager reconciles it.** For pnpm, a
   cloned tree at a new path becomes valid after one offline install. That
   install is a no-op that rewrites path-bearing files. The manager is the
   arbiter.
4. **pnpm records the store's absolute path in the installed tree.** If the
   path differs, the restored tree is thrown away, unless that recorded path is
   rewritten first.

### What the code does today

Cited against `donmai` at the time of writing.

1. **The install step is hard-coded in the runner.**
   - `runner/deps_install.go` runs `pnpm install --prefer-offline
     --frozen-lockfile` when the selected leaf has `pnpm-lock.yaml` and no
     `node_modules/.bin`. It runs `go mod download` when the leaf has `go.mod`.
   - It is best-effort, under one 5-minute timeout, and skipped for a
     read-only leaf.
   - It runs in the worker, before the harness spawns, unconfined, in the
     seat's capped environment. So it uses the operator's default stores,
     which every session on the host shares read-write, and package lifecycle
     scripts run unconfined.
   - The step installs for no other package manager.
2. **A confined harness gets per-session caches that start empty.**
   `provider/harness/pi/confinement.go` binds `GOCACHE`, `GOMODCACHE`,
   `GOPATH`, `NPM_CONFIG_CACHE`, `NPM_CONFIG_STORE_DIR`,
   `PNPM_CONFIG_STORE_DIR` and `XDG_RUNTIME_DIR` to new, empty directories
   under the session root.
   - The install step and the harness therefore see different caches.
   - An agent's own `go build` or `pnpm add` in a confined seat starts cold.
     `go build` downloads every module that `go mod download` already fetched
     into the operator's cache, minutes earlier, in the same session.
   - The list is hard-coded in one harness adapter. No kit declares it.
3. **Kits declare caches that nothing reads.**
   - The official kits' `[provide.workarea_config]` names host-global stores
     in `preserve_dirs`: `~/.pnpm-store`, `~/.npm`, `~/go/pkg/mod`,
     `~/.cargo/registry`, `~/.cache/uv`, and others.
   - No code parses `preserve_dirs`. Only `clean_dirs` reaches the kit view.
   - Honouring `preserve_dirs` as written would create exactly the shared
     read-write cache that confinement D2.2 forbids.
4. **A Linux install can hard-link into the operator's store.** The managers'
   default import methods hard-link on Linux:
   - pnpm 10 falls back from a copy-on-write clone to a hard link where the
     filesystem has no reflinks;
   - pnpm 11 tries a hard link first on Linux;
   - bun's default backend on Linux is a hard link.

   The worker installs from the operator's store, so on such a host a seat's
   `node_modules` files can be the store's own inodes. A seat that edits one
   edits the store for every later session. That is the hazard confinement
   D2.3 names.
5. **Nothing bounds retention.**
   - `PreserveWorktreeOnFailure` and `PreserveWorktreeAlways` keep roots after
     the session ends, and nothing ever expires them.
   - `capacity.poolMaxDiskGb` governs only the workarea cache of `003`, which
     is specified and unbuilt.

### What the corpus already decides

This ADR fits inside Accepted decisions and must not reopen them.

- **Confinement.** `ADR-2026-10-03-executor-os-confinement.md`:
  - D2 puts per-session toolchain caches (`session_cache`) in the closed
    writable set and leaves shared caches outside it.
  - D2.2 says caches are "seeded, not shared". The executor may clone the
    host's warm cache into the session's directory by copy-on-write. It may
    also expose a warm cache read-only "where the tool can consume it without
    writing (a module proxy reading a local directory, a package store
    imported by clone or copy)". A shared read-write cache demotes the
    harness's `fileWrite` attestation to `host`.
  - D2.3: no hard link to an inode outside the set. A package manager in a
    confined session imports by clone or copy. A write through a symbolic link
    is judged at its target.
  - D4.3 gives the deny-only composer callback, and D5 refuses rather than
    degrading.
- **The repository keeper.** `ADR-2026-10-08-per-host-repository-keeper.md`:
  - a store's identity carries a credential scope supplied through a callback
    (D2);
  - one writer per store, with cross-process locks (D3, D8);
  - a narrow read slice for hosts serving more than one scope (D7);
  - liveness derived from root-bound records, never from idle time (D9);
  - dependency stores excluded and sent here (D10);
  - standalone, opt-out and ephemeral behaviour unchanged (D11).
- **Seeds.** `ADR-2026-08-22-session-owned-multi-repository-workarea.md`:
  - D7.8 lets a host keep "a base clone, prepared dependency tree, snapshot,
    or copy-on-write seed outside all session roots";
  - D7.4 charges shared copy-on-write blocks to the seed and private blocks to
    the session, never twice;
  - D7.1 removes no leaf independently while the session lives.
- **Workspace roots (Proposed).**
  `ADR-2026-08-30-workspace-root-and-lazy-repository-materialization.md`
  places `session_cache` under `state/<harness-key>/ephemeral/cache/`, purged
  before pause or archive. Its D10 defines the materialization events this ADR
  extends.
- **Toolchain demands.** `001` § Layer 4 and `006` Seam 2:
  - a kit's toolchain demand is a signal to the workarea and sandbox
    scheduler;
  - a kit's `provide()` may run its framework's install step;
  - Seam 2 names "slow per-session installs that should have been warmed" as
    the bug class it prevents.
- **Placement.** `ADR-2026-08-12-placement-composition-law-and-single-fallback-rule.md`
  D3: ranking orders candidates and never gates them.
- **Kit manifests.** `005`: a new contribution type needs an `api` revision.
  `ADR-2026-07-10-deterministic-kit-packages-and-command-composition.md`
  already requires the next revision.
- **Sweeps.** `011`: no sweep may use "this looks orphaned" or "nothing touched
  this recently". Deletion is an explicit transition, and a cleanup deletes
  only what a manifest declares deletable.
- **Network.** `ADR-2026-09-27-execution-security-levels.md`: the effective
  `network` level bounds what an install may fetch.

### Forces

- **Many managers, few shapes.** Nine managers matter now: pnpm, bun, npm,
  yarn (berry and classic), Go modules, cargo, uv and pip. They differ in
  every detail. Each still has a content store, a lockfile, a fetch, an
  offline install and an installed tree. The daemon must stay agnostic of
  managers, and the kit must carry the specifics.
- **Tenancy.**
  - Private registries mean a store holds one organization's private code.
  - A store shared across scopes answers "has this host fetched X?" for
    another scope.
  - Sharing also lets one scope's fetch of a name shadow another scope's
    private package of the same name (dependency confusion).
- **Untrusted code at install time.** Lifecycle scripts, source builds and
  native addon compilation run package code. Fetching need not.
- **Confinement.** Seats are moving under executor confinement on macOS and
  Linux. macOS has no per-process mount namespace, so a path cannot differ
  per seat.
- **Native ABI.** An installed tree can hold binaries built for one OS, CPU,
  libc and runtime ABI. Reusing it elsewhere fails at run time, or worse,
  half-works.
- **Disk.** Content stores only grow. Installed trees are large. Retained
  roots are unbounded today.

## Decision

Each kit declares its package managers' stores. Each host's daemon owns one
**dependency keeper** that keeps one store per (manager, credential scope).

- **One writer.** A daemon-owned filler alone writes a store, by running the
  kit's own fetch command into immutable generations. It never runs package
  code, and it never takes bytes from a seat.
- **Per-session views.** A seat sees its scope's store through a per-session
  view: an overlay on Linux, a copy-on-write seed on macOS, or a read-only
  view or proxy where the manager can consume one. Nothing a seat writes
  reaches the shared store.
- **Install snapshots.** The keeper captures each pristine installed tree as a
  copy-on-write snapshot keyed by an install key (inputs, manager, toolchain
  ABI, platform, scope). A later seat with the same key restores the snapshot
  and lets the manager's own offline install reconcile it. A failed reconcile
  falls back to a normal install.
- **Budgets.** Stores and snapshots share one disk budget, and eviction takes
  snapshots first. Retained work areas get a retention budget for the first
  time: installed trees are dropped first, whole roots later, and a root with
  unpushed work is archived, never deleted.
- **Exact fallback.** When the keeper is disabled or degraded, the install
  step behaves as it does today.

### D1 — Kits declare dependency stores

A kit declares each package manager it supports as one
`[[provide.dependency_store]]` entry. The entry tells the host what the
mechanism needs and says nothing about hosts. This is the official TypeScript
kits' pnpm entry, for pnpm 10. pnpm 11 reads only `PNPM_CONFIG_*` variables
and changes the store layout, so it gets its own entry and fixtures:

```toml
[[provide.dependency_store]]
manager   = "pnpm"
ecosystem = "node"
lockfiles = ["pnpm-lock.yaml"]
inputs    = ["pnpm-workspace.yaml", "**/package.json", ".npmrc", ".pnpmfile.cjs", "patches/**"]
version   = "pnpm --version"

[provide.dependency_store.store]
env          = ["NPM_CONFIG_STORE_DIR"]
default      = { macos = "~/Library/pnpm/store", linux = "~/.local/share/pnpm/store" }
sharing      = "content-addressed"
integrity    = "on-use"
content      = ["v10/files", "v10/index"]
bookkeeping  = ["v10/projects"]
records_path = true

[provide.dependency_store.import]
env = { NPM_CONFIG_PACKAGE_IMPORT_METHOD = "clone-or-copy" }

[provide.dependency_store.commands]
fetch    = "pnpm fetch"
install  = "pnpm install --offline --frozen-lockfile"
online   = "pnpm install --prefer-offline --frozen-lockfile"
relocate = "bin/pnpm-relocate"

[provide.dependency_store.snapshot]
installed         = ["node_modules", "**/node_modules"]
abi               = ["os", "arch", "libc", "node-abi"]
relocation        = "reconcile"
runs_package_code = true
```

| Field | Meaning |
|---|---|
| `manager` | The manager's identifier. At most one entry per manager per kit. |
| `ecosystem` | Groups managers that compete for one leaf, such as `node` or `python`. |
| `lockfiles` | Paths whose presence in a leaf selects the entry. Their committed bytes key every install (D7). |
| `inputs` | Further committed files that change what an install produces: workspace manifests, patches, and the repository's own manager configuration. |
| `version` | A command that prints the manager version, which is part of every key. |
| `store.env` | Variables the host binds to the session's store view (D5). |
| `store.default` | Where the manager keeps its store when unconfigured, per OS. The host never binds it for a seat. It is what an opted-out or standalone run uses (D11), and what the stats report the keeper supersedes. |
| `store.sharing` | `content-addressed` (shareable within a scope) or `session-only` (never shared). |
| `store.integrity` | `on-use` (the manager checks each artifact against the lockfile's hash or its content address whenever it installs it), `on-fetch` (it checks only at download), or `none`. Only the first two may be shared (D4). |
| `store.content` | Store-relative paths that hold content-addressed artifacts. These are shareable. |
| `store.bookkeeping` | Store-relative paths the manager writes on every install, even a complete hit. These are always per session. |
| `store.secrets` | Store-relative paths that may hold credentials or configuration. They are never fetched into, seeded, snapshotted or exposed. |
| `store.never_share` | Store-relative paths that hold outputs of package code, such as built wheels or post-install side effects. They are never in a shared generation. |
| `store.records_path` | The installed tree records the store's absolute path. |
| `import.env` | Settings that make the manager import by clone or copy, never by hard link (D5). |
| `commands.fetch` | Downloads the lockfile's artifacts into a store, running no package code (D4). |
| `commands.install` | Installs from the store with the lockfile frozen and the network off. |
| `commands.online` | The same install, allowed to fetch. It is the fallback when the store misses. |
| `commands.reconcile` | Proves that a restored tree matches the lockfile. It defaults to `install`. |
| `commands.verify` | Re-checks a whole store against its hashes. Required for `on-fetch` integrity where the manager has one (`go mod verify`). |
| `commands.relocate` | Optional, package-owned. It rewrites the store path a restored tree records, for `records_path` managers (D5). |
| `snapshot.installed` | The leaf paths the install creates. |
| `snapshot.abi` | The facts that make an installed tree platform-specific. |
| `snapshot.relocation` | `reconcile` (the tree is valid at another path after reconcile, and after relocate when declared) or `none` (no snapshots). |
| `snapshot.runs_package_code` | Whether the install runs lifecycle scripts or builds. |
| `proxy.env` | Optional. A read-only local source the manager can read without writing (D5). |

1. **Declarations are claims, and fixtures decide.** The matrix that controls
   exposure and snapshots is computed per (manager version, OS) from passing
   fixtures (Test plan), never from a declaration alone. This follows
   `ADR-2026-08-08` D4 and `ADR-2026-08-13` D6. Commands may be OS-keyed, as
   elsewhere in `005`; bun's `--backend`, for example, differs per OS.
2. **Selection.** An entry applies to a mutable leaf whose files match one of
   its `lockfiles`. When entries of the same `ecosystem` both match, the
   leaf's own declaration decides where the ecosystem has one (for Node, the
   `packageManager` field). Otherwise no entry applies, and the install step
   reports `manager_ambiguous`.
3. **Composition.** Entries from several kits compose by union, keyed by
   `manager`. Two kits that declare the same `manager` conflict unless the
   active composition lock selects one, exactly as generic commands do in
   `005`.
4. **The manifest revision.** The section is a new contribution type, so it
   arrives with a manifest `api` revision. It rides the revision that
   `ADR-2026-07-10` already requires. A consumer that does not understand the
   revision rejects it; it never half-applies it.
5. **`preserve_dirs` stops naming host caches.** Host-global entries in
   `workarea_config.preserve_dirs` (any path outside the leaf) lose their
   meaning, because the keeper replaces them. Entries inside the leaf keep
   their `003` cache meaning. The accepting commit adds the retired-claim rule
   `PRESERVE_DIRS_HOST_CACHE`.
6. **Managers leave the runner and the adapters.** The runner's hard-coded
   pnpm and Go commands become the official kits' entries. The pi adapter's
   hard-coded cache list becomes the union of the selected entries'
   `store.env`. The adapter keeps only bindings that name no manager, such as
   the per-session `XDG_RUNTIME_DIR`. No harness adapter names a package
   manager.

### D2 — The host's dependency keeper

Each host's daemon owns one **dependency keeper** beside the repository
keeper.

- **Storage.** It lives under the daemon's state directory
  (`<state-dir>/dep-keeper/`, mode `0700`, owned by the daemon's user), on the
  same filesystem as the workarea parent so copy-on-write is possible.
- **Contents.** It holds:
  - `stores/<scope-digest>/<manager>/<layout>/generations/<n>/`, with a
    `current` pointer;
  - `snapshots/<scope-digest>/<manager>/<install-key>/`;
  - `locks/`;
  - a secret-free catalog: generation coverage, snapshot provenance, sizes and
    last use.
- **What it never is.** It is never inside a session root, never a harness
  working directory, never adopted as a session, and never bound writable into
  a seat.
- **A seed class.** Store generations and snapshots are the "prepared
  dependency tree … seed outside all session roots" of `ADR-2026-08-22` D7.8.
  Their bytes are charged to the keeper. A session's private copy-on-write
  blocks are charged to the session (D7.4).
- **Not the workarea cache.** The keeper holds stores and installed-tree
  snapshots, not prepared work areas. If the `003` cache warmer is ever built,
  it seeds from both keepers.

### D3 — Store identity is (manager, layout, credential scope)

- **The layout** is the manager's own store format version, such as pnpm's
  `v10`. A manager upgrade that changes the format starts a new store.
- **The credential scope** is an opaque, secret-free string. The composing
  binary supplies it through a callback beside the repository keeper's scope
  callback: `dependencyScope(ctx, session) → (scope, error)`. The OSS default
  is one host scope, which is today's single-tenant behaviour. A session whose
  scope cannot be resolved gets the `session-only` exposure (D5), never another
  scope's store.
- **No content crosses scopes**, not even byte-identical public packages.
  - A shared store answers "has this host fetched X?" across scopes.
  - It lets one scope's fetch of a name shadow another scope's private package
    of that name. Some stores are keyed by name and version rather than by
    content (bun's cache, Go's module cache), so a shadowing entry would be
    served.
  - The managers themselves treat a store as shared only among mutually
    trusted users; pnpm's documentation says so.

  Two scopes that use the same packages cost two stores. This is accepted for
  isolation, as the keeper accepts two mirrors.
- **Credentials are never stored.** The filler's registry credentials come per
  invocation from a second callback,
  `dependencyCredentials(ctx, scope, manager)`. They reach the fetch process in
  memory, or in a `0700` per-invocation file removed afterwards, and never
  enter a generation. Paths in `store.secrets` are excluded everywhere: for
  example, cargo keeps `credentials.toml` inside `CARGO_HOME`.

### D4 — One writer: the filler fetches into immutable generations

1. **Single writer.** Only the keeper's filler writes a scope's store, and only
   by running the entry's `fetch` command. Seats never write a shared
   generation, and nothing a seat downloaded is ever promoted into one.
2. **Generations.**
   - The filler builds generation n+1 from n by copy-on-write clone where the
     filesystem has one. Otherwise it uses a hard-link farm: generations are
     daemon-only, immutable and outside every writable set, so confinement
     D2.3 is not engaged.
   - It runs `fetch` into the new generation, verifies it (rule 6), makes it
     read-only, and publishes it by atomic rename and pointer swap.
   - A published generation never changes. That is what makes it safe as an
     overlay's lower layer (D5) and stable for the life of a seat that binds
     it.
3. **Inputs.** The filler runs in a daemon-owned scratch directory that holds
   exactly the entry's `lockfiles` and `inputs` at the session's commit. They
   are copied from the freshly seeded leaf before the harness spawns. The
   filler never runs inside a session root. The declared inputs must be enough
   for `fetch`, and a fixture proves it. cargo, for example, needs every
   workspace member's manifest.
4. **Confinement.** The filler runs under the host's executor confinement
   backend where the host has one. Its writable set is the staging generation
   and its scratch directory. It has network access, a scratch `HOME`, and the
   scope's credentials in memory.
5. **No package code.** `fetch` must not run package code: no lifecycle
   scripts, no source builds, no build scripts.
   - Managers whose download path can build declare a mode that refuses to
     build, such as uv's `--no-build` or pip's `--only-binary :all:`.
   - A lockfile that cannot be fetched without a build is not covered, and its
     sessions install online (`fetch_requires_build`).
   - A fixture proves the rule: a package whose install script writes a
     marker, and no marker after the fetch.
6. **Integrity.**
   - Sharing requires `store.integrity` of `on-use` or `on-fetch`. An entry
     that declares `none` is `session-only`.
   - With `on-use`, the manager checks each artifact against the lockfile's
     hash or its content address whenever it installs from the store, so a
     damaged or substituted entry fails the install instead of being used.
     pnpm's `verifyStoreIntegrity` and npm's cache verification on extraction
     are of this kind, and uv checks `uv.lock` hashes even for cached wheels.
   - With `on-fetch`, the manager checks only at download: Go keeps
     precomputed hashes and does not re-hash on use, and bun checks
     `bun.lock` integrity for newly downloaded packages. From then on, the
     single writer and the immutability of generations carry the guarantee.
     The filler runs the entry's `verify` command, where there is one, over
     the whole generation before publishing it.
   - The filler also checks that no `store.secrets` or `store.never_share`
     path exists in the generation.
7. **Coverage, and warming that never blocks** (founder ruling, 2026-10-08).
   - The catalog records which lockfile digests a generation covers, meaning
     the filler completed `fetch` for those inputs. Checking coverage is a
     catalog lookup and never waits.
   - A session never waits for the filler. When the bound generation does not
     cover the session's lockfile digest, the session installs online at once
     into its own view (D6). The keeper starts a background fill for that
     digest, so a later session finds it covered.
   - Fills are single-flight per (scope, manager, lockfile digest). A fan-out
     wave on a new lockfile therefore causes one fill. Sessions that arrive
     before the fill completes still fetch online for themselves.
   - This is the repository keeper's rule (its D4 and D11): the keeper is a
     fast path with an exact fallback, and it never fails or blocks a
     session.
8. **Write-back is a refetch.** When a session's online install fetched what
   the store lacked, or the session's commit changes the lockfile, the worker
   reports the new lockfile digest and the filler fetches it in the
   background. The seat's own
   bytes are discarded with its root. A poisoned seat therefore never reaches
   another session through the store.
9. **Locks.** Locks are cross-process, as in the keeper's D8:
   - a fill lock per (scope, manager);
   - a maintenance lock, held shared by fills, binds and seeds, and held
     exclusive by compaction and eviction.

### D5 — How a store reaches a seat

A session gets one **store view** per selected entry. The view is bound to
`store.env` for both the install step and the harness, which ends today's
split between the two. The host uses the cheapest exposure that the manager's
fixtures pass on that host and executor class:

1. **`overlay`** (Linux, mount namespace; confinement D3).
   - The lower layer is the bound generation, read-only. The upper and work
     directories are in the session's `session_cache`, on the same
     filesystem.
   - It is mounted at the **stable store path**
     `<state-dir>/dep-keeper/stores/<scope-digest>/<manager>/view` inside the
     seat's namespace. That path is the same string for every session of the
     scope.
   - It is fully writable at constant cost.
   - Overlay inside an unprivileged user namespace needs kernel support.
     Without it, the executor builds the mount before dropping privilege
     (confinement D3.1), or the host falls back to `seeded`.
2. **`seeded`** (macOS APFS; Linux with reflinks, such as XFS with
   `reflink=1` or btrfs).
   - The generation's `content` paths are cloned copy-on-write into the
     session's `session_cache`, and the `bookkeeping` paths are created empty.
   - It is fully writable, at a path that differs per session.
   - It is never a byte copy. On a filesystem without copy-on-write, `seeded`
     is not offered.
   - On macOS one `clonefile(2)` per directory is about twelve times faster
     than cloning file by file (1.1 s against 12.6–13.8 s for the measured
     tree). Apple's manual page discourages directory clones and points to
     `copyfile(3)`, so a fixture on each OS release proves the directory
     clone. Without one, the host clones file by file.
3. **`view`** (any OS).
   - The `content` paths are linked read-only to the bound generation, and the
     `bookkeeping` paths are per session and writable.
   - It is constant cost, and it serves an install that only reads: an offline
     install of a covered lockfile, or a snapshot reconcile. Writes to content
     fail, because confinement D2.3 judges a write through a link at its
     target.
   - It is offered only when the manager's fixture passes a complete offline
     install through it. pnpm 10 passes. A plain read-only store fails on
     `v10/projects/`.
   - On macOS, `view` and `seeded` share one per-session path:
     - the install step runs while the content paths are still links;
     - the clone is made concurrently beside them;
     - each link is replaced by its clone, by atomic rename, before the
       harness spawns.

     The store path that the installed tree records stays valid, and an
     agent's own `pnpm add` gets a writable store.
4. **`proxy`** (any OS).
   - A manager-native, read-only local source feeds a per-session cache:
     - Go: `GOPROXY=file://<generation>/cache/download` ahead of the
       configured proxy;
     - pip and uv: a wheel directory passed as `--find-links`.
   - The manager only reads it, nothing is linked, and it works on any
     filesystem.
5. **`session-only`.** An empty per-session cache. This is today's confined
   behaviour, and the fallback whenever nothing above applies or the scope is
   unresolved.

Rules that hold for every exposure:

- **No hard link outside the writable set** (confinement D2.3). `import.env`
  is applied whenever store content sits outside the set (`view`, `proxy`). A
  probe checks that no installed file shares an inode with a path outside the
  set.
- **A stable store path for `records_path` managers.** Capture and restore
  must see the same presented store path.
  - `overlay` gives it.
  - Elsewhere, the kit's `relocate` command rewrites the recorded path before
    reconcile. For pnpm 10, rewriting `storeDir` in `node_modules/.modules.yaml`
    turns an 8.1 s reinstall into a 0.4 s no-op.
  - The founder accepted this coupling to a manager-internal file on
    2026-10-08, gated per manager version. `relocate` runs only for a manager
    version whose relocate fixture passes. That fixture restores at a new
    path, relocates, reconciles to a no-op, and matches a fresh install.
  - A `records_path` manager with neither gets no snapshot restore
    (`store_path_unstable`). Neither does a version whose relocate fixture
    fails or has not run; the session does a normal install from the store
    or online.
- **The read slice.** As in the keeper's D7: on a host with stores for more
  than one scope, seats must not read other scopes' stores or snapshots. Any
  one of these satisfies it:
  - the Linux namespace omits them;
  - user separation runs seats under their own identities against the
    daemon-owned `0700` storage;
  - the composing binary denies reads of the keeper root, except the bound
    scope, through `ConfinementExtraRules`.

  A host that can do none of these does not hold stores for more than one
  scope. The extension decides.
- **Unconfined seats** get the same views. There, file modes are the only
  protection, and same-user `chmod` is not enforcement (`ADR-2026-08-22`
  D6.7). That is no weaker than today, when every seat shares the operator's
  stores read-write.

### D6 — The install step

1. **It replaces `installSessionDependencies`.** For the selected mutable leaf,
   each applicable entry runs, in order:
   1. restore a snapshot (D7);
   2. otherwise, if the bound generation covers the lockfile (D4 rule 7), run
      `install` offline;
   3. otherwise, run `online` at once, when the session's effective `network`
      level allows it, while the keeper fills the store in the background.
      With network denied, the miss is reported as `store_miss_offline`.

   No step waits for the keeper. The step stays best-effort, as today: a
   failure is logged and the session continues.
2. **The same confinement as the harness.** When the harness is confined, the
   install step runs under the same executor confinement, writable set and
   store view, because it runs package code. When the harness is unconfined,
   the step runs as it does today.
3. **An install record.** The step writes a secret-free install record, per
   leaf and entry, into the root's reserved metadata (`.workarea/`): the
   manager, the install key, the store generation, the exposure, the path taken
   (`snapshot`, `store`, `online`, `skipped` or `failed`), and the installed
   paths. Liveness (D8) and retention (D9) read that record.
4. **Read-only leaves** are never installed into, as today.

### D7 — Install snapshots

1. **The install key** is a digest of:
   - the scope, the manager and its version, and the entry's digest;
   - the committed bytes of every `lockfiles` and `inputs` path, by path;
   - the resolved toolchain and its ABI (for Node, the version and its modules
     ABI; for Python, the version and ABI tag);
   - the platform: OS, CPU architecture, libc family and version;
   - the presented store path, for `records_path` managers on `overlay`;
   - the install command, and the values of any environment variables the
     entry declares as affecting the install.
2. **Capture only from a pristine install.** The keeper captures a tree only
   when all of these hold:
   - the install ran on a leaf freshly seeded at the declared commit, with no
     installed paths already present;
   - it was the entry's offline `install` from a store generation, so the tree
     derives from that generation and the lockfile alone;
   - it ran before the harness spawned;
   - it changed no tracked file;
   - every ignored path it created lies inside `snapshot.installed`.
     Otherwise the capture is refused, with `install_outputs_undeclared` or
     `install_mutated_tracked`.

   A tree an agent has touched is never captured. That covers a tree after
   spawn, at release, during retention or archive, and in a resumed root
   (founder ruling, 2026-10-08). An online install is not captured either:
   its tree does not derive from a generation alone. On a new lockfile, the
   first capture therefore comes from the first session that finds the
   background fill complete.

   The keeper clones the installed paths into staging, makes them read-only,
   and publishes them by atomic rename. Captures are single-flight per key, and
   the first good capture wins. Capture adds one copy-on-write clone (about
   1.2 s for the measured tree) to that one session.
3. **Restore and reconcile.**
   - The keeper clones `snapshot.installed` into the fresh leaf, with one
     `clonefile(2)` per directory or a reflink copy.
   - It runs `relocate` when it is declared and needed, and the manager
     version's relocate fixture passes (D5). Then it runs `reconcile` offline,
     under the install step's confinement and within a budget (default 30 s).
   - Success is a hit. On failure, the restored paths are removed, the
     snapshot is quarantined (`reconcile_failed`), and the install step falls
     back to a normal install, as D6 describes.
4. **ABI safety.** Platform and runtime ABI are in the key, so a built native
   module is reused only under an identical key. A toolchain upgrade changes
   the key. Shared stores never hold build outputs (D4 rule 5 and
   `store.never_share`).
5. **A copy, never a mount.** A restored tree is a copy-on-write copy inside
   the leaf, never an overlay. `rm -rf node_modules` followed by a fresh
   install then behaves as it does on any machine.
6. **The cost gate.** Per (scope, manager), the keeper keeps rolling medians of
   restore plus reconcile, and of a store install. It stops capturing where
   snapshots do not beat the store install. For uv, for example, a store
   install is already fast and a virtual environment is not relocatable.
7. **Invalidation is by key.** Correctness needs no TTL. Eviction follows D8,
   quarantine follows a failed reconcile, and an operator can purge.
8. **Trust** (founder ruling, 2026-10-08).
   - A snapshot holds what the lockfile-pinned packages' scripts produced in a
     confined, pristine install in the same scope, before any agent acted.
   - Install-script outputs are reused across the sessions of one credential
     scope by default, and only from such snapshots (rule 2). They never cross
     scopes (D3).
   - Reuse adds one exposure: the output of a non-deterministic or malicious
     script is reused rather than re-run.
   - An entry, or an operator, may still turn snapshots off for an entry whose
     `runs_package_code` is true.

### D8 — Budgets and garbage collection for stores and snapshots

- **One budget** (the coordinator's default, 2026-10-08).
  - The keeper has one budget, `dependencyKeeper.maxDiskGb`. It covers stores,
    generations and snapshots together, separate from the repository keeper's
    budget and the workarea cache's. `0` means no limit.
  - The cache's warn-at-80% and refuse-at-90% thresholds apply.
  - Under pressure, eviction takes snapshots before stores, in this order:
    1. quarantined snapshots;
    2. other snapshots, least recently used first;
    3. generations that no live root binds;
    4. compaction of a store (below).

    A snapshot is the cheaper loss: a store install rebuilds its tree in
    seconds, while losing a store costs a refetch.
  - At the budget, the filler stops publishing, capture stops, and sessions
    degrade to `session-only` and online installs.
- **Liveness is positive and root-bound.**
  - A generation is live while any root that binds it, according to its
    install record, is not durably `released`. That covers roots that are
    active, release-pending, quarantined or parked for resume.
  - A restored snapshot is an independent copy, so no root depends on a
    snapshot after restore.
  - Idle time only orders eviction among unreferenced items. It is never the
    criterion (the `011` sweep rule).
- **Compaction.** Content stores only grow. When a scope's store exceeds its
  share of the budget, the filler builds a fresh generation by fetching only
  the lockfile digests used within the compaction window (default 14 days).
  - The catalog keeps those lockfile and input bytes, with any userinfo
    stripped from URLs.
  - Older generations retire once no live root binds them.
  - Manager prune commands such as `pnpm store prune` are not used. They read
    the project registry, which here is per-session bookkeeping.
- **Recovery order.** The dependency keeper reconciles its catalog after the
  repository keeper and before workarea-cache admission (`011` recovery
  order). A keeper that is still reconciling serves `session-only` and online
  installs.

### D9 — A retention budget for retained work areas

1. **Scope.** The budget applies only to roots whose session is durably
   terminal and that were retained by preservation (`PreserveWorktreeAlways`,
   `PreserveWorktreeOnFailure`). It never applies to a root that is leased,
   release-pending, quarantined, parked for resume, adopted or unreconciled
   (`ADR-2026-07-18`, `ADR-2026-10-07` D8, `011`).
2. **Dehydrate first.** The defaults in this decision (24 hours, 14 days,
   30 days) are the founder's of 2026-10-08. After
   `retention.dehydrateAfterHours` (default 24),
   the keeper removes from each leaf exactly the installed paths that the leaf's
   install record lists. Those are the manifest-declared deletables of `011`,
   and they can be rebuilt from the recorded install key. Source, `.git` and
   every unignored file stay. A later restore of the root reinstalls from the
   recorded key, by snapshot or store.
3. **Expire later.** After `retention.maxAgeDays` (default 14), or least
   recently used first when `retention.maxDiskGb` is exceeded, a root is
   archived or destroyed (founder ruling, 2026-10-08):
   - **Archived, never destroyed,** if any mutable leaf holds unpushed work.
     Unpushed work means any of:
     - commits unreachable from that leaf's remote-tracking refs;
     - uncommitted changes to tracked files;
     - untracked files that git does not ignore.

     Uncommitted changes are this ADR's conservative reading of "unpushed".
   - **Destroyed** otherwise. Expiry may delete a root whose work is all on a
     remote.

   Archives have their own age budget, `retention.archiveMaxAgeDays` (default
   30). Dropping an archive is a separate transition with its own receipt. It
   is the only path by which unpushed work leaves the host.
4. **Explicit transitions.** Each dehydrate and expire is an explicit
   transition with a receipt that names the policy and the bytes reclaimed. It
   is never a "looks orphaned" sweep. A root is disposed of as a whole, apart
   from dehydration, which removes only declared deletables.
5. **Roots retained before install records existed.** That is every root
   retained today. Each gets a one-time classification:
   - the applicable entries are derived from the leaf's lockfiles;
   - a path is dehydratable only if it matches an entry's
     `snapshot.installed` and git ignores it in that leaf.

   The classification is written as the root's install record before anything
   is removed, so removal always reads a record. Dehydration and expiry are
   dispositions of a root in its existing layout. They never migrate a
   retained legacy layout (`ADR-2026-08-22` D9).
6. **Off switches.** Setting `0` disables each rule.

### D10 — Observability

- **The install step event.** Each install step emits
  `dependency.install.completed` or `dependency.install.failed`, carrying:
  - the manager, the exposure, and the path taken (`snapshot`, `store`,
    `online`, `session-only` or `skipped`);
  - the miss reason, from a closed enum (below);
  - durations: restore, relocate, reconcile, install and seed;
  - the bytes the seat fetched itself;
  - the generation id and the install-key digest.
- **Keeper events.**
  - `dependency.fill.started`, `.completed` and `.failed`;
  - `dependency.snapshot.captured`, `.restored`, `.quarantined` and
    `.evicted`;
  - `dependency.store.compacted`;
  - `retention.dehydrated` and `retention.expired`.
- **Time saved is an estimate, labelled as one.**
  - Per (scope, manager, lockfile path), the keeper keeps a rolling median of
    `online` installs, which is the cold baseline, and of `store` installs.
  - For each hit it reports `baseline − actual`, with the baseline's sample
    count.
  - With no baseline, nothing is reported. A guess is never shown as a
    measurement.
- **Daemon stats.** The existing daemon stats report:
  - hit and miss counts and rates per manager and path, over 1 h, 24 h and
    7 d;
  - miss reasons;
  - estimated time saved;
  - store, generation and snapshot bytes;
  - budget pressure;
  - retained roots by state (hydrated or dehydrated), and bytes reclaimed.

  This ADR adds no new daemon route and no `workarea`-spelled path
  (`ADR-2026-08-07`).
- **Nothing secret.** No event or stat carries a scope value, a registry URL
  or a credential.
- **Existing vocabularies.** The `003` `acquire_path` field gains a sibling,
  `dependency_path`. The materialization events of `ADR-2026-08-30` D10 gain
  the dependency phases.

```ts
type DependencyMissReason =
  | 'no_entry'                   // no kit entry matches the leaf
  | 'manager_ambiguous'          // two managers of one ecosystem match (D1)
  | 'scope_unresolved'           // no credential scope for the session (D3)
  | 'keeper_disabled'            // opt-out or still reconciling (D8, D11)
  | 'exposure_unavailable'       // no exposure passes on this host (D5)
  | 'no_snapshot'                // no snapshot for the install key
  | 'store_path_unstable'        // records_path manager, no overlay, no relocate (D5)
  | 'reconcile_failed'           // snapshot quarantined (D7)
  | 'not_covered'                // generation lacks the lockfile's artifacts; a background fill starts (D4)
  | 'fetch_requires_build'       // fetch would run package code (D4)
  | 'store_miss_offline'         // a miss with network denied (D6)
  | 'budget_exhausted'           // the keeper is at its budget (D8)
```

The enum is closed, and an unknown value is malformed. Human-readable detail
is display-only.

### D11 — Layering, standalone, opt-out and the ephemeral posture

- **OSS** ships the manifest section, the keeper, the filler, the views, the
  snapshots, the budgets, the retention rules, the events, the official kits'
  entries and the fixtures, all working for a single-scope host.
- **The extension** carries four things in the companion private corpus's
  mirrored stub:
  - scope derivation on a host that serves more than one organization;
  - registry credential delivery to the filler;
  - placement that prefers a host already holding a warm store or a snapshot
    for the session's install key. This is a ranking input under the placement
    law (`ADR-2026-08-12` D3), never a gate;
  - fleet-wide aggregation of hit rates and time saved.
- **Standalone runs.** `donmai agent run` without a daemon keeps today's
  install against the operator's own stores.
- **Opt-out.** `dependencyKeeper.enabled: false` runs the entries' `online`
  commands against the operator's stores, which is today's behaviour. The
  official kits' `online` commands are the commands the runner hard-codes
  today.
- **No import of an operator store.** Generation 0 is built by `fetch`, never
  imported from the operator's existing store. That store can hold outputs of
  package code that no path rule can strip: pnpm's side-effects cache, on by
  default, keeps built packages inside its index, keyed by platform, CPU and
  Node major version.
- **The ephemeral posture.** Work whose locked posture forbids long-lived state
  bypasses the keeper entirely, and never creates or reads a store or a
  snapshot. The code-survival default of
  `ADR-2026-06-01-code-survival-pool-execution.md` is such work.

### D12 — What this ADR does not adopt

- **A shared read-write store for seats.** Confinement D2.2 forbids it, and it
  is the poisoning path.
- **Hard-link import from a shared store** (confinement D2.3).
- **Layouts that symlink installed packages into a shared tree**, such as a
  global virtual store. Writes would land in the shared tree, and so would
  package-code outputs.
- **Promoting seat-fetched bytes** into a shared store, even after an
  integrity check. The seat controls the store's metadata as well as its
  content. A refetch costs one extra download on a miss and needs no trust in
  the seat.
- **Content shared across scopes** (D3).
- **A per-host caching registry proxy.** That means one server per ecosystem,
  and it saves network but not linking. A proxy can later become the filler's
  upstream without changing this design.
- **Overlay mounts for installed trees** (D7 rule 5).
- **The `003` prepared work-area cache.** On a busy repository a prepared
  work area goes stale within the hour (the keeper's D10).
- **Build caches.** `GOCACHE`, cargo's `target/`, `.next/cache` and task-runner
  caches are outputs of compiling the session's own code, not dependencies.
  They stay per session (confinement D2.2), and warming them is a separate
  decision.
- **Windows.** There is no backend.

### The per-manager matrix (initial declarations)

These are the official kits' starting declarations, checked against each
manager's documentation at the time of writing. The fixtures compute the matrix
that is actually used (D1 rule 1). Each default location moves with the
variable named.

| Manager | Lockfile | Store variable (default) | Integrity | Shareable | Exposure | Snapshot |
|---|---|---|---|---|---|---|
| pnpm 10 | `pnpm-lock.yaml` | `NPM_CONFIG_STORE_DIR` (`$PNPM_HOME/store`, else `~/Library/pnpm/store` or `~/.local/share/pnpm/store`) | on-use | yes | overlay; on macOS view, then seeded | yes: reconcile, plus relocate off `overlay` |
| bun | `bun.lock` (`bun.lockb` is legacy) | `BUN_INSTALL_CACHE_DIR` (`~/.bun/install/cache`) | on-fetch | yes, within a scope | overlay; seeded | yes, if its reconcile fixture passes |
| npm | `package-lock.json`, `npm-shrinkwrap.json` | `npm_config_cache` (`~/.npm`, data in `_cacache`) | on-use | yes | overlay; seeded | yes, with a tree check as reconcile |
| yarn berry | `yarn.lock` | `YARN_GLOBAL_FOLDER` (`~/.yarn/berry`); `YARN_CACHE_FOLDER` when the global cache is off | on-use | yes | overlay; seeded | yes: reconcile |
| yarn classic | `yarn.lock` | `YARN_CACHE_FOLDER` (`yarn cache dir`) | on-fetch | yes, within a scope | seeded; overlay | yes: reconcile |
| Go modules | `go.sum` | `GOMODCACHE` (`$GOPATH/pkg/mod`) | on-fetch, plus `go mod verify` | yes | proxy; overlay; seeded | none: there is no installed tree in the leaf |
| cargo | `Cargo.lock` | `CARGO_HOME` (`~/.cargo`), content subtrees only | on-fetch | yes | seeded; overlay | none: `target/` is a build cache |
| uv | `uv.lock` | `UV_CACHE_DIR` (`$XDG_CACHE_HOME/uv` or `~/.cache/uv`, macOS included) | on-use | yes, for downloaded wheels | seeded; overlay | none: an environment is not relocatable, and a store install is fast |
| pip | `requirements*.txt` | `PIP_CACHE_DIR` (`~/Library/Caches/pip`, `~/.cache/pip`); the shared store is a wheel directory | on-use, with hashes only | only for hash-pinned requirements | proxy | none |

Commands and caveats, per manager:

- **pnpm 10.**
  - Commands: `fetch` is `pnpm fetch`, which reads only the lockfile.
    `install` is `pnpm install --offline --frozen-lockfile`. Import is
    `package-import-method=clone-or-copy`.
  - Caveats:
    - every install writes `v10/projects/`;
    - the installed tree records `storeDir`;
    - `.bin` shims carry an absolute `NODE_PATH`;
    - the side-effects cache, on by default, keeps built packages inside the
      store's index, keyed by platform, CPU and Node major version.
  - pnpm 11 reads only `PNPM_CONFIG_*`, adds an SQLite index to the store, and
    on Linux tries hard links first. It needs its own entry.
- **bun.**
  - Commands: `fetch` is `bun install --frozen-lockfile --ignore-scripts` in
    scratch. `install` is `bun install --frozen-lockfile --offline`. Import is
    `--backend=clonefile` on macOS and `--backend=copyfile` on Linux, where the
    default is a hard link.
  - Caveats:
    - the cache is keyed by name and version, not by content;
    - integrity is checked only for new downloads;
    - lifecycle scripts run for a built-in trusted list, which
      `trustedDependencies` replaces;
    - `.bin` entries are relative links.
- **npm.**
  - Commands: `fetch` is `npm ci --ignore-scripts` in scratch. `install` is
    `npm ci --offline`. npm unpacks packages as copies.
  - Caveats:
    - `_cacache` is content-addressed and verified on insertion and
      extraction, but its index is keyed by URL;
    - it holds private tarballs, though not authorization headers;
    - reconcile is a tree check (`npm ls --all`), because `npm ci` deletes
      `node_modules` first.
- **yarn berry.**
  - Commands: `fetch` is `yarn install --mode=skip-build` in scratch.
    `install` is `yarn install --immutable` with `YARN_ENABLE_NETWORK=0`.
    Import: Plug'n'Play reads the archives in place. With the `node-modules`
    linker, `nmMode` must not be `hardlinks-global`.
  - Caveats:
    - archives are checked against `yarn.lock` checksums (`checksumBehavior`
      defaults to `throw`);
    - the cache is documented as safe for concurrent instances;
    - repositories that commit `.yarn/cache` need no store;
    - the installed paths are `.pnp.cjs`, `.pnp.loader.mjs`, `.yarn/unplugged`
      and `.yarn/install-state.gz`, or `node_modules`.
- **yarn classic.**
  - Commands: `fetch` is `yarn install --frozen-lockfile --ignore-scripts` in
    scratch. `install` is `yarn install --frozen-lockfile --offline`.
  - Caveats: the cache is not safe for concurrent writers (the documentation
    prescribes `--mutex`), which the single filler satisfies.
- **Go modules.**
  - Commands: `fetch` is `go mod download`. `install` is `GOPROXY=off` with the
    view bound. `proxy` is `GOPROXY=file://<generation>/cache/download`.
    Modules are read in place and are read-only.
  - Caveats:
    - `go.mod`, `go.work` and `go.work.sum` are inputs;
    - the cache is documented as safe for concurrent `go` commands;
    - `GOPRIVATE` and `GONOSUMDB` skip the checksum database but not `go.sum`;
    - `GOCACHE` is out of scope (D12).
- **cargo.**
  - Commands: `fetch` is `cargo fetch --locked`. `install` is
    `cargo build --offline --locked`, which is `--frozen`.
  - Store paths:
    - content is `registry/index`, `registry/cache`, `registry/src`, `git/db`
      and `git/checkouts`;
    - `credentials.toml` and `config.toml` are `store.secrets`, because cargo
      keeps tokens there in plain text;
    - `bin/` is `never_share`.
  - Caveats: `.crate` files are checked against the index's `cksum` and
    `Cargo.lock`'s `checksum`, and cargo serializes access with its own
    package-cache lock.
- **uv.**
  - Commands: `fetch` is `uv sync --frozen --no-build --no-install-project`
    into a scratch environment. `install` is `uv sync --frozen --offline`.
    Import is `UV_LINK_MODE=clone`, the default on macOS and Linux, or `copy`,
    never `hardlink`. The cache and the environment must share a filesystem.
  - Caveats:
    - built wheels are `never_share`;
    - an sdist-only package gives `fetch_requires_build`;
    - `pyvenv.cfg` and script shebangs are absolute, and `--relocatable` does
      not cover scripts.
- **pip.**
  - Commands: `fetch` is `pip download --only-binary=:all: --require-hashes -d
    <wheels>`. `install` is `pip install --no-index --find-links <wheels>
    --require-hashes`.
  - Caveats:
    - the HTTP cache is keyed by URL, and the local wheel cache holds built
      wheels, so neither is ever shared;
    - unhashed requirements are `session-only`.

### Rollout

| Phase | Where | Scope |
|---|---|---|
| 1 | the macOS reference host | The official pnpm and Go entries (D1). D2–D4 for a single scope. D5 `seeded` with `view` for pnpm, and `proxy` or `seeded` for Go. D6, with the hard-coded runner list and the adapter's cache list removed. D9 dehydration first, for immediate disk relief. D10. pnpm snapshots behind the relocate fixture. Measure against the baseline above |
| 2 | Linux seat hosts | `overlay` at the stable store path. pnpm snapshots without relocate. The multi-scope read slice. A container fixture lane in CI |
| 3 | the other official kits | bun, npm, both yarns, cargo, uv and pip, as each passes its fixtures, with snapshot classes taken from the fixtures |

### Test plan

Every test runs real package managers at pinned versions: in containers (the
`donmai` repository already has a podman test lane) and on a macOS runner. The
registries are local: an npm-compatible registry for pnpm, npm, yarn and bun; a
file-based Go module proxy; a local cargo registry; and a local package index
for uv and pip. Each test must go red without the mechanism it covers.

- **Isolation.** Two scopes, A and B, on one host, each with a private package
  in each ecosystem.
  1. B's seat cannot list, stat or read A's stores or snapshots. This is
     probed through the production spawn binding, on Linux and on macOS.
  2. B's offline install of A's private package fails as not covered, even
     after A has fetched it.
  3. B never restores A's snapshot, even with a byte-identical lockfile.
  4. B's fill never receives A's credentials, asserted per invocation of the
     credential callback.
  5. The catalog, the stats and the events contain no scope value, no URL and
     no credential.
- **Integrity and poisoning.**
  - A seat that overwrites a file in its `overlay` or `seeded` view leaves the
    next session seeing the generation's original.
  - A tampered generation file makes the install fail through the manager's
    own check.
  - A fetch never runs a lifecycle script (the marker).
  - No `store.secrets` path appears in any generation, such as cargo's
    `credentials.toml`.
- **No hard links.** For every manager and exposure, no installed file shares
  an inode with a path outside the writable set.
- **Snapshots.**
  - The key changes when the runtime ABI, the manager version, the platform or
    any input changes.
  - A tree restored under a different store path reconciles to a no-op only
    with relocate.
  - A failed reconcile quarantines the snapshot and falls back.
  - Capture is refused when the install touched a tracked file or an
    undeclared path.
  - A native addon built for one ABI is never restored under another.
- **Budgets and retention.**
  - Under budget pressure, a root that is parked, leased or quarantined is
    never dehydrated or expired.
  - Dehydration removes exactly the recorded installed paths.
  - Expiry archives a root with unpushed commits.
  - A generation bound by a live root survives compaction.
- **One view.** After the install step, an agent's own `go build` or
  `pnpm install` in a confined seat fetches nothing. Today it refetches.
- **Retained roots.** A root retained before install records existed has its
  record written before anything is removed. A path that git does not ignore
  is never dehydrated.
- **Fan-out without waiting.** Nine concurrent sessions on a new lockfile
  cause one fill. None of them waits for it, and the tenth session installs
  from the store.
- **Opt-out.** With the keeper disabled, the install step runs exactly today's
  commands and environment, checked against a golden file.

### Expected effect

These are estimates from the measurements above, until Phase 1 reports.

- **The install step for the busy monorepo.** Today it takes minutes on the
  reference host. With a warm store it should take about 5 s, the laptop's
  store install. With a snapshot it should take about 1.6 s (a 1.2 s restore
  plus a 0.4 s reconcile). On macOS a 3.7 s store seed runs concurrently.
- **Agents' own installs** in confined seats stop starting cold.
- **Network.** There is one fill per lockfile, per scope, per host, instead of
  one fetch per session. Sessions never wait for it: those that arrive before a
  new lockfile's fill completes still fetch online, so the first wave on a new
  lockfile is not reduced, and every later one is.
- **Disk.** Retained roots shed their installed trees after a day and expire
  after two weeks. Stores and snapshots share one budget.
  - A caveat on the figures: `du` counts copy-on-write clones in full. On a
    host whose installs already clone from the store, dehydration frees less
    than the 1.6 GB per root that `du` reports. Phase 1 measures the change in
    free space, not `du`.

## Rulings on the open questions (2026-10-08)

The draft put five questions to the founder. The founder ruled on Q1–Q4 on
2026-10-08. Q5 is the coordinator's default, not a founder ruling. The
decisions above already carry each answer. The founder then accepted the ADR
as drafted (§ "Clarified at acceptance").

1. **Retention (founder).** The defaults stand:
   - installed dependencies are dehydrated after 24 hours;
   - work areas expire after 14 days;
   - archives are dropped after 30 days.

   Expiry may delete a work area whose commits are all pushed. Anything with
   unpushed commits is archived, never deleted (D9 rule 3).
2. **pnpm path rewrite on macOS (founder).** Yes, gated per pnpm version by
   a fixture. Where the fixture fails, the session falls back to a normal
   reinstall (D5, and D7 rule 3).
3. **Install-script outputs (founder).** They are reused across the sessions
   of one credential scope by default. The only source is a snapshot captured
   from a clean install before the agent starts. A tree an agent has modified
   is never captured (D7 rules 2 and 8).
4. **Warm wait (founder).** Never wait. A session installs online at once,
   while the daemon warms the store in the background. This matches the
   repository keeper's rule that the keeper never fails or blocks a session
   (D4 rule 7, D6).
5. **Disk budget (coordinator default).** One budget covers stores and
   snapshots, and eviction takes snapshots before stores (D8).

## Clarified at acceptance

These were recorded on 2026-10-08, when the founder accepted the ADR as drafted.

- **Unpushed work includes uncommitted and untracked files.** The draft read
  "unpushed" conservatively, and the founder confirmed that reading. Unpushed
  work is:
  - commits unreachable from a leaf's remote-tracking refs;
  - uncommitted changes to tracked files;
  - untracked files that git does not ignore.

  A root holding any of these is archived at expiry, never destroyed (D9
  rule 3).
- **Dropping an archive is the only exit.** Dropping an archive after
  `retention.archiveMaxAgeDays` (30) is the only path by which unpushed work
  leaves a host. It is its own explicit transition, with its own receipt (D9
  rules 3 and 4).
- **`preserve_dirs` is retired for host-global paths.**
  `scripts/retired-claim-lint.sh` gains the rule `PRESERVE_DIRS_HOST_CACHE`.
  The `005` example no longer names a host cache.

## Consequences

### Positive

- **The user's own stack is fast.** Any manager whose kit declares it gets a
  warm store, and snapshots where a fixture proves them safe. The daemon names
  no manager.
- **One store per scope.** One writer, fed only by the manager's own fetch,
  replaces three mechanisms: the operator's shared read-write stores, the
  confined harness's empty caches, and the kits' unread `preserve_dirs`.
- **Tenancy and confinement do not get weaker.**
  - No content crosses scopes.
  - Nothing a seat writes reaches a shared store.
  - Imports never hard-link outside the writable set.
  - Install-time package code runs under the harness's confinement.
- **The install step and the harness agree.** They see the same store view.
- **Disk is bounded.** For the first time retained roots have a budget, and
  stores and snapshots have one too.
- **The effect is measurable.** Hits, misses with typed reasons, and estimated
  time saved are reported against a measured baseline.

### Negative

- **A second daemon-owned store**, with its own generations, fills, locks,
  compaction and failure modes. Every failure mode degrades to today's
  behaviour, but each one still has to be built and tested.
- **Two scopes that use the same packages double the store disk.** This is
  accepted for isolation.
- **Per-manager fixtures must track managers.** A pnpm release that writes
  new bookkeeping, or moves `storeDir`, turns a fixture red, and that host
  falls back to `seeded` or a plain install until the entry is updated.
- **macOS pays a store seed per seat** (3.7 s for a 267k-file store,
  growing with the store until compaction), where Linux pays a constant
  overlay mount.
- **The catalog retains lockfile bytes** within the compaction window.

### Risks

- **Reused lifecycle output.** A malicious or non-deterministic install script
  has its output reused within a scope until the key changes. The key, the
  pristine-capture rule and the scope bound the risk. The founder accepted
  this exposure on 2026-10-08 (ruling 3).
- **Filler credentials.** The filler holds a scope's registry credentials
  during a fetch. They are delivered per invocation and never persisted, but a
  compromised fetch binary sees them, exactly as a session's own install does
  today.
- **Overlay support** varies by kernel and container runtime. The fallback is
  `seeded`, then `session-only`, and each step is visible in the events.
- **Same-user hosts.** An unconfined harness can write keeper storage through
  file modes alone. The manager's integrity checks turn that into failed
  installs rather than silent substitution, and on Linux seat hosts user
  separation closes the gap.

## Alternatives considered

- **Keep the shared read-write operator store.** This is today's install step.
  It is rejected under confinement D2.2, it is the poisoning path, and on Linux
  it hard-links seats to the store.
- **Keep empty per-session caches.** This is today's confined harness. It is
  rejected on cost: every agent install starts cold.
- **Promote a seat's downloads after an integrity check.** Rejected (D12).
- **One store shared across scopes, with authorization at bind.** Rejected for
  the same reasons as the keeper's shared mirror: existence leaks across
  scopes, and so does shadowing.
- **A per-host caching registry proxy.** Deferred (D12).
- **A global virtual store, or any symlink-into-store layout.** Rejected for
  seats (D12).
- **Snapshots of whole prepared work areas** (the `003` cache). Deferred
  (D12).
- **Manager-specific code in the daemon instead of kit declarations.** Rejected
  by the founder's ruling that stores are kit scope. The daemon keeps only
  generic primitives: generations, views, clone, overlay, digests and locks.

## Affected documents

Amended in the accepting commit:

- `005-kit-manifest-spec.md`
  - Add the `[[provide.dependency_store]]` contribution (D1), with its
    composition rule in the per-contribution table.
  - Retire the host-global meaning of `workarea_config.preserve_dirs`.
  - Note the `api` revision.
- `003-workarea-provider.md`
  - In the slow path, step 3 becomes "restore an install snapshot, or install
    from the scope's dependency store".
  - Add a short § "Dependency keeper" summarizing D2–D9.
  - Add `dependency_path` beside `acquire_path`.
- `011-local-daemon-fleet.md`
  - Add the keeper settings (`dependencyKeeper.enabled`,
    `dependencyKeeper.maxDiskGb` and the compaction window) and the `retention.*` settings.
  - Add the keeper to the state-directory layout and the recovery order, and
    its fields to the daemon stats.
- `004-sandbox-capability-matrix.md` — the store-view exposure per executor
  class (D5).
- `006-cross-provider-interactions.md` Seam 2 — kit dependency entries feed the
  dependency keeper. A framework install step becomes declared, not ad hoc.
- `ADR-2026-10-03-executor-os-confinement.md` — forward note: D2.2's seeded and
  read-only caches are realized by D5 here, and the install step runs under the
  harness's confinement (D6).
- `ADR-2026-10-08-per-host-repository-keeper.md` — forward note on D10: it now
  points to this ADR.
- `ADR-2026-08-22-session-owned-multi-repository-workarea.md` — forward note on
  D7.4 and D7.8: generations and snapshots are the prepared-dependency seed
  class.
- `ADR-2026-08-30-workspace-root-and-lazy-repository-materialization.md` —
  forward note: the dependency phases in its D10 events.
- `scripts/retired-claim-lint.sh` — a rule for `preserve_dirs` naming
  host-global caches.
- The companion private corpus gets a mirrored stub carrying the extension
  items of D11.

## Affected work items

None are cited here. Tracker references live in the companion private corpus.

## Implementation notes

- **Start from the two hard-coded lists.** `runner/deps_install.go` becomes the
  D6 install step. The cache list in `provider/harness/pi/confinement.go`
  becomes the union of the selected entries' `store.env`, fed into the
  existing `confinement.Cache` bindings.
- **Share the keeper's primitives.** Reuse the repository keeper's lock and
  catalog package.
  - On macOS, clone directories with `clonefile(2)`, one call per directory
    (`unix.Clonefile`). The measured gap is 1.1 s against 12.6 s for per-file
    `cp -c -R`.
  - On Linux, use the `FICLONE` ioctl for reflinks.
  - Build the `overlay` exposure in the Linux confinement stage, beside the
    read-only binds.
- **Stay manager-agnostic.** The daemon hashes committed bytes and never parses
  a lockfile. Manager knowledge lives in the entry and in package-owned
  commands such as `relocate`.
- **The macOS seed runs concurrently** with repository seeding and the install
  step, on `view`. The harness spawns after both.
- **pnpm details observed with 10.34.1**, which the official entry and its
  fixtures must track:
  - the `v10/projects/` registry;
  - `storeDir` in `node_modules/.modules.yaml`;
  - absolute `NODE_PATH` in `.bin` shims, which reconcile rewrites.
