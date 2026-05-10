# 016 — Workflow Engine

**Status:** Reference (initial draft)
**Last updated:** 2026-04-27
**Related:** `001-layered-execution-model.md`, `015-plugin-spec.md`, `013-orchestrator-and-governor.md`, ADR-2026-04-27.

## Why this exists

The Rensei Platform shipped a workflow engine inspired by [WeaveMindAI/weft](https://github.com/WeaveMindAI/weft) (REN-1021 competitive intel + decision doc, Accepted 2026-04-17). Workflows are graphs of typed nodes that compose plugin verbs into runnable processes — the SDLC dispatch, custom QA pipelines, eventual scheduled flows. The engine is the runtime substrate the orchestrator embeds; the corpus needs to specify it formally because every Plugin's verbs are invoked through it.

The engine is **versioned grammar** (`apiVersion: workflow/v1`), **typed nodes**, **durable execution**, **compile-time validation**. It inherits from WEFT's "if it compiles, it runs" property and adds Rensei-specific patterns (BFSI approval gates, multi-tracker scoping, agent dispatch as a first-class action class).

### What we adopted from WEFT

The W1-W5 imports from REN-1021 (in active backlog as platform issues, including REN-1139 "Loop node type, composes with Weft W2 groups"):

- **W1: Typed ports + compile-time edge validation.** Reject type-incompatible edges at save time with actionable errors.
- **W2: Recursive groups with scoped typed interfaces.** Any subgraph collapses to a reusable node with declared inputs/outputs. Single biggest lever for workflow legibility at scale.
- **W3: AST-as-source-of-truth; bidirectional code⇄graph sync.** YAML is one projection of the AST; React Flow is another. Edits to either propagate.
- **W4: Null-propagation branching semantics.** Required ports refuse null; downstream skips; optional `?` ports absorb. Cleaner than the legacy true/false-handle ceremony.
- **W5: Per-node folder layout + auto-discovery registry.** Lowers cost-to-add-a-node; pairs with the Plugin spec's verb registry.

### What we declined from WEFT

Per REN-1021 §7:

- **Restate-based durable executor.** Our DB-memoized DAG executor + Redis pub/sub is durable-enough; Restate adds K8s coupling.
- **Compile-to-Rust standalone binary.** No customer problem this solves.
- **Custom-language syntax as primary authoring surface.** Conflicts with our React Flow canvas + YAML + AI-builder triad.
- **Breadth-first messaging catalog (Discord/Telegram/SMS).** Anti-ICP for regulated enterprise.
- **In-product K8s manifest authoring.** Targets self-hosted solo AI builders, not enterprise.

## Grammar

```yaml
apiVersion: workflow/v1
kind: WorkflowDefinition

metadata:
  name: Custom QA Pipeline
  description: Run unit tests, integration tests, and security scan in parallel.
  version: "3"
  authoredBy: did:web:tenant.example
  scope:
    project: my-project

# Required providers — refuse to deploy if not active
requires:
  - plugin: linear@1
  - plugin: agentfactory@1
  - plugin: vercel@1

# Triggers — entry points that fire workflow runs
triggers:
  - id: pr_opened
    kind: webhook
    config:
      eventType: github.pr.opened
  - id: cron_nightly
    kind: cron
    config:
      schedule: "0 3 * * *"
      timezone: America/Los_Angeles

# Spec — the graph
spec:
  steps:
    - id: extract_pr
      type: trigger                    # references triggers[].id
      config:
        triggerId: pr_opened
      next: [route_by_size]

    - id: route_by_size
      type: condition
      config:
        action: agentfactory@1:agent.size_estimate
        nodeId: agent.size_estimate
        provider: agentfactory
      branches:
        small: run_unit_tests
        medium: run_unit_and_integration
        large: run_full_pipeline
      defaultHandle: small
      edgeLabels:
        small: ≤ 50 LoC
        medium: 51-500 LoC
        large: > 500 LoC

    - id: run_unit_tests
      type: action
      config:
        action: agentfactory@1:agent.dispatch_to_queue
        provider: agentfactory
        workType: qa
        scope: unit-tests-only
      next: [report_results]

    # ... (other branches) ...

    - id: report_results
      type: action
      config:
        action: linear@1:linear.agent_session.acknowledge
        provider: linear
```

## Node taxonomy

Four types. The engine never invents a fifth without a major version bump.

### `trigger`

Entry points. Externally-fired. Cannot be invoked by the engine. Subscribed to via `triggers[]` at the top of the workflow definition.

```yaml
triggers:
  - id: my_trigger
    kind: webhook | cron | signal | manual
    config:
      eventType: ...                   # webhook: external event match
      schedule: ...                    # cron: cron expression
      signalEventType: ...             # signal: typed event subscription
```

Trigger-step nodes in `spec.steps[]` reference these by id. Multiple triggers per workflow are allowed; each fires an independent run.

### `condition`

Branching node. Two modes.

**Boolean mode** (`branches.yes`/`no`):

```yaml
- id: project_allowed
  type: condition
  config:
    action: linear@1:linear.issue.project_allowed
    provider: linear
  branches:
    yes: continue
    no: reject
```

**Switch mode** (`mode: switch`, `cases[]`, `defaultHandle`):

```yaml
- id: detect_work_type
  type: condition
  config:
    mode: switch
    action: agentfactory@1:agent.work_type.detect
    cases: [development, qa, acceptance, refinement, research]
    defaultHandle: true
  branches:
    development: dev_group
    qa: qa_group
    acceptance: acceptance_group
    refinement: refinement_group
    research: research_group
    default: development              # fallback when defaultHandle: true
```

The verb's output schema must declare an enum that matches `cases[]`. Compile-time validation rejects mismatches.

### `action`

Side-effect node. Invokes a plugin verb. Outputs feed downstream nodes.

```yaml
- id: dispatch_dev
  type: action
  config:
    action: agentfactory@1:agent.dispatch_to_queue
    provider: agentfactory
    workType: development
    issueId: ${trigger.data.issueId}
  next: [await_completion]
```

The verb's `sideEffectClass` (`read-only` / `external-write` / `internal-only` per `015`) drives policy hooks — e.g., a tenant policy may require human approval before any `external-write` verb in a regulated environment.

### `gate`

Suspends until a typed event matches. Pairs with verbs declared `kind: gate` in their plugin manifest.

```yaml
- id: await_session_complete
  type: gate
  gateConfig:
    gateType: signal
    signalEventType: com.linear.AgentSessionEvent.completed
    onTimeout: skip                   # skip | error | branch:<step-id>
    timeoutMs: 86400000               # 24h
  next: [route_by_status]
```

Durable across crashes (see "Durable execution" below).

## Verb namespacing — ownership vs domain

Verbs use `<plugin>.<resource>.<verb>` or `<plugin>.<verb>`. The first token is the **plugin id** (ownership/auth boundary, established by `015`). The second token is an **entity-domain namespace** within the plugin. The third (when present) is the operation.

Example: `linear.issue.is_terminal` decomposes as:
- `linear` — Linear plugin owns this verb; auth/credentials route through Linear's OAuth
- `issue` — operates on Linear's `Issue` entity
- `is_terminal` — predicate operation

This is meaningful: the workflow author can read the verb id and know both *who provides it* and *what entity domain it touches*. The engine doesn't enforce three-token vs two-token style; both are valid. Plugins choose based on their domain depth.

## Compilation contract

Workflow Definitions go through a compile pass before deploy. The engine validates:

1. **Plugin presence** — every plugin in `requires` is installed and enabled.
2. **Verb resolution** — every `config.action` resolves to a registered verb at the pinned version.
3. **Schema validation** — templated inputs (Handlebars `${...}` against the trigger payload + step outputs) match the verb's input schema.
4. **Branch enums** — for switch conditions, declared `cases` are members of the verb's output enum.
5. **Topology** — DAG (no cycles), every step reachable from at least one trigger, terminal steps don't claim non-existent next-step ids.
6. **Type compatibility (W1)** — when inter-node output piping is implemented (see Open Questions), upstream output types must satisfy downstream input types.
7. **Scope** — provider scope (`002`) admits the workflow's tenant/project; plugins with insufficient scope reject installation.
8. **Provider-enabled gating** — every verb's owning provider (the prefix segment of the verb id, e.g., `linear` in `linear.agent_session.acknowledge`) must be registered AND enabled in the workflow's bound tenant/project. A workflow that references `linear.*` verbs against a GitHub-Issues-bound subscription fails to publish. This is the compile-time enforcement of `ADR-2026-05-10-native-rich-providers.md`.

Failed compilation produces structured errors with line numbers (when YAML) or node ids (when authored via React Flow). The "if it compiles, it runs" property is intentional inheritance from WEFT.

**Editor palette filtering.** The workflow editor (React Flow canvas + node picker) reads the active org's enabled integrations + each provider's declared capability flags (`002`) and shows only the nodes/verbs the user can actually wire up. Linear-only orgs never see GitHub-Issues nodes in the palette; orgs with no Vercel integration never see `vercel.deploy`. This is the user-visible counterpart to compile-time gating — the editor never offers a verb that compilation would later reject. Per `ADR-2026-05-10-native-rich-providers.md`, doubling node count when a second provider lands is the correct cost; palette filtering is what keeps the surface tractable.

## Durable execution

Sessions and workflows run for minutes to days. Crashes happen. Re-orchestration must not double-effect.

The engine persists **every step output** to the platform's database (`stepExecutions` table, memoized by `(workflowRunId, stepId, attempt)`). On orchestrator restart, the engine resumes by replaying memoized outputs and re-invoking only steps not yet complete.

For gate nodes specifically:

- The engine stores a subscription record for the gate's `signalEventType`.
- When a matching event arrives (from any plugin's webhook handler emitting it onto the signal bus), the gate resumes and continues to its `next` step.
- Timeouts handle the no-event case: `onTimeout: skip` advances; `error` halts the run; `branch:<step-id>` reroutes.

This is durable-enough for the use cases REN-1021 enumerated. Restate-style cluster-of-actor durability is explicitly declined per the WEFT decline list.

## Workflow design discipline

The legacy auto-generated SDLC YAML (`/Users/markkropf/Downloads/rensei-default-sdlc.yaml`) is the canonical example of *what not to do*. Long flat chain of `parent? → ack → dispatch → ack → dispatch` per work type, plus an opaque `Detect Work Type` switch. The pathology W1.b (recursive groups) was imported to fix.

**Top-level discipline:** A workflow's root view should fit on a single screen. Detail belongs in groups.

The user's manual SDLC (the canonical pattern this engine should be capable of expressing without ceremony):

1. Write a short paragraph about the capability/problem
2. Mention research agent
3. Manual review, mention backlog-writer
4. Manual move to backlog, mention agent → dev/coordination
5. Same for QA
6. Same for acceptance

Translates to:

```yaml
spec:
  steps:
    - id: trigger
      type: trigger
      next: [classify]

    - id: classify
      type: condition
      config:
        mode: switch
        action: agentfactory@2:agent.classify_request
        cases: [research, refinement, development, qa, acceptance, ad-hoc]
      branches:
        research: research_group
        refinement: refinement_group
        development: development_group
        qa: qa_group
        acceptance: acceptance_group
        ad-hoc: development_group
      defaultHandle: development

    - id: research_group
      type: group                     # W2 — group with scoped typed interface
      config:
        ref: ./groups/research.yaml

    - id: refinement_group
      type: group
      config: { ref: ./groups/refinement.yaml }

    - id: development_group
      type: group
      config: { ref: ./groups/development.yaml }

    # ... etc
```

Top-level: 7 nodes (trigger + classify + 5 groups + maybe a terminal). Groups encapsulate the dispatcher gates, ack-then-queue chain, and per-work-type logic. Each group internally fits its own single screen.

## Locus of definition — user-visible nodes only

This is the binding architectural rule for the workflow engine and any framework that builds on top of it (templates, lifecycle configs, plugin-shipped flows):

> Every behavior that affects the user's process — transitions, conditions, agent dispatch, branching, success/failure handling — MUST live as a visible, editable node on the workflow canvas (or in a user-edited workflow YAML). The platform provides composable primitives; users wire them up. Declarative shorthands (lifecycle tables, stage lists, prompt registries) are acceptable only as **sugar that compiles into user-visible nodes** at publish or render time — never into hidden auto-generated workflows or implicit framework behavior.

The transitions themselves are not the issue. `linear.issue.update`, `linear.issue.status_equals`, `agent.session.completed`, and the rest of the action/condition/trigger taxonomy already exist as nodes a user can place. The rule constrains where and how they are *defined*, not whether they exist.

### Corollaries

1. **No hidden workflows.** Anything the engine treats as part of "the user's process" is visible at the canvas root or one group level deeper. No auto-published companion workflows that the user did not author. A template that needs to ship a multi-step flow ships it as a *published workflow the user can see and edit*, not as code-generated SQL inserts on install.

2. **No required mutations.** Schema fields that force a transition, write, or side effect to exist are anti-patterns. A stage that wants to halt without mutating tracker state must be expressible. Optional fields are fine; required-with-no-no-op-default fields are not.

3. **Sugar compiles to nodes.** If the platform offers a compact declarative shorthand for a common pattern (e.g. `spec.lifecycle: { research: { trigger: …, exit: … } }`), the result on the canvas must be inspectable as if the user had drawn it. The user can then delete, reorder, or extend it.

4. **Closed registries are deprecated.** Hardcoded lists of stage ids, work types, or prompt keys lock users out of using the platform for processes the platform's authors didn't anticipate. Users supply names; the engine treats them as opaque strings. Validation rejects unknown *structure*, not unknown *names*.

5. **The Agent Exit primitive.** Today's "Agent Session Completed" and "Agent Session Failed" exist as two separate trigger node types. They fold into a single **Agent Exit** node with `success` and `fail` output edges, so post-agent flow is one node with two branches rather than two parallel trigger chains. This is the right primitive shape for the canvas; everything downstream (the locus rule, the lifecycle-config compilation target, the cross-link to Topology view) gets cleaner with it.

6. **Node transparency — every node's logic is on its surface.** A node's behavior must be visible and configurable from the canvas, not hidden in node-implementation code or behind opaque JSON payloads. A switch-mode condition that shows a list of case labels while its routing rules live in TypeScript is a black box from the user's perspective: they see *that* a decision happens, not *how*. So is any node that requires pasting a long JSON config blob to invoke hidden code paths the user cannot inspect. If a node's decision logic is non-trivial, that logic must be exposed as named, typed, editable inputs — rules, mappings, prompts, status tables — the user reads and revises without leaving the canvas. Concretely deprecated examples in the legacy default SDLC (`Downloads/rensei-default-sdlc.yaml`):

   - **`agent.work_type.detect` ("Detect Work Type")** — node surface shows the case set [development, inflight, qa, acceptance, refinement, research]; the actual decision logic (`STATUS_WORK_TYPE_MAP`, mention-keyword scan, first-touch override) lives in `src/lib/nodes/condition/agent.work_type.detect/backend.ts`. Remediation: split into composable nodes (a Linear status condition, a comment-keyword condition, an explicit routing branch) that the user wires; *or* surface the mapping table and override rules as the node's editable config.
   - **`linear.issue.status_switch` ("Next Station")** — same shape; routing rules between native states live in code rather than on the canvas. Remediation: replace with `Linear Status Equals` condition nodes wired to user-labelled outgoing branches.

   These are slated for removal as part of unwinding wave 7's hidden SDLC; the principle generalises beyond them. Any future node that proposes "logic in code, labels on canvas" fails this corollary.

### How to apply this rule in design reviews

When reviewing a PR, ADR, or workflow template, ask:

- *Does this introduce behavior the user didn't place on the canvas?* If yes, redesign so the behavior is a node the user sees.
- *Does this require a tracker mutation, write, or side effect for the workflow to be "successful"?* If yes, make it optional and let the user wire the mutation.
- *Does this hardcode a list of names (stages, work types, profiles, prompts) that the platform's runtime accepts?* If yes, open the registry. Validate structure, not vocabulary.
- *Does this node show case labels, action names, or status pills while its actual decision logic lives in node-implementation code?* If yes, expose the logic as editable config on the node, or split into smaller composable nodes whose behavior is fully expressed by their wiring.
- *Does invoking this node require pasting an opaque JSON blob the user can't reason about line-by-line?* If yes, redesign the node's surface so its inputs are named, typed, and individually editable.
- *Does this ship a compact declarative form?* That's fine — if and only if its compile target is a user-visible node graph.

The corollaries above are the test, not the principle itself; new corollaries can be added when an unanticipated coupling pattern shows up. See `ADR-2026-05-03-locus-of-workflow-definition.md` for the full decision record and the wave-7 + legacy-SDLC inventory that motivated it.

## Templating and the inter-node output piping gap

The current `apiVersion: workflow/v1` supports Handlebars-style templating against the trigger payload only (`{{ trigger.data.* }}`):

```yaml
config:
  issueId: "{{ trigger.data.issueId }}"
  promptContext: "{{ trigger.data.body }}"
```

What's **missing** today: references to the output of upstream steps in the graph. A WEFT-style typed port between intermediate nodes — `{{ steps.detect.output.workType }}` — does not yet work.

The user has confirmed this is a **gap to close**, not an intentional restriction. The fix is part of a future `apiVersion: workflow/v2` migration:

- Each step's output schema declares its shape.
- Downstream steps reference upstream outputs via `{{ steps.<id>.output.<field> }}`.
- The engine validates type compatibility at compile time (W1).
- The current trigger-only model continues to work as a special case (`{{ trigger.* }}` is shorthand for `{{ steps.<trigger-id>.output.* }}`).

Tracked as a `009` net-new issue: *"Inter-node output piping for workflow/v2"*. Priority is high — without it, every step has to encode all needed state in its config from the trigger payload, which makes complex pipelines write-only.

## Versioning

Three layers of versioning compose:

### 1. Engine `apiVersion`

`workflow/v1` is Rensei's current workflow grammar — groups, switch conditions, signal gates, durable execution. (Note: an earlier draft of this spec briefly used `workflow/v2` because the model was Weft-imported; with low adoption and no actual v0 in production, the version space resets to `v1`.) `workflow/v2` is the next bump and adds inter-node output piping (per Open Question above).

Engine version bump policy: patch (input-compatible), minor (additive), major (breaking; requires verb-version pinning and deprecation window). Major bumps run multiple `apiVersion` workflows simultaneously during a deprecation window — when the field is exercised at scale.

### 2. Workflow Definition `metadata.version`

Per-workflow internal version. Edits bump it. Gate event subscriptions and durable run state are pinned to a specific workflow version — in-flight runs continue on their pinned version even when the workflow definition is edited.

### 3. Plugin verb pinning

Workflows reference verbs as `<plugin>@<major>:<verb>`. See `015` versioning section. The engine refuses to compile workflows whose pinned verb version is past its deprecation date.

## Topology view (cross-link)

The Rensei Platform's Topology view (live, React Flow-based) renders **workflow runs in flight**, not workflow *definitions*. It shows: Issue Cluster → Sessions → Sub-agents → Satellites. Sub-agents appear when an `AgentRuntimeProvider` emits Task-tool events (Claude does today; Codex/Spring AI may not — `emitsSubagentEvents` capability flag).

Detail in `013-orchestrator-and-governor.md`. Worth knowing here: the engine emits structured run events that the Topology view subscribes to via SSE; gates show as "waiting for `<eventType>`" with timeout countdown.

## OSS vs SaaS responsibilities

| Concern | OSS | SaaS |
|---|---|---|
| Workflow grammar (`apiVersion: workflow/v1`) | ✅ owns | consumes |
| YAML parser + AST | ✅ owns | consumes |
| Compile-time validation | ✅ ships | inherits |
| Durable execution runtime | ✅ ships (sqlite + in-process) | ✅ ships (Postgres + Redis pubsub) |
| Workflow registry | ✅ ships local | ✅ ships hosted |
| React Flow designer | ❌ (TUI only) | ✅ owns |
| Workflow marketplace | ❌ | ✅ owns |
| Cross-tenant workflow templates | ❌ | ✅ owns |
| Migration tooling for apiVersion bumps | ✅ ships | inherits |

OSS users get a working workflow engine, can author YAML by hand, run it locally. SaaS adds the visual designer, the marketplace, and multi-tenant administration.

## Linear realignment hooks

- **REN-1021** (Competitive Intel - Weft) — Accepted; the research basis. Workstreams W1-W10 land as platform issues; this doc defines the contracts they implement against.
- **REN-1139** (Loop node type, composes with Weft W2 groups) — implements W2 group composability.
- **W1-W5 cluster** (typed ports, groups, AST source-of-truth, null propagation, per-node folders) — the foundation; some shipped, some pending. `009` realignment expansion enumerates current state.
- **Default SDLC YAML rewrite** — the legacy generated YAML should be replaced with a human-readable group-shaped version once W2 ships. Net-new issue in `009`.

## Open questions

1. **Inter-node output piping (workflow/v2).** Confirmed as a gap to close. Concrete grammar and migration path land as an ADR when implementation starts.
2. **Group versioning.** Groups can ship as separate files (`./groups/research.yaml`). Should groups be versionable independently of their parent workflow? Default: yes — a group is a Workflow Definition with declared interface ports; pin like a plugin.
3. **Workflow as kit contribution.** Should kits (`005`) be allowed to contribute workflow templates? Default: yes — a Spring kit might ship a "Spring-typical QA pipeline" template. Plugins (`015`) can also; kits are a sibling.
4. **Compile-time vs install-time validation cost.** Compile is fast on small workflows; on large workflows with many groups + cross-plugin dependencies, validation cost grows. Mitigation: incremental compile (only re-validate changed steps + their type-frontier).
5. **AI-builder generation conventions.** When AI generates a workflow YAML, the legacy SDLC anti-pattern (long flat chains) emerges naturally. Worth a "design lint" pass that scores generated workflows on group-density, max top-level node count, and verb-namespace cleanliness. Future tooling, post-W3.
6. **Manual designer round-trip.** Today's React Flow designer emits YAML with broken indentation (visible in the SDLC YAML file). Pre-W3 fix worth tracking, but ultimately an AST-source-of-truth refactor (W3) closes it.

These are intentional gaps for ADRs as we get implementation experience.
