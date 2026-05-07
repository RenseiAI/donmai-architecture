# agentfactory-architecture

Canonical OSS architecture corpus for the **AgentFactory execution layer** — the `af` binary, the local daemon, the runner, the eight Provider Families, the Kit composition framework, and the workflow engine that underlies them.

**Module / repo**: `github.com/RenseiAI/agentfactory-architecture` (public)

## Purpose

This corpus is the single source of truth for cross-repo architectural decisions affecting the OSS execution layer. Implementation details live in the project repos (`agentfactory-tui`, `agentfactory`, future Kit repos); the **contracts** live here.

Where any project's documentation conflicts with what's written here, this wins. Where this corpus disagrees with shipped code, either the code aligns to the corpus or an ADR amends the corpus — see "How to disagree with this doc" below.

The OSS-canonical framing is load-bearing: every doc in this corpus is something that can be implemented, run, and operated **without** the Rensei SaaS control plane. If a doc here ever names an interface whose only working implementation lives downstream in the Rensei platform, the boundary has been violated and the doc needs to be split per `BOUNDARY.md`.

## Boundary

This repo is the **OSS-public canonical corpus**. Its sibling, [`rensei-architecture`](https://github.com/RenseiAI/rensei-architecture), carries the **Rensei-Platform-extensions** — Linear realignment against the Rensei team's backlog, PM agent definitions tied to that backlog, multi-tenant control-plane decisions, the SaaS dashboard parity discipline, and `<doc>-platform-extensions.md` deltas that extend shared docs in this repo.

The boundary discipline — verbatim from `001-layered-execution-model.md` § "The agentfactory ↔ Rensei Platform contract":

> 1. The OSS layer defines all interfaces in this corpus.
> 2. The OSS layer ships a working implementation of every interface — never *only* the type.
> 3. The SaaS control plane extends with alternate implementations and centralized administration (registries, signing, policy enforcement, multi-tenant management, the SaaS dashboard, the routing-intelligence panel).
> 4. The OSS layer never depends on the SaaS plane to function. Removing the platform leaves a usable single-machine product.
> 5. The boundary between them is a small set of pluggable function callbacks (`setAgentLauncher`-shaped), not subprocess or RPC. The platform composes the OSS layer as a library; both ship as one binary to end users.

**Operational implication for agents working in this repo:** never let Rensei-platform-specific content land here. Concretely:

- No Linear issue IDs (`REN-XXXX`) inline in doc bodies. Cross-references to Rensei tracker IDs belong in `rensei-architecture`'s extension docs. (Migration-context call-outs in commit messages are fine; doc bodies stay tracker-agnostic.)
- No references to platform-resident endpoints (`/api/cli/capacity`, `/api/cli/whoami`, etc.) as if they were OSS-shipped. Daemon endpoints (`/api/daemon/*`) are OSS; platform CLI endpoints (`/api/cli/*`) are not.
- No SaaS-dashboard parity claims. The dual-surface discipline ("every dashboard panel ships a TUI counterpart") is a platform commitment; it lives in `rensei-architecture`.
- No multi-tenant policy hooks (Cedar, RLS, org allowlists) presented as OSS-shipped. The OSS layer ships single-tenant; the platform ships multi-tenant on top.
- No closed-source repo references (the legacy TS `agentfactory/` monorepo, `platform/`, `rensei-tui` private extensions) as if they were canonical sources of truth for the contract. Cite OSS repos (`agentfactory-tui`, `tui-components`, future OSS Kit repos) and the public TS package names (`@renseiai/agentfactory-server`, `@renseiai/agentfactory-code-intelligence`) when illustrating the contract.

If a proposed change to this corpus brings any of the above with it, the right move is **split**: the OSS-substance lands here, the platform delta lands in `rensei-architecture/<doc>-platform-extensions.md`. See `BOUNDARY.md` for the mechanics.

## Read order

Humans and fleet agents alike should consume in this order:

1. **`001-layered-execution-model.md`** — Layered model, terminology, the eight Provider Families, the OSS↔platform boundary, capability-flag abstraction. Read first. Carries the synchronized "agentfactory ↔ Rensei Platform contract" section that mirrors verbatim in `rensei-architecture/001-layered-execution-model-platform-extensions.md`.
2. **`002-provider-base-contract.md`** — Without the base contract, the rest looks like a list of unrelated provider types.
3. **`015-plugin-spec.md`** — Plugin manifest, single-artifact distribution, atomic auth, verb registry. Read second; it formalizes how Provider Families and Workflow Verbs come together in one shippable artifact.
4. **`016-workflow-engine.md`** — Workflow grammar, node taxonomy, durable execution, versioning. Read third; it's the runtime substrate that consumes everything below.
5. The reference doc for whichever layer you are working on:
   - **`003-workarea-provider.md`** — Workarea contract and pool semantics.
   - **`004-sandbox-capability-matrix.md`** — Sandbox capability flags and the cross-provider scheduler.
   - **`005-kit-manifest-spec.md`** — Kit manifest, detect/provide lifecycle, daemon kit registry.
   - **`007-intelligence-services.md`** — Memory + Code Intelligence + Architectural Intelligence interfaces.
   - **`008-version-control-providers.md`** — VCS contract + git/Atomic/S3 adapters.
6. **`013-orchestrator-and-governor.md`** — Orchestrator, governor, worker, AgentRuntime dispatch, completion contracts, macOS signing rule. The runtime that embeds the workflow engine.
7. **`011-local-daemon-fleet.md`** — Operator manual for the local daemon mode of the `af` binary.
8. **`014-tui-operator-surfaces.md`** — TUI display primitives, capability-chip pattern, theme + accessibility. Read if you're building TUI/dashboard features.
9. **`006-cross-provider-interactions.md`** — The seams. Read once you understand the individual layers; this is where most subtle bugs live.

**ADRs to read in order of foundational impact:**

- **`ADR-2026-04-27-plugin-and-workflow-architecture.md`** — Plugin / Provider Family / Workflow taxonomy + AgentRuntime as 8th family. Cross-cutting; mirrored as stub in `rensei-architecture`.
- **`ADR-2026-05-07-daemon-http-control-api.md`** — Local daemon's `/api/daemon/*` HTTP control API. The Wave 9 ADR — canonical example of "OSS daemon owns its own surface."
- **`ADR-2026-04-29-long-running-runtime-substrate.md`** — `@renseiai/agentfactory-server` substrate. Platform schema mirror + JWT trust anchor extensions live in `rensei-architecture`.
- **`ADR-2026-05-03-locus-of-workflow-definition.md`** — Workflow-grammar discipline. Cross-cutting; mirrored as stub in `rensei-architecture`.
- **`ADR-2026-05-06-tui-noun-consolidation.md`** — `host` / `fleet` / `capacity` consolidation. User-auth retrofit + Live capacity addendum extensions live in `rensei-architecture`.
- **`ADR-2026-04-28-sandbox-capabilities-in-types.md`** — TypeScript file-layout decision in `packages/core/src/providers/`.
- **`ADR-2026-04-28-workflow-piping-uses-nodes.md`** — `{{ nodes.*.output.* }}` workflow grammar.
- **`ADR-template.md`** — Template for new architectural decisions. Copy when proposing changes. Mirrored to `rensei-architecture` via stub.

**Agents (archetypes):**

- **`agents/pm/backlog-writer.yaml`** — PM-archetype: refine/groom/author modes, no-sub-issue rule, haiku-executable scope discipline.
- **`agents/pm/outcome-auditor.yaml`** — Outcome auditor archetype.
- **`agents/pm/improvement-loop.yaml`** — Improvement-loop archetype.
- **`agents/pm/operational-scanner-sentry.yaml`** — Operational-scanner archetype family (Sentry representative).
- **`agents/migration/migration-coordinator.yaml`** — Migration coordinator archetype.

Each agent YAML ships with `tools: []` placeholder; operator-specific tool allowlists extend via `extends:` siblings in `rensei-architecture/agents/<group>/<name>-rensei.yaml`. See `BOUNDARY.md` § "extends: composition pattern for agents YAMLs".

Skip when consuming only this OSS corpus: [`009-linear-realignment.md`](https://github.com/RenseiAI/rensei-architecture/blob/main/009-linear-realignment.md) and [`012-product-management-agents.md`](https://github.com/RenseiAI/rensei-architecture/blob/main/012-product-management-agents.md) (both platform-only; live in `rensei-architecture`). Their content operates against the Rensei team's Linear backlog.

## How to disagree with this doc

This corpus is the canonical synthesis of an architectural conversation, not a final answer. To disagree:

1. Open an ADR proposing the change (copy `ADR-template.md`).
2. State the affected sections of this corpus and the reference docs.
3. Declare the ADR's `boundary:` field in frontmatter — `OSS-only`, `platform-only`, or `shared`. See `BOUNDARY.md` for the verdict definitions.
4. Commit the ADR; if the discussion converges, update the affected reference docs in the same commit that flips the ADR to `Accepted`.

Direct edits without an ADR are fine for clarifications, examples, typo fixes, and broken-link repairs. Anything that changes a contract, a layer's responsibility, or a discipline statement requires an ADR.

**Cross-cutting ADRs** (those whose `boundary:` field is `shared`) follow the dual-publish-stub pattern: the canonical file lives here; `rensei-architecture` carries a thin stub that references this corpus. See `BOUNDARY.md` § "Cross-cutting ADR dual-publish".

## Conventions

- Doc numbering is stable. Don't renumber without an ADR. New docs append (`010-`, `017-`, etc.).
- Diagrams use Mermaid embedded in markdown. Avoid external image assets.
- Code samples are TypeScript or Go depending on subject; concrete code lives in source repos, not here.
- "Kit" is a placeholder name pending brand decision; do not search/replace until the rename ADR lands.
- ADR frontmatter declares `boundary:` upfront — see `BOUNDARY.md`.
- Synchronized sections (currently: `001` § "The agentfactory ↔ Rensei Platform contract") carry a `BOUNDARY-SYNC` comment marker; edits require paired commits to both corpora. See `BOUNDARY.md` § "Synchronized sections".

## Status

**Wave 10 Phase 3 migration complete.** OSS-only and shared-with-OSS-substance docs have migrated from `rensei-architecture` here in a series of per-doc commits. Cross-reference rewrites (Phase 4) come next; expect some markdown cross-links to currently point at bare filename references that Phase 4 promotes to absolute `agentfactory-architecture` URLs or platform-extensions sibling URLs as appropriate.
