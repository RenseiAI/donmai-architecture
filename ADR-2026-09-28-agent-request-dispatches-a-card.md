---
status: Proposed
date: 2026-09-28
boundary: shared
split: sibling-extensions
---

# ADR-2026-09-28 — An agent request dispatches a card: one card-parameterised workflow, tighten-only parameters, a chosen default

**Status:** Proposed
**Date:** 2026-09-28
**Boundary:** shared (OSS-canonical here: the `agent.request` input contract, card
resolution and binding, the split between what a card owns and what a workflow
owns, stage moves, the parameter schema and its tighten-only law, card-keyed
allowlists, dispatch-workflow selection and the refusal codes. The command-line
verb, the reference workflow's name, storage, the hosted policy engine's
resource, provisioning and the migration live in `rensei-architecture`: a
short mirrored stub plus a platform-extensions sibling.)
**Authors:** architecture lane, filed by the coordinator session

## Context

`ADR-2026-06-19-requester-provider-inbound-agent-family.md` added the inbound
`agent.request` trigger with the input contract `{ project, goal, workType? }`.
Implementations built one workflow per work type: near-identical workflows that
differ in a handful of builder arguments, chosen by a closed work-type word that
every entry surface (HTTP, the MCP facade, the A2A dispatcher, the command line,
the typed-delegation adapter) re-validates on its own. The agent definitions
behind those workflows, **agent cards** resolved through the AgentRegistry
family, are already data. The workflows are split only because the input names a
work type instead of a card.

Four forces make that shape wrong:

1. **Work types are not a closed list.** `016` § "Locus of definition" corollary 4
   deprecates closed registries of work types. Deployments define their own
   stages, each with a role. A contract whose selector is a fixed work-type word
   cannot address a deployment-defined stage, and every new card costs a new
   workflow.
2. **What differs between the workflows is card data.** Prompt, work type (and so
   role), tool posture, capability flags, completion contract (artifact kind,
   required fields, verdict vocabulary, whether success advances the stage),
   grader and declared inputs all belong to the card. The rest of each per-type
   workflow is duplicated or incidental.
3. **Tracker status names leak into dispatch.** The per-type workflows move a
   bound issue by literal status names, so dispatch breaks on any tracker whose
   vocabulary differs.
4. **The standard workflow cannot be configured without editing it.** Callers
   cannot pass limits and installers cannot set defaults. Any surface that adds
   this must respect `ADR-2026-09-27-execution-security-levels.md`: no request
   field lowers an execution-security level.

The allowlist in `ADR-2026-06-20-byoa-requester-registration-record.md` names
workflows by template slug. Once one workflow carries every card, that list no
longer says what work an external agent may start.

Product-owner decisions of 2026-09-28 fix the shape of D5 and D7: dispatch is
always backed by a real installed workflow, with no implicit or compiled-in
fallback; a project may carry several dispatch workflows, the user chooses when
more than one matches, and exactly one is the project's default; the workflow
declares typed input parameters that callers may only tighten, and nothing
weakens an execution-security floor.

## Decision

An `agent.request` names an **agent card**, not a work type. A dispatch workflow
binds the card from admitted trigger data, so one workflow runs any card the
project can see. The card owns what the agent is; the workflow owns how it runs.
Callers pass typed parameters that can only tighten. A project may carry several
dispatch workflows, exactly one of which is its default, and no dispatch ever
runs outside an installed workflow.

### D1 — The request names a card

1. The input contract becomes version 2:
   `{ project, card, goal, issue?, workflow?, params? }`. `card` is required and
   there is no default card. `workType` is removed.
2. `card` accepts a card slug, a display name (case-insensitive) or a full scoped
   card reference with an optional version. The control plane resolves it, never
   the caller. Resolution runs over the cards the caller may dispatch into the
   project: published, non-deprecated, visible to the project and inside the
   caller's allowed cards (D6). The narrowest scope in the deployment's scope
   chain wins (workflow, then project, then each wider scope). A tie at the
   winning scope is refused with `agent_request_card_ambiguous`, listing the
   tied candidates; no match is `agent_request_card_not_found`, with the nearest
   names. Candidates and nearest names come only from the caller's dispatchable
   set, so a refusal never reveals a card the caller cannot dispatch, and a card
   outside that set is simply not found (a caller "cannot see, much less call"
   it, per `ADR-2026-06-21-mcp-adapter-archetype.md`). A narrower card
   shadowing a wider card of the same name is the intended override path.
3. A card's work type must be a stage the deployment defines. Card names and work
   types are opaque strings (`016` corollary 4); nothing on the dispatch path
   branches on a particular name.
4. `issue` optionally binds an existing tracker item. It is never required: issue
   tracking stays an optional output, and a request without an issue is
   complete.
5. A version-1 body (one that carries `workType` or lacks `card`) is refused with
   `agent_request_contract_version`, from the moment version 2 ships, naming the
   version-2 contract. There is no translation from a work type to a card,
   because that translation would be a compiled-in default card; a caller still
   sending version 1 at the cut gets that refusal, never a guessed card.
6. The trigger kind stays `agent.request`. Every entry surface carries the same
   version-2 contract and calls the same resolver: native HTTP, the MCP facade of
   `ADR-2026-06-21-mcp-adapter-archetype.md`, A2A (the card is the requested
   skill) and the command line. None of them keeps its own list of work types.

### D2 — One card-parameterised invocation

1. A dispatch workflow's invoke node binds its agent from the trigger through one
   exact binding expression that names the admitted card. A workflow whose invoke
   node uses that expression is **card-parameterised**. Any other expression on
   that field is a static binding and keeps today's meaning.
2. The control plane resolves and admits the card **before** the run. It stamps
   the admitted card (id, version, content digest, work type and its role,
   completion contract, declared inputs) into the trigger data beside the
   workflow admission, and records it on the admission receipt. The executor
   refuses a card binding that admission did not stamp, as it already refuses an
   unstamped workflow admission.
3. The caller's `card` is stage-0 intent in the sense of
   `ADR-2026-08-12-placement-composition-law-and-single-fallback-rule.md`: it
   selects among cards the caller may run and never widens a permission. The card
   version is fixed at admission, and a resume uses the admitted version.
4. The stage a run executes is the card's work type, so the request word never
   reaches a stage registry.

### D3 — The card owns the agent; the workflow owns the run

| Concern | Owner | Rule |
|---|---|---|
| Prompt and partials | card | Unchanged mechanism |
| Work type, and so role | card | Must be a defined stage |
| Tool allow and deny lists | card | Compose at the workflow scope, tighten-only (`ADR-2026-09-27` D2 rule 7) |
| Capability flags (memory, code intelligence, architecture) | card | The workflow wires every capability; the invoke node passes only those the card enables |
| Declared inputs | card | Typed; validated at dispatch; rendered into the goal |
| Completion contract | card | One member of the workflow's bounded union (below) |
| Grader | card | Unchanged |
| Model, budget, placement, delivery | workflow | Visible node configuration; never on the card |

**Bounded completion union.** A card chosen at run time cannot add output ports
to a published workflow. A dispatch workflow therefore declares, at publication,
the set of completion contracts it handles. Each member names an artifact kind,
its required fields, its verdict vocabulary and the stage move for each verdict
(D4). A workflow statically bound to one card has a one-member union: that
card's completion contract. A card whose completion contract is not a member
does not match that workflow (D7). An outcome outside the admitted contract
routes to the workflow's outcome-unknown path, never to a success branch.

### D4 — Stage moves, not status names

A completion contract names stage **moves** (`advance`, `reject` or `none`),
never a tracker status. The IssueTracker provider resolves a move for the card's
work type through the project's configured stage mapping. A card with a verdict
vocabulary (for example `approve`, `request-changes`, `block`) maps each verdict
to a move in its contract; a card without one moves only on success. An
issue-bound request whose card names a move for a work type the project's stage
mapping does not cover is refused at dispatch with `agent_request_stage_unmapped`,
which names the work type. Nothing on the dispatch path names a tracker status.

### D5 — Typed workflow parameters that only tighten

1. **Declared once, versioned with the workflow.** The `agent.request` trigger of
   a dispatch workflow declares a typed parameter schema. Each parameter has a
   key, a type, validation, the node configuration it drives, whether a caller
   may set it (`callerSettable`) and whether it is a limit that may only move
   tighter (`tightenOnly`). The schema is part of the workflow definition, so it
   is versioned with it (`016` § "Versioning") and travels with any template that
   carries it.
2. **Two layers.** *Install parameters* are set by whoever installs or
   administers the workflow in a project, and are stored per project. *Call
   parameters* are the `callerSettable` subset, passed in `params`. `params` also
   carries the card's declared inputs. A card whose input keys collide with the
   workflow's parameter keys does not match that workflow (D7).
3. **Resolution.** For each parameter: the call value, when settable and valid;
   then the install value; then the workflow's visible node-configuration
   default; then an inherited project or wider-scope default. No default lives in
   code. The value this chain yields **without** the call value is the
   parameter's *base*. The receipt records every resolved value and the scope
   that set it.
4. **Tighten-only, against the base.** A caller compares with the base, not with
   the install value alone, which is often unset (for example after automatic
   provisioning). A numeric limit may only be lowered from the base. A
   set-valued parameter may only narrow to a subset of the base. A posture
   parameter may only add denies to the base. A caller value that would loosen
   is refused, never silently clamped. Where no scope yields a base, the
   parameter is unbounded and any valid caller value tightens it.
5. **Floors are out of reach.** No parameter names or selects an
   `executionSecurity` dimension; the effective levels stay the strongest any
   scope sets (`ADR-2026-09-27` D2 rules 2 and 6). Credentials are never
   parameters. Placement and stage behaviour (whether success advances, whether
   a review verdict gates) are install-only.
6. **The control plane is authoritative.** A client may pre-validate against the
   published schema; it never substitutes its own verdict. Refusals carry
   per-key codes (D8).

### D6 — Authorisation names cards

The registration of `ADR-2026-06-20` keeps its allowed projects and gains
**allowed cards**, by scoped card reference; unset means any card visible to an
allowed project. Allowed cards replace the allowed-workflows-by-template-slug
list, which cannot tell one unit of work from another once a single workflow
carries every card. A registration may also narrow which dispatch workflows it
may select, by a republish-stable workflow identity; unset means any. Both are
permission (stage 1) narrowings, evaluated before D7's selection. An
out-of-set card is not found (D1.2), and an out-of-set workflow is refused
before execution, as an out-of-set project is today.

### D7 — Several dispatch workflows, one default, no implicit path

1. **Always a real workflow.** Every dispatch runs through an installed, active
   dispatch workflow in the target project. A deployment may provision one
   automatically, for example at project creation, but what it provisions is an
   ordinary visible and editable workflow (`016` corollary 1, "No hidden
   workflows"). There is no compiled-in dispatch path and no fallback workflow.
2. **Several are allowed.** A project may carry more than one dispatch workflow,
   for example a stricter review variant beside a general one. A workflow
   **matches** a request when it is active in the project; it is
   card-parameterised, or statically bound to the resolved card (a fixed-card
   workflow serves only its own card); the caller may select it (D6); the card's
   completion contract is in its union (D3; for a fixed-card workflow, that card's
   contract); and the card's inputs do not collide with its parameters (D5).
3. **Exactly one default.** A project with at least one dispatch workflow has
   exactly one default, held in the project's defaults. Removing or deactivating
   the default requires naming its successor in the same operation, unless it is
   the last dispatch workflow.
4. **Selection.** An explicit `workflow` that matches is used. An explicit
   `workflow` that does not match is refused with
   `agent_request_workflow_not_selectable` and never falls back. With no
   selection, the default is used if it matches; otherwise the single match, if
   there is exactly one; otherwise the request is refused with
   `agent_request_workflow_ambiguous`, listing the matches the caller may
   select. No match at all is `agent_request_workflow_none`. Interactive surfaces
   show the matches with the default preselected; non-interactive callers select
   with the `workflow` field.
5. The receipt records the selected workflow and how it was chosen: `explicit`,
   `default` or `only-match`.

### D8 — Refusal codes

The closed `AgentRequestRefusalCode` enum. Human-readable detail is display-only
and no consumer branches on it (`ADR-2026-08-13` D4.1).

| Code | Meaning |
|---|---|
| `agent_request_contract_version` | A version-1 body, or a body without `card` |
| `agent_request_card_not_found` | No card in the caller's dispatchable set matches; carries the nearest names from that set |
| `agent_request_card_ambiguous` | More than one dispatchable card ties at the winning scope; carries those references |
| `agent_request_input_invalid` | A card input is missing or fails the card's schema; per key |
| `agent_request_param_unknown` | A key that neither the workflow nor the card declares |
| `agent_request_param_invalid` | A value fails its declared type or validation; per key |
| `agent_request_param_not_caller_settable` | A caller supplied an install-only parameter |
| `agent_request_param_weakens_limit` | A caller value is looser than the base (D5.3); carries the base and the scope that set it |
| `agent_request_stage_unmapped` | An issue-bound request needs a stage move the project's stage mapping does not cover |
| `agent_request_workflow_none` | No dispatch workflow in the project matches |
| `agent_request_workflow_ambiguous` | Several match, the default is not among them and none was selected; carries the matches |
| `agent_request_workflow_not_selectable` | The selected workflow does not match, or is outside the caller's allowed workflows |

## Consequences

### Positive

- Any card, including a deployment-defined one, is dispatchable without a new
  workflow. Adding a card is a data change.
- One workflow per project to publish, review and upgrade instead of one per work
  type, and the entry surfaces lose their duplicate work-type checks.
- Stage moves make dispatch tracker-neutral.
- Installers and callers can configure the standard workflow without editing it,
  and the tighten-only law keeps parameters from becoming a bypass.
- Allowlists describe the work an external agent may start.
- A stricter variant can sit beside the general workflow without a new trigger
  kind or a second contract.

### Negative

- Admission gains a dynamic binding. It must now prove, per request, what a
  static binding proved by inspection (D2.2).
- Card completion contracts and declared inputs become load-bearing, so card
  publication must validate them.
- The inbound contract breaks. Every entry surface and client moves in one
  change; there is no compatibility window.
- A project whose default is restricted and which carries several other matching
  workflows can return `agent_request_workflow_ambiguous` to a non-interactive
  caller that did not select.

### Risks

- **An admission that trusts the caller's card** would let a request run a card
  the caller may not run. Mitigation: D2.2's server-side stamp and the executor's
  refusal of anything unstamped.
- **A card outside every workflow's union** is undispatchable. It surfaces as
  `agent_request_workflow_none` at dispatch; card publication should warn when a
  card matches no dispatch workflow in its scope.
- **Stored install values that never reach node configuration** would make D5
  decorative: validated at install, ignored at run time. Acceptance needs a test
  that fails when a stored value is ignored.
- **Model and budget resolution must walk the same key** for the dispatch
  response and for the run. Otherwise the receipt reports a model the run did
  not use.

## Alternatives considered

- **One workflow per card, generated from card data.** Removes hand-copying but
  keeps a publish per card, multiplies upgrades, and leaves a workflow allowlist
  standing in for a card allowlist. Rejected.
- **Map deployment-defined work types to templates.** Keeps the work-type
  selector and adds a mapping table, which is a closed registry by another name
  (`016` corollary 4). Rejected.
- **A compiled-in dispatch path when no workflow is installed.** Works on day
  zero without provisioning, but hides the user's process in code (`016`
  corollary 1) and bypasses workflow admission. Rejected; provisioning installs
  a real workflow instead.
- **Exactly one dispatch workflow per project.** Simpler selection, but forbids a
  stricter variant beside the general one. Rejected in favour of D7's default
  plus choice.
- **Clamp a loosening caller value to the install value.** Friendlier to callers,
  but a silent clamp hides that the request was not honoured. Rejected;
  loosening is refused with the install value and its scope.

## Affected documents

Status stays **Proposed** in this change; the index entries in `README.md` and
`AGENTS.md` land now so the index matches disk. The edits below land in the
commit that flips this ADR to **Accepted**, OSS side first, with the paired edits
to the mirrored stub and its platform-extensions sibling:

- `016-workflow-engine.md` — § "Node taxonomy" → `trigger`: the `request:` line
  becomes the version-2 contract, and the section gains the card binding (D2),
  the parameter schema and its tighten-only law (D5), card-keyed allowlists (D6)
  and dispatch-workflow selection (D7).
- `002-provider-base-contract.md` — § "RequesterProvider — inbound contract":
  allowed cards replace the allowed-workflow-template-slugs whitelist, and the
  refusal enum (D8) is added.
- `001-layered-execution-model.md` — the RequesterProvider row reads "request →
  card dispatch through a project's dispatch workflow". No `BOUNDARY-SYNC` region
  is touched.
- `013-orchestrator-and-governor.md` — § "Completion contracts and backstop": a
  card dispatch's completion contract is the card's, a member of the workflow's
  union, with stage moves (D3, D4).
- `ADR-2026-06-19-requester-provider-inbound-agent-family.md` — amendment note:
  Decision 3's input contract is superseded by D1, and an optional issue binding
  is admitted.
- `ADR-2026-06-20-byoa-requester-registration-record.md` — amendment note on
  Decision 2: allowed cards and the optional workflow narrowing (D6).
- `ADR-2026-06-21-mcp-adapter-archetype.md` — amendment note: `dispatch` takes the
  version-2 contract, and the discovery tool is renamed `list_cards` and returns
  the cards the caller may dispatch, each with its inputs and the dispatch
  workflows that admit it. Parameters belong to each workflow, so every listed
  workflow carries its own caller-settable parameters and their bases. The
  surface stays at three tools.
- `README.md` — this ADR's entry refreshed to the accepted text, and the
  `ADR-2026-06-21-mcp-adapter-archetype.md` entry, which names `list_workflows`,
  updated to `list_cards`. `AGENTS.md` — this ADR's entry refreshed.

## Affected work items

This corpus carries no tracker identifiers; the platform-extensions sibling in
the platform corpus enumerates the delivery program. By shape:

- **Control plane:** the card resolver and discovery listing; the card binding
  and admission stamp; stage-move resolution; the reference dispatch workflow and
  its parameter declarations; run-time reading of stored install values; caller
  parameters; the card-keyed allowlist; the version-2 contract on every entry
  surface; provisioning and migration.
- **This corpus's repositories:** OSS clients that submit agent requests move to
  the version-2 contract.

## Implementation notes

- Unchanged: the trigger kind `agent.request`, the `requester.respond` node, the
  `external_agent` principal and the `dispatch:invoke` scope.
- One resolver serves every entry surface and the discovery listing. Card
  resolution, allowlist checks and workflow matching share their predicates with
  the listing, so a listed card is dispatchable and an unlisted one is not.
- Acceptance evidence: a test per D8 code that has been watched failing; a test
  that an unstamped card is refused by the executor; a test that a stored install
  value changes the run.
