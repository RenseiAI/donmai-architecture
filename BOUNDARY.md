# Boundary convention

This doc is how `agentfactory-architecture` and `rensei-architecture` stay honest about which corpus owns which content. Every doc in either corpus carries a verdict; every shared doc has a defined split mechanism; every cross-cutting ADR follows the dual-publish-stub pattern.

The convention here was authored at Wave 10 Phase 2 stand-up; the resolutions feeding it (Phase 1 audit + coordinator decisions on six open questions) are at `runs/WAVE10_PHASE1_AUDIT.md` and `runs/WAVE10_PHASE1_RESOLUTIONS.md` in the Rensei runs directory. Phase 5 will refine this doc — for instance, the synchronized-section CI hook is *flagged* here but not yet *implemented*; it lands as a small Go tool or GitHub Action in Phase 5.

## The three verdicts

Every doc, ADR, and agent definition that affects either corpus carries one of three verdicts:

- **`OSS-only`** — The content is OSS-execution-layer plumbing. Implementations of every interface ship in OSS code; no part of the contract requires the SaaS control plane to function. Lives only in `agentfactory-architecture`. Examples: provider base contract, workarea provider contract, kit manifest spec, daemon HTTP control API.
- **`platform-only`** — The content is Rensei-platform-specific. Tied to the Rensei team's Linear backlog, the Rensei SaaS dashboard, multi-tenant control-plane policy, or operational state of the Rensei org. Lives only in `rensei-architecture`. Examples: `009-linear-realignment.md`, the PM agent rosters tied to Rensei team's backlog, multi-tenant Postgres+RLS+Cedar policy.
- **`shared`** — The content has both OSS-substance and platform-extension portions. The OSS-substance lives in `agentfactory-architecture`; the platform-extension delta lives in `rensei-architecture` either as a sibling `<doc>-platform-extensions.md` or as inline addenda in the `rensei-architecture` copy. Examples: `001-layered-execution-model.md`, `011-local-daemon-fleet.md`, `014-tui-operator-surfaces.md`.

The Phase 1 audit (`runs/WAVE10_PHASE1_AUDIT.md`) is the source of truth for the initial verdict assignment of every existing doc. Every new doc declares its verdict in frontmatter (see "Frontmatter `boundary:` field" below).

## The split mechanism for shared docs

Three sub-mechanisms cover all shared-doc content:

### Mechanism 1: sibling `<doc>-platform-extensions.md`

The default. The OSS-substance of a shared doc lives at `agentfactory-architecture/<doc>.md`; the platform delta lives at `rensei-architecture/<doc>-platform-extensions.md`. The platform-extensions file:

- Declares `extends: agentfactory-architecture/<doc>.md` in frontmatter.
- Contains only the platform-specific sections (the OSS-substance is **not** duplicated).
- Cross-references the OSS doc for any layer/contract context.

Use when: most of a shared doc's content is OSS-pure with a few clearly-bounded platform sections (`011`'s multi-machine fleet, `014`'s Live capacity contract, `006`'s Seam 4 platform implementation block + Seam 6).

### Mechanism 2: inline addenda in `rensei-architecture`'s copy

Some shared docs have platform extensions that are too thin or too inline-coupled to lift into a sibling file. In those cases the OSS doc lives in `agentfactory-architecture` as canonical, and the `rensei-architecture` copy is a re-export that references the canonical and adds short inline addenda. Mechanism 1 is preferred; use Mechanism 2 only when the platform delta is < ~200 lines and tightly threaded through the OSS body.

### Mechanism 3: synchronized verbatim mirror

Reserved for content that is by definition load-bearing in both corpora — most prominently `001-layered-execution-model.md` § "The agentfactory ↔ Rensei Platform contract", which **defines** the boundary itself and would be incomplete in either corpus alone.

Synchronized sections carry a comment marker:

```html
<!-- BOUNDARY-SYNC: This section is mirrored verbatim across
     agentfactory-architecture/<path> and rensei-architecture/<path>.
     Any change MUST land simultaneously in both corpora via paired commits. -->
```

The CI check that enforces this mirror is **planned for Phase 5**, not implemented in Phase 2. Until then, maintainers must keep paired commits manually disciplined; see "Synchronized-section CI hook plan" below.

Use sparingly. Mechanism 3 is the highest-cost option (manual sync) and exists only for content where Mechanisms 1/2 would leave either corpus genuinely incomplete.

## Cross-cutting ADR dual-publish

Some ADRs are conceptually OSS-canonical but apply to both layers. Examples: `ADR-2026-04-27-plugin-and-workflow-architecture.md` (the core taxonomy), `ADR-2026-05-03-locus-of-workflow-definition.md` (workflow-grammar discipline), and `ADR-template.md` (the bare template).

Pattern (per `runs/WAVE10_PHASE1_RESOLUTIONS.md` Q2 resolution):

- The **OSS corpus owns the canonical ADR file**. Full content lives at `agentfactory-architecture/ADR-YYYY-MM-DD-...md`.
- The **platform corpus carries a thin stub** at `rensei-architecture/ADR-YYYY-MM-DD-...md` containing only:

  ```yaml
  ---
  status: Mirrored
  canonical: agentfactory-architecture/ADR-YYYY-MM-DD-...md
  ---
  ```

  Plus a one-paragraph summary and a "see canonical" link.

This avoids divergence (the canonical never lives in two places at once) while preserving discoverability inside the platform corpus. A reader scanning `rensei-architecture` for ADRs sees all relevant ones, including OSS-canonical ones, and follows the link for full content.

When a cross-cutting ADR's content materially affects platform-only behavior, the platform stub may carry a small platform-extensions section under the link (kept short — long enough to capture the platform implication, short enough that it doesn't become a divergence target). If that section grows beyond ~50 lines, lift it into a separate platform-extensions ADR that cross-references the OSS canonical.

## Frontmatter `boundary:` field for new ADRs

Every new ADR (in either corpus) declares its boundary in frontmatter:

```yaml
---
status: Proposed
date: 2026-MM-DD
boundary: OSS-only | platform-only | shared
canonical: <path>   # only when status is "Mirrored"
---
```

Acceptable values:

- `OSS-only` — file lives in `agentfactory-architecture` only.
- `platform-only` — file lives in `rensei-architecture` only.
- `shared` — file lives in both, following one of the three split mechanisms above. The frontmatter SHOULD also note which mechanism applies (e.g., `split: sibling-extensions` or `split: synchronized-mirror`).

Authors propose the verdict at ADR-write time; reviewers can challenge it during review. If unclear, default to `shared` and declare `split: TBD` — the reviewer can lock the mechanism before merge.

## Synchronized-section CI hook plan

Phase 5 ships a small CI check that detects drift on `BOUNDARY-SYNC`-marked sections between the two corpora. Sketch:

1. Both corpora's CI runs a shared script (likely `scripts/check-boundary-sync.sh`) that:
   - Greps both repos for `BOUNDARY-SYNC` markers.
   - For each pair, extracts the bounded text and computes a content hash (whitespace-normalized).
   - Fails if hashes diverge between the two corpora.
2. The check fires on PR; failure means the PR author missed a paired commit. The fix is straightforward — land the same edit in the sister repo.
3. Implementation: small Go tool or shell script under `scripts/` in this repo, invoked from a GitHub Action.

**Not implemented in Phase 2.** Tracking issue / implementation lands as a Phase 5 deliverable. Until then, maintainers must keep paired commits manually disciplined; treat any edit to a `BOUNDARY-SYNC` section as a hard ping to also land the same edit in the sister repo.

## `extends:` composition pattern for agents YAMLs

Per the Phase 1 audit, several agent definition YAMLs have OSS-archetype substance + Rensei-team-specific tool allowlists. The split (per `runs/WAVE10_PHASE1_RESOLUTIONS.md` Q1 resolution) follows a composition pattern modeled on how `rensei-tui` imports `agentfactory-tui`'s command factories:

- **OSS canonical**: `agentfactory-architecture/agents/<group>/<name>.yaml` — declares the archetype's purpose, model selection, inputs, completion contract, hard rules, and `tools: []` (empty placeholder; the archetype declares no Rensei-specific tools).
- **Rensei-specific override**: `rensei-architecture/agents/<group>/<name>-rensei.yaml` — declares `extends: agentfactory-architecture/agents/<group>/<name>.yaml` in its frontmatter, then specifies the Rensei-specific `tools:` allowlist (e.g., `pnpm af-linear`, `pnpm af-code`) and any team-specific gates (e.g., the REN-1407 binary-distribution acceptance gate on `migration-coordinator-rensei.yaml`).

The OSS YAML is genuinely runnable as a template — anyone forking AgentFactory can compose their own override layer the same way. The `extends:` field is a documentation convention today; if Phase 5 ships a YAML composer that actually merges them at agent-load time, the convention becomes structural.

Five agent YAMLs are slated for this split per the Phase 1 audit:

- `agents/pm/backlog-writer.yaml`
- `agents/pm/outcome-auditor.yaml`
- `agents/pm/improvement-loop.yaml`
- `agents/pm/operational-scanner-sentry.yaml`
- `agents/migration/migration-coordinator.yaml`

## What this doc is not

- **Not the audit itself.** The per-doc verdicts and detailed shared-doc section splits live at `runs/WAVE10_PHASE1_AUDIT.md` (Rensei runs/ directory). This doc states the convention; the audit applies it.
- **Not a tool.** The boundary lints / link-checkers / synchronized-section CI hook are Phase 5+ deliverables. Today this doc is process discipline; tomorrow it grows tooling under `scripts/` to enforce.
- **Not the boundary rule.** That rule lives in `001-layered-execution-model.md` § "The agentfactory ↔ Rensei Platform contract" (currently in `rensei-architecture`; migrating in Phase 3). This doc operationalizes the rule into a doc/ADR/agent-YAML convention.

## Status

**Wave 10 Phase 2 — initial seed.** Phase 5 (boundary-tagging convention) will revise this doc with: synchronized-section CI hook implementation, any refinements surfaced by Phases 3-4 doc-move experience, and the operational details of the `extends:` composition pattern once Phase 3 has actually split agent YAMLs.
