---
status: Proposed
date: 2026-11-11
boundary: shared
split: sibling-extensions
---

# ADR-2026-11-11 — Session-independent dependency preparation

**Status:** Proposed 2026-11-11. Architecture only: nothing here is built.
It **extends**
[`ADR-2026-10-08-kit-dependency-stores.md`](ADR-2026-10-08-kit-dependency-stores.md)
(Accepted) and reopens none of its rulings. On acceptance, the accepting commit
adds a forward note to that ADR and makes the edits under "Affected documents".
**Date:** 2026-11-11
**Boundary:** shared. The entry point, its error taxonomy, the subject-shaped
scope callback, the fallback order, the time bounds, the confinement and
environment rules and the official kits' declarations are OSS, and work on a
single-tenant host with no control plane. How a control plane derives a
dependency credential scope for an invocation, and how it releases registry
credentials to one, belong in the companion private corpus's mirrored stub.
**Authors:** architecture lane (research agent), answering a founder question:
a non-agent executor checks out a repository and runs a declared script, and
needs the repository's dependencies installed with no agent session.

## Context

### What ADR-2026-10-08 decides, in one paragraph

Kits declare each package manager as a `[[provide.dependency_store]]` entry
(D1). Each host's daemon owns a dependency keeper with one store per (manager,
layout, credential scope) (D2, D3), written only by a filler that runs the
kit's `fetch` into immutable generations (D4). Seats see a per-session store
view (D5). The install step tries a snapshot, then the store, then an online
install, and never waits for the keeper (D6, D7). One disk budget covers
stores and snapshots, and retained work areas get a retention budget (D8, D9).
Typed miss reasons and events (D10), layering and opt-out (D11), and
non-adoptions (D12) complete it.

### What is built

Cited against `donmai` at `2b15888e` (2026-11-11).

1. **Slice 1 only.** `internal/kit/dependency_store.go` parses, validates,
   composes and selects entries (its header, lines 1–13, says the keeper,
   filler, views, snapshots, budgets and events are later slices).
   `daemon/kit_dependency_stores.go` gates the section to `donmai.dev/v2`.
   No official kit declares an entry, so nothing ever selects one.
2. **The real install is still two hard-coded commands.**
   `runner/deps_install.go` runs
   `pnpm install --prefer-offline --frozen-lockfile --ignore-scripts --ignore-pnpmfile`
   (line 32) or `go mod download` (line 36), detected by two file probes
   (lines 184–196). Its execer accepts exactly those two strings (lines
   303–314). It runs only at the weakest execution-security levels (lines
   265–267), with a minimal inherited environment (lines 272–280), under one
   five-minute timeout, and reports a closed per-ecosystem outcome.
   `installSessionDependencies` is unexported and takes a session's queued
   work (line 66).
3. **The outcome wire is closed to two ecosystems.**
   `agent/dependency_preparation.go` line 19 fixes the names to `pnpm` and
   `go`.
4. **The keeper's daemon wiring was attempted and closed unmerged.** A branch
   (`depkeeper-daemon-wiring`, three commits of 2026-10-11) added settings,
   stats, events and an eviction order over in-memory records with no store
   beneath them. Review found that nothing in production called it, that
   eviction and compaction emitted events without touching disk, and that its
   scope digest was a 64-bit non-cryptographic hash. It was closed under the
   stale-change rule on 2026-10-19 and is far behind main. It is evidence of
   the shape of slice 7, not a base to build on.
5. **Kit hooks resolve against the repository, not the kit.** The composer
   appends a hook string verbatim (`internal/kit/compose.go` line 274). The
   runner runs it through `sh -c` with the work area as the working directory
   (`runner/loop.go` line 775, `runner/kit_execer.go` lines 40–41). The
   official kits' `post_acquire = "bin/setup.sh"` therefore names the
   repository's `bin/setup.sh`, not the kit's. A repository without one fails
   provisioning, which aborts the session (Seam 2). A repository with one has
   its own script run, unconfined, in the kit's name. `005` already requires
   `donmai.dev/v3` to type such fields as package paths. That revision is not
   built.
6. **The official TypeScript kit's hook installs non-frozen.** Its
   `bin/setup.sh` runs `pnpm install --prefer-offline` without
   `--frozen-lockfile`, or `yarn install`, or `npm install`. Each may
   re-resolve the lockfile, and each runs lifecycle scripts unconfined.
7. **Composition drops the package root.** `ComposedDependencyStore`
   (`internal/kit/dependency_store.go` lines 137–151) carries the kit id and
   digest but no package location. A package-owned `relocate` command (D5)
   cannot be resolved from a composed entry.
8. **One entry per manager per kit.** `ValidateDependencyStores` (lines
   335–350) rejects a kit that declares a manager twice. ADR-2026-10-08 says
   pnpm 11 "gets its own entry". Selection reduces a leaf's `packageManager`
   to a bare manager token (`leafManagerToken`, line 705), so two entries for
   one manager cannot be told apart by version.

### Every seam is session-shaped

- **Scope.** `dependencyScope(ctx, session)` (D3).
- **Install step.** It runs "before the harness spawns" in the worker, and
  writes its install record into the root's reserved metadata (D6).
- **Exposure.** The view is bound "for both the install step and the harness"
  (D5).
- **Credentials.** The companion corpus has the filler borrow the triggering
  session's registry credentials.
- **Code.** The only caller is the runner's session loop.

None of these has an answer when there is no session.

### The new caller

A non-agent executor (for example, an operator-installed command lane that runs
one declared package script on a host that consented to it) has this shape:

- a clean checkout of a bound repository at a branch head, discarded after one
  invocation;
- an environment constructed from scratch: a fixed `PATH` of toolchain
  directories, `HOME` and `TMPDIR` set to per-invocation scratch directories,
  and only the credentials its own contract declares;
- a preparation budget that covers the checkout and the install together
  (seven minutes in the first such executor);
- a write check after the command that refuses any untracked, non-ignored file;
- code in another Go module, which cannot import `internal/` packages and
  cannot call an unexported runner method.

Today such an executor can only refuse a checkout whose script needs installed
dependencies.

### A measurement

On the macOS reference host, a small TypeScript repository (11 direct
dependencies; `packageManager` pins pnpm 9.15.9; the host's pnpm is a later
major, which switches itself to the pinned version) was cloned and installed
with the constructed environment above: an empty scratch `HOME`,
`--frozen-lockfile --ignore-scripts --ignore-pnpmfile`.

- **Time:** 9 s wall, including the pinned manager's own download.
- **Scratch `HOME` afterwards:** 590 MB, holding the store (pnpm 9's `v3`
  layout) and the downloaded manager.
- **Installed tree:** 468 MB as `du` counts it.

This is one sample and network-bound. It shows that a cold, per-invocation
install fits a minutes-scale budget for a small repository, and that every
invocation repeats both downloads while nothing reuses them.

### Gaps

For **agent sessions**:

- S1. The install never uses a kit entry, so no manager beyond pnpm and Go is
  installed, and the pi adapter's cache list stays hard-coded
  (`provider/harness/pi/confinement.go` lines 609–623).
- S2. Above the weakest execution-security levels the install is skipped
  outright, because it cannot yet run confined.
- S3. The official kits' `post_acquire` hooks are wrong as written (Context 5
  and 6).
- S4. The outcome wire cannot name a third manager.

For **session-less invocations**, all of the above, and:

- N1. **No entry point.** The install is unexported and takes queued session
  work.
- N2. **No scope or credentials without a session.** The scope callback takes
  a session, and the filler's credentials are borrowed from one.
- N3. **No registry authentication path** that is not the host's ambient
  configuration. A scratch `HOME` hides the operator's `.npmrc` and git
  credential helper, which is correct, and leaves nothing in their place.
- N4. **Manager version pinning.** A self-switching manager downloads the
  pinned version into the scratch `HOME` every time. pnpm 9 (`v3`) and pnpm 10
  (`v10`) differ in store layout, and one kit cannot declare both.
- N5. **Runtime version.** Nothing reads `.nvmrc`, `.node-version` or
  `engines`. The runtime is whatever the toolchain directories hold.
- N6. **Lifecycle scripts.** The runner disables them, the kit's `online`
  command enables them, and the TypeScript kit's hook runs them unconfined.
  pnpm 9 runs every dependency's scripts by default, while pnpm 10 runs only
  an allowlist. A repository's `.pnpmfile.cjs` is repository code that pnpm
  loads even during `fetch`.
- N7. **Reuse.** Without a keeper, each invocation starts cold. The operator's
  store is invisible (correctly), and D12 of ADR-2026-10-08 forbids sharing it.
- N8. **Time.** The runner's single five-minute timeout and D7's 30-second
  reconcile do not partition a budget that also has to cover a clone.
- N9. **Confinement.** Nothing runs install-time package code under the
  executor confinement backend yet.
- N10. **Leaf hygiene.** D6's install record is written into the root, which
  the new caller's write check would read as an undeclared file.
- N11. **Hosts with no kits installed.** Kits are installed per host. A host
  with none selects no entry, and the hard-coded runner list is all it has.

## Decision

Dependency preparation becomes a library operation with an exported, stable
entry point that takes a **subject** instead of a session. The runner is one
caller and a non-agent executor is another. Both get the same fallback order,
the same confinement and environment rules, and the same typed result. The
keeper of ADR-2026-10-08 plugs in behind the entry point when it exists; until
then the entry point runs the kit's frozen install into a per-invocation cache.

### D1 — The entry point: package `runtime/depprep`

`donmai` exports a package `runtime/depprep`, beside `runtime/repokeeper`. It
imports the kit engine internally and exposes only its own types, so a program
in another module can call it.

```go
package depprep

// New validates cfg once per host process.
func New(cfg Config) (*Preparer, error)

// Prepare installs a leaf's dependencies through the kit entries that select
// it. It never waits for a keeper fill. The context deadline is the whole
// budget.
func (p *Preparer) Prepare(ctx context.Context, req Request) (*Report, error)

type Config struct {
    Entries     EntrySource      // required: composed kit entries for a leaf (D7)
    Scope       ScopeFunc        // nil: one host scope (ADR-2026-10-08 D3 default)
    Credentials CredentialFunc   // nil: no registry credentials, ever
    Keeper      Keeper           // nil: no keeper; exposure is session-only
    Confiner    Confiner         // nil: install-time package code never runs (D4)
}

type Request struct {
    Root      string            // absolute path of the mutable leaf (a clean checkout)
    Subject   Subject           // who the install is for (D2)
    Toolchain []string          // fixed directories; PATH is these plus /usr/bin:/bin
    Scratch   string            // caller-owned, per-invocation; HOME, TMPDIR and caches go under it
    Network   NetworkPolicy     // Allow or Deny; Deny allows only snapshot and store paths
    ProxyEnv  map[string]string // optional explicit proxy settings; nothing is inherited
    ReadOnly  bool              // true: report skipped, install nothing
}

type Subject struct {
    Kind  SubjectKind       // SubjectSession | SubjectInvocation
    ID    string            // opaque; logged only as a digest
    Attrs map[string]string // opaque; passed to ScopeFunc, never logged or emitted
}

type ScopeFunc      func(ctx context.Context, s Subject) (scope string, err error)
type CredentialFunc func(ctx context.Context, scope, manager string) (Registry, error)
```

The `Report` lists, per selected entry:

- the manager and its effective version, and the kit id and digest;
- the exposure and the path taken (`snapshot`, `store`, `online`, `skipped`
  or `failed`);
- the closed miss reason (ADR-2026-10-08 D10, extended in D8 below);
- the phase durations;
- the installed paths;
- whether package code ran, and the network posture.

It also carries a secret-free install record. The overall `Outcome` is
`ready`, `not_applicable`, `skipped` or `failed`. The `Report` is also returned
alongside an error, so a caller can always record what was attempted.

**Errors.** A non-nil error is a `*depprep.Error` with a code from a closed set
and a sentinel per code for `errors.Is`. Codes:

| Code | Meaning | Caller's usual mapping |
|---|---|---|
| `invalid_request` | `Root` is not an absolute directory, `Scratch` is missing, or the toolchain directories are unclean | bug; refuse |
| `entries_unavailable` | the entry source failed: an invalid kit, a composition conflict without a lock selection | refuse, not retryable |
| `manager_ambiguous` | two entries of one ecosystem match and the leaf does not decide (D1.2 of ADR-2026-10-08) | refuse, not retryable |
| `toolchain_unavailable` | the manager or runtime is in no toolchain directory, or the pinned manager version cannot be obtained under the network policy | refuse, host fix |
| `toolchain_mismatch` | the leaf pins a manager version that no selected entry's `versions` range covers (D5) | refuse, kit or repository fix |
| `network_denied` | every offline path missed and `Network` is `Deny` (`store_miss_offline`) | refuse |
| `credentials_unavailable` | the credential callback failed for the scope | refuse, retryable |
| `install_failed` | the last permitted step exited non-zero | refuse; the report names the step |
| `deadline_exceeded` | the budget ran out, or too little remained to start the online step (D3) | refuse, retryable |

The set is closed. A new code needs an ADR. A caller treats an unknown code as
`install_failed`.

**No entry selects the leaf.** Prepare runs nothing and returns `Outcome:
not_applicable` with miss reason `no_entry` and a nil error. It never falls back
to a built-in command list. What a leaf with no entry means is the caller's
decision: the runner carries on (D9), and a non-agent executor may refuse a
command that needs dependencies.

**Read-only leaves.** `Outcome: skipped`, as today.

**Stability.** The package follows the module's semantic version. A field is
added only with a zero value that keeps the earlier behaviour.

### D2 — Subjects, scope and registry credentials without a session

1. **The scope callback takes a subject.** ADR-2026-10-08 D3's
   `dependencyScope(ctx, session)` becomes `dependencyScope(ctx, subject)`.
   A session is `SubjectSession`. A non-agent invocation is
   `SubjectInvocation`. The OSS default returns one host scope for both,
   which is today's single-tenant behaviour.
2. **The scope is derived from what the subject was granted,** never from the
   host's ambient identity and never from the subject kind. A session and an
   invocation that resolve to the same scope string share that scope's stores
   and snapshots. That is the point of a scope: it names a set of registries
   and credentials, not a caller.
3. **An unresolved scope gives `session-only` exposure** (ADR-2026-10-08 D3),
   for an invocation as for a session. It is not an error.
4. **One credential callback.** ADR-2026-10-08 D3's
   `dependencyCredentials(ctx, scope, manager)` serves both the filler and the
   online step of any subject. There is no second path. Credentials are:
   - never the invocation's own command credentials, which a caller must not
     pass here;
   - never the daemon's environment;
   - never the host's credential helpers or user-level manager configuration,
     which a scratch `HOME` already hides.
5. **Delivery.** Credentials reach only the fetch phase (D4), as a per-run,
   mode-`0600` manager configuration file under the scratch directory, outside
   the leaf. It is named through the entry's declared variable (for the npm
   family, the user configuration path) and removed afterwards. They never
   appear in an environment that package code can read, in the report, in the
   catalog or in an event.
6. **With no credentials,** an install reaches only registries that need none.
   An authorization failure is the manager's own failure: `install_failed`.

### D3 — Fallback order and time bounds

Per selected entry, in order:

1. **Snapshot.** Restore and reconcile (ADR-2026-10-08 D7). Only with a keeper
   and a snapshot for the install key.
2. **Store view.** Offline `install` through the scope's view, when the bound
   generation covers the lockfile (D4 rule 7 there).
3. **Online, frozen, in two phases:**
   1. the entry's `fetch` into the invocation's own view or cache, with the
      scope's credentials and no package code;
   2. the entry's offline `install` from that cache, with no credentials, and
      with package code only as D4 allows.

   When a keeper exists, a miss also starts a background fill, as today.
4. **Refuse.** Return the typed error. No step falls back to a weaker policy:
   no non-frozen install, no resolution, no retry with scripts enabled, and no
   second online attempt.

ADR-2026-10-08 D6's single `online` command remains the opt-out form (its D11).
The two-phase form replaces it whenever Prepare runs, because it keeps
credentials and package code in different processes.

**Time bounds.** These are defaults; the context deadline always wins.

| Bound | Default | Rule |
|---|---|---|
| Whole budget | the context deadline; 5 min when there is none | today's runner timeout |
| Snapshot reconcile | 30 s | ADR-2026-10-08 D7.3 |
| Offline store install | 90 s | then fall through to online |
| Online floor | 60 s | the online step is not started with less remaining: `deadline_exceeded` |
| Reserve | 15 s | kept back for killing, cleanup and the report |

- Self-provisioning of a pinned manager (D5) counts against the online step.
- Every child runs in its own process group. The group is killed on the
  deadline, and a descendant holding an output pipe is waited for only
  briefly, as `runner/deps_install.go` does today.
- **Budget split for an executor whose budget covers a clone.** Bound the
  clone separately and hand Prepare the remainder. For a seven-minute budget,
  the recommended split is at most three minutes for the clone, leaving at
  least four for preparation. That is four times the online floor and well
  above the measured cold install.

### D4 — Install-time code: confinement and environment

1. **The environment is constructed, never inherited.** It contains:
   - `PATH`: the request's toolchain directories, then `/usr/bin:/bin`;
   - `HOME`, `TMPDIR` and every `XDG_*` base: fresh directories under
     `Scratch`;
   - `LANG`, and `CI=1`;
   - the entry's `store.env`, bound to the exposure (an empty per-run
     directory under `Scratch` for `session-only`);
   - the entry's `import.env` and, when D4 rule 3 applies, `no_code.env`;
   - `ProxyEnv`, when the caller supplies one.

   Nothing else passes: no daemon token, no loader variable (`DYLD_*`,
   `LD_*`), no `NODE_OPTIONS`, and no session authentication. This is the
   rule `runner/deps_install.go` already follows (lines 272–280), made
   complete.
2. **The fetch phase runs neither package code nor repository code.**
   - Lifecycle scripts and builds are off (ADR-2026-10-08 D4 rule 5).
   - Repository-supplied manager hooks are off too. pnpm's `.pnpmfile.cjs`
     and yarn's plugins are code from the leaf, and a fetch must not execute
     them. The entry declares how to turn them off (D6).
   - A lockfile that the manager refuses to install frozen without the
     repository's hook is not covered, with the new miss reason
     `requires_repository_code` (D8). Fixtures decide which managers do this.
3. **Package code runs only confined.** The offline install runs lifecycle
   scripts only when `Config.Confiner` is set. It runs under the executor
   confinement backend
   ([`ADR-2026-10-03-executor-os-confinement.md`](ADR-2026-10-03-executor-os-confinement.md)):
   - the writable set is the leaf, the invocation's view or cache, and the
     scratch directories;
   - there is no network where the backend can deny it, because an offline
     install needs none;
   - there are no credentials.

   Which scripts run is the repository's own manager configuration (pnpm's
   `onlyBuiltDependencies`, bun's `trustedDependencies`), enforced by the
   manager. The preparer neither widens nor narrows it.
4. **Unconfined, package code never runs.** Without a confiner, every phase
   runs with the entry's `no_code.env`. The report records
   `packageCode: skipped`. An entry that declares no `no_code` cannot be used
   unconfined: the miss reason is `confinement_unavailable`, and the entry is
   refused. A repository that needs a built native module then fails when its
   command runs, visibly. It is never fixed by running scripts unconfined.
   This holds for sessions too. It is what the runner does today, and it
   replaces the execution-security gate that skips the install entirely
   (S2): above the weakest level, the install runs confined or with package
   code off.
5. **The leaf stays clean.** For `SubjectInvocation`, the install record goes
   into the `Report` only, never into the leaf's reserved metadata. Every path
   the install creates must be inside `snapshot.installed` and ignored by git
   in the leaf. Otherwise the report names it, and the caller's write check
   sees an ordinary change. Sessions keep ADR-2026-10-08 D6.3's in-root record.

### D5 — Manager and runtime versions

1. **The leaf's pin wins.** For Node, the leaf's `packageManager`
   (`name@version`, optionally `+hash`) is the effective manager and version.
   The preparer runs the entry's `version` command in the leaf, with the
   constructed environment. Self-switching managers (pnpm's own version
   management, corepack) then report the pinned version, and the preparer
   records it.
2. **Obtaining a pinned manager is a download,** so it happens only in the
   online step. Without a keeper, the downloaded manager lives in the scratch
   directory, as measured. With a keeper, an entry may declare its tool-cache
   paths as `store.content`, and they are filled and exposed like any store
   content. Where the pin carries a hash, the manager verifies it. A pin
   without one is recorded as unverified; it is not refused.
3. **Entries select by version.** An entry may declare `versions`, a semver
   range over the effective manager version. Composition is keyed by
   (manager, range), and ranges of one manager may not overlap within a kit
   or across the composed set. Selection first picks the manager, as today,
   then the entry whose range covers the effective version. If none does, the
   result is `toolchain_mismatch`. A missing `versions` covers every version.
   Store identity already includes the layout (ADR-2026-10-08 D3), so a pnpm
   9 store (`v3`) and a pnpm 10 store (`v10`) never mix.
4. **The runtime is not switched.** The preparer never installs or selects a
   runtime: no version managers, and `.nvmrc` and `.node-version` are not
   read. It resolves the runtime from the toolchain directories and records
   its version and ABI, which are already in the install key (ADR-2026-10-08
   D7.1). `engines` checks are the manager's (its engine-strict setting).
   Runtime selection stays a Layer 4 toolchain demand, and deciding it is
   separate work.

### D6 — Manifest additions and their revision

The entry gains three things:

- `versions`: a semver range string (D5).
- `[provide.dependency_store.no_code] env`: the settings that make every phase
  run no package code and no repository-supplied manager hooks. For pnpm 9 and
  10, the candidates are `npm_config_ignore_scripts` and
  `npm_config_ignore_pnpmfile`. pnpm 11 reads only `PNPM_CONFIG_*`. Fixtures
  decide (ADR-2026-10-08 D1 rule 1).
- `[provide.dependency_store.credentials] config_env`: the variable that
  names the per-run credential file (D2 rule 5). For the npm family this is
  the user configuration path variable.

Composition carries each entry's **verified package root**. A package path in
an entry (`relocate`) resolves only against that root, never against the leaf.

**The revision.** No published kit declares `donmai.dev/v2` yet. Released
parsers apply strict keys to v2, so a v2 manifest carrying these keys is
rejected by them, never half-applied. Two options:

- **A (proposed).** Amend `donmai.dev/v2` in place before its first
  publication, and record the amendment in `005`'s revision table.
- **B.** Add these keys as `donmai.dev/v4`, after the reserved `v3`.

The founder decides. Either way, a consumer that does not understand the keys
rejects the manifest.

### D7 — Where entries come from; hooks; the official kits

1. **The entry source.** `daemon`'s kit registry implements
   `depprep.EntrySource`. For a leaf it composes the entries of every enabled
   kit whose `lockfiles` the leaf holds, whether or not the kit's `detect`
   rules matched. Dependency stores are selected by lockfile (ADR-2026-10-08
   D1.2), and a plain JavaScript repository with a lockfile but no
   `tsconfig.json` must still select its manager's entry. Composition
   conflicts follow the existing lock rule.
2. **Preparation never runs a hook.** `hooks.post_acquire` is not part of
   dependency preparation. A kit that declares a manager's entry must not also
   install that manager's dependencies in a hook.
3. **Hook path resolution.** Until `donmai.dev/v3` types package paths, a
   hook string that is a relative path resolves against the kit's verified
   package root, or is refused, and never against the leaf. Inline shell text
   keeps running with the leaf as its working directory.
4. **The first official declarations.**
   - **The TypeScript foundation kit:**
     - a pnpm entry for `versions = ">=9 <10"` (the `v3` store layout);
     - a pnpm entry for `versions = ">=10 <11"` (ADR-2026-10-08's entry);
     - `no_code` and `credentials` blocks on both.
   - **The Go kit:** the Go modules entry (`fetch = "go mod download"`,
     `verify = "go mod verify"`, a `proxy` exposure, no snapshot). Private
     modules fetched over git use only credentials from the callback, never a
     host credential helper (the companion corpus's residual).
   - **The Next.js framework kit** declares nothing. It composes on the
     foundation kit, and declaring pnpm twice would conflict.
   - **Both foundation kits drop their `post_acquire` hooks.** The hooks'
     install branches are replaced by the entries, including the TypeScript
     hook's non-frozen `pnpm`, `yarn` and `npm` installs.
   - **Each changed kit is a new signed package version.** Its manifest
     moves from `rensei.dev/v1`, the legacy v1 spelling, to the dependency
     revision. Daemons that predate the revision reject it, so the catalog
     keeps the previous v1 versions installable for them.
   - npm, bun, yarn, cargo, uv and pip follow ADR-2026-10-08 Phase 3.
5. **A baseline for hosts with no kits installed (proposed; the founder
   decides).**
   - **What ships.** The daemon binary carries the official kits' signed
     dependency entries for the managers it hard-codes today, pnpm and Go,
     verified against the embedded trust root.
   - **When they apply.** Only for a leaf where no installed, enabled kit
     declares that manager. An installed kit always wins, and an operator
     setting disables the baseline.
   - **Why.** Without it, removing the runner's hard-coded list (D9) is a
     regression on every host that has no official kit installed.

### D8 — Observability additions

- `dependency.install.*` events and daemon stats gain `subject_kind`
  (`session` or `invocation`). They carry no subject id or attribute.
- The closed `DependencyMissReason` enum gains three values:
  - `requires_repository_code`: the frozen install needs a repository-supplied
    manager hook (D4 rule 2);
  - `confinement_unavailable`: the entry has no `no_code` and no confiner is
    set (D4 rule 4);
  - `toolchain_mismatch`: no entry's `versions` range covers the leaf's pin
    (D5).
- The report and events record whether package code ran.

### D9 — Migration of the runner

- **The runner becomes a caller.** It calls `Prepare` with `SubjectSession`,
  and its two hard-coded commands are deleted once one of these holds:
  - the baseline of D7.5 is accepted and shipped;
  - every supported host is known to have the official kits installed.
- **The golden file.** With no keeper and the baseline entries, the commands
  and environment the runner runs must match today's install. This is
  ADR-2026-10-08's "Opt-out" test.
- **The outcome wire** (`agent.DependencyPreparation`) gains a per-manager
  list beside the two fixed fields. The fixed fields remain for older readers.
  The recovery handoff is unchanged.
- **Best-effort is preserved.** For sessions, an error from `Prepare` is
  logged and the session continues, as today. Only non-agent callers turn it
  into a refusal.

### D10 — Behaviour before the keeper exists

With `Config.Keeper` nil, every subject gets `session-only` exposure:

- each install fetches online into a per-run cache under `Scratch`, and that
  cache is discarded with the scratch directory;
- nothing is shared between runs, so no tenancy or poisoning question arises;
- the cost is a cold install per run.

This is the shipping state until ADR-2026-10-08's keeper slices land behind
`Config.Keeper`. The keeper never changes `Prepare`'s signature, codes or
fallback order.

## Consequences

### Positive

- **Any executor can prepare dependencies.** A non-agent executor gets a
  supported way to prepare a checkout, with typed refusals instead of a
  missing module at run time.
- **One path for every subject.** Sessions and invocations share one fallback
  order, one environment rule and one confinement rule, and the runner loses
  its manager list.
- **Credentials and package code never meet.** Credentials reach only a phase
  that runs no code. Package code runs only confined.
- **Version pins are honoured** and recorded. pnpm 9 and pnpm 10 repositories
  each get the right entry.
- **The kit defects are fixed.** The hook path defect and the non-frozen
  TypeScript hook stop installing dependencies.

### Negative

- **More moving parts.** A new exported package with a compatibility promise,
  a manifest revision decision, and two entries per pnpm major.
- **Some repositories stop working unconfined.** Those that need lifecycle
  scripts fail at command time on hosts without a confinement backend, until
  that backend runs the install.
- **Cold installs repeat.** Until the keeper exists, every invocation pays a
  cold install and a manager download. For a large monorepo that can be
  minutes.

### Risks

- **Fixtures must track manager settings.** The `no_code` settings depend on
  manager configuration names that change between majors (pnpm 11).
  ADR-2026-10-08's fixtures catch it.
- **A self-switching manager is downloaded code.** It runs before any
  confinement applies to the install. The pin's hash, where present, is the
  check.
- **A shared scope is still a shared scope.** An invocation that shares a
  scope with sessions shares its stores. A scope derivation that is too
  coarse leaks across the control plane's tenancy boundary. The companion
  corpus owns that derivation.

## Alternatives considered

- **Export the runner's two commands as they are.** This is the smallest
  change. It is rejected because it entrenches the hard-coded list that
  ADR-2026-10-08 D1.6 removes, and a second caller would make removal harder.
- **Let the executor run the kit's `post_acquire` hook.** Rejected. The hook
  resolves against the repository (Context 5), installs non-frozen, and runs
  scripts unconfined.
- **Put the entry point in the `daemon` package.** Rejected. Preparation
  needs the kit engine, not a daemon, and a library caller should not
  construct one.
- **Mount the operator's store read-write for invocations.** Rejected, as in
  ADR-2026-10-08 D12.
- **One online command with credentials and scripts together** (the existing
  `online`). Rejected for Prepare, because package code would see the
  registry credentials. It stays the opt-out form.

## Affected documents

Edited in the accepting commit:

- `ADR-2026-10-08-kit-dependency-stores.md`
  - a forward note: D3's scope callback takes a subject;
  - D6 is realized by `runtime/depprep`, and its online step is two-phase;
  - D10 gains three miss reasons and `subject_kind`.
- `003-workarea-provider.md` § "Dependency keeper": the entry point and the
  subject.
- `005-kit-manifest-spec.md` § "Dependency stores":
  - `versions`, `no_code` and `credentials`;
  - lockfile-based eligibility;
  - the revision row under option A or B;
  - hook path resolution until `v3`.
- `011-local-daemon-fleet.md`: the baseline setting, if D7.5 is accepted.
- The companion private corpus gets a mirrored stub. It carries invocation
  scope derivation, registry credential release to an invocation, and the
  first non-agent executor's use of the entry point.

## Affected work items

None are cited here. Tracker references and the unit breakdown live in the
companion private corpus and its run records.

## Implementation notes

- **`runtime/depprep`** imports `internal/kit` and the confinement package. It
  must not import `daemon`. `daemon` implements `EntrySource` and imports
  `depprep`.
- **The execer** carries forward today's process-group and output-bound
  behaviour from `runner/deps_install.go`.
- **Fixtures** for D4 rule 2:
  - a `.pnpmfile.cjs` that writes a marker, with no marker after the fetch;
  - a dependency with a postinstall marker, with no marker unconfined;
  - the same dependency allowlisted, with the marker present only when
    confined.
- **Fixtures** for D5: a leaf pinning pnpm 9 selects the `v3` entry, and a
  leaf pinning a version no entry covers gives `toolchain_mismatch`.
- **A golden test** for D2: the credential file exists only during the fetch
  phase, and is absent from the environment of the install phase.
