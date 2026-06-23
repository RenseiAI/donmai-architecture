---
status: Accepted
date: 2026-06-22
boundary: OSS-only
---

# ADR-2026-06-22 — OSS Linear CLI verb contract for backlog grooming

**Status:** Accepted
**Date:** 2026-06-22
**Boundary:** OSS-only
**Authors:** agent:claude (groomer design session)

## Context

The `donmai linear` subcommand tree (registered via `afcli.RegisterCommands`,
backed by the hand-rolled GraphQL client at `donmai/internal/linear/client.go`)
shipped read/write verbs adequate for an agent reacting to a single assigned
issue: fetch an issue, post a comment, transition a status. It was never built
for **backlog grooming** — the bulk, structure-aware pass an agent makes over a
project's whole inventory: enumerate the top-level (parent) issues in a target
status, walk each one's sub-issues, wire blocking relations, normalize labels,
and adjust status/priority/estimate in batch.

Three gaps forced the design:

1. **No parent/child-aware enumeration.** The existing list verb returned a flat
   page of issues with no way to (a) restrict to parents only, (b) filter by a
   set of statuses, or (c) scope to a team — and the issue payload carried no
   `parentID`, so a consumer could not reconstruct the tree client-side. A
   grooming agent had no sanctioned way to ask "give me the top-level issues in
   this project that are in Backlog or Triage."
2. **No relation or label write verbs.** Grooming requires expressing structure
   (`A blocks B`) and taxonomy (apply/remove labels). Neither had a CLI verb;
   the agent could only mutate the fields already exposed by the single-issue
   update path.
3. **Per-invocation scope boilerplate.** Every grooming verb needs a project and
   usually a team. Threading `--project`/`--team` flags through every call in a
   long grooming loop is error-prone and noisy; the standalone `donmai` binary
   had no env-default for either.

The verbs below ship in donmai v0.49.2. This ADR records their contract as
OSS-canonical so downstream consumers (and the platform's CLI-Linear proxy per
`ADR-2026-05-12-cli-linear-proxy.md`) compose against a stable surface.

## Decision

`donmai linear` gains a **backlog-grooming verb set** and an **env-default
project/team scope**. All verbs work in both the standalone (`LINEAR_API_KEY`)
path and the platform-proxy path unchanged — the wire-format switch is
encapsulated in the client per `ADR-2026-05-12`, so these verbs add only new
GraphQL operations, not a new auth axis.

### D1 — Enumeration verbs

**`donmai linear list-backlog-issues`** — enumerate top-level issues in a target
status set, scoped to a project/team.

```
donmai linear list-backlog-issues \
  --parents-only \                 # exclude sub-issues; return only issues with no parent
  --statuses "Backlog,Triage" \    # comma-separated status-name filter (OR within the set)
  --team ENG \                     # team key or id; falls back to DONMAI_LINEAR_TEAM
  [--project <slug|id>]            # falls back to DONMAI_LINEAR_PROJECT
```

- `--parents-only` filters to issues whose `parent` is null. Without it, the verb
  returns the full flat set matching the status filter (parents and children
  intermixed), each carrying its `parentID` so the consumer can reconstruct the
  tree.
- `--statuses` takes a comma-separated list of status **names** (not ids), matched
  OR-wise: an issue in any of the named statuses is included. Empty/omitted means
  no status filter.
- **Every returned issue carries `parentID`** (null for top-level issues). This is
  the load-bearing schema addition: it makes the parent/child tree reconstructable
  from a single flat response, which the cascade contract (D5) depends on.

**`donmai linear list-sub-issues`** — enumerate the direct children of one parent.

```
donmai linear list-sub-issues <parentIssueID>
```

Returns the parent's direct sub-issues (one level; not recursive). Each child
carries its own `parentID` (equal to the queried parent) for symmetry with
`list-backlog-issues` output.

**`donmai linear list-labels`** — enumerate the label catalog in scope.

```
donmai linear list-labels [--team ENG] [--project <slug|id>]
```

Returns the label set (id, name, color, group) available for `apply-label`.

### D2 — Relation verb

**`donmai linear add-relation`** — create a typed relation between two issues.

```
donmai linear add-relation --type blocks <fromIssueID> <toIssueID>
```

- `--type blocks` is the v1 relation type (the grooming-relevant one): `from`
  blocks `to`. The flag is explicit (not defaulted) so the relation direction is
  never ambiguous at the call site.
- The verb is idempotent against an already-existing identical relation: a
  duplicate `blocks` relation between the same ordered pair is a no-op success,
  not an error, so a re-run of a grooming pass does not fail on relations it
  already created.

### D3 — Label verb

**`donmai linear apply-label`** — apply a label to an issue.

```
donmai linear apply-label <issueID> <labelNameOrID>
```

Resolves the label by name (within scope) or id, then adds it to the issue's
label set (additive; does not clear existing labels). Idempotent: re-applying an
already-present label is a no-op success.

### D4 — Field-update verb

**`donmai linear update-issue`** — adjust the grooming-relevant scalar fields of
one issue.

```
donmai linear update-issue <issueID> \
  [--status   <statusName>] \      # transition to a named workflow state
  [--priority <0-4>] \             # Linear priority scale (0 none … 4 urgent)
  [--estimate <points>]           # numeric estimate in the team's estimation scale
```

At least one of `--status` / `--priority` / `--estimate` MUST be provided; a call
with no field flag is a usage error (no silent no-op write). Each provided flag
sets exactly that field; omitted flags are left untouched (partial update, never a
full-object replace). `--status` resolves the named state within the issue's team
before transitioning.

### D5 — The parent-in-target-status-then-cascade dimensionality contract

Grooming is **two-dimensional**: a status filter selects a set of *parents*, and
for each selected parent the agent then *cascades* down that parent's sub-issue
subtree. The two dimensions are kept orthogonal by contract:

1. **Selection dimension (the status filter) applies to parents only.** A grooming
   pass runs `list-backlog-issues --parents-only --statuses <S>` to obtain the
   set of top-level issues in the target status set `S`. The status filter is the
   *entry condition for the parent*, never a filter applied independently to the
   children.
2. **Cascade dimension applies per selected parent.** For each parent returned by
   step 1, the agent runs `list-sub-issues <parentID>` to obtain that parent's
   children and grooms the subtree (relations, labels, field updates). The cascade
   walks the children **regardless of the children's own statuses** — a child is
   in-scope because its parent matched, not because the child independently
   matched the status filter.

The invariant: **a sub-issue is groomed iff its parent was selected.** This means
`list-backlog-issues` without `--parents-only` (the flat mode) is for tree
*reconstruction/inspection*, not for selection — selection always goes through
`--parents-only`, and children always come from `list-sub-issues` keyed on a
selected parent's id. Conflating the two (e.g., applying `--statuses` to a flat
list and grooming whatever matched) would silently groom orphaned children whose
parent was out of scope, and silently skip in-scope children that happen to sit in
a non-matching status. The `parentID` field (D1) is what lets a consumer enforce
this invariant without a second round-trip per child.

### D6 — Env-default project/team scope

Two env vars set the default scope for every grooming verb:

- **`DONMAI_LINEAR_PROJECT`** — default `--project` value.
- **`DONMAI_LINEAR_TEAM`** — default `--team` value.

Resolution order per verb, per scope dimension: explicit flag → env var → (for
verbs where scope is optional) unscoped. A verb that *requires* a scope dimension
(e.g., `list-backlog-issues` needs a project) errors with an actionable message
naming both the flag and the env var when neither is set. The env vars follow the
`DONMAI_*` naming convention (`ADR-2026-06-02-oss-brand-neutral-runtime-contract.md`)
— no closed-brand env name is read.

## Consequences

### Positive

- An agent can run a complete structure-aware grooming pass over a project's
  backlog with a small, composable verb set, instead of scripting raw GraphQL or
  reaching past the CLI.
- `parentID` in the issue payload makes the parent/child tree reconstructable from
  one flat response, eliminating a per-child round-trip just to learn parentage.
- The selection/cascade orthogonality (D5) is encoded in the verb shapes
  themselves (`--parents-only` for selection, `list-sub-issues` for cascade), so
  the correct grooming dimensionality is the path of least resistance.
- Env-default scope (D6) removes per-call flag boilerplate from long grooming
  loops without introducing hidden global state — the env var is explicit and
  overridable per call.
- Idempotent writes (D2/D3) make a grooming pass safely re-runnable: a partial
  pass that died mid-way can be re-run without duplicating relations or labels.

### Negative

- `--type blocks` is the only v1 relation type. Other Linear relation types
  (`related`, `duplicate`) need future verbs/flags; agents needing them must wait
  or use the platform UI.
- The status filter matches on status **names**, which are team-configurable and
  can drift. A renamed status silently drops out of a hard-coded `--statuses`
  list. (Matching by name rather than id is deliberate — names are what an agent
  reasoning about a backlog actually knows — but it is a coupling to team config.)
- `update-issue` is a one-issue-at-a-time verb; bulk field updates across many
  issues are N invocations. A batch-update verb was deferred (see Alternatives).

### Risks

- **Cascade misuse.** Nothing at the CLI layer *enforces* the D5 invariant — it is
  a contract on how the verbs are composed, not a single atomic verb. A consumer
  that applies `--statuses` to flat output and grooms the matches violates the
  invariant. Mitigation: D5 is documented as load-bearing here and in
  `008`; the `--parents-only` flag is the sanctioned selection path and the
  natural one.
- **Status-name resolution races.** `update-issue --status` and the `--statuses`
  filter both resolve names against current team config; a concurrent status
  rename mid-pass can cause a transition or filter to miss. Low-frequency;
  acceptable for a grooming pass that re-runs idempotently.
- **Estimate-scale mismatch.** `--estimate` is interpreted in the team's
  estimation scale; passing a value outside the team's configured scale (e.g.,
  Fibonacci-only teams) is rejected by Linear, surfaced as a verb error. The verb
  does not pre-validate against the team scale.

## Alternatives considered

- **A single `groom-backlog` mega-verb that selects parents and cascades in one
  call.** Rejected: it bakes one grooming policy into the CLI and gives the agent
  no room to interleave reasoning between selection and per-subtree action. The
  composable verb set keeps policy in the agent and primitives in the CLI.
- **Recursive `list-sub-issues` (full subtree in one call).** Rejected for v1: a
  one-level verb keyed on `parentID` composes into a recursive walk when needed,
  and a flat-recursive response would lose the per-level structure the cascade
  contract (D5) walks. Deep trees are rare in practice; the one-level verb is the
  honest primitive.
- **Match `--statuses` by status id instead of name.** Rejected: an agent
  grooming a backlog reasons in status *names* ("Backlog", "Triage"), not opaque
  ids. Name-matching is the ergonomic choice; the coupling to team config is
  called out as a known cost.
- **A `batch-update-issues` verb taking an issue-id list.** Deferred, not
  rejected: the per-issue `update-issue` is the honest primitive and idempotent
  re-runs cover the recovery case. A batch verb is a future ergonomics add if
  grooming-loop volume justifies it.
- **Implicit `--type` defaulting to `blocks` on `add-relation`.** Rejected:
  relation direction/type is exactly the kind of thing that must be explicit at
  the call site. A defaulted relation type invites a silently-wrong relation.

## Affected documents

No reference doc (`002`–`008`) is amended. Following the precedent of
`ADR-2026-05-12-cli-linear-proxy.md` (which amended no reference doc because the
proxy is CLI plumbing below the abstraction those docs cover), this ADR is the
canonical home for the grooming-verb contract — the verbs are new `donmai linear`
cobra subcommands layered on the existing `linear.Linear` interface, not a new
architectural primitive or provider seam. The IssueTracker family is documented
inline in `002-provider-base-contract.md`; these verbs do not change that
family's interface contract.

Index/cross-ref edits land in this commit:

- `README.md` § ADRs — add the index line for this ADR.
- `AGENTS.md` § Read order (ADRs) — add the index line for this ADR.

No edit touches a `BOUNDARY-SYNC`-marked region; this is an OSS-only CLI surface
addition with no platform-extension delta beyond the existing CLI-Linear proxy
(`ADR-2026-05-12-cli-linear-proxy.md`), which forwards these GraphQL operations
unchanged.

## Affected work items

Shipped in donmai v0.49.2. Tracker references for the grooming-loop program live
in the platform corpus / tracker (this OSS ADR carries no internal tracker id).

## Implementation notes

- The verbs land in `donmai/afcli/linear.go` as new cobra subcommands consuming
  the existing `linear.Linear` interface; the new GraphQL operations
  (parent-filtered issue query with `parentID` in the selection set, sub-issue
  query, `issueRelationCreate`, `issueAddLabel`, `issueUpdate` partial) live in
  `donmai/internal/linear/client.go`.
- The env-default resolution is a small helper applied uniformly across the
  grooming verbs (flag → `DONMAI_LINEAR_PROJECT` / `DONMAI_LINEAR_TEAM` →
  unscoped/error), not duplicated per verb.
- Idempotency for `add-relation` / `apply-label` is implemented by tolerating the
  "already exists" GraphQL error class as success, so a re-run of a grooming pass
  is safe.
