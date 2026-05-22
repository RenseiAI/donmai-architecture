# /agents/pm/ — OSS PM Agent Archetypes

Canonical OSS agent definitions for the Product Management (PM) archetype family. These are the foundation definitions: they declare the tool contract, prompt structure, model preferences, and completion contract for each PM role. They carry no implementation-specific tools.

Architecture authority: `../../016-workflow-engine.md` (workflow dispatch); `../../002-provider-base-contract.md` (AgentRegistryProvider interface); `../../BOUNDARY.md` (boundary convention and `extends:` overlay pattern).

## OSS archetype index

| File | Archetype | Role summary |
|---|---|---|
| `backlog-writer.yaml` | `backlog-writer` | **Linchpin PM agent.** Refines icebox-quality issues into backlog-actionable issues. Optimizes scope for parallelism and explicit dependency relationships. |
| `backlog-groomer.yaml` | `backlog-groomer` | Continuous icebox grooming. Staleness detection, duplicate clustering, Fibonacci effort estimation, goal-alignment tagging. |
| `outcome-auditor.yaml` | `outcome-auditor` | Post-acceptance audit. Compares delivered work against original intent; authors follow-up issues for gaps. |
| `improvement-loop.yaml` | `improvement-loop` | Systemic pattern finder. Scans session outcomes for recurring failure modes; authors meta-improvement issues. |
| `operational-scanner-sentry.yaml` | `operational-scanner` | Sentry error cluster scanner. Representative of the scanner family; other source-specific variants (Vercel, CI, audit) follow the same archetype. |
| `ga-readiness.yaml` | `ga-readiness` | Pre-launch readiness gate. Evaluates issue backlog, test coverage signals, and open blockers against a GA checklist. |
| `documentation-steward.yaml` | `documentation-steward` | Docs freshness maintenance. Detects stale documentation relative to recent code changes; authors update issues. |
| `coordination.yaml` | `coordination` | Cross-cutting coordination. Plans and sequences a set of dependent issues; surfaces blockers; does not execute implementation. |
| `qa-runner.yaml` | `qa-runner` | Quality review. Reads acceptance criteria and code changes; produces a structured pass/fail verdict with evidence. |
| `program-manager.yaml` | `program-manager` | Epic-level planning and progress tracking. Not a per-issue agent — operates at milestone and cycle granularity. |
| `release-coordinator.yaml` | `release-coordinator` | Release gate orchestration. Coordinates go/no-go decisions, changelog authoring, and post-release retrospective issues. |
| `acceptance-reviewer.yaml` | `acceptance-reviewer` | Acceptance criteria verification. Validates that a completed issue's deliverables match its stated criteria. |
| `code-reviewer.yaml` | `code-reviewer` | Code review automation. Produces structured review comments aligned to the org's coding conventions partial. |

## The `extends:` overlay pattern

OSS archetypes declare `boundary: shared` in frontmatter. Operators and platform teams customise them via `extends:` overlays rather than editing the base files directly.

**Canonical overlay pattern:**

```yaml
# rensei-architecture/agents/pm/backlog-writer-rensei.yaml
apiVersion: donmai.dev/v1
kind: AgentDefinitionOverride
metadata:
  id: backlog-writer-rensei
  name: Backlog Writer (platform team)

# Point at the OSS canonical base.
extends: agentfactory-architecture/agents/pm/backlog-writer.yaml
boundary: platform-only

# Add platform-specific tool allowlist.
# The OSS base's tools.disallow entries are inherited unchanged.
tools:
  allow:
    - shell: "pnpm af-linear get-issue *"
    - shell: "pnpm af-linear update-issue *"
    - shell: "pnpm af-linear create-issue *"
    - shell: "pnpm af-linear list-comments *"
    - shell: "pnpm af-linear create-comment *"
    - shell: "pnpm af-code search-symbols *"
    - shell: "pnpm af-code search-code *"
  disallow:
    # Concrete shell form of the OSS archetype's abstract disallow rule.
    - shell: "pnpm af-linear create-issue --parentId *"

observability:
  metricsPrefix: donmai_pm_backlog_writer
```

The `extends:` field is resolved at publish time (not at dispatch time): the platform performs a deep-merge (child fields win on conflict) and stores the result as a flat materialized `agent_cards` row. Dispatch is a single table lookup — no chain traversal.

**Merge direction is upward-only:** project-scope cards may extend org-scope or system-scope; org-scope may extend system-scope; system-scope may not extend an org-scope card.

Platform-team overlays live in `rensei-architecture/agents/pm/<name>-rensei.yaml`. For custom tenant overrides, create a new file using the pattern above and publish it via the platform API (`/api/org/agents` or `/api/project/agents`).

## Hard rule across all PM archetypes

**No PM agent creates Linear sub-issues for decomposition.** Per `../../001-layered-execution-model.md` Principle 1, sub-issues are reserved for human intent. Cost-efficiency decomposition uses sub-agents within a session (Task tool on Claude; equivalents on other AgentRuntimeProviders). Every archetype's `tools.disallow` list includes:

```yaml
disallow:
  - issue-tracker:create-issue-with-parent
```

Overlays must not reinstate this disallow rule. The concrete shell form (`pnpm af-linear create-issue --parentId *`) should be added to platform-specific `tools.disallow` lists to enforce at the CLI level.

## Boundary tags

| Boundary value | Meaning |
|---|---|
| `shared` | OSS-substance. This corpus owns the authoritative definition. Platform teams extend via overlay, not by editing here. |
| `OSS-only` | Pure OSS plumbing. No platform extension expected. |

See `../../BOUNDARY.md` for the full four-value `boundary:` enum and the simultaneous-PR rule for synchronized sections.

## Cross-reference: platform implementations

The platform-level documentation for how AgentCards are published, scoped, and invoked from workflow nodes:

```
../rensei-architecture/agents/README.md       — 10-pack PM roster + Layer 6 ADR index
<platform>/docs/agent-capability-layer/       — developer-facing reference docs
```

The 10-pack publication (platform Y1 roster) uses these OSS archetypes as bases. The published system-scope cards are materialized during the Lane A1 migration (Stream A, Wave A+B+C, 2026-05-12).
