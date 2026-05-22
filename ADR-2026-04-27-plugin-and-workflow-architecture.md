# ADR-2026-04-27 — Plugin Distribution Model and Workflow Engine as First-Class Architecture

**Status:** Accepted
**Date:** 2026-04-27
**Boundary:** shared (OSS-canonical; mirrored as a stub in `rensei-architecture` per `BOUNDARY.md` § "Cross-cutting ADR dual-publish")
**Authors:** Mark Kropf (Rensei) + Claude Opus 4.7 (1M context) — synthesized from architectural conversation 2026-04-27

## Context

The initial architectural corpus (`001`–`009`, `011`) defined seven plugin families (Sandbox, Workarea, VCS, IssueTracker, Deployment, AgentRegistry, Kit) with a unified Provider base contract. Two pieces of context emerged late in the architectural conversation that require a corpus-level reframe before further docs can land coherently:

1. **The agentfactory codebase has two existing provider concepts not unified by the corpus.** `AgentProvider` (claude/codex/amp/spring-ai/a2a) — a typed LLM dispatch interface with its own capability struct — and `ProviderPlugin` (Slack/GitHub/Jira-shaped integration plugins with actions, triggers, conditions). Neither maps onto the seven families as drafted.

2. **The platform has shipped a workflow engine** (`apiVersion: workflow/v1`) inspired by WEFT (`WeaveMindAI/weft`). Workflows are graphs of typed nodes (`trigger | condition | action | gate`), and every functional node references a `provider` namespace + `verb`. The workflow engine is the runtime substrate for the orchestrator and is absent from the corpus.

3. **A fundamental decomposition pattern** was being implemented via Linear sub-issue creation (e.g., backlog-writer creating 3 sub-issues for a 1-point ticket). This conflates *human intent* with *agent-internal work decomposition* and creates real friction (humans need to enable sub-issue view; agents misread sub-issue dependencies as blockers).

A research turn covering plugin distribution patterns (Backstage, GitHub Apps, Vercel Integrations, n8n, Temporal, Argo Events, Inngest, Pipedream, VSCode extensions) and a workflow-engine research turn (WEFT) settled the model below.

## Decision

This ADR records four interlocking decisions that together amend the corpus.

### Decision 1: Plugin is the artifact of distribution; Provider Family is the typed interface

A **Plugin** is one installable unit (npm package, registry artifact). It declares zero, one, or many implementations of typed Provider Family interfaces. It also declares a registry of named Workflow Verbs that the workflow engine can invoke.

Manifest shape (VSCode/n8n hybrid):

```yaml
apiVersion: donmai.dev/v1
kind: Plugin
metadata:
  id: vercel
  version: 1.4.0
providers:                          # typed-arrays-per-capability
  deployment:
    - id: vercel.deployment
      class: ./dist/providers/deployment.js#VercelDeploymentProvider
  sandbox:
    - id: vercel.sandbox
      class: ./dist/providers/sandbox.js#VercelSandboxProvider
  observability:
    - id: vercel.logs
      class: ./dist/providers/logs.js#VercelLogDrainProvider
verbs:                              # flat verb registry
  - id: vercel.deploy
    inputSchema: ./schemas/deploy.input.json
    outputSchema: ./schemas/deploy.output.json
    implementedBy: vercel.deployment
events:
  webhookPath: /webhooks/vercel
  types: [vercel.deployment.succeeded, vercel.deployment.failed]
auth:
  type: oauth2
  scopes: [deployments:read, deployments:write, projects:read, logs:read]
engines:
  donmai: ">=0.9 <2.0"
```

**Single artifact** for distribution. **Atomic auth** — one OAuth flow grants the full declared scope set. **Verb namespace** enforced at registry validation: every verb must start with `<plugin>.` prefix to prevent collisions. **Major-version pinning** in workflow definitions (`vercel@1:vercel.deploy`) so plugin upgrades don't break installed workflows.

Rationale: every consumer-facing ecosystem we surveyed (VSCode, n8n, GitHub Apps, Vercel Integrations) chose typed-arrays-per-capability + single-artifact + atomic-auth. Multi-artifact and capability-level scoping have all regressed to atomic in the systems that tried them.

### Decision 2: AgentRuntimeProvider added as an 8th typed family

The codebase's `AgentProvider` (claude/codex/amp/spring-ai/a2a) is renamed in the corpus to **AgentRuntimeProvider** to disambiguate from "agent" as a content concept. It joins the seven existing families as the 8th:

`Sandbox, Workarea, VCS, IssueTracker, Deployment, AgentRegistry, Kit, AgentRuntime`

Capabilities include the existing `supportsMessageInjection`, `supportsSessionResume`, `supportsToolPlugins`, `toolPermissionFormat`, plus new flags discovered during the conversation:

- `emitsSubagentEvents: boolean` — does this runtime emit events when it spawns sub-agents (Claude's Task tool: yes; Codex: no)? Drives Topology view sub-agent visibility per provider.
- `humanLabel: string` — paired with each capability flag for TUI rendering ("billed continuously while running" rather than `'wall-clock'`).

The codebase's existing `AgentProvider` is the implementation; the corpus name is `AgentRuntimeProvider`. Migration is rename-only.

### Decision 3: Workflow Engine elevated to first-class corpus citizen

The workflow engine is documented in a new corpus doc `016-workflow-engine.md`. It defines:

- **Grammar:** `apiVersion: workflow/v1` (versioned), `WorkflowDefinition` resource with `metadata`, `triggers[]`, `spec.steps[]`.
- **Node taxonomy:** `trigger | condition | action | gate`. Conditions support boolean (`branches.yes/no`) and switch (`mode: switch, cases: [...]`). Gates subscribe to typed event signals.
- **Verb namespacing:** `<plugin>.<resource>.<verb>` or `<plugin>.<verb>`. The `provider` field on a node is the ownership/auth boundary; the verb's first token after the plugin prefix is an entity-domain namespace.
- **Compilation contract:** verbs validate input schemas, output schemas, and branch enums at compile time. Workflows refuse to deploy if required providers aren't active.
- **Versioning policy:** patch (input-compatible), minor (additive), major (breaking; requires verb-version pinning and deprecation window).
- **Open architectural question:** the current YAML only templates `{{ trigger.data.* }}` — there is no inter-node output piping (`{{ steps.detect.output }}`). User confirmed this is a gap, not an intentional restriction; closure tracked in `016`. Will land as `workflow/v2`.

Workflows compose Plugin verbs; the engine is a runtime substrate the orchestrator embeds. Doc `013-orchestrator-and-governor.md` describes the orchestrator/governor as components that *invoke* the engine, not as the engine itself.

### Decision 4: Three discipline principles for the orchestration model

To resolve the sub-issue / coordination friction, the corpus adopts three principles, recorded in `001` and enforced by templates and orchestrator behavior:

**Principle 1 — Issues are human intent. Sessions are agent work. Sub-agents are intra-session optimization. Linear sub-issues are reserved for human use.**

The system MUST NOT create Linear sub-issues for cost-efficiency decomposition. Cost-efficiency decomposition uses sub-agents within a session (Task tool on Claude provider; equivalent on others where supported). Linear sub-issues are created only when a human (or an agent acting on a human's explicit refinement instruction) decides the work merits separate intent tracking.

**Principle 2 — Decomposition is a session-internal concern, not a workflow-level fork.**

The current `-coordination` work types (`development-coordination`, `inflight-coordination`, `qa-coordination`, `acceptance-coordination`) are deprecated. Coordinators are agents using sub-agents heavily; they're not a different work type. Work types collapse from eight to five: `development`, `qa`, `acceptance`, `refinement`, `research`. Backlog-writer is elevated to a first-class agent (separate from work types) and is documented in [`rensei-architecture/012-product-management-agents.md`](https://github.com/RenseiAI/rensei-architecture/blob/main/012-product-management-agents.md).

**Principle 3 — Quality must compound, not decay.**

The architecture explicitly commits to closing the Day-1-vs-Day-40 gap (where agent fleet quality decays as a project ages while conversation quality stays consistent). The mechanism: active context injection at session start via the Memory layer (`007`), with the architecture corpus itself as one of the highest-priority retrieval sources. Detail in updated `007`.

## Consequences

### Positive

- **Unifies the codebase's two existing provider concepts** (`AgentProvider`, `ProviderPlugin`) under one model without a rewrite. Migration is rename + manifest extraction.
- **Makes the Vercel friction tractable.** Single Donmai Vercel App = one install, OAuth atomic, multiple capabilities (Deployment + Sandbox + Observability + workflow verbs). No per-user-seat cost ridiculousness.
- **Sub-issue pollution stops at the architectural level.** Backlog-writer's "1-point gets 3 sub-issues" pathology is named explicitly as an anti-pattern in `012`.
- **SDLC workflow simplifies dramatically.** Post-W1-W5 (group support), the SDLC YAML becomes top-level case-statement-into-Group-per-work-type instead of the current 30+ node opaque chain.
- **Spring team contribution path is concrete** — the Plugin manifest in `015` is a stable target Spring can build against.

### Negative

- **Existing platform issues need rescoping.** Multi-tracker mirror, agent registry, and Vercel integration backlog items all have plugin shapes implied; some of their drafted scope no longer applies cleanly.
- **One-time migration cost for existing projects** with thousands of agent-created sub-issues. Operational, out of scope for the architecture.
- **Workflow engine work (WEFT W1-W5 cluster) becomes load-bearing for the SDLC redesign.** The new SDLC YAML can't be authored cleanly until typed ports + recursive groups + AST source-of-truth ship. Sequencing matters.

### Risks

- **The unified Provider base contract may be stretched too thin** if AgentRuntime and Kit are genuinely different shapes. The contract in `002` admits this; if implementation reveals real divergence, an ADR can split the base.
- **Capability discrepancy between declared and observed** — the runtime verification step (`002`) is critical for plugin trust. Without it, plugins can lie about their capabilities and the scheduler routes incorrectly.
- **Workflow versioning is hard.** `workflow/v1` is already shipped; future migrations need clear policy. `016` proposes a three-tier policy (patch/minor/major) but real migration experience is needed.

## Alternatives considered

- **(a) Treat ProviderPlugin as the public face of the seven families** — rejected because the codebase implementation is genuinely distinct and the workflow engine's verb registry is a real second concept that deserves first-class treatment.
- **(b) Promote ProviderPlugin to a 9th family (`WorkflowIntegrationProvider`)** — rejected because the integration concept (Slack/GitHub/Jira) cleanly decomposes into a Plugin that implements existing families + exposes verbs. A 9th family would duplicate.
- **(c) Keep workflows as an internal concern of the orchestrator** — rejected because the workflow engine is now the runtime substrate that every plugin verb is invoked through. Hiding it inside `013` inverts the dependency.
- **(d) Adopt sub-issue-based decomposition with better tooling** — rejected because the underlying primitive (Linear sub-issues) was built for human intent, not agent decomposition. No amount of tooling closes the human/agent semantic mismatch.

## Affected documents

- **`001-layered-execution-model.md`** — major update: new layered picture (Plugin / Provider Family / Workflow Verb / Workflow Definition / Workflow Engine), AgentRuntimeProvider added as 8th family, Three Principles section, Day-1-vs-Day-40 commitment, dual-surface discipline, two-binary boundary canonical realization.
- **`002-provider-base-contract.md`** — clarify Plugin vs Provider Family relationship, add `humanLabel` companion to capability flags, add capability-tag-to-typed-struct migration path.
- **`004-sandbox-capability-matrix.md`** — cite `donmai/worker/types.go` dial-out impl as reference for worker registration model.
- **`007-intelligence-services.md`** — add language-host boundary subsection (multi-impl behind one consumer interface), add active context injection section (Day-1-vs-Day-40).
- **`011-local-daemon-fleet.md`** — answer the GUI status open question (the TUI's `daemon status` IS the GUI surface).
- [`rensei-architecture/009-linear-realignment.md`](https://github.com/RenseiAI/rensei-architecture/blob/main/009-linear-realignment.md) — major expansion: cross-repo findings (agentfactory, donmai, closed-source TUI, tui-components), plugin/workflow reframe consequences, ~40 net-new issues.

## Follow-on implementation items

Net-new items to implement (full list in `009`):

- Plugin manifest spec implementation
- Workflow engine inter-node output piping (W3 / new)
- Backlog-writer agent definition (`012`)
- Active backlog grooming workflow
- AgentRuntimeProvider rename + capability struct expansion
- `-coordination` work type deprecation migration
- Sub-issue cleanup utility
- Topology view sub-agent persistence (cold-start visibility)
- ... ~40 total in `009`

## Implementation notes

The corpus updates land in five sequenced commits:

1. ADR + `001` reframe (this commit).
2. New core docs: `015-plugin-spec.md`, `016-workflow-engine.md`, `013-orchestrator-and-governor.md`.
3. Targeted updates to `002`, `004`, `007`, `011`.
4. Deferred docs: `014-tui-operator-surfaces.md`, [`rensei-architecture/012-product-management-agents.md`](https://github.com/RenseiAI/rensei-architecture/blob/main/012-product-management-agents.md) + `/agents/pm/*.yaml`.
5. Major expansion of [`rensei-architecture/009-linear-realignment.md`](https://github.com/RenseiAI/rensei-architecture/blob/main/009-linear-realignment.md).

`010-security-architecture.md` remains explicitly deferred; the security cross-cut in `001` is authoritative until it lands.
