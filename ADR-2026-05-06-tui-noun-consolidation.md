# ADR-2026-05-06-tui-noun-consolidation

**Status:** Accepted
**Date:** 2026-05-06
**Boundary:** shared (OSS-canonical; platform extensions live at `rensei-architecture/ADR-2026-05-06-tui-noun-consolidation-platform-extensions.md`)
**Authors:** mark, claude

## Context

The CLI's TUI surface had grown to seven flat top-level commands — `worker`, `workarea`, `machine`, `execution`, `provider`, `route`, `pool` — alongside a separate `routing` namespace. That layout mixed three different concept layers at the same level of the noun tree:

- **Local execution host** — the daemon on this machine, its capacity envelope, the local workarea pool, and the providers installed for it (`worker`, `workarea`, daemon-side `provider`).
- **Fleet visibility** — other machines registered to the org and the per-project execution routing policy that selects among them (`machine`, top-level `route`, `routing`).
- **Org capacity config** — the org-wide execution providers and pool definitions the routing policy chooses from (`execution`, `provider`, `pool`).

Two collisions made the surface actively misleading. There were two unrelated `provider` commands — one for the daemon's installed runtimes (claude/codex/etc., a host concern) and one for org-level execution providers (a capacity concern) — sharing a verb. And `route` (top-level, for setting per-project routing) lived next to `routing` (a separate namespace), with no readable distinction between them.

Best-practice CLI guidance (clig.dev's "subcommands are the tree of nouns" rule, the Azure CLI noun discipline, kubectl's resource-type discipline) consistently favors a small number of top-level nouns each owning one concept layer, with deeper structure for verbs. A seven-noun flat surface fails that rule.

This drift accumulated during the wave-by-wave buildout of the local-daemon model (`011`), the multi-machine fleet, and the workarea+sandbox capacity work (`003`, `004`). Each wave added its own top-level noun; nothing pulled them together.

The CLI noun model itself is OSS — it applies to the `donmai` binary too via `afcli.RegisterCommands`. Hidden deprecated aliases are OSS-shipped CLI behavior. The platform-side delta (auth retrofit on three worker endpoints, the Live capacity addendum) is documented in the platform extensions doc.

## Decision

The TUI consolidates to three top-level nouns, each owning exactly one concept layer:

- **`host`** — *this machine.* Daemon lifecycle (install / status / doctor / drain / update), capacity envelope, local workarea pool, installed providers. Subsumes the old `worker` (daemon-as-worker), `workarea` (top-level), and the daemon-side `provider`.
- **`fleet`** — *other machines + how this org's projects route to them.* Plural rename of `machine`, also subsuming the old top-level `route` and `routing`. `fleet list` enumerates remote daemons; `fleet route set` binds a project's execution route policy.
- **`capacity`** — *org-wide execution provider + pool config.* Rename of `execution`, subsuming the old `execution provider` and `execution pool` subtrees.

Old top-level commands (`worker`, `machine`, `execution`, `workarea`, the top-level `provider`) remain available as **hidden deprecated aliases** for one release. They print a one-line deprecation notice that names the new command, then forward. After one release they are removed.

A first-run wizard chains the onboarding path — `auth add --user` → `host install` → `fleet route set` — so a freshly logged-in user reaches a routable, working state without prior knowledge of the noun map. The OSS binary's onboarding wizard targets self-hosted orchestration; the platform-binary form targets the SaaS auth path documented in the platform extensions.

## Consequences

### Positive

- The noun map now matches the user's mental model: "this machine," "other machines," "org capacity." A first-time user can reason about where a command lives before reading help.
- The two-different-`provider` collision and the `route` vs `routing` collision are gone. There is one `provider` (under `host`) and one routing surface (under `fleet`).
- The onboarding wizard becomes a straight three-step chain on visible top-level nouns, not a hunt across seven sibling namespaces.
- The dual-surface discipline from `001` and `014` has a coherent grouping for any platform-side dashboard to mirror — three top-level panels rather than seven.

### Negative

- One release of forwarding-aliases noise. Users who muscle-memory `<binary> worker host status` see a deprecation line for one release before it goes away.
- Documentation, smokes, and the architecture corpus all need to track the rename. We are paying that cost in this commit and the corresponding work in downstream repos.

### Risks

- **Alias regression risk.** Hidden aliases that silently stop forwarding break automation. Mitigation: an alias-forwarding smoke asserts every old top-level still resolves to its new target until the planned removal release.
- **Doc-vs-code skew.** Doc text or example fences that still reference `<binary> worker ...` after the rename will mislead new users. Mitigation: a `grep -rE '(worker|machine|execution|workarea) '` sweep against the corpus is part of the verify step on this ADR's commit, and an equivalent sweep runs against downstream repos' docs/spec text in a separate cleanup commit.

## Alternatives considered

**A. Keep seven top-levels, add a `host` and `fleet` aggregator on top.** Rejected. Doubles the surface area instead of reducing it. The user still has to learn that `worker` and `host` overlap.

**B. Rename only `worker` → `host` and leave the rest.** Rejected. Half-fixes the noun map. The `route` vs `routing` collision and the two-`provider` collision both survive; the user still cannot find capacity config under a sensible top-level.

**C. Wait for the v1 release to consolidate.** Rejected. Each wave that ships under the seven-noun surface adds more code and docs to migrate later, and every new user who hits help during this period is taught the wrong mental model. Doing it now while the alias-forwarding cost is small is cheaper than doing it after v1.

## Affected documents

- `014-tui-operator-surfaces.md` — replace tables/examples that show the old top-level surface with the new one; add a short "Noun model" subsection spelling out host/fleet/capacity and the deprecation alias period.
- `003-workarea-provider.md` — cross-reference paragraph noting that the pool-state contract (warming/ready/acquired/releasing/invalid/retired) is consumed by `host workarea` rather than the old top-level `workarea`.
- `011-local-daemon-fleet.md` — daemon CLI lifecycle commands (install, status, doctor, drain, update) are now invoked as `<binary> host *`. One sentence + example fences updated.

## Implementation notes

The rename lands as a single coordinated push across the OSS binary's command tree, the platform binary's command tree, and any platform-side endpoint retrofits (see platform extensions). The deprecation aliases stay in for exactly one release; their removal is tracked as a separate work item gated on the next minor.

Doc/spec text scrubbed of `NNN-*.md` filename leaks travels in a separate commit so this ADR's diff stays focused on the noun map. The architecture corpus is the canonical naming reference: when this ADR is accepted, downstream repos cite the new nouns by name and link here.
