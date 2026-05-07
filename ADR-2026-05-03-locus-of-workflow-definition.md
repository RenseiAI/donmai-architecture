# ADR-2026-05-03-locus-of-workflow-definition

**Status:** Proposed
**Date:** 2026-05-03
**Boundary:** shared (OSS-canonical; mirrored as a stub in `rensei-architecture` per `BOUNDARY.md` § "Cross-cutting ADR dual-publish")
**Authors:** mark, claude

## Context

The Rensei Platform's value proposition is that users compose any process they want from a small set of composable primitives — triggers, conditions, actions, gates — wired together as a node graph on the workflow canvas. AgentFactory (OSS) is opinionated and batteries-included; Rensei (paid) is the engine that makes the user's process explicit and editable.

Wave 7 (REN-1485, REN-1486, REN-1488) shipped a stage-driven SDLC implementation that, in the course of solving real wire-up gaps, accumulated coupling that contradicts that value proposition:

- A required `transition_to: string` field on every stage's exit (`src/lib/workflow/stages/lifecycle-schema.ts`), forcing every stage to mutate tracker state on success.
- An auto-generated *pair* of workflows per stage (a `dispatch` workflow and a separate `exit` workflow) at publish time (`src/lib/workflow/templates/sdlc-default-stage-driven/index.ts`). Neither workflow is visible on the canvas; the user cannot see, debug, or replace them.
- A hardcoded `CANONICAL_STAGE_IDS` list of five SDLC stages (`research`, `backlog-writer`, `development`, `qa`, `acceptance`) that the dispatcher (`agent.dispatch_stage`) and prompt loader reject anything outside of.
- A trigger normaliser that emits hardcoded `com.rensei.stage.<id>.start` CloudEvents — users cannot substitute their own trigger.
- Stage prompts are TypeScript modules in `src/lib/workflow/stages/prompts/<stageId>.ts`; users cannot supply a prompt via configuration.

The same antipattern predates wave 7. The legacy default SDLC workflow (`Downloads/rensei-default-sdlc.yaml`) ships two condition nodes whose user-facing surface is a list of case labels but whose decision logic lives in node-implementation code rather than on the canvas:

- **`agent.work_type.detect` ("Detect Work Type")** — surface shows cases `[development, inflight, qa, acceptance, refinement, research]`. The actual routing logic (`STATUS_WORK_TYPE_MAP`, mention-keyword scan, first-touch override that promotes `inflight`→`development` when no session exists) lives in `src/lib/nodes/condition/agent.work_type.detect/backend.ts`. From the user's perspective, the node is a black box: they see *that* a routing decision happens, not *how* or *why*.
- **`linear.issue.status_switch` ("Next Station")** — same shape; routing between Finished→QA, Delivered→Acceptance, Rejected→Refinement is encoded in the node's TypeScript backend, not on the canvas.

Some nodes in the same family also accept long opaque JSON config blobs that the user must paste verbatim to invoke hidden code paths — the user cannot read or revise them line by line.

A user wanting a non-SDLC lifecycle — for example "New DM → Draft Response → Apply Brand Voice → Publish" for a social media pipeline — cannot author it on the canvas today. They would have to fork the platform's source. Likewise, a user wanting to *understand* what the existing default SDLC actually does cannot do so by reading the canvas; they must read TypeScript.

The platform already ships the primitives a self-describing workflow needs (Agent Session Completed trigger, Linear Status Equals condition, Linear Update Issue action). The problem is not whether transitions exist — it is **where** they are defined and **how visible their internals are** once defined.

## Decision

Every behavior that affects the user's process — transitions, conditions, agent dispatch, branching, success/failure handling — MUST live as a visible, editable node on the workflow canvas (or in a user-edited workflow YAML). The platform provides composable primitives; users wire them up.

Declarative shorthands such as `spec.lifecycle` are acceptable only as **sugar that compiles into user-visible nodes** at publish or render time — never into hidden auto-generated workflows or implicit framework behavior.

Concretely, this ADR accepts the following invariants for the workflow engine and any framework that builds on top of it:

1. **No hidden workflows.** Anything the engine treats as part of "the user's process" is visible at the canvas root or one group level deeper. No auto-published companion workflows that the user did not author.
2. **No required mutations.** Schema fields that force a transition, write, or side effect to exist are anti-patterns. Fields like `exit.transition_to` become optional or are removed entirely in favor of user-placed action nodes.
3. **Sugar compiles to nodes.** If the platform offers a compact way to express a common pattern (a lifecycle table, a stage list, a prompt registry), the resulting graph must be inspectable on the canvas exactly as if the user had drawn it themselves. The user can then edit it.
4. **Closed registries are deprecated.** Hardcoded lists of stage ids, work types, or prompt keys lock users out of using the platform for processes the platform's authors didn't anticipate. Users supply names; the engine treats them as opaque strings.
5. **The Agent Exit primitive.** Today, "agent finished successfully" and "agent failed" are two separate triggers. They should fold into a single Agent Exit node with `success` and `fail` output edges, so a user expresses post-agent flow as one node with two branches rather than two parallel trigger chains.

6. **Node transparency.** Every node's behavior is visible and configurable from the canvas. A node that shows case labels while its routing logic lives in node-implementation code is a black box and is forbidden going forward. Likewise, a node whose configuration requires the user to paste a long opaque JSON blob to invoke hidden code paths is forbidden. If a node's decision logic is non-trivial (status mappings, keyword tables, override rules, prompt strings), that logic is exposed as named, typed, editable inputs the user reads and revises without leaving the canvas. The legacy `agent.work_type.detect` ("Detect Work Type") and `linear.issue.status_switch` ("Next Station") nodes are deprecated examples; both get either replaced with composable smaller nodes or refactored to surface their internal mappings as canvas-editable config.

## Consequences

### Positive

- The platform's value proposition becomes literally true: users can author any process. The "social DM pipeline" example is achievable on the canvas without code changes.
- Wave 7's debugging difficulty (9 wire-up gaps across 9 PRs in this iteration alone) drops sharply — when behavior is on the canvas, it is grep-able and correlatable to a specific node id.
- The OSS / SaaS boundary in `016` becomes more honest: OSS owns the grammar and runtime; SaaS adds the visual designer that makes node-graph authoring tractable. Hidden auto-generated workflows muddied this — they were behavior shipped by SaaS templates that OSS users could not see or edit.
- Customers who upgrade from AgentFactory to Rensei get exactly the upgrade we sell: their soldered SDLC unfolds into composable nodes they own.

### Negative

- Wave 7's stage-driven SDLC implementation needs partial rework. The dispatch + exit pair-workflows-per-stage shape is incompatible with this ADR. The migration is one user-visible workflow per stage with the agent dispatch action, the session-completed branch, and any transition action all on the same canvas. Some of the inventory's 10 baked-in items become explicit work items.
- Convenience templates that today bake an entire SDLC into a project on install will become more verbose. Mitigation: ship the templates as **published workflows** (visible on the canvas, deletable, editable) rather than as hidden code-generated workflows.

### Risks

- **Schema migration risk.** Existing published workflows that rely on `lifecycle.transition_to` need a migration path. Mitigation: keep the field accepted at parse time, mark it deprecated, compile it into a user-visible `linear.issue.update` action node on the published workflow rather than into a hidden companion workflow.
- **Designer ergonomics risk.** Single-stage workflows with explicit success/failure branches have more visible nodes than today's hidden version. The Agent Exit node primitive is the mitigation; pairs of "Agent Session Completed" + "Agent Session Failed" trigger chains would be a regression.
- **Cross-cutting reach.** This ADR touches `016`, `001`, and parts of `013`. The Linear realignment in `009` and the orchestrator contracts in `013` need a once-over for any other implicit-behavior assumptions baked in.

## Alternatives considered

**A. Make `transition_to` optional but keep the auto-generated pair workflows.** Rejected. The tightest coupling is the hidden-workflow shape, not the required field. Optional `transition_to` only addresses one of ten inventory items.

**B. Document the SDLC chain as a built-in product feature, accept the coupling.** Rejected. It contradicts the platform's value proposition and the existing language in `001 Principle 2` and `016 Compilation contract` (both already imply user-authored control flow).

**C. Wait until wave 8 to refactor.** Rejected. Each wave that ships under the wave-7 shape adds more code to migrate later. Stating the principle now anchors design reviews on subsequent PRs.

## Affected documents

- `001-layered-execution-model.md` — Principle 2 extended to mention workflow-canvas as the locus of control-flow definition.
- `016-workflow-engine.md` — new top-level section "Locus of definition — user-visible nodes only", inserted between "Workflow design discipline" and "Templating and the inter-node output piping gap".
- `013-orchestrator-and-governor.md` — completion contracts section gets a clarifying note that contract outputs are observable artifacts (commits, comments, status transitions made via user-authored action nodes), not hidden side effects of the orchestration framework.

## Affected work items

- **REN-1485** (Wave 7 stage-driven SDLC) — its current shape is the inventory under "Context"; remediation issues spawn from this ADR.
- A new follow-up Linear issue captures the 10-item baked-in coupling inventory plus the legacy `Detect Work Type` / `Next Station` deprecations, and tracks the migration to user-visible, transparent nodes. (To be filed when this ADR is accepted.)
- The Agent Exit node primitive is a separate work item (palette + designer + executor support).
- **`agent.work_type.detect` and `linear.issue.status_switch` deprecations** — each gets a dedicated work item: either replace with composable smaller nodes the user wires explicitly, or refactor to expose internal mappings (status table, keyword pool, override rules) as canvas-editable typed config. The Default SDLC YAML rewrite called out in `016` § "Linear realignment hooks" subsumes the user-facing portion of this work.

## Implementation notes

The migration is staged. First step is non-breaking: keep `lifecycle.transition_to` parsing, compile it to a user-visible `linear.issue.update` node on the published workflow, deprecate the field with a console warning. Second step deletes the auto-generated companion-workflow shape and the closed `CANONICAL_STAGE_IDS` registry. Third step ships the Agent Exit node and migrates wave-7 prompts out of `prompts/<stageId>.ts` into config the user can edit.
