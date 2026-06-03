# Donmai Architecture

Canonical OSS architecture corpus for the **Donmai execution layer** — the `donmai` binary, the local daemon (`donmai daemon`), the runner, the eight Provider Families, the Kit composition framework, and the workflow engine that underlies them.

This corpus is the single source of truth for cross-repo architectural decisions affecting the OSS execution layer. Where any project's documentation conflicts with what's written here, this wins.

## What lives here vs. its sibling

This repository is the **OSS-public canonical corpus**. Its sibling, [`rensei-architecture`](https://github.com/RenseiAI/rensei-architecture), is the **Rensei-Platform-extensions corpus** — it carries the platform-only docs (Linear realignment against the Rensei team's backlog, PM agent definitions tied to that backlog, the SaaS dashboard parity discipline, multi-tenant control-plane decisions) and the platform-side `<doc>-platform-extensions.md` deltas that extend shared docs in this repo.

The boundary discipline — verbatim from `001-layered-execution-model.md` § "The donmai ↔ Rensei Platform contract":

> 1. The OSS layer defines all interfaces in this corpus.
> 2. The OSS layer ships a working implementation of every interface — never *only* the type.
> 3. The SaaS control plane extends with alternate implementations and centralized administration (registries, signing, policy enforcement, multi-tenant management, the SaaS dashboard, the routing-intelligence panel).
> 4. The OSS layer never depends on the SaaS plane to function. Removing the platform leaves a usable single-machine product.
> 5. The boundary between them is a small set of pluggable function callbacks (`setAgentLauncher`-shaped), not subprocess or RPC. The platform composes the OSS layer as a library; both ship as one binary to end users.

That discipline — particularly point (4), "removing the platform leaves a usable single-machine product" — is what determines which docs live in this corpus and which extend the contract from `rensei-architecture`. See `BOUNDARY.md` for the convention this repo uses to keep the split honest going forward.

## Status

**Wave 10 Phase 3 migration complete.** OSS-only and shared-with-OSS-substance docs have migrated from `rensei-architecture` here. Phase 4 (cross-reference rewrite) follows; expect some inline markdown links to currently use bare filename forms that Phase 4 promotes to absolute repo URLs or sibling-repo paths.

## Index

### Canonical

- **`001-layered-execution-model.md`** — Layered model, terminology, the eight Provider Families, the OSS↔platform boundary, capability-flag abstraction. Read first. This doc carries a **synchronized** "donmai ↔ Rensei Platform contract" section that is mirrored verbatim in `rensei-architecture/001`; see `BOUNDARY.md`.

### Reference docs (per layer)

- **`002-provider-base-contract.md`** — Unified `Provider` interface that all eight plugin families extend. Manifest, capability struct, AgentRuntime v2 enrichments.
- **`003-workarea-provider.md`** — Deterministic filesystem state. `acquire`/`release` lifecycle, snapshot semantics, local pool implementation.
- **`004-sandbox-capability-matrix.md`** — Capability flags and regime-fit table for Sandbox providers (Local, Vercel, E2B, Modal, Daytona, Docker, K8s). Cross-provider scheduler.
- **`005-kit-manifest-spec.md`** — Buildpacks-shaped contribution framework. `detect`/`provide` lifecycle, manifest schema, daemon kit registry.
- **`006-cross-provider-interactions.md`** — How layers cooperate at the seams. Workarea↔Memory cursor, Kit toolchain → Sandbox image, A2A as transport flavor (OSS-substance seams; Seam 4 cost-emission and Seam 6 audit-chain extensions live in `rensei-architecture`).
- **`007-intelligence-services.md`** — Memory + Code Intelligence + Architectural Intelligence interfaces and single-tenant reference impls. Multi-tenant federation lives in `rensei-architecture`.
- **`008-version-control-providers.md`** — `VersionControlProvider` interface admitting git hosts, Atomic, S3, and non-code substrates.

### Distribution & runtime

- **`011-local-daemon-fleet.md`** — Operator manual for the local daemon mode of the `donmai` binary. Install paths (macOS launchd, Linux systemd, Docker), first-run wizard, config knobs, drain semantics, recovery, observability, HTTP control API. Multi-machine fleet aggregation lives in `rensei-architecture`.
- **`013-orchestrator-and-governor.md`** — Orchestrator, governor, worker, AgentRuntime dispatch, completion contracts, macOS signing & notarization rule. Topology view + Donmai merge-queue specifics live in `rensei-architecture`.
- **`014-tui-operator-surfaces.md`** — TUI display primitives, capability-chip pattern, theme + accessibility, primitive registry. Live capacity contract + dual-surface discipline live in `rensei-architecture`.
- **`015-plugin-spec.md`** — Plugin manifest, single-artifact distribution, atomic auth, verb registry, namespacing, lifecycle, versioning.
- **`016-workflow-engine.md`** — Workflow grammar, node taxonomy, compile contract, durable execution, locus-of-definition rule, inter-node piping.

### ADRs

- **`ADR-template.md`** — Template for new architectural decisions. Copy when proposing changes. Mirrored to `rensei-architecture` via stub.
- **`ADR-2026-04-27-plugin-and-workflow-architecture.md`** — Plugin / Provider Family / Workflow taxonomy + AgentRuntime as 8th family. Cross-cutting; mirrored as stub in `rensei-architecture`.
- **`ADR-2026-04-28-sandbox-capabilities-in-types.md`** — TypeScript file-layout in `packages/core/src/providers/`.
- **`ADR-2026-04-28-workflow-piping-uses-nodes.md`** — `{{ nodes.*.output.* }}` workflow grammar.
- **`ADR-2026-04-29-long-running-runtime-substrate.md`** — `@donmai/server` substrate. Platform schema mirror + JWT trust anchor extensions live in `rensei-architecture`.
- **`ADR-2026-05-03-locus-of-workflow-definition.md`** — Workflow-grammar discipline. Cross-cutting; mirrored as stub in `rensei-architecture`.
- **`ADR-2026-05-06-tui-noun-consolidation.md`** — `host` / `fleet` / `capacity` consolidation. User-auth retrofit + Live capacity addendum extensions live in `rensei-architecture`.
- **`ADR-2026-05-07-daemon-http-control-api.md`** — Local daemon's `/api/daemon/*` HTTP control API. Wave 9 ADR — canonical example of "OSS daemon owns its own surface."
- **`ADR-2026-05-10-native-rich-providers.md`** — Provider abstractions split into typed-internal contract + native-rich user-visible surface; never lowest-common-denominator. Cross-cutting; mirrored as stub in `rensei-architecture`.
- **`ADR-2026-05-12-cli-linear-proxy.md`** — CLI Linear proxy via platform login session; `rensei linear` command routes through platform OAuth on behalf of the agent. Cross-cutting; mirrored as stub in `rensei-architecture`.
- **`ADR-2026-05-12-cross-process-hook-bus-bridge.md`** — Cross-process Layer 6 hook bus bridge for daemon-driven sessions; enables hook events to propagate from worker children back to the daemon host. Cross-cutting; mirrored as stub in `rensei-architecture`.
- **`ADR-2026-06-01-code-survival-pool-execution.md`** — Code-survival batch execution in the worker pool: ephemeral-clone posture, atomic claim, concurrent fan-out, soft reachability weight. Cross-cutting; platform extensions in `rensei-architecture`.
- **`ADR-2026-06-02-interactive-agent-run-mode.md`** — Interactive (non-headless) agent run mode; in-pool streaming sessions with token output and all auth modes. Cross-cutting; mirrored as stub in `rensei-architecture`.
- **`ADR-2026-06-02-oss-brand-neutral-runtime-contract.md`** — Removes closed-source Rensei brand from OSS donmai runtime (env names, default URLs, state paths); pushes all Rensei identity into composition layers. Cross-cutting; mirrored as stub in `rensei-architecture`.
- **`ADR-2026-06-03-batch-work-type-category.md`** — Formalizes `batch` as a first-class work-type category in the execution model, amending `001` §Layer 3 and `013`; covers KG extraction and code-survival as examples. Cross-cutting; mirrored as stub in `rensei-architecture`.
- **`ADR-2026-06-03-injectable-state-dir.md`** — Makes daemon host-state dir (state + log paths) injectable by the embedding binary via a `donmai/runtime/statehome` seam; OSS default stays `donmai`, closed composing binary sets its own brand. Cross-cutting; mirrored as stub in `rensei-architecture`.

### Agents (archetypes)

- **`agents/pm/backlog-writer.yaml`** — PM-archetype: refine/groom/author modes, no-sub-issue rule, haiku-executable scope discipline. Rensei-team tool allowlists live in `rensei-architecture/agents/pm/backlog-writer-rensei.yaml` via `extends:`.
- **`agents/pm/outcome-auditor.yaml`** — same pattern.
- **`agents/pm/improvement-loop.yaml`** — same pattern.
- **`agents/pm/operational-scanner-sentry.yaml`** — Sentry-source archetype; same pattern.
- **`agents/migration/migration-coordinator.yaml`** — Migration archetype: AgentDefinition + Task tool + WORK_RESULT marker. Rensei-team-specific binary-distribution gate + tool allowlists live in `rensei-architecture/agents/migration/migration-coordinator-rensei.yaml` via `extends:`.

### Convention

- **`BOUNDARY.md`** — How this corpus stays OSS-canonical: the three verdicts (`OSS-only` / `platform-only` / `shared`), split mechanism for shared docs, dual-publish-stub pattern for cross-cutting ADRs, frontmatter `boundary:` field, synchronized-section CI hook plan, `extends:` composition pattern for agents YAMLs.

## Reading order for new contributors

Humans and fleet agents alike should consume in this order:

1. **`001-layered-execution-model.md`** — Layered model, terminology, the eight Provider Families, the OSS↔platform boundary, capability-flag abstraction. Read first.
2. **`002-provider-base-contract.md`** — Without the base contract, the rest looks like a list of unrelated provider types.
3. **`015-plugin-spec.md`** — Plugin manifest, single-artifact distribution, atomic auth, verb registry.
4. **`016-workflow-engine.md`** — Workflow grammar, node taxonomy, durable execution.
5. The reference doc for whichever layer you are working on: `003` (workarea), `004` (sandbox), `005` (kit), `007` (intelligence), `008` (VCS).
6. **`013-orchestrator-and-governor.md`** — The runtime that embeds the workflow engine.
7. **`011-local-daemon-fleet.md`** — Operator manual for the local daemon mode of the `donmai` binary.
8. **`014-tui-operator-surfaces.md`** — TUI display primitives, capability-chip pattern, theme + accessibility.
9. **`006-cross-provider-interactions.md`** — The seams; where most subtle bugs live.

For full read-order detail (including ADR ordering and agent archetypes), see `AGENTS.md`. Skip [`009-linear-realignment.md`](https://github.com/RenseiAI/rensei-architecture/blob/main/009-linear-realignment.md) and [`012-product-management-agents.md`](https://github.com/RenseiAI/rensei-architecture/blob/main/012-product-management-agents.md) when consuming only this OSS corpus — both are platform-only and live in `rensei-architecture`.

## How this corpus changes

This repo follows permissive-direct-to-main norms. Both humans and fleet agents may commit directly. The git history is the audit log.

**Substantive architectural changes follow the ADR pattern**: copy `ADR-template.md` to a new dated file (e.g., `ADR-2026-06-12-merge-queue-as-vcs-capability.md`), commit the proposal, and update the affected reference docs in the same commit. The canonical doc (`001`) is updated only when an ADR has shifted the layered model itself. New ADRs declare a `boundary:` field in their frontmatter — see `BOUNDARY.md`.

**Non-substantive edits** (typos, clarifications, examples, broken-link fixes) commit directly without ceremony.

## Conventions

- Doc numbering is stable. Don't renumber without an ADR. New docs append (`010-`, `017-`, etc.).
- Diagrams use Mermaid embedded in markdown. Avoid external image assets.
- Code samples are TypeScript or Go depending on subject; concrete code lives in source repos (`donmai`, `donmai-libraries`, future Kit repos), not here.
- "Kit" is a placeholder name pending brand decision; do not search/replace until the rename ADR lands.
