---
status: Proposed
date: 2026-11-02
boundary: shared
split: inline-addenda
amends: ADR-2026-09-28-agent-request-dispatches-a-card.md, ADR-2026-06-03-batch-work-type-category.md
---

# ADR-2026-11-02 — Stages, roles and stage cards: one process model for the 1.0 wire

**Status:** Proposed (2026-11-02, on the product owner's decisions of the same day).
Architecture only; nothing in it is built. The edits under "Affected documents" land
in the commit that flips this record to Accepted, OSS side first.
**Date:** 2026-11-02
**Boundary:** shared. This record is OSS-canonical for the execution-layer contract:
the stage, its seven roles, stage cards, outcome transitions, the tracker status
mapping shape, the model selection vocabulary and its resolution order, skill
attachment and delivery, the 1.0 dispatch wire, portable templates and the reserved
coordination slot. The platform corpus carries a mirrored stub with the hosted delta
inline: model access, catalog curation and the marketplace, storage, migration and
fleet continuity.
**Authors:** architecture lane (coordinator draft)

## Context

The process vocabulary is split three ways today. Cards carry a **work-type** label.
Workflows, stage mappings and the dispatch wire carry a separate **stage** notion
(`spec.lifecycle.<stage>`, a wire `stageId`). And the runner holds **name-keyed
tables** (`AllWorkTypes`, `workTypeCompleteStatus` / `workTypeFailStatus`, the
per-name completion contract and template tables) that turn a work-type name into a
completion contract and a tracker status move. Five forces make that shape wrong:

1. **It is brittle.** The shipped tracker SDLC template branches once per tracker
   status. Adding a card to a status, or adding a status, means editing several
   workflow nodes.
2. **It does not travel.** Templates embed card ids, model ids and tracker status
   names, so the same template cannot run against a second status vocabulary.
3. **Four roles are too few.** `intake`, `inflight`, `review` and `terminal` cannot
   say "not scheduled", "failed verification", or "completed" versus "abandoned",
   and coordination rules (ancestor admission, roll-up, cascades) depend on exactly
   those distinctions.
4. **Failure is overloaded.** A material share of failed sessions end *blocked*: a
   prerequisite is missing. Failure handling re-dispatches the same context into the
   same wall. `ADR-2026-09-28-agent-request-dispatches-a-card.md` D4's stage moves
   (`advance`, `reject`, `none`) cannot say "blocked", "leave it here" or "close as
   a duplicate", and the execution layer and the control plane disagree today on
   whether a failed development stage stays in place.
5. **Skills do not reach the harness reliably.** The runner appends skill bodies to
   the system prompt, for some harnesses in a single argument with no size guard,
   and a skill that reaches dispatch as a descriptor without content cannot be
   delivered at all.

The product owner decided on 2026-11-02: the seven-role set below is adopted; work
type is not a card label; stages cascade through the scope chain and a project may
define its own; stages declare outcome transitions; templates are portable and a
lint enforces it; skills attach at four levels with a repository-discovery policy;
and one harness may deliver skills through workspace trust.

## Decision

A **stage** is a scoped definition with a stable key, a name and one of seven fixed
**roles**. A stage lists the **stage cards** that may run in it, with one default,
and declares where work goes on each of four **outcomes**. The machine branches on
the role and the card's completion contract only; every name (stage, card, tracker
status) is data. Work type is retired as a concept. The dispatch wire moves to 1.0 in
one lock-step release.

### D1 — Vocabulary

| Term | Meaning |
|---|---|
| **Stage** | A step of the process: key, name, role, description, stage cards, outcome transitions. Defined at a scope (D2). |
| **Role** | The closed set of seven the machine branches on (D3). |
| **Card** | An agent card: prompt, tools, skills and completion contract. It may sit in many stages. |
| **Stage card** | A card's membership in a stage: default flag, mention keywords, model selection and skills for that card in that stage. |
| ~~Work type~~ | Retired. It survives only as a legacy wire and telemetry field during migration (D9), replaced by stage id plus card id. |

"Stage" here means a process step only. The placement law's six "stages"
(`ADR-2026-08-12-placement-composition-law-and-single-fallback-rule.md`) stay a
documentation term for its authority order and never appear on a wire or surface.

### D2 — A stage is a scoped definition

1. **Shape.** `stage { id, scope, key, name, role, description, overridesStageId?,
   disabled, cards[], modelSelection?, outcomes, retry, policies? }`. `key` is a
   stable slug, unique within the set visible to a project. Stage ids are stable
   across scopes.
2. **Cascade.** Definitions resolve system → org → project → workflow, like every
   other default; the workflow scope is today's `spec.lifecycle.<stage>`. At each
   scope a user may **add** a stage, **override** an inherited stage's name,
   description, cards, selection or transitions, or **disable** an inherited stage.
   An override may never change the **role**, so work already in the stage keeps its
   meaning. Stage configuration supplies **inherited defaults** for cards, model
   selection, skills and outcomes; the workflow keeps final authority and may
   override any value (D11.4).
3. **Computed, never copied.** The effective set for a project is computed at
   evaluation. A scope inherits built-ins; it does not receive copies.
4. **Built-ins are system-scope stages** (research, backlog writing, development,
   QA, acceptance and the rest). They reference only system cards and system-owned
   selections. Their names are not special anywhere in code.

### D3 — Seven roles

| Role | Machine meaning | Examples |
|---|---|---|
| `hold` | Not scheduled. Admission refuses it and its descendants. | Icebox, Waiting |
| `intake` | Ready to be picked up. Dispatchable. Not work in progress. | Backlog, Ready, Triage |
| `inflight` | Being built. Work in progress. A completion contract applies. | Started, Active |
| `review` | Being verified. Work in progress. A verdict contract applies. | Finished, Delivered, Verify |
| `rework` | Failed verification; routes back with findings. | Rejected |
| `done` | Completed. Counts toward a parent's roll-up. | Accepted, Done |
| `closed` | Abandoned. May cascade to children (D12). | Canceled, Duplicate |

The set is closed: roles are structure, and `016` corollary 4 rejects unknown
structure, not unknown names. The previous four map in directly, with `terminal`
splitting into `done` and `closed`. Everything else, including whether a run owes a
pull request, is card data (D4), never a role or a stage name.

### D4 — Stage cards

1. A stage lists the cards that may run in it and marks exactly one **default**.
   With no mention, the default runs. A mention selects any card listed on the
   stage, matched by card handle or by one of its **mention keywords**. A card may
   sit in many stages.
2. A card carries **no stage or work-type label**. Its **completion contract** is
   explicit card data, `{ pr, verdict, workResult }` (what the run owes, possibly
   nothing), defaulting from the stage role so the defaults reproduce today's
   behaviour; a card's explicit value wins.
3. A stage card holds a **model selection** (D7) and **skills** (D8), so the same card
   can run one model as a reviewer in one stage and another model elsewhere. Model
   selection lives on the stage card, never on the card.

### D5 — Outcomes and transitions

1. A stage declares a target for each of four outcomes. A target is a stage key or
   `stay` (no move). Seeded stages carry today's behaviour as their defaults, and a
   workflow may override them (D2.2).

   | Outcome | Carries | Target rule |
   |---|---|---|
   | `success` | follow-ups as contract data (an approve-with-follow-ups verdict is a success) | any stage, or `stay` |
   | `failure` | `reason`, the terminal-reason code; a review's request-changes verdict lands here | any stage (typically `rework`), or `stay` |
   | `blocked` | `blockedReason` and prerequisite data | a `hold`- or `intake`-role stage, or `stay` |
   | `close` | `reason` (`duplicate`, `obsolete`, `canceled`), optional `duplicateOf` | a `closed`-role stage |

2. **Not outcomes.**
   - **Retry is stage policy** (`retries`, `backoff`) for provider, spawn, workarea
     and launch-acknowledgement errors. A stage emits `failure` or `blocked` only
     once retries are exhausted. Mechanical failures (provider error, runner
     contract) retry and never count as a stage outcome.
   - **No verdict, an operator cancel and a gate timeout mean stay and comment.** A
     cancel never routes to rework; a workflow that maps a cancel to failure is
     defective.
   - **CI, deploy, merge and human gates are preconditions** to `success`, not
     outcomes.
   - **Split** (create children; the parent stays and rolls up) and **wait** (blocked
     with prerequisite data) are card-contract results.
3. **Resolution.** The control plane resolves each outcome's target to the tracker's
   write status (D6) and sends the resolved transitions on the wire (D9). The runner
   applies the one matching its outcome and holds no status name. A standalone
   deployment supplies the same transitions by configuration. A run with no stage
   carries no transitions (D9.3).

### D6 — Tracker status mapping

1. Status mapping stays **per project tracker binding**, so a project may bind more
   than one tracker. Each binding maps native statuses to stages; many statuses may
   read as one stage.
2. Writing needs one answer, so each binding names exactly one **write status** per
   stage: the native status set when work moves into that stage.
3. Tracker status names live in the mapping and nowhere else. A resolved write status
   travels on the wire as data (D9). This amends `ADR-2026-09-28` D4's "nothing on
   the dispatch path names a tracker status" to: nothing holds a status name in code,
   a card, a profile, a skill or a template.

### D7 — Model selection and resolution

1. **Values.** Each level holds one of `inherit` · `pinned(<model>)` ·
   `follow(<line>, minor | latest)` · `profile(<id>)` · `router`, plus an optional
   effort.
   - `inherit` passes through to the next level.
   - `pinned` names one concrete available model and never moves. It is hard within
     the placement law (`ADR-2026-08-12` D1.3).
   - `follow(<line>, minor)` (the default form) resolves to the newest
     non-deprecated model on the same line and major version; `latest` crosses
     majors. It resolves only over models the deployment has made available and
     permitted; when the newest is not available, the newest available on the line
     is used.
   - `profile` is a named, optional **constraint** (provider, auth mode, effort,
     configuration, sub-agent) and resolves to a concrete model within it.
   - `router` delegates the choice to a ranking policy over exactly the models
     available and permitted for that project and actor. Ranking orders and never
     widens (`ADR-2026-08-12` D1.4, D3); with no richer policy configured, the
     default declared-order policy applies.
2. **Order.** First concrete hit wins:
   `node pin → stage card (workflow → project → org → system) → stage default (same
   cascade) → project default → org default → system`.
3. **Invariants.**
   - Resolution happens at dispatch, before admission, and is recorded. A followed
     model is never substituted at spawn (the same rule `001` states for harness
     versions).
   - Whatever resolves must fall inside the effective permission, a stage-1
     question.
   - **Effort is a quantity and is never refused.** A request above the permitted
     levels clamps down to the highest permitted level at or below it; a request
     below every permitted level clamps up to the lowest. Every clamp is recorded
     with the requested level, the effective level and the scope that binds. This
     follows `ADR-2026-10-05-set-broad-enforce-the-minimum.md` R2 and D15 of
     `rensei-architecture/ADR-2026-09-30-model-library-dispatch-candidates-and-provider-failover.md`.
   - Credentials and auth are never set per node or per template; they resolve from
     the deployment's default credential binding through the same cascade.
   - The receipt records the level that bound, the selection value, the concrete
     model, the follow resolution and the effort source.
4. A single-machine deployment has one scope; `follow` resolves over its configured
   models and `router` uses the default ordering policy.

### D8 — Skills

1. **A skill is its own entity:** a versioned package (`SKILL.md` plus files) carried
   with its content. A card references skills by id and version; it no longer is
   one.
2. **Attach levels.** Skills attach at org, project, stage card and card. The dispatch
   merges them in that order, the more specific copy winning on an id clash.
   Disallowed tools are a session-level union and only ever narrow.
3. **Repository skills.** Skills committed in the target repository (for example
   `.claude/skills`, `.agents/skills`, `.pi/skills`) are governed by a policy set at
   project and overridable per stage card: `all` (default; the harness discovers
   them as a developer would), `allowlist` (only the named repository skills) or
   `none` (card and attached skills only). An attached skill beats a repository
   skill on a name clash. **Kit-detected skills** (`005`) are governed as repository
   skills under the same policy.
4. **The policy is best-effort per harness.** Each materializer renders the policy as
   far as its harness allows, and the run receipt records the policy actually
   achieved. A harness that cannot suppress repository discovery runs with what it
   achieved rather than being refused; repository skills are workspace content, not
   capabilities, so the denial rule of
   `ADR-2026-08-13-capability-realization-registry-and-viability-of-absence.md` D3
   does not apply to them.
5. **Delivery.** The dispatch resolves skills to content and sends them on the wire.
   Each harness adapter carries a **skill materializer** that delivers them natively,
   inside the existing adaptation vocabulary of
   `ADR-2026-08-06-harness-adaptation-plan-and-receipt.md` (channel `skill`; no new
   channel or delivery strategy). The plan names the delivery per skill before spawn
   and the receipt records which applied.

   | Harness | Native delivery |
   |---|---|
   | Claude Code | a per-session plugin directory outside the worktree, passed by `--plugin-dir` |
   | Pi | `--skill <dir>` from the run's state root |
   | Codex | `$CODEX_HOME/skills` or `.agents/skills/donmai-*`, decided by an implementation spike; prompt fallback until then |
   | Muse | `.agents/skills/donmai-*` with `--trust-workspace` (accepted, including that it loads the repository's own rules and hooks; see Risks) |

6. **Fallback.** Where no native delivery exists, the runner falls back to today's
   prompt append, which gains a size cap.

### D9 — The 1.0 dispatch wire

```
QueuedWork / PollWorkItem {
  stage?:       { id, key, name, role }          // optional (D9.3); stageId exists; key, name, role are added
  card:         { id, handle, contract, skills[] }   // contract = { pr, verdict, workResult }
  skills[]:     { id, name, description, version, digest,
                  files[{ path, contentBase64, mode, sha256 }],
                  invocation, delivery, body /* fallback */, disallowedTools }  // merged per D8.2
  repoSkills:   { policy: all | allowlist | none, allow[] }
  transitions?: { <outcome>: { stageKey, writeStatus } }   // only with a stage; resolved per D5.3
  stageContext: { ... }                          // D10
  workType                                       // legacy: stage.key during migration, then removed
}

BatchWorkItem {
  batchKind                                      // replaces the workType discriminant (D9.4)
  payload
}
```

1. The runner branches on `card.contract` and, when a stage is present,
   `stage.role`; nothing else. `AllWorkTypes`, `workTypeCompleteStatus` /
   `workTypeFailStatus`, the name-keyed contract and template tables, and
   `workTypeRole` are deleted. Status moves come from `transitions`, never from a
   compiled-in name.
2. **Lock-step release.** The OSS binary, the composing binary and the control plane
   release together, because the embed surface couples them. The control plane adds
   the new fields first and keeps sending the legacy ones until the new binaries run
   on every host; the legacy fields are removed after that.
3. **Stage is optional.** A run with no tracker work item (an interactive dispatch,
   an ad-hoc agent request) omits `stage` and carries no `transitions`. The card
   contract alone decides completion, and no tracker status moves.
4. **Batch work gets its own discriminant.** `BatchWorkItem` carries `batchKind`
   instead of riding the retired `workType`. This amends
   `ADR-2026-06-03-batch-work-type-category.md`: its batch handlers register and are
   selected by `batchKind`, and both fields are sent during the lock-step window. Its
   category semantics do not change: one poll and claim loop, no
   `AgentRuntimeProvider`, no agent quota, and no stage or card.

### D10 — What the dispatched agent knows

Every dispatch with a stage carries a stage context block on the wire, also rendered
into the prompt: the stage name and role, the tracker status it was dispatched from, the card
and why it was chosen (default or mention), and the work item's parent plus a bounded
child summary (identifier, stage, role). Cards may opt into richer tree context later.

### D11 — Portable templates and the locus of definition

1. **Invariant, enforced by a lint over shipped templates:** a template holds no card
   ids, model or profile ids, credential ids or tracker status names. Cards, profiles
   and skills hold no tracker statuses. Node pins are a user override and never part
   of a template.
2. The tracker SDLC template becomes two paths, "work item entered a stage" and
   "mention on a work item", both calling one generic **dispatch-stage** node. Card
   choice, model, skills, credentials and the next status all come from
   configuration.
3. **Acceptance:** the same template, unmodified, runs against two different status
   vocabularies (for example the shipped SDLC mapping and a Ready / Active / Verify /
   Waiting / Done mapping), and adding a card or a stage needs no workflow edit.
   Template size is reported before and after, not targeted.
4. **Locus (product-owner decision, 2026-11-02).** Stage configuration across the
   system → org → project → workflow cascade supplies **inherited defaults** for
   cards, model selection, skills and outcomes. The workflow keeps final authority
   and may override any value. The dispatch-stage node always shows the effective
   values (statuses, stage, cards and default, selections, skills, transitions) and
   the source of each. That is how `016`'s locus rule is satisfied: the values are
   visible and editable at the node, never hidden behaviour (corollaries 3 and 6).

### D12 — A reserved coordination slot

`stage.policies` is a typed, versioned slot with empty defaults in 1.0. It reserves
room, without building it, for: admission predicates (ancestor roles); parent
derivation (enter, block, roll up); cascades on `closed` and `hold`, with exemptions
and a "needs coordinator" route; the child start stage; and a claim-lease override.
Roles `hold`, `rework`, `done` and `closed` carry the tree semantics, stage ids are
stable across scopes, and the stage context carries parent and child summaries, so
each rule has a home that needs no breaking change. A coordinator is a card like any
other.

### D13 — What this supersedes and amends

- `ADR-2026-09-28-agent-request-dispatches-a-card.md`: **D4 is superseded** by D5 and
  D6 (four outcomes with `stay` replace `advance` / `reject` / `none`). **Amended:**
  D1.3 (a card has no work type), D2.2 (the stamp carries the stage and the card's
  contract, not a work type and its role), D2.4 (the stage is the one the work item
  is in, not a label on the card; a request with no work item has no stage, D9.3),
  the D3 table's work-type row,
  and D3's model row (a node pin still wins; otherwise the stage-card selection
  resolves, D7). `agent_request_stage_unmapped` now means the target stage has no
  write status in the project's tracker binding.
- `ADR-2026-06-03-batch-work-type-category.md`: the batch discriminant becomes
  `batchKind` (D9.4); the category is otherwise unchanged.
- `016-workflow-engine.md` § "Locus of definition": corollaries 3, 4 and 6 are
  applied, not changed (D3, D11.4).
- **Inherited stage defaults.** Platform-corpus decisions that bar stage settings
  from owning cards, launch choices or outcome mappings, or bar an agent-card
  execution default, are superseded to the extent that stage configuration supplies
  inherited defaults (D2.2, D11.4). The workflow's final authority is unchanged. The
  mirrored stub names them.
- `014-tui-operator-surfaces.md` § "Open registries": the work-type registry gives
  way to roles (a closed set shipped in core) and stage names (opaque labels styled
  by role).
- In the platform corpus: the work-type registry amendment (W1 to W6) of
  `rensei-architecture/ADR-2026-05-12-agentcard-schema-and-scope.md`, the work-type
  axis of `rensei-architecture/ADR-2026-05-12-worktype-and-model-profile-routing.md`
  and D16 of
  `rensei-architecture/ADR-2026-09-30-model-library-dispatch-candidates-and-provider-failover.md`
  are superseded by the stage model; the mirrored stub carries the detail.

## Consequences

### Positive

- Adding a card to a stage, or a stage to a project, is a data change; no workflow
  edit and no new runner code.
- One template runs against any status vocabulary, and the template shrinks because
  per-status branches collapse into one node.
- `blocked` stops re-dispatching into the same wall, which saves tokens; `stay` makes
  "leave it where it is" explicit and resolves today's disagreement about failed
  stages.
- The runner holds no tracker names, so standalone use with any tracker works by
  configuration.
- Skills reach every harness natively where the harness supports it, and the
  argument-length spawn failure goes away.
- Coordination rules gain homes without being built.

### Negative

- The wire breaks in one lock-step release across the OSS binary, the composing
  binary and the control plane.
- Card contracts, stage transitions and the tracker mapping become load-bearing and
  must be validated on write.
- The effective stage table is computed across four scopes, so every surface that
  shows it must show where each value came from.

### Risks

- **A partial cut-over** (new runner, old control plane) leaves a runner with no name
  table and no stage. Mitigation: the additive ordering of D9.2.
- **Workspace trust (accepted).** Muse's `--trust-workspace` makes the harness load
  the repository's own rules and hooks. That is workspace content an agent, a
  contributor or an untrusted fork can write, and hooks execute code; it is the
  exposure `ADR-2026-08-12-pi-extension-delivery-seam-and-capability-pack-boundary.md`
  D2 keeps away from operator trust for extensions. The product owner accepted this
  risk on 2026-11-02 for Muse only. The adaptation plan records the delivery; no
  other harness inherits the allowance.
- **Repository-skill policy is best-effort.** On a harness that cannot suppress
  discovery, `none` or `allowlist` is not a guarantee; the receipt shows what was
  achieved (D8.4).
- **The effective stage table could become hidden logic** if a surface shows a stage
  name without its resolved values and their sources. D11.4 is the guard.

## Alternatives considered

- **Keep work type beside stage.** A third concept next to the existing stage notion;
  every surface would keep translating between them. Rejected: one stage row.
- **Keep four roles.** Cannot express hold, rework, or done versus closed. Rejected.
- **Org-only stages with project opt-in.** Simpler resolution, but a project in a
  large org could not define its own process. Rejected for the cascade (D2).
- **One org-level status list.** Breaks a project that binds two trackers. Rejected
  for per-binding mapping (D6).
- **Fold blocked into failure** with a reason code. Keeps re-dispatching into the
  wall. Rejected.
- **Keep the runner's name tables with a role fallback.** Leaves status names in the
  runner. Rejected: role plus contract only (D9.1).
- **Prompt-append skills only.** No size guard and a spawn-failure risk. Rejected for
  native delivery with a capped fallback (D8).

## Decided while drafting (product-owner rulings, 2026-11-02)

These were open in the first draft and are now decisions:

1. A run with no tracker work item omits `stage`; the card contract alone decides
   completion, with no transitions (D9.3).
2. Batch work carries `batchKind`, not `workType` (D9.4).
3. Kit-detected skills are repository skills under the `repoSkills` policy (D8.3).
4. The Codex skill location is decided by an implementation spike, with prompt
   fallback until then (D8.5).
5. The repository-skill policy is best-effort per harness, and the receipt records
   the policy achieved (D8.4).
6. Muse `--trust-workspace` is accepted, including loading the repository's own rules
   and hooks (Risks).
7. Stage configuration supplies inherited defaults, the workflow overrides, and the
   dispatch-stage node shows effective values and sources (D11.4).
8. Effort clamps and is never refused (D7.3).

## Affected documents

These edits land in the accepting commit:

- `001-layered-execution-model.md` — Principle 2: "work types collapse from eight to
  five" becomes stages with roles; § "How the nouns compose": one line that its
  "stages" are a documentation term (D1); Layer 3: batch work is discriminated by
  `batchKind` (D9.4). No `BOUNDARY-SYNC` region is touched.
- `013-orchestrator-and-governor.md` — § "Completion contracts and backstop": the
  name-keyed table becomes the card's contract defaulting from the stage role; status
  moves come from the wire's transitions, and a run with no stage moves nothing;
  § "Two governor loops": batch specs are discriminated by `batchKind`.
- `ADR-2026-06-03-batch-work-type-category.md` — an amendment note: the discriminant
  is `batchKind` (D9.4).
- `014-tui-operator-surfaces.md` — § "Open registries": as D13.
- `016-workflow-engine.md` — § `trigger` card-binding bullets (stage comes from the
  stage, not the card); the `agent.work_type.detect` switch and `workType` action
  examples; § "Workflow design discipline" (the dispatch-stage node); corollary 6
  (D11.4).
- `002-provider-base-contract.md` — § "RequesterProvider": the meaning of
  `agent_request_stage_unmapped`.
- `ADR-2026-09-28-agent-request-dispatches-a-card.md` — an amendment note on D1.3,
  D2.2, D2.4, D3 and D4.
- `README.md` and `AGENTS.md` — this record's entry, refreshed.

## Affected work items

This corpus carries no tracker identifiers; the platform stub names the delivery
program. By shape: the stage model and its cascade; the seven roles; stage cards; the
outcome transitions and tracker mapping v2; model selection and its resolver; skills
as packages with native delivery; the 1.0 wire; the template lint; smokes for
built-in and custom-stage dispatch.

## Implementation notes

- Runner: delete the name tables; branch on `stage.role` and `card.contract`; apply
  `transitions`; add a skill materializer per adapter; cap the prompt fallback.
- The lock-step release is gated on a smoke run of built-in and custom-stage
  dispatch.
- Acceptance evidence: a test, watched failing, that a runner given a stage whose key
  no table knows completes with the card's contract and applies the sent transition.
