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

**Pending Phase 3 migration.** The Phase 1 boundary audit (`runs/WAVE10_PHASE1_AUDIT.md` in the Rensei runs/ directory) tagged 11 OSS-only docs and 13 shared docs (with OSS substance) for migration into this corpus. Until those Phase 3 commits land, treat `rensei-architecture/001-layered-execution-model.md` § "Reading order for new contributors" as the source of truth, skipping `009-linear-realignment.md` and `012-product-management-agents.md` (both platform-only).

A concrete OSS-canonical reading order will land in this AGENTS.md as part of Phase 3's final commit, replacing this placeholder. Until then:

> **Placeholder note (Wave 10 Phase 2):** the per-doc read order will be authored once the OSS docs migrate from `rensei-architecture` in Phase 3 (one commit per doc). Maintainers committing the Phase 3 series should update this section in the same commit that lands `001-layered-execution-model.md` here.

## How to disagree with this doc

This corpus is the canonical synthesis of an architectural conversation, not a final answer. To disagree:

1. Open an ADR proposing the change (copy `ADR-template.md` once it lands in Phase 3; until then, copy from `rensei-architecture/ADR-template.md`).
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

**Wave 10 Phase 2 scaffolding** — repo just stood up. Phase 3 will migrate the OSS-only docs from `rensei-architecture` here in a series of commits. This AGENTS.md will be revised in Phase 3 to point at concrete docs once they land.
