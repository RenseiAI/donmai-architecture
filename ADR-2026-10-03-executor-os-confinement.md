---
status: Accepted
date: 2026-10-03
boundary: shared
split: inline-addenda
---

# ADR-2026-10-03 — Executor OS confinement for harnesses without a sandbox of their own

**Status:** Accepted 2026-10-03 (product-owner acceptance, as drafted).
Architecture only: implementation, release and activation are pending. The
corpus edits listed under "Affected documents" landed in the accepting commit;
the source-side text updates of D6 land with the implementing change.
**Date:** 2026-10-03
**Boundary:** shared (OSS-canonical here: attestation granularity, the writable
set, the qualifying primitives, composition, the self-test and the refusal
reasons. A composing binary's own host profile and the hosted control plane's
later minimums live in the platform corpus's mirrored stub.)
**Authors:** architecture lane, filed by the coordinator session

## Context

A product-owner ruling of 2026-10-03 asks for real OS confinement for sessions
of a harness that has no sandbox of its own, `pi` first: its writable roots
limited to its own repository and its session state, and read-only
repositories actually read-only. `ADR-2026-09-27-execution-security-levels.md`
already reserved the slot — its rendering table gives the "extension API, no
native policy" family `executor OS sandbox or placement only` for the file and
network dimensions — and nothing fills it yet.

The as-is, stated from the OSS `donmai` source:

1. **pi has no permission system and no sandbox.** The runner's policy
   extension is an in-process boundary: a hostile model output can only call
   the overridden tools, but a tool execution runs as the spawning user. The
   package documentation (`provider/harness/pi/doc.go`) says so, and adds that
   OS enforcement "stays the sandbox provider family's job". pi's
   execution-security rendering declares nothing above index 0, because path
   containment on the file tools does not confine the bash tool
   (`provider/harness/pi/execution_security.go`).
2. **A pi session cannot hold a read-only repository at all.** A declared
   `read-only` leaf requires the bound executor to attest
   `repositoryAuthorityEnforcement: 'isolated-read-only-v1'`
   (`ADR-2026-08-22` D6.6), and only one harness attests it, through its own
   native sandbox's writable roots. Even that harness does not declare
   `fileWrite: workarea`, because its sandbox leaves the shared temporary
   directories writable.
3. **The vocabulary exists and nothing produces it.** The `executor_os_sandbox`
   enforcing layer and the `os-sandbox` isolation level are defined and
   validated and never produced. The host's `executionSecurityEnforcement` is
   one host-wide value supplied by the embedding binary and not probed, and the
   generic sandbox tag is derived from it. The only **per-harness** attestation
   on the registration wire is the workarea-executor list (`WorkareaExecutors`:
   one `ExecutorCapabilityAttestation` per harness id, adapter version,
   manifest digest and session modes, carrying `repositoryAuthorityEnforcement`),
   added because a host-wide flag "would let an enforcing harness accidentally
   admit work for a non-enforcing sibling harness".
4. **No OS confinement exists for pi on macOS or Linux.** The OSS layer has no
   namespace, Landlock or seccomp policy and no macOS profile. The OSS spawner
   exposes no command wrapper; its only composer seam mutates the spawn
   environment. A composing binary can therefore wrap a worker in its own
   macOS profile only through that seam and a self re-exec, which jails the
   whole worker subtree. Such a profile is a privacy and control-plane jail,
   not a writable-root confinement.
5. **The runner is the wrong place to confine.** pi is spawned in two places:
   the headless child (`provider/harness/pi/pi.go`, `spawnChild`) and the
   interactive PTY child (`provider/harness/pi/interactive.go`, through the PTY
   host and the session shim, which is the worker process re-entered). In both,
   pi's parent is the worker, and the worker writes its own state outside the
   workarea: logs, shim journals and registry, receipts, the host state home.
   Confining the worker either grants those writes to the harness too or breaks
   the worker.
6. **Today's writable state is undeclared.** pi's state sits inside the
   selected leaf (`<cwd>/.pi`, agent home `<cwd>/.pi/agent-home`); `HOME` and
   `TMPDIR` are inherited from the runner; no toolchain cache variable is set.
   New workareas are provisioned by clone (the worktree-add strategy has no
   caller), but a retained legacy worktree-add session still carries a `.git`
   file pointing into a shared base clone. `ADR-2026-08-30` proposes
   `state/<harness-key>/` for harness state; it is Proposed, not Accepted.

Precedents this record composes with, unchanged:

- `ADR-2026-09-27` D1 (`fileWrite: workarea` is the session's workarea plus
  executor-owned temporary and state paths; `isolation: os-sandbox` is an OS
  sandbox the harness cannot widen), D2.5 (one answer for every session mode),
  D3.1 (attestation by negative probe on the exact version, then a per-session
  record), D3.2 (achievable level is the strongest of the placement's and the
  harness rendering's), D3.4 (placement-owned configuration only tightens),
  D3.5 (no false sandbox claim), D4 (no channel added; enforcing layers in the
  receipt) and D5 (the refusal codes).
- `ADR-2026-08-22-session-owned-multi-repository-workarea.md` D6.6–D6.8
  (executor-owned boundary; same-identity permissions are not enforcement; no
  enforcement, no candidate), D8.6 (the legacy sibling environment variable is
  never an attestation), D9 (legacy flat workareas) and proof obligation 10
  (the read-only negative proof, from the real harness, through the production
  executor binding).
- `ADR-2026-08-12-pi-extension-delivery-seam-and-capability-pack-boundary.md`
  D4.2 — isolation is proven by observing writes, not by asserting environment.
- `ADR-2026-08-06-harness-adaptation-plan-and-receipt.md` D6 — headless and PTY
  evidence stay separate.
- `ADR-2026-08-12-placement-composition-law-and-single-fallback-rule.md` D1.2
  and the `ADR-2026-08-13` addendum — a loud, typed empty set; a closed reason
  plus a stable rule id; detail display-only.
- `001`'s boundary contract, rules 2 and 5 — the OSS layer ships the working
  implementation, and a composer extends it through function callbacks, not
  subprocesses.

## Decision

The executor confines the **harness process itself**, at the harness's own
spawn and in both session modes, whenever a session needs a level that only an
executor boundary can give that harness. The harness's adaptation manifest
declares the layer, the host proves its backend with a startup self-test and
publishes the result **per harness**, the writable set is a closed list, Linux
qualifies a mount namespace and not Landlock alone, exactly one confinement
applies to a harness process and a composer extends it with deny-only rules,
and a requested confinement that cannot be applied refuses the run with a
typed reason.

### D1 — Attestation is per harness: the manifest declares, the host proves, the list publishes

1. **The manifest declares the confinement channel.** The exact
   harness/version's execution-security rendering names `executor_os_sandbox`
   as the enforcing layer for each dimension it reaches, per session mode. For
   pi: `fileWrite: workarea` and `isolation: os-sandbox`, plus the
   `isolated-read-only-v1` repository-authority capability, each for headless
   and interactive. The declaration is a ceiling (`ADR-2026-09-27` D3.1) and is
   computed from a passing harness fixture (rule 4) on that adapter version,
   never hand-asserted (`ADR-2026-08-08` D4, `ADR-2026-08-13` D6). It is **not**
   a new adaptation channel or delivery strategy: the redirections the
   confinement needs (temporary directory, cache variables, state
   directories) ride the existing `environment_binding` channel, and the
   boundary itself is an executor layer reported in the receipt.
2. **The host proves each backend at start.** Before the daemon publishes any
   per-harness entry, the executor runs the probe set (rule 5) through the
   **production spawn binding** — the same code that will wrap the harness —
   with a probe process standing in for the harness, once per session mode's
   spawn path. The self-test record names the backend, its implementation
   version, the OS build, the probe-set version, each probe's outcome and a
   digest. The daemon re-runs it when the daemon binary, the OS build or the
   backend version changes; a record older than any of those is stale (D5).
3. **The list publishes per harness, never host-wide.** The existing
   per-harness executor attestation list gains, additively, a per-harness
   execution-security enforcement and the self-test reference. A level above
   index 0 is published for a harness only when that harness's manifest
   declares it for the session mode **and** the backend it uses passed a
   current self-test on this host. The host-wide `executionSecurityEnforcement`
   is untouched, and the generic sandbox tag stays derived from the host-wide
   value only, so confinement that covers only pi never lets the host advertise
   isolation for any other harness (`ADR-2026-09-27` D3.5). Viability reads,
   per dimension, the strongest of the host-wide value and the candidate
   harness's own entry (`ADR-2026-09-27` D3.2). The list carries an entry for
   every harness with a per-harness attestation, not only harnesses with a
   workarea protocol.
4. **The harness fixture proves the harness under the backend.** The harness
   conformance fixtures (checklist rows 9 and 10) run the probe set from inside
   the real pinned harness, through its own tool path (pi's bash tool), under
   each backend, with headless and interactive evidence kept separate. This is
   `ADR-2026-08-22` proof obligation 10's "from the real harness"; the host
   self-test proves the backend on a host and cannot stand in for it.
5. **The probe set.** Every probe runs inside the confined process:
   - **Outside the writable set, refused:** create, write, truncate, rename
     into or out of, remove, permission change, timestamp change and
     extended-attribute change, against the operator's home, the host state
     home (daemon configuration included), a decoy sibling session root, the
     workarea root's reserved metadata, a shared temporary directory (on
     Linux, a write to `/tmp` must land in `session_tmp`, not the host's), a
     shared cache directory and a base clone's git common directory.
   - **On a read-only leaf, refused:** write, create, rename, remove,
     permission change, remount or mount over the leaf; a hard link created in
     a mutable sibling to a file in the leaf; a write through a symbolic link
     planted in a mutable sibling.
   - **Widening, refused:** re-entering or replacing the confinement from
     inside (invoking the backend again, entering a new namespace and
     remounting) yields nothing newly writable, and every write proxy of D2.5
     either refuses or runs the command equally confined.
   - **Positive controls, accepted:** create, write, rename, remove and
     permission change in a mutable leaf, in harness state, in the per-session
     temporary directory and in a per-session cache. Without them a profile
     that denies everything passes.
   - **Discriminating control:** replacing the backend with none, or with
     same-identity `chmod`, turns the self-test red for the exact probe that
     the backend was holding.
6. **Each session carries its own record.** The runner's applied receipt
   reports `executor_os_sandbox` in `enforcingLayers` for every dimension the
   confinement reaches, with `evidenceDigest` set to the digest of a
   confinement record: the backend, the self-test digest relied on, the
   writable-set classes and read-only leaf names, the composer-rule digest
   (D4.3), the session mode and the rendered-spec digest. The record carries no
   credential and no raw home path. An attestation counts toward viability only
   once the control plane can verify that record at secret release
   (`ADR-2026-09-27` D3.1), unchanged.

```ts
// Additive, optional fields on the existing per-harness executor attestation.
interface ExecutorCapabilityAttestation {
  harnessId: string
  adapterVersion: string
  manifestDigest: string
  sessionModes: SessionMode[]
  repositoryAuthorityEnforcement?: 'none' | 'isolated-read-only-v1' // existing
  // ...existing workarea fields unchanged
  executionSecurityEnforcement?: Partial<ExecutionSecurityLevels> // NEW; absent dimension = index 0
  confinement?: ConfinementAttestation                           // NEW
}

type ConfinementBackend = 'macos-seatbelt' | 'linux-mount-namespace' | 'user-separation'

interface ConfinementAttestation {
  backend: ConfinementBackend
  backendVersion: string      // backend implementation version plus OS build
  probeSetVersion: string
  selfTestDigest: string
  sessionModes: SessionMode[] // spawn paths the self-test passed through
  testedAt: string
}

interface ConfinementRecord {
  recordId: string
  backend: ConfinementBackend
  selfTestDigest: string
  sessionMode: SessionMode
  writableClasses: Array<'mutable_leaf' | 'harness_state' | 'session_tmp' | 'session_cache'>
  readOnlyLeaves: string[]    // leaf names only
  composerRuleDigest?: string
  renderedSpecDigest: string  // what the receipt's evidenceDigest names
}
```

This slice produces `fileWrite` and `isolation` only. `fileRead`, `network`
and `credentials` stay at whatever the host-wide value and the harness's other
layers give (D7).

### D2 — The writable set under `fileWrite: workarea` is a closed list

The harness and every descendant may write **only** to:

| Class | What | Under `ADR-2026-08-30` (if Accepted) |
|---|---|---|
| `mutable_leaf` | each repository leaf declared `mutable`, including its own `.git` directory | `repos/<repository-key>/` |
| `harness_state` | the harness's documented per-session state directories (`ADR-2026-08-12` D4.1); today inside the selected mutable leaf, and so already covered by it | `state/<harness-key>/` |
| `session_tmp` | an executor-owned per-session temporary directory outside every repository leaf, released with the root; `TMPDIR`, `TMP` and `TEMP` bound to it | `state/<harness-key>/ephemeral/tmp/` |
| `session_cache` | per-session toolchain caches (D2.2) | `state/<harness-key>/ephemeral/cache/` |

plus the device nodes a process needs (null, zero, its own terminal and file
descriptors). Everything else is read-only to the harness. Named explicitly,
because each has been assumed writable somewhere: the workarea root itself and
its reserved metadata (a harness that can rewrite the declaration record can
rewrite its own authority); every declared `read-only` leaf, which wins over
any broader rule; runner-injected artifacts such as the trust-boundary
extension, which the executor keeps outside the set even when they sit beside
harness state; the host state home; every other session's root; the
operator's home; shared temporary and cache directories; and any shared git
common directory.

**D2.1 — Shared `/tmp` does not count.** It is neither workarea nor
executor-owned: every process of the same user shares it, other sessions and
the operator included. On Linux the executor gives the harness a private
`/tmp`, `/var/tmp` and `/dev/shm` backed by `session_tmp`, which therefore
counts. macOS cannot remap them, so the profile denies writes to the shared
temporary locations (`/tmp`, `/var/tmp` and the per-user temporary and
cache directories the OS assigns); `TMPDIR` redirects well-behaved tools,
and a tool that hard-codes `/tmp` fails with a permission error instead of
writing into a shared namespace. An executor that leaves shared temporary
locations writable may still attest `isolation: os-sandbox` and
`isolated-read-only-v1`, but not `fileWrite: workarea` — the same
conclusion the native-sandbox harness's rendering already records.

**D2.2 — Toolchain caches are per session, seeded, never shared
read-write.** Each cache variable the adapter or a kit declares (`GOCACHE`,
`GOMODCACHE`, the npm cache, the pnpm store, and any other) is bound to a
per-session directory. Speed comes from **seeding, not sharing**: the
executor may clone the host's warm cache into the session's directory with a
copy-on-write clone where the filesystem has one, and may expose a warm
cache **read-only** where the tool can consume it without writing (a module
proxy reading a local directory, a package store imported by clone or copy).
A shared read-write cache is a write path into every later session that
trusts its entries. An operator may still allow one on a host for
throughput, but that host's per-harness attestation for `fileWrite` is then
`host`, visibly, never `workarea`; `isolation` and `isolated-read-only-v1`
do not depend on it and may still hold.

**D2.3 — Links do not bypass the set.** The set is enforced by path, and a
hard link is one inode reachable from two paths. The executor materializes
writable leaves and caches by clone, copy or copy-on-write, never by hard
link to an inode outside the set, and a package manager in a confined
session imports by clone or copy, because a hard-link import makes a shared
store writable through the leaf. The backend refuses a new hard link inside
the set to a file outside it, and judges a write through a symbolic link at
its target. Both are probes (D1.5).

**D2.4 — A shared git common directory is never writable.** A base clone's
common directory holds every attached worktree's refs and objects and the
configuration git reads on every command, hook paths included; granting it
lets one session rewrite another's branch or plant a hook that runs outside
any confinement. A confined session's mutable leaves are self-contained
repositories with their own `.git` directory, and may borrow objects from a
base clone read-only through git's alternates mechanism, since git writes
new objects only to the session's own object store. New workareas are
already provisioned by clone. A retained legacy worktree-add session
(`ADR-2026-08-22` D9) is not confinable: confinement requested for one is
refused with `writable_set_unrepresentable`, and it is never confined with
the common directory granted.

**D2.5 — Write proxies are outside the set too.** A process the harness asks
to run something outside the boundary writes wherever that process can, so a
boundary that leaves such a path open attests neither `fileWrite: workarea`
nor `isolation: os-sandbox` (an OS sandbox the harness cannot widen). The
backend closes at least: submitting jobs to the OS's per-user job launcher or
service manager; opening documents or applications through the desktop's
launch service, and sending inter-application scripting events; attaching to
or writing the memory of a process outside the boundary; and connecting to
local sockets outside the writable set (a terminal-multiplexer server, a
container runtime, a per-user message bus), except sockets the adapter
declares for the session, such as its own control channel or an agent socket
the `credentials` level grants. Each is a widening probe (D1.5). The
execution layer's own control surfaces, the daemon API and spawn authority,
are governed by their own authorization, not by this boundary.

**D2.6 — Harness state inside a leaf limits cwd selection.** While a
harness's state lives inside the selected leaf, that harness cannot select a
`read-only` working directory under confinement, and it declares no support
for one. That changes when its state moves to `state/<harness-key>/`.

### D3 — Linux: a mount namespace qualifies; Landlock alone does not

1. **The qualifying primitive is a mount namespace the harness cannot
   reshape.** The executor builds the harness's view before exec: the
   filesystem read-only, the writable set bind-mounted read-write, each
   read-only leaf and the root's metadata bind-mounted read-only over
   themselves, private temporary mounts (D2.1), and none of the host's
   per-user runtime or socket directories that would reach a write proxy
   (D2.5), inside its own process namespace so no process outside the
   boundary is visible to attach to. The harness then runs with no new
   privileges, no capabilities, and no way to regain mount authority: nested
   user namespaces disabled, or every inherited mount locked so a nested
   namespace cannot remount it writable. On a read-only bind mount,
   write, create, rename, remove, permission, owner, timestamp and
   extended-attribute changes all fail, and a hard link across mounts fails, so
   the whole D1.5 probe set holds by construction. The namespace may be entered
   through an unprivileged user namespace, bubblewrap-style, or built by a
   privileged executor that drops privilege before exec; the backend is the
   same either way.
2. **Landlock alone does not qualify.** It restricts writing, creating,
   removing, renaming and truncating, but not permission, owner, timestamp or
   extended-attribute changes, and `ADR-2026-08-22` D6.6 requires permission
   changes refused. Adding a seccomp filter on the permission-change calls
   cannot be scoped by path, so it also refuses `chmod +x` inside a mutable leaf
   and breaks ordinary work. One probe set serves both `fileWrite: workarea`
   and `isolated-read-only-v1`, so a Landlock-only executor attests neither.
   Landlock may be layered under a qualifying namespace as defense in depth; it
   is never the attesting layer.
3. **Containers: read-only leaves come from provisioning or from user
   separation.** User namespaces are often refused inside containers, by the
   runtime's default system-call filter or by a security module, so the
   executor's self-test fails there and it publishes no confinement entry.
   Read-only leaves then come from one of two places:
   - **Provisioning.** The provisioning control plane creates the container
     with read-only leaves as read-only mounts and the writable set as the only
     writable mounts, and records that in its provisioning record with the
     `provider_sandbox` layer (`ADR-2026-09-27` D4). The executor does not
     attest what provisioning did.
   - **User separation.** The executor runs as a distinct identity that owns
     the read-only leaves and the root's metadata, and runs the harness as
     another OS user who can write only the writable set. The harness cannot
     change permissions on files it does not own, so this is not the
     same-identity case `ADR-2026-08-22` D6.7 excludes. It attests
     `isolated-read-only-v1`, and `fileWrite: workarea` only when the probe set
     also finds no writable location outside the set (a container per session,
     or temporary directories private to that identity). It claims no
     `isolation` level of its own; the container's class comes from
     provisioning.

   An executor that could not build its boundary never falls back to `chmod`
   or to Landlock alone and attests anyway.

### D4 — Composition: one confinement per harness process, composer rules through a callback, both modes

1. **Confinement wraps the harness spawn, not the worker.** It applies at the
   headless child's spawn and at the interactive PTY child's spawn inside the
   session shim. The worker and shim stay outside and keep writing their own
   state. Every descendant of the harness inherits the boundary: a macOS
   profile is inherited and cannot be removed, and a mount namespace is
   inherited.
2. **No nested profile.** On macOS a process already under a profile cannot
   apply a second one, so an outer profile around the worker makes the inner
   confinement impossible. When the executor confines a harness, no
   composer-supplied profile wraps that session's worker or shim. An executor
   that finds itself already sandboxed at spawn refuses with `nested_sandbox`;
   it never runs under the outer profile and reports the inner level. On Linux
   nesting is possible, and the rule is the same for attestation: the
   executor's namespace is the attesting layer, and an outer container is
   provisioning's layer, recorded separately. A harness that applies its own
   OS sandbox is not wrapped by executor confinement (D7).
3. **Composer rules arrive through a deny-only callback.** The OSS layer
   exposes a pluggable function callback that a composing binary sets. Per
   confined spawn it returns rules from a closed, backend-neutral vocabulary,
   and the executor appends them after its own rules so they always win. A
   rule can only deny; the callback cannot add an allow or remove an executor
   rule, so the attested levels hold whatever it returns. A rule the active
   backend cannot render refuses the spawn with `rule_unrenderable`; it is
   never dropped. The self-test (D1.2) calls the callback with a probe context,
   so a composer that returns an unrenderable rule fails at start, not at the
   first session.
4. **Both session modes, one answer.** Headless and interactive get the same
   writable set, backend, composition and refusals (`ADR-2026-09-27` D2.5),
   with evidence kept per mode (`ADR-2026-08-06` D6). A harness whose manifest
   declares confinement for one mode only cannot run in the other at a level
   that requires it: `mode_unsupported`, never a lower level for that mode.
5. **Adoption and resume.** A confined process stays confined across a daemon
   restart and shim adoption, because the boundary belongs to the process.
   A resume, which is a new process, re-renders and re-applies the confinement.
   A session is never resumed unconfined; a resume onto a host whose self-test
   no longer passes is refused with the typed reason.

```ts
type ConfinementRule =
  | { kind: 'deny_read'; path: string; scope: 'literal' | 'subtree' }
  | { kind: 'deny_write'; path: string; scope: 'literal' | 'subtree' }
  | { kind: 'deny_service_lookup'; service: string } // macOS named services; unrenderable elsewhere

// Set by a composing binary; called once per confined spawn and once by the self-test.
type ConfinementExtraRules = (ctx: {
  sessionId: string
  harnessId: string
  sessionMode: SessionMode
  backend: ConfinementBackend
  workareaRoot: string
}) => ConfinementRule[]
```

### D5 — Requested but unavailable refuses the run, with a typed reason

1. **When confinement is requested.** Any one of:
   - the session's effective `fileWrite` is `workarea` or its `isolation` is
     `os-sandbox`, and the candidate meets that level through the harness's
     `executor_os_sandbox` layer rather than through the placement;
   - a declared `read-only` leaf needs `isolated-read-only-v1` from the
     executor;
   - placement-owned configuration, such as a per-harness setting in the
     host's daemon configuration, requires confinement for the harness. This
     only tightens (`ADR-2026-09-27` D3.4), and it is how a single host makes
     every session of a harness confined before any control plane stamps a
     level.

   Confinement applies exactly when requested, never opportunistically, so a
   session's behaviour does not depend on which host happened to claim it.
2. **Refused at the earliest point that knows, with zero spawn and zero secret
   delivery.** At viability, a candidate whose per-harness entry lacks the
   level is excluded with `execution_security_unmet` and rule id
   `execution-security.<dimension>`, or with the repository-authority
   exclusion of `ADR-2026-08-22` D6.8. At spawn, where the entry was present but
   the confinement cannot be applied, the adaptation plan is denied with
   `execution_security_unrenderable`, carrying a closed
   `ConfinementUnavailableReason`. No refusal code is added to
   `ADR-2026-09-27` D5.
3. **No fallback.** Never `chmod`, never Landlock alone, and never "run
   unconfined and report index 0" when the request came from any rule-1
   trigger. A host whose self-test fails stays registrable, publishes index 0
   for that harness, and work that needs confinement routes elsewhere or fails
   loudly (`ADR-2026-08-12` D1.2). A host whose own configuration requires
   confinement still starts; it refuses each affected session and raises the
   condition on the host-status signal
   (`ADR-2026-08-07-onboarding-is-the-only-user-action.md` D7), not only in a
   log line.

```ts
type ConfinementUnavailableReason =
  | 'backend_absent'               // no backend for this OS, or its implementation is missing
  | 'self_test_failed'             // a probe failed on this host
  | 'self_test_stale'              // daemon, OS build or backend changed since the last pass
  | 'nested_sandbox'               // the executor is already inside a profile (D4.2)
  | 'namespace_unavailable'        // the kernel or container refused the namespace
  | 'writable_set_unrepresentable' // e.g. a shared git common dir (D2.4), a hard-linked store (D2.3)
  | 'rule_unrenderable'            // a composer rule the backend cannot express (D4.3)
  | 'mode_unsupported'             // the manifest does not declare this session mode (D4.4)
```

The reason enum is closed; an unknown value is malformed and denies.
Human-readable detail is display-only.

### D6 — Text updates

The corpus edit landed in the accepting commit. The source edits are not
corpus changes and land with the implementing change, not before it:

- **pi package documentation** (`provider/harness/pi/doc.go`; source, lands
  with the implementing change). The sentence
  `OS/sandbox-family enforcement stays the sandbox provider family's job
  (E2B/container cells), unchanged.` is to be replaced with: "OS-level confinement is
  the executor's job, not this extension's: when a session's effective levels,
  its read-only repositories or the host's own configuration require it, the
  runner spawns pi inside the executor confinement of
  `ADR-2026-10-03-executor-os-confinement.md`, headless and interactive alike,
  and the receipt reports `executor_os_sandbox`. Container and microVM
  isolation stay with the sandbox provider family. Without that confinement a
  hostile tool execution still runs as the user." The sentence that pi itself
  ships no permission system and no sandbox stays: it remains true of pi. The
  adapter's execution-security rendering
  (`provider/harness/pi/execution_security.go`, today "index 0 only") gains
  the D1.1 declaration once its fixtures pass.
- **`004-sandbox-capability-matrix.md`, the Local column** (corpus; landed in
  the accepting commit). The host-wide cells
  stay as they are (`fileWrite: host`, `isolation: host-user`,
  `repositoryAuthorityEnforcement: none`), because they are the values every
  harness on a local host gets. The `fileWrite`, `isolation` and
  `repositoryAuthorityEnforcement` cells gain "per harness: `workarea` /
  `os-sandbox` / `isolated-read-only-v1` where the executor confines that
  harness and its self-test passes", and a dated amendment note explains that
  viability reads the strongest of the host-wide value and the candidate
  harness's own entry. The capability struct documents the per-harness entry,
  and § "Capability declarations for daemon mode" states that executor
  confinement is attested per harness and never raises the host-wide value or
  the generic sandbox tag.

### D7 — What this ADR does not decide

- **`fileRead`, `network` and `credentials` through the same layer.** The same
  profile or namespace can later carry them; each needs its own probes, and
  this ADR attests none of them.
- **Harnesses with their own OS sandbox.** They keep it. Executor confinement
  does not wrap a harness that applies its own macOS profile, which would
  nest. Whether a native-sandbox harness should also be executor-confined is a
  separate, per-harness decision.
- **Windows.** No backend; `backend_absent`.
- **Hosted control-plane minimums.** Mapped in the platform corpus once runner
  attestations count for routing there.
- **A read-only working directory for pi.** Waits on its state leaving the leaf
  (D2.6).

## Consequences

### Positive

- The first real producer of `executor_os_sandbox`, `os-sandbox` and
  `isolated-read-only-v1` for a harness with no sandbox: pi sessions can hold
  read-only repositories, and their writes stop at their own leaves and state.
- Per-harness publication keeps confinement honest on mixed hosts: one
  confined harness never lifts another harness's levels or the host's tag.
- The writable set is a closed list with named exclusions, so "workarea" means
  the same thing on both operating systems and in every session mode.
- Failure is typed and early: viability excludes before claim, spawn refuses
  before any secret moves, and an operator sees which probe or primitive
  failed.

### Negative

- Tools that write into the operator's home by default fail under confinement
  until their cache or state variable is redirected; each harness's
  conformance fixture has to enumerate what its toolchain needs.
- Per-session caches cost disk and cold-start time where no copy-on-write
  clone is available.
- A composing binary that wraps workers in its own macOS profile must stop
  doing so for confined sessions and move its denies into the callback.
- Containers without user namespaces need provisioning or user separation for
  read-only leaves; the executor alone cannot provide them there.
- Legacy worktree-add sessions cannot be confined; they age out under
  `ADR-2026-08-22` D9.

### Risks

- **macOS components that ignore `TMPDIR`.** Some system components write to
  OS-assigned per-user directories regardless of the environment. Mitigation:
  the harness fixture surfaces them; the answer is a redirect where one exists,
  otherwise that harness's macOS `fileWrite` attestation is `host`. Never a
  quiet allow.
- **Backend drift across OS updates.** Profile semantics or namespace policy
  can change under an OS update. Mitigation: the self-test is keyed to the OS
  build and goes stale on change (D1.2).
- **Socket path length.** A deep per-session temporary directory can exceed
  the platform's socket path limit for tools that create sockets there.
  Mitigation: the executor keeps `session_tmp` short; the fixture includes a
  socket probe.
- **Write proxies not yet enumerated.** D2.5 names classes, not a complete
  list, and an operating system can add a new way to run a command elsewhere.
  Mitigation: each discovered proxy becomes a probe, and a probe that passes
  through a proxy turns the self-test red rather than leaving a note.
- **Composer rules that break the harness.** A deny-only rule cannot weaken a
  level, but it can deny something the harness needs. Mitigation: that failure
  is visible in the self-test or the session, never a silent downgrade.

## Alternatives considered

- **Confine the runner or worker subtree.** Rejected: the worker writes state
  outside the workarea, so the boundary must either grant those writes to the
  harness or break the worker.
- **Raise the host-wide attestation.** Rejected: viability would then credit
  every harness on the host with a boundary only pi has — the defect the
  per-harness list was introduced to prevent.
- **Landlock alone, or Landlock plus seccomp.** Rejected (D3.2): it misses
  permission changes, and a system-call filter cannot be scoped by path.
- **Same-identity `chmod` on read-only leaves.** Rejected by `ADR-2026-08-22`
  D6.7: the harness can undo it.
- **Allow shared `/tmp` on macOS and still claim `workarea`.** Rejected
  (D2.1): it is a cross-session write channel.
- **Allowlisted shared read-write caches under `workarea`.** Rejected (D2.2):
  a cache every later session trusts is a write path into those sessions. It
  stays available as an operator choice that is reported as `fileWrite: host`.
- **Grant the git common directory for legacy worktree sessions.** Rejected
  (D2.4): it reaches every attached worktree's refs and the hook
  configuration.
- **Nest the executor's profile inside a composer's profile.** Rejected: the
  OS does not allow it, and an executor that ran under the outer profile only
  would report a level it did not apply.
- **Opportunistic confinement whenever a backend exists.** Rejected: the same
  stamp would behave differently on different hosts, and failures would depend
  on placement. Confinement applies exactly when requested.

## Affected documents

Landed in the accepting commit:

- `004-sandbox-capability-matrix.md` — the Local column's per-harness
  annotations, the struct documentation and the daemon-mode paragraph (D6).
- `ADR-2026-09-27-execution-security-levels.md` — a forward annotation on the
  rendering table's "Extension API, no native policy" row naming this ADR as
  the executor OS sandbox it defers to.
- `ADR-2026-08-22-session-owned-multi-repository-workarea.md` — forward notes
  after D6, on rule 6 (executor confinement is one qualifying boundary), and
  after D9 (a legacy worktree-add session is not confinable).
- `011-local-daemon-fleet.md` — a short section: the startup self-test, the
  per-harness publication, the host-status condition when a required backend is
  unavailable.
- `013-orchestrator-and-governor.md` — the read-only authority paragraph names
  executor confinement as a source of the attestation.
- `README.md`, `AGENTS.md` — index and read-order entries.

Not edited, deliberately: `ADR-2026-08-30-workspace-root-and-lazy-repository-materialization.md`
is Proposed. If it is Accepted, its D5 names `session_tmp` and
`session_cache` as executor-owned directories inside `ephemeral/`.

No `BOUNDARY-SYNC` region is touched.

## Affected work items

This corpus carries no tracker identifiers; the delivery work is named by
shape:

- the confinement package with the macOS profile and Linux mount-namespace
  backends, the probe set and the startup self-test;
- the per-harness attestation fields on registration and refresh;
- the pi adapter's rendering declaration, the environment bindings for
  `session_tmp` and `session_cache`, and the wrap at both spawn sites;
- the composer callback;
- harness fixtures in both modes and smoke coverage for a confined session.

## Implementation notes

- **Spawn sites.** The headless child's `exec.Command` and the PTY host's spawn
  under the session shim each gain a wrapped command built by the confinement
  package from the session's declaration and the self-test record. Today
  neither has a wrapper seam, and the spawner's only composer seam mutates the
  environment.
- **macOS backend.** A generated profile: reads allowed in this slice; a
  default deny on file writes; allows for the writable set; denies for
  read-only leaves and the root's metadata after the allows; denies on mount
  services, hard-link creation and the write proxies of D2.5; then the
  composer's rules last. The profile is written under the host state home,
  outside every session root.
- **Linux backend.** A pinned helper or an in-process namespace setup; either
  way the attestation names the implementation version.
- **Existing coupling.** The manifest capability check that today ties
  read-only authority to one harness's native sandbox mode generalizes to "the
  declared enforcing layer is attested for this harness and mode".
