---
status: Template
boundary: shared
---

# ADR-YYYY-MM-DD-short-slug

**Status:** Proposed | Accepted | Superseded by ADR-XXX | Deprecated | Mirrored
**Date:** YYYY-MM-DD
**Boundary:** OSS-only | platform-only | shared
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

## Affected work items

Tracker issue IDs (or other tracker references) whose scope changes as a result. Cite explicitly so the change is traceable from issue → ADR → architectural impact.

## Implementation notes

Optional. High-level pointers for where the implementation lands, but not a substitute for the issue's own scope. Detailed implementation belongs in the source repo, not in the ADR.

---

## Boundary discipline (delete this section in your ADR)

Declare your ADR's `Boundary:` field above:

- **`OSS-only`** — file lives only in `agentfactory-architecture`. Most ADRs about the OSS execution layer.
- **`platform-only`** — file lives only in `rensei-architecture`. ADRs operating against the Rensei platform's backlog or SaaS-specific behavior.
- **`shared`** — file lives in both corpora; either as `extends:` sibling extensions (default) or as cross-cutting dual-publish-stub mirror (rare). See `BOUNDARY.md` for the mechanism.

Cross-cutting ADRs (the boundary itself, foundational architecture decisions affecting both layers) follow the dual-publish pattern: canonical file lives in `agentfactory-architecture`; `rensei-architecture` carries a thin stub with `Status: Mirrored` frontmatter pointing back.
