---
status: Accepted
date: 2026-08-03
boundary: shared
split: sibling-extensions
---

# ADR-2026-08-03 — CLI noun tree: retire `fleet`, consolidate on `host` + `capacity`

**Status:** Accepted — architecture decision; the OSS `host` factory (D2), the OSS/downstream alias-and-deletion sequencing (D5), and most of the downstream `capacity`-migration work are implementation and release pending. Downstream `fleet` retirement (moving its leaves under `capacity`, deleting overdue aliases) proceeds now per the 2026-08-03 operator ruling; OSS `daemon`→`host` has not shipped. See § Implementation notes.
**Date:** 2026-08-03 (proposed and accepted same day)
**Boundary:** shared (OSS-canonical here; `status: Mirrored` stub plus a platform-extensions delta in `rensei-architecture`)
**Authors:** agent:claude, filed for mark
**Supersedes in part:** `ADR-2026-05-06-tui-noun-consolidation.md` (the three-noun decision and its one-release alias window)

## Context

`ADR-2026-05-06-tui-noun-consolidation.md` decided a three-noun top-level CLI
surface — `host` (this machine), `fleet` (other machines + per-project
routing), `capacity` (org-wide provider/pool config) — with the old flat
top-levels kept as hidden deprecated aliases "for one release." That ADR is
`Accepted` and OSS-canonical: it declares the noun tree itself OSS, on the
grounds that `afcli.RegisterCommands` wires the same tree into both the OSS
binary and any composing downstream binary.

Three months and roughly eighty-four downstream releases later, the decision
has only half landed, and the half that landed is inconsistent with the half
that did not. Everything below was verified against the two command trees as
they build today (2026-08-03), not read from prior audit notes.

### Finding 1 — the OSS binary never adopted the noun tree at all

The OSS binary has **no `host` command and no `capacity` command**. Its
top-level surface is still the pre-ADR flat shape plus `daemon`:

```
daemon  fleet  fleet-watch  worker  workarea  provider  kit  routing  project  status  …
```

Daemon lifecycle is `daemon install` / `daemon status` / `daemon doctor`, not
`host install`. `worker` and `fleet` are **visible and carry no Cobra
`Deprecated` marker**; the `EnableLegacyWorkerFleet` config field gates them
for *embedders* (default off), while the standalone OSS binary sets it `true`,
so a user of the OSS binary sees them as ordinary commands. There is a third,
unrelated `host` in the tree — `code host`, the code-intelligence warm host.

Two OSS-canonical docs assert otherwise and are therefore stale:
`011-local-daemon-fleet.md`'s command-surface note and example fences show
`<binary> host install`, and `014-tui-operator-surfaces.md` § "Noun model"
states "Both binaries speak the noun model … Composition lives at the
cobra-command-factory layer (`afcli.RegisterCommands`), so the noun model is
shared across binaries." Neither is true of shipped code. The noun tree is
assembled by hand in the downstream binary's own `main`, not exported by
`afcli`.

### Finding 2 — `fleet` means two incompatible things across the boundary

- **OSS `fleet`** supervises multiple local worker *processes* on one machine:
  `fleet start` / `stop` / `status` / `scale`, backed by a PID file. It is the
  pre-daemon local supervisor, explicitly superseded by `daemon`. `fleet scale`
  has never worked — it returns `"not yet supported — stop and start with new
  count"` unconditionally, a permanent stub. A sibling top-level `fleet-watch`
  is a *local* live dashboard for this host's sessions. `011`'s own title,
  "Local Daemon Fleet," and its body use "worker fleet" for the set of workers
  on one machine; `011` states plainly that multi-machine aggregation is a
  downstream extension.
- **Downstream `fleet`** enumerates *other machines* registered to an
  organization and sets a project's execution route (`fleet list`,
  `fleet show <id>`, `fleet route show|set|test`). It is wired directly in the
  downstream binary's `main`, entirely separate from `afcli`; the two `fleet`
  implementations coexist under one root without sharing a line of code.

So the same top-level noun denotes "this machine's worker processes" in OSS and
"every machine except this one" downstream. `ADR-2026-05-06` created that
inversion by assigning `fleet` the org-wide sense in an OSS-canonical document
while `011` (also OSS-canonical) uses it in the single-machine sense. The
downstream binary implements `ADR-2026-05-06`'s sense; the OSS binary
implements `011`'s. Both are "correct" against a canonical doc. That is the
defect.

`donmai/afcli/fleet.go` has **no `fleet route`** at all, correctly — there is
no control plane in OSS to route work against. `rensei-architecture`'s
`ADR-2026-08-03-execution-route-patch-semantics.md` already recorded this and
its companion addendum resolved `fleet route` as a *platform-only leaf under an
otherwise-shared noun*. This ADR takes the next step: a noun whose leaves are
entirely platform-only, and whose name already means something else in OSS, is
not a shared noun worth keeping.

### Finding 3 — the trees were renamed but never merged, leaving literal synonyms

In the downstream binary today:

- Org-level capacity (`capacity`, `fleet`) and this-machine capacity
  (`host capacity`, `host provider`) are sibling roots, even though `host`'s
  own one-line help advertises "daemon, capacity, local pool, installed
  providers, kits."
- `capacity pool …` and `execution pool …` are the *same* Cobra factory invoked
  twice (`executionPoolCmd()`), as are `capacity provider` / `execution
  provider` and `fleet route` / `execution route`. `execution` is a hidden
  deprecated alias; the duplication is literal, not merely similar.
- `fleet` and `machine` are the same factories (`machineListCmd()`,
  `machineShowCmd()`); `machine` is a hidden deprecated alias.
- `host capacity set` and the OSS `daemon set` accept the identical two-key
  allowlist (`capacity.maxConcurrentSessions`, `capacity.poolMaxDiskGb`) and
  write the same daemon config file. The downstream binary exposes that surface
  three times: `host capacity set`, `daemon set`, and the deprecated
  `worker capacity set`.
- The downstream `daemon` tree (17 leaf paths) is a full duplicate of the
  `host` lifecycle tree and is `Hidden` but **not** `Deprecated` — it prints no
  notice and has no removal date.

Verified leaf-path counts in the downstream binary: `host` 37, `capacity` 8,
`fleet` 5; hidden aliases `worker` 18, `kit` 9, `execution` 9, `workarea` 4,
`machine` 2, `provider` 2; hidden-but-undeprecated `daemon` 17.

### Finding 4 — the "one release" alias window closed long ago

`ADR-2026-05-06`'s aliases were to survive "one release." The rename landed
2026-05-06 and first shipped in the downstream binary's `v0.6.0`. As of
2026-08-03 the same aliases are still registered, and **84 tags** have shipped
since. Their `Deprecated` strings still say "will be removed in next release."
The window did not merely pass; the promise was unfalsifiable, because
"next release" was never bound to a version number.

### The constraint that makes this an ADR

`ADR-2026-05-06` § Context declares the CLI noun model OSS-canonical.
Retiring a top-level noun from that model therefore requires a decision in this
corpus, even though every command being consolidated is platform-only. The
downstream repository cannot unilaterally drop `fleet` without contradicting an
`Accepted` OSS ADR and two OSS reference docs.

## Decision

### D1 — Two top-level nouns, not three: `host` and `capacity`

`host` owns *this machine*. `capacity` owns *the organization's execution
capacity*. `fleet` is retired as a top-level noun.

| Top-level | Concept layer | Owns | Implemented in |
|---|---|---|---|
| `host` | This machine | Daemon lifecycle (install/uninstall/setup/run/start/restart/stop/status/logs/doctor/pause/resume/drain/update), this machine's capacity envelope and workarea pool, installed providers and kits, project admission, the local live-session dashboard | OSS; composed downstream unchanged |
| `capacity` | The org's execution capacity | Execution providers, pools, live instances (persistent hosts **and** on-demand sandboxes), project→pool routing, cost rollups | Downstream only; **name reserved** in OSS |

`capacity` is a **name reservation**, not an interface obligation. A
single-machine OSS deployment has no organization-wide capacity, so the OSS
binary ships no `capacity` command and this ADR asks for none. Reserving the
name in the corpus prevents a future OSS feature from claiming it with a third
meaning — which is precisely how `fleet` broke. This does not violate boundary
rule 2 ("the OSS layer ships a working implementation of every interface"),
because no interface is being declared here: a reserved noun is a naming
constraint on the OSS command tree, not a contract with an implementation.

### D2 — `host` becomes a real OSS command; `daemon` becomes its alias

`afcli` gains an exported `host` parent command that owns the daemon lifecycle
subcommands, the local capacity envelope, the workarea pool, providers, kits,
project admission, and the local live-session dashboard. `daemon` becomes a
hidden deprecated alias of `host` with a declared removal version.

This inverts today's OSS shape and makes `011` and `014` true rather than
aspirational. It also lets the downstream binary drop its hand-assembled `host`
tree and its hidden-undeprecated `daemon` duplicate, consuming one exported
factory instead. Until it lands, `011`/`014` must describe the OSS surface as
`daemon`, not `host` (see § Affected documents).

### D3 — What `fleet` means after this, on each side of the line

- **OSS.** `fleet` keeps exactly one meaning and it is **single-machine**: the
  worker processes supervised on this host. It is simultaneously declared
  **legacy and superseded by `host`/`daemon`**, and scheduled for removal:
  - `fleet` and `worker` gain a Cobra `Deprecated` marker in the standalone OSS
    binary (today they carry none), naming `host` as the replacement and a
    removal version.
  - `EnableLegacyWorkerFleet` stays default-off for embedders and is not
    re-enabled by any composing binary.
  - `fleet scale` is **removed**, not implemented. A subcommand that has only
    ever returned an error is not a capability with a deprecation cost.
  - `fleet-watch` is renamed `host watch` (it is a *this-host* dashboard), with
    `fleet-watch` retained as a hidden deprecated alias for one declared
    version. The downstream binary already re-grafts this command under
    `host watch`; D2 makes that the OSS shape too.
  - After removal, the word "fleet" survives **only in prose**, only in the
    single-machine sense (`011`'s title; the one-line summary text of
    `status`), and never as a command noun.
- **Downstream / platform.** `fleet` is retired as a top-level noun. Its five
  leaves move under `capacity`:

  | Today | After | Note |
  |---|---|---|
  | `fleet list` | `capacity show --kind persistent-host` | Already the same platform endpoint and the same wire row |
  | `fleet show <id>` | `capacity show <id>` | `capacity show` takes an optional instance id |
  | `fleet route show` | `capacity route show` | |
  | `fleet route set` | `capacity route set` | |
  | `fleet route test` | `capacity route test` | |

  No new server endpoint is required: `fleet list`/`fleet show` and
  `capacity show` already read the same live-capacity endpoint and render the
  same instance row; the persistent-host-only variant is a query filter. The
  move is a pure surface change.

  `fleet` becomes a hidden deprecated alias for exactly one declared version,
  then is deleted.

### D4 — Sub-noun placement rules (extending `ADR-2026-05-06`)

1. **One noun, one referent, at every depth.** A word may not appear at two
   depths meaning different things. This is why the org-side machine list does
   **not** become `capacity host` — `host` already means "this machine" at the
   top level, and `capacity host` would mean "any machine," reproducing the
   two-`provider` collision `ADR-2026-05-06` was written to kill. The org-side
   vocabulary is *instance* (matching the platform wire's own
   `instanceKind: persistent_host | on_demand_sandbox`), surfaced through
   `capacity show`.
2. **A leaf may be platform-only under a shared noun** (per
   `rensei-architecture/ADR-2026-05-06-tui-noun-consolidation-platform-extensions.md`
   § Addendum 2026-08-03). A **noun** may not mean different things in two
   binaries. `fleet` violated the second rule, which is why it is retired
   rather than redefined.
3. **The daemon's scheduler-debug surface (`routing`) stays where it is.** It
   is not project→pool policy and does not merge into `capacity route`.

### D5 — Deprecation path, with dates that can be checked

The `ADR-2026-05-06` window is **spent** — 84 downstream releases, three months.
Therefore:

1. **Next downstream minor:** delete the hidden aliases `worker`, `machine`,
   `execution`, and the hidden top-level `workarea` / `provider` / `kit`
   duplicates (44 leaf paths across six aliases). Delete the hidden,
   never-deprecated `daemon` duplicate in favour of `host` (17 leaf paths).
   In the same release, introduce `fleet` as a hidden deprecated alias
   forwarding to `capacity`.
2. **The minor after that:** delete `fleet`.
3. **OSS:** mark `fleet` / `worker` deprecated and remove `fleet scale` in the
   next OSS minor; remove `fleet` / `worker` one OSS minor later; ship
   `host` (D2) and the `daemon`→`host` alias in the same OSS minor as the
   deprecation marking, so the replacement exists before the notice points at
   it.
4. **New rule, to stop this recurring:** every hidden alias **declares its
   removal version at creation**. `Deprecated:` text names an explicit version
   ("removed in v0.10.0"), never "next release," and a release-gate check fails
   the build when an alias is past its declared removal version. An alias with
   no removal version is a defect.

## Consequences

### Positive

- One mental model with two entries — "this machine" and "my org's capacity" —
  instead of three entries where one of them means the opposite thing in the
  other binary.
- The literal synonyms disappear: one `pool` surface, one `provider`-config
  surface, one route surface, one daemon-lifecycle surface.
- `011` and `014` become true statements about shipped code rather than
  aspirations, and the OSS binary finally gets the noun tree an OSS-canonical
  ADR promised it three months ago.
- `capacity show` becomes the single answer to "what compute do I have running
  right now," covering on-demand sandboxes that `fleet list` never showed.
- The alias-with-a-version rule converts an unfalsifiable promise into a gate.

### Negative

- A second rename in three months for anyone who learned `fleet route set` —
  including the first-run wizard's advertised chain, the onboarding
  documentation, and the smoke harness.
- D2 is real OSS work (an exported `host` factory plus an alias) that this ADR
  requires but does not itself deliver; until it lands, the corpus must
  describe OSS as `daemon`-shaped, which is a visible admission of the gap.
- Deleting 44 alias leaf paths in one minor is a larger single break than the
  original ADR contemplated, because the window it promised was never honoured
  incrementally.

### Risks

- **Automation breakage at alias removal.** Six aliases have been forwarding
  silently for 84 releases; anything scripted against them breaks at once.
  Mitigation: the removal release notes enumerate every removed path and its
  replacement, and the alias-forwarding smoke is converted into an
  alias-*absence* assertion in the same change rather than deleted.
- **Doc-vs-code skew, again.** This ADR is `Proposed` while `011`/`014` still
  describe the 2026-05-06 tree. Mitigation: the doc corrections land in the
  commit that flips this ADR to `Accepted`, not before — and the corrections
  are listed explicitly below so the flip is mechanical.
- **`capacity show <id>` argument overload.** `capacity show` currently takes
  no arguments; adding an optional instance id risks ambiguity if a future
  filter wants a positional. Mitigation: filters are flags, positionals are
  ids — stated here so the constraint is inherited rather than rediscovered.

## Alternatives considered

**A. Keep `fleet` and redefine it org-wide in OSS too.** Rejected. It would
require renaming OSS's existing local `fleet` and `fleet-watch`, and it would
put an org-wide noun in a corpus whose entire premise is that the product works
on one machine without a control plane. `011` would have to stop calling the
single-machine case a fleet, which is the natural English reading.

**B. Keep `fleet` downstream only, and drop it from the OSS corpus.** Rejected.
The noun tree is OSS-canonical by `ADR-2026-05-06`; a top-level noun that exists
in the composed binary and nowhere in OSS is exactly the drift the boundary
convention exists to prevent, and it leaves OSS's own `fleet` meaning something
else with no doc saying so.

**C. Move the org-side machine commands to `capacity host list` / `show`.**
Rejected under D4.1 — `host` would mean "this machine" at depth 1 and "any
machine" at depth 2. The platform's own API path (`/api/capacity/hosts/{id}`)
uses that word, but a URL namespace and a CLI noun tree have different collision
rules; the CLI has a top-level `host` and the URL does not.

**D. Leave the aliases in place indefinitely and only add `capacity route`.**
Rejected. It grows the surface a third time without ever shrinking it, and it
keeps four ways to set one daemon config key.

**E. Do nothing until v1.** Rejected for the same reason `ADR-2026-05-06`
rejected it, with three months of additional evidence: waiting produced 84
releases of alias debt and a second incompatible meaning for `fleet`.

## Migration cost estimate

**Commands that move (downstream):** 5 leaf paths (`fleet list`, `fleet show`,
`fleet route show|set|test`) plus the retirement of one top-level noun.

**Commands that are deleted (downstream):** 44 alias leaf paths across six
hidden aliases (`worker` 18, `kit` 9, `execution` 9, `workarea` 4, `machine` 2,
`provider` 2), plus the 17-leaf hidden `daemon` duplicate. All 61 have a
surviving equivalent under `host` (37 leaves) or `capacity` (8 leaves, growing
to 13 with the `fleet` intake).

**Commands that change in OSS:** `daemon` (15 leaves) becomes an alias of a new
`host` parent; `fleet` (4 leaves) and `worker` (1 leaf) become deprecated then
removed; `fleet scale` is deleted outright; `fleet-watch` (1 leaf) becomes
`host watch`.

**What breaks for an existing user:**

- Anyone typing `fleet …` against the composed binary gets a deprecation notice
  for one minor, then a "unknown command" error. Interactive users are
  unaffected past the notice; scripted users must edit.
- Anyone still typing `worker …`, `machine …`, or `execution …` — none of which
  have appeared in `--help` since v0.6.0 — loses them without a further notice
  period, because they have already had 84 releases of one.
- No wire-format, config-file, or on-disk-state change. No daemon restart, no
  re-registration, no token churn. The daemon config keys, the daemon HTTP
  control API, and the platform endpoints are untouched.

**Downstream text that must be swept** (counted, not modified, on
2026-08-03): 28 documentation pages containing `fleet` command invocations
(111 lines), 23 `fleet` invocations in the smoke harness across ~10 files, 19
non-test source files and 9 test files in the composing binary. The first-run
wizard's advertised chain (`auth add --user` → `host install` → `fleet route
set`) is user-visible text in three places and must change in the same release
as the alias.

**Is a release forced?** Yes — two, on each side, and they are ordered.
OSS ships `host` + the `daemon` alias first (D2); the composing binary cannot
consume the exported factory until that OSS tag exists, and the two ship
lock-step because the embed surface moves. Then the composing binary ships the
alias-deletion + `fleet`-deprecation minor, and one minor later the
`fleet`-deletion. No release is forced *urgently* — nothing is broken today
except the operator's mental model — so this can ride the normal minor cadence.

## Affected documents

These edits land in the commit that flips this ADR to `Accepted`, not before.

- `ADR-2026-05-06-tui-noun-consolidation.md` — status becomes
  `Superseded in part by ADR-2026-08-03-cli-noun-tree-fleet-retirement.md`;
  the three-noun table and the one-release alias sentence are annotated with a
  pointer here. The wizard chain in its § Decision changes to
  `auth add --user` → `host install` → `capacity route set`.
- `011-local-daemon-fleet.md` — the 2026-05-06 command-surface note and every
  example fence currently showing `<binary> host install` are corrected: as
  shipped today the OSS form is `<binary> daemon install`, and it becomes
  `<binary> host install` only when D2 lands. The doc title and its
  single-machine use of "fleet" are correct as-is and are affirmed by D3.
- `014-tui-operator-surfaces.md` § "Noun model" — the three-row table becomes
  two rows; the sentence claiming both binaries speak the noun model via
  `afcli.RegisterCommands` is replaced with the truth (the downstream binary
  assembles its own tree today) plus the D2 commitment. `FleetGrid` /
  `MachinePivot` are re-homed from `fleet` to `capacity`.
- `003-workarea-provider.md` — the `host workarea` cross-reference is
  unaffected; listed only so the sweep is exhaustive.

No `BOUNDARY-SYNC`-marked region is touched. The only synchronized region in
either corpus is the boundary-discipline section of
`001-layered-execution-model.md`, which this ADR neither amends nor alters
inside its markers. `scripts/check-boundary-sync.sh` was run
on 2026-08-03: the two cross-corpus pairs it resolves both report `OK`, and its
two `ERROR` lines are a pre-existing environmental artefact — a stale untracked
worktree copy inside each repo doubles every marker id — not drift introduced
here.

## Affected work items

- OSS: export a `host` parent from `afcli`; alias `daemon`; deprecate
  `fleet`/`worker`; delete `fleet scale`; rename `fleet-watch` to `host watch`.
- Composing binary: move the five `fleet` leaves under `capacity`; add the
  optional instance-id positional and `--kind` filter to `capacity show`;
  delete six hidden aliases and the hidden `daemon` duplicate; consume the
  exported `host` factory instead of hand-assembling one.
- Smoke harness: replace `fleet` invocations; convert the alias-forwarding
  assertion into an alias-absence assertion.
- Documentation: sweep the 28 pages carrying `fleet` invocations; retire the
  `fleet` command reference page in favour of `capacity`.
- Release tooling: the alias-removal-version gate from D5.4.

## Implementation notes

As of this ADR's acceptance (2026-08-03), nothing in it has shipped. Per the
2026-08-03 operator ruling, downstream implementation proceeds now — `fleet`
retires org-side and overdue aliases get deleted — while OSS `host` (D2) is
built but not yet merged. Order still matters for the sequencing that depends
on the unmerged piece: OSS `host` factory → OSS minor → downstream `go get`
bump → downstream alias-deletion minor → downstream `fleet`-deletion minor.
Attempting the downstream move before the OSS factory exists reproduces the
hand-assembled tree this ADR is trying to delete. Until an OSS release
carrying D2 exists, `011-local-daemon-fleet.md` and `014-tui-operator-surfaces.md`
correctly describe the OSS binary as `daemon`-shaped (see their command-surface
notes) even though this ADR is `Accepted`.

The platform-side delta — which platform endpoints back the moved leaves, the
route write-path semantics the moved `capacity route set` inherits, and the
smoke-harness sequencing — lives in
`rensei-architecture/ADR-2026-08-03-cli-noun-tree-fleet-retirement-platform-extensions.md`.
