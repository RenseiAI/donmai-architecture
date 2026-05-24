---
# Required frontmatter for every new ADR.
# `status` — one of: Proposed | Accepted | Superseded by ADR-XXX | Deprecated | Mirrored
# `boundary` — REQUIRED. One of:
#   - OSS-only      — ADR lives only in donmai-architecture
#   - platform-only — ADR lives only in rensei-architecture
#   - shared        — ADR has both OSS-substance and platform-extension portions; default
#                     for cross-cutting decisions affecting both corpora
#   - mirrored      — used ONLY by the thin stub copy in rensei-architecture that points
#                     at a canonical donmai-architecture ADR. Requires a `canonical:`
#                     pointer; see BOUNDARY.md § "Cross-cutting ADR dual-publish"
# `canonical` — REQUIRED when boundary is "mirrored"; absolute repo-relative path to the canonical ADR
# `split` — RECOMMENDED when boundary is "shared"; one of:
#   sibling-extensions | synchronized-mirror | inline-addenda
status: Template
boundary: shared
---

# ADR-YYYY-MM-DD-short-slug

**Status:** Proposed | Accepted | Superseded by ADR-XXX | Deprecated | Mirrored
**Date:** YYYY-MM-DD
**Boundary:** OSS-only | platform-only | shared | mirrored
**Authors:** name(s) or agent identifier(s)

## Context

What is the situation that prompts this decision? What forces are at play (technical, organizational, customer-driven)? Reference specific issues, incidents, or external constraints.

## Decision

The decision in one or two sentences. Be specific about what changes and what stays.

## Consequences

### Positive

- What gets better, simpler, faster, or possible.

### Negative

- What gets harder or what we lose. Be honest — every decision has cost.

### Risks

- What could go wrong. Quantify where possible.

## Alternatives considered

For each meaningful alternative: what it was, why we rejected it. Don't pad — only include alternatives that actually got debated.

## Affected documents

List the canonical/reference docs in this corpus that this ADR amends. Update those docs in the same commit as this ADR.

- `001-layered-execution-model.md` — section X
- `00N-foo.md` — section Y

If this ADR amends a `BOUNDARY-SYNC`-marked synchronized section (currently: `001-layered-execution-model.md` § "The donmai ↔ Rensei Platform contract"), the same commit MUST update both corpora via paired PRs and run `scripts/check-boundary-sync.sh` to confirm the regions stay byte-identical. See `BOUNDARY.md` § "Simultaneous-PR rule for synchronized sections".

## Affected work items

Tracker issue IDs (or other tracker references) whose scope changes as a result. Cite explicitly so the change is traceable from issue → ADR → architectural impact.

## Implementation notes

Optional. High-level pointers for where the implementation lands, but not a substitute for the issue's own scope. Detailed implementation belongs in the source repo, not in the ADR.

---

## Boundary discipline (delete this section in your ADR)

Declare your ADR's `Boundary:` field above using one of the four values:

- **`OSS-only`** — file lives only in `donmai-architecture`. Most ADRs about the OSS execution layer (the daemon HTTP API, provider base contract changes, kit manifest schema, workflow grammar). Default for ADRs that have a working OSS-shipped implementation and don't depend on the SaaS control plane.
- **`platform-only`** — file lives only in `rensei-architecture`. ADRs operating against the Rensei team's Linear backlog, the SaaS dashboard, multi-tenant control-plane policy, or the Rensei org's operational state.
- **`shared`** — ADR has both OSS-substance and platform-extension portions; lives in `donmai-architecture` as canonical with a thin `mirrored` stub in `rensei-architecture`. Use for cross-cutting decisions affecting both layers (e.g., the plugin/workflow taxonomy, the locus-of-workflow-definition rule).
- **`mirrored`** — value used **only** by the platform-side stub of a cross-cutting ADR. The stub declares `canonical:` pointing back at the OSS-corpus canonical file. The OSS canonical itself uses `shared` (or `OSS-only`), not `mirrored`.

If your ADR is `shared`, also declare a `split:` field in frontmatter — one of `sibling-extensions`, `synchronized-mirror`, or `inline-addenda` — so the split mechanism is unambiguous from the frontmatter alone. See `BOUNDARY.md` for the mechanism definitions.

Cross-cutting ADRs (`shared`) follow the dual-publish-stub pattern: canonical file lives in `donmai-architecture`; `rensei-architecture` carries a thin stub with `Status: Mirrored` frontmatter pointing back. See `BOUNDARY.md` § "Cross-cutting ADR dual-publish" for the exact stub shape.
