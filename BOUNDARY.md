# Boundary convention

This doc is how `agentfactory-architecture` and `rensei-architecture` stay honest about which corpus owns which content. Every doc in either corpus carries a verdict; every shared doc has a defined split mechanism; every cross-cutting ADR follows the dual-publish-stub pattern.

The convention here was authored at Wave 10 Phase 2 stand-up and refined at Phase 5; the resolutions feeding it (Phase 1 audit + coordinator decisions on six open questions) are at `runs/WAVE10_PHASE1_AUDIT.md` and `runs/WAVE10_PHASE1_RESOLUTIONS.md` in the Rensei runs directory.

## Table of contents

- [The three verdicts](#the-three-verdicts)
- [The split mechanism for shared docs](#the-split-mechanism-for-shared-docs)
  - [Mechanism 1: sibling `<doc>-platform-extensions.md`](#mechanism-1-sibling-doc-platform-extensionsmd)
  - [Mechanism 2: inline addenda in `rensei-architecture`'s copy](#mechanism-2-inline-addenda-in-rensei-architectures-copy)
  - [Mechanism 3: synchronized verbatim mirror](#mechanism-3-synchronized-verbatim-mirror)
- [Cross-cutting ADR dual-publish](#cross-cutting-adr-dual-publish)
- [Frontmatter `boundary:` field](#frontmatter-boundary-field)
- [BOUNDARY-SYNC inline marker syntax](#boundary-sync-inline-marker-syntax)
- [Simultaneous-PR rule for synchronized sections](#simultaneous-pr-rule-for-synchronized-sections)
- [Synchronized-section CI hook](#synchronized-section-ci-hook)
- [`extends:` composition pattern for agents YAMLs](#extends-composition-pattern-for-agents-yamls)
- [How to add a new doc to this corpus](#how-to-add-a-new-doc-to-this-corpus)
- [What this doc is not](#what-this-doc-is-not)
- [Status](#status)

## The three verdicts

Every doc, ADR, and agent definition that affects either corpus carries one of three verdicts. Each maps to a `boundary:` frontmatter value (see [Frontmatter `boundary:` field](#frontmatter-boundary-field) for the four-value enum, including the fourth `mirrored` value used by stub files):

- **`OSS-only`** — The content is OSS-execution-layer plumbing. Implementations of every interface ship in OSS code; no part of the contract requires the SaaS control plane to function. Lives only in `agentfactory-architecture`. Examples: provider base contract, workarea provider contract, kit manifest spec, daemon HTTP control API.
- **`platform-only`** — The content is Rensei-platform-specific. Tied to the Rensei team's Linear backlog, the Rensei SaaS dashboard, multi-tenant control-plane policy, or operational state of the Rensei org. Lives only in `rensei-architecture`. Examples: `009-linear-realignment.md`, the PM agent rosters tied to Rensei team's backlog, multi-tenant Postgres+RLS+Cedar policy.
- **`shared`** — The content has both OSS-substance and platform-extension portions. The OSS-substance lives in `agentfactory-architecture`; the platform-extension delta lives in `rensei-architecture` either as a sibling `<doc>-platform-extensions.md` or as inline addenda in the `rensei-architecture` copy. Examples: `001-layered-execution-model.md`, `011-local-daemon-fleet.md`, `014-tui-operator-surfaces.md`.

The Phase 1 audit (`runs/WAVE10_PHASE1_AUDIT.md`) is the source of truth for the initial verdict assignment of every existing doc. Every new doc declares its verdict in frontmatter (see [Frontmatter `boundary:` field](#frontmatter-boundary-field) below).

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

Synchronized sections carry a paired marker — see [BOUNDARY-SYNC inline marker syntax](#boundary-sync-inline-marker-syntax) for the exact shape and [Synchronized-section CI hook](#synchronized-section-ci-hook) for the integrity check.

Use sparingly. Mechanism 3 is the highest-cost option (paired-PR maintenance + CI gate) and exists only for content where Mechanisms 1/2 would leave either corpus genuinely incomplete. As of Wave 10 Phase 5, exactly one synchronized region exists: `001-agentfactory-rensei-platform-contract`.

## Cross-cutting ADR dual-publish

Some ADRs are conceptually OSS-canonical but apply to both layers. Examples: `ADR-2026-04-27-plugin-and-workflow-architecture.md` (the core taxonomy), `ADR-2026-05-03-locus-of-workflow-definition.md` (workflow-grammar discipline), and `ADR-template.md` (the bare template).

Pattern (per `runs/WAVE10_PHASE1_RESOLUTIONS.md` Q2 resolution):

- The **OSS corpus owns the canonical ADR file**. Full content lives at `agentfactory-architecture/ADR-YYYY-MM-DD-...md`.
- The **platform corpus carries a thin stub** at `rensei-architecture/ADR-YYYY-MM-DD-...md` with `boundary: shared` (`status: Mirrored` to flag the stub) and a `canonical:` pointer:

  ```yaml
  ---
  status: Mirrored
  canonical: agentfactory-architecture/ADR-YYYY-MM-DD-...md
  boundary: shared
  ---
  ```

  Plus a one-paragraph summary and a "see canonical" link.

This avoids divergence (the canonical never lives in two places at once) while preserving discoverability inside the platform corpus. A reader scanning `rensei-architecture` for ADRs sees all relevant ones, including OSS-canonical ones, and follows the link for full content.

When a cross-cutting ADR's content materially affects platform-only behavior, the platform stub may carry a small platform-extensions section under the link (kept short — long enough to capture the platform implication, short enough that it doesn't become a divergence target). If that section grows beyond ~50 lines, lift it into a separate platform-extensions ADR that cross-references the OSS canonical.

Verified live mirrors as of Wave 10 Phase 3 (each pair: canonical lives in `agentfactory-architecture`, stub lives in `rensei-architecture`):

- `ADR-2026-04-27-plugin-and-workflow-architecture.md`
- `ADR-2026-05-03-locus-of-workflow-definition.md`
- `ADR-template.md`

## Frontmatter `boundary:` field

Every new ADR (in either corpus) — and every new reference doc whose verdict isn't trivially obvious from its filename — declares its boundary in frontmatter. The field is **required** for ADRs and shared-doc files; OSS-only reference docs in `agentfactory-architecture` whose verdict is obviously `OSS-only` MAY omit it for brevity but SHOULD declare it when promoting clarity.

```yaml
---
status: Proposed
date: 2026-MM-DD
boundary: OSS-only | platform-only | shared | mirrored
canonical: <path>   # required when boundary is "mirrored"
split: sibling-extensions | synchronized-mirror | inline-addenda  # recommended when boundary is "shared"
---
```

Acceptable values:

- **`OSS-only`** — file lives in `agentfactory-architecture` only. Use when the contract has a working OSS-shipped implementation and no part of it requires the SaaS control plane. The vast majority of new contract docs and ADRs land here.
- **`platform-only`** — file lives in `rensei-architecture` only. Use when the content describes Rensei-platform-specific behavior — multi-tenant policy, the SaaS dashboard, the platform's webhook proxy, the Rensei team's backlog, or operational state of the Rensei org.
- **`shared`** — file has both OSS-substance and platform-extension portions, split via one of the three mechanisms above. Use when the content has clearly separable OSS-pure and platform-pure halves. The frontmatter SHOULD also declare a `split:` field (`sibling-extensions`, `synchronized-mirror`, or `inline-addenda`) so the split mechanism is unambiguous from the frontmatter alone.
- **`mirrored`** — used **only** by stub files in `rensei-architecture` that point at a canonical OSS file. The stub MUST declare a `canonical:` field. Reserved for cross-cutting ADRs (see [Cross-cutting ADR dual-publish](#cross-cutting-adr-dual-publish)). The OSS canonical of a mirrored stub still uses one of `OSS-only` / `shared` for its own boundary; `mirrored` flags the stub-side, not the canonical-side.

Authors propose the verdict at write time; reviewers can challenge it during review. If unclear, default to `shared` and declare `split: TBD` — the reviewer can lock the mechanism before merge.

## BOUNDARY-SYNC inline marker syntax

Synchronized verbatim sections (Mechanism 3) carry a paired HTML-comment marker. The marker shape is **exact** — both the CI script and human reviewers anchor on the precise form below:

```html
<!-- BOUNDARY-SYNC-START: <marker-id> -->
<!-- Optional explanatory note. -->

... mirrored content ...

<!-- BOUNDARY-SYNC-END: <marker-id> -->
```

Rules:

- **Marker ids are kebab-case** and globally unique across both corpora. Use the form `<doc-number>-<short-slug>` so a reader can find the canonical home from the id alone — e.g., `001-agentfactory-rensei-platform-contract` (the only synchronized region today).
- **Markers are paired.** Every `START: <id>` MUST have a matching `END: <id>` later in the same file, in the same order. The CI script (see [Synchronized-section CI hook](#synchronized-section-ci-hook)) fails if pairs are imbalanced.
- **Both corpora must carry the same marker ids.** Adding a new synchronized region requires adding the start/end pair in both repos in paired commits.
- **Content between markers is byte-identical.** Whitespace, punctuation, link text, everything. The CI script compares byte-for-byte, not whitespace-normalized.
- **Explanatory comment lines are inside the marker block.** The optional note explaining "this section is mirrored, do not edit alone" goes between the START marker and the actual content (or omit it; the marker name itself is self-documenting).

As of Wave 10 Phase 5, the canonical example lives at:

- `agentfactory-architecture/001-layered-execution-model.md` (canonical)
- `rensei-architecture/001-layered-execution-model-platform-extensions.md` (mirror)

Both carry the marker id `001-agentfactory-rensei-platform-contract` around the five-point boundary discipline.

## Simultaneous-PR rule for synchronized sections

Landing a change to any `BOUNDARY-SYNC` section requires **paired PRs** — one to each repo — with byte-identical content edits between the markers. The two PRs may land in either order; the CI hook ([Synchronized-section CI hook](#synchronized-section-ci-hook)) ensures the corpora cannot stay drifted post-merge.

Recommended PR shape:

- Title both PRs with the same prefix (e.g., `docs(boundary-sync): <change>`) and reference the sibling PR in the body.
- Land the OSS-side PR first when possible (the OSS corpus is canonical for boundary content); platform-side PR follows immediately.
- If a maintainer can only land one side (e.g., the sibling repo's CI is red for unrelated reasons), the post-merge CI hook on the just-landed side will fail until the sibling lands. That failure is the reminder; do not bypass it.

If a synchronized region needs to *grow* (e.g., a new sub-bullet in the boundary discipline) or *shrink* (e.g., one point graduates to OSS-only or platform-only), the same paired-PR rule applies. Adding/removing a synchronized region (a new marker pair, or removing an existing pair) is the only `BOUNDARY.md`-level convention change that requires updating this doc — and that change itself ships in the same paired PRs.

## Synchronized-section CI hook

Phase 5 ships `scripts/check-boundary-sync.sh` to detect drift on `BOUNDARY-SYNC`-marked sections between the two corpora. Contract:

- **Lookup mode.** With no arguments, the script enumerates all marker ids in this repo, locates the matching marker pair in the sibling repo (`../rensei-architecture/`), extracts the bounded text in both, and `diff`s.
- **Single-id mode.** With one argument (a marker id), the script checks that one pair only. Useful for fast iteration during a sync edit: `./scripts/check-boundary-sync.sh 001-agentfactory-rensei-platform-contract`.
- **Exit codes.** `0` if all pairs match. `1` if any pair drifts (with `diff` output to stderr). `2` if a marker is unpaired or missing in the sibling repo (configuration error).
- **Sibling layout assumption.** The sibling repo is at `../rensei-architecture/` relative to this repo. Override with `DONMAI_ARCH_PATH=/abs/path` for non-default layouts.

Local invocation:

```bash
# from agentfactory-architecture/
./scripts/check-boundary-sync.sh                                          # check all pairs
./scripts/check-boundary-sync.sh 001-agentfactory-rensei-platform-contract  # check one pair
```

GitHub Actions integration: a workflow stub lives at `.github/workflows/boundary-sync.yml` (mirrored to `rensei-architecture/.github/workflows/boundary-sync.yml`). It triggers on PR for `*.md` changes, checks out both repos, and runs the script. The stub is **disabled by default** (commented `on:` triggers) until Wave 11 picks up the operational green-light — at which point flipping the on-block live is a one-line change. Until then, run the script locally before pushing a paired-PR pair.

The script and the workflow are sibling-repo aware: both corpora ship the same script and the same workflow file (the script is duplicated, not symlinked, because the two repos are independent git histories). Edits to either copy must land in both via paired commits — same discipline as a `BOUNDARY-SYNC` section.

## `extends:` composition pattern for agents YAMLs

Per the Phase 1 audit, several agent definition YAMLs have OSS-archetype substance + Rensei-team-specific tool allowlists. The split (per `runs/WAVE10_PHASE1_RESOLUTIONS.md` Q1 resolution) follows a composition pattern modeled on how the closed-source TUI imports `donmai`'s command factories:

- **OSS canonical**: `agentfactory-architecture/agents/<group>/<name>.yaml` — declares the archetype's purpose, model selection, inputs, completion contract, hard rules, and `tools: []` (empty placeholder; the archetype declares no Rensei-specific tools).
- **Rensei-specific override**: `rensei-architecture/agents/<group>/<name>-rensei.yaml` — declares `extends: agentfactory-architecture/agents/<group>/<name>.yaml` in its frontmatter, then specifies the Rensei-specific `tools:` allowlist (e.g., `pnpm af-linear`, `pnpm af-code`) and any team-specific gates.

The OSS YAML is genuinely runnable as a template — anyone forking Donmai can compose their own override layer the same way. The `extends:` field is a documentation convention today; if a future wave ships a YAML composer that actually merges them at agent-load time, the convention becomes structural.

Five agent YAMLs are split this way (verified shipped in Phase 3):

- `agents/pm/backlog-writer.yaml` ↔ `agents/pm/backlog-writer-rensei.yaml`
- `agents/pm/outcome-auditor.yaml` ↔ `agents/pm/outcome-auditor-rensei.yaml`
- `agents/pm/improvement-loop.yaml` ↔ `agents/pm/improvement-loop-rensei.yaml`
- `agents/pm/operational-scanner-sentry.yaml` ↔ `agents/pm/operational-scanner-sentry-rensei.yaml`
- `agents/migration/migration-coordinator.yaml` ↔ `agents/migration/migration-coordinator-rensei.yaml`

## How to add a new doc to this corpus

Concrete checklist for the three common cases.

### Case A — New OSS-only doc

1. Author the doc at `agentfactory-architecture/<NNN>-<slug>.md`.
2. Declare `boundary: OSS-only` in frontmatter (or in a "Boundary:" line in the doc preamble for plain-prose files that don't carry YAML frontmatter, e.g., `001`).
3. Add to the read order in `agentfactory-architecture/README.md` § "Index" and `agentfactory-architecture/AGENTS.md` § "Read order".
4. Cross-link from related docs. Internal links use bare filenames (`002-provider-base-contract.md`); cross-corpus links use absolute GitHub URLs (`https://github.com/RenseiAI/rensei-architecture/blob/main/...`).
5. No platform-side mirror is needed.

### Case B — New shared doc (with platform-extension delta)

1. Author the OSS-substance at `agentfactory-architecture/<NNN>-<slug>.md`. Declare `boundary: shared` and `split: sibling-extensions` in frontmatter.
2. Author the platform-extension sibling at `rensei-architecture/<NNN>-<slug>-platform-extensions.md`. Declare `extends: agentfactory-architecture/<NNN>-<slug>.md` and `boundary: platform-only` in frontmatter (the platform-extensions file is itself platform-only; its `extends:` field captures the contractual link to the shared parent).
3. Optionally drop a thin re-export at `rensei-architecture/<NNN>-<slug>.md` that points readers at the OSS canonical and the platform-extensions sibling, so platform-corpus readers land on either when scanning by doc number. This re-export is convenience, not contract; skip it if the doc isn't expected to be browsed by doc-number alone.
4. Add to read orders in both corpora's README + AGENTS.md.

### Case C — New cross-cutting ADR (or any cross-cutting doc using Mechanism 3 or stub-mirror)

1. Author the canonical ADR at `agentfactory-architecture/ADR-YYYY-MM-DD-<slug>.md`. Declare `boundary: shared` (or `OSS-only` if the ADR is genuinely OSS-only and just happens to interest platform readers).
2. Add a thin stub at `rensei-architecture/ADR-YYYY-MM-DD-<slug>.md` with frontmatter:

   ```yaml
   ---
   status: Mirrored
   canonical: agentfactory-architecture/ADR-YYYY-MM-DD-<slug>.md
   boundary: shared
   ---
   ```

   Plus a one-paragraph summary and a "see canonical" link.
3. If the ADR amends a synchronized section, the ADR commit MUST also include the paired edit to the `BOUNDARY-SYNC` block in both `001-layered-execution-model.md` (OSS) and `001-layered-execution-model-platform-extensions.md` (platform). Run `./scripts/check-boundary-sync.sh` locally before opening the paired PRs.
4. Add to the ADR section of both corpora's README + AGENTS.md.

## What this doc is not

- **Not the audit itself.** The per-doc verdicts and detailed shared-doc section splits live at `runs/WAVE10_PHASE1_AUDIT.md` (Rensei runs/ directory). This doc states the convention; the audit applies it.
- **Not exhaustive tooling.** The `scripts/check-boundary-sync.sh` hook ships in Phase 5 for synchronized-section integrity; broader boundary lints (frontmatter validation, cross-corpus link-checking) remain process discipline backed by reviewer attention.
- **Not the boundary rule.** That rule lives in `001-layered-execution-model.md` § "The agentfactory ↔ Rensei Platform contract" (synchronized between both corpora). This doc operationalizes the rule into a doc/ADR/agent-YAML convention.

## Status

**Wave 10 Phase 5 — convention canonicalized.** Phase 5 ships:

- The `boundary:` frontmatter field with four-value enum (`OSS-only | platform-only | shared | mirrored`) and required-field discipline.
- The `BOUNDARY-SYNC-START: <id>` / `BOUNDARY-SYNC-END: <id>` paired-marker syntax (upgraded from Phase 3's looser open-marker shape).
- The simultaneous-PR rule for synchronized sections.
- The `scripts/check-boundary-sync.sh` integrity-check script (sibling-repo aware; runs locally today; CI workflow stub committed but disabled).
- The "How to add a new doc" checklist covering OSS-only, shared, and cross-cutting cases.

Future waves will revisit this doc when: (a) a fourth split mechanism becomes necessary (today the three suffice), (b) the CI workflow stub flips live, or (c) the YAML `extends:` composer ships and converts that convention from documentation to runtime contract.
