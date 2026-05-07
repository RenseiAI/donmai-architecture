# ADR-2026-04-28-workflow-piping-uses-nodes

**Status:** Accepted

**Date:** 2026-04-28

**Authors:** Mark Kropf + post-foundation audit (continuation of session db959ae0)

## Context

REN-1296 (Workflow Engine — inter-node output piping) and REN-1300 (Active Backlog Management workflow) shipped the inter-node templating syntax in `apiVersion: workflow/v2`. The corpus draft in `016-workflow-engine.md` Open Question #1 described the syntax as `{{ steps.<id>.output.<field> }}`. The implementation that landed uses `{{ nodes.<id>.output.<field> }}` instead.

The naming choice was made by the implementing sub-agent without explicit corpus author confirmation, but the rationale is sound:

- `nodes.*` aligns with the workflow engine's internal node taxonomy (every executable unit is a "node," not just sequential "steps")
- WEFT's W2 group composability (which the workflow engine adopted) naturally produces non-sequential, branched DAGs — `steps.*` implies a linear sequence, `nodes.*` is shape-agnostic
- The trigger node is also a node, so `{{ trigger.* }}` shorthand consistently expands to `{{ nodes.<trigger-id>.output.* }}`

This ADR ratifies the implementation choice.

## Decision

The canonical inter-node templating syntax in `apiVersion: workflow/v2` is `{{ nodes.<id>.output.<field> }}`. The corpus draft's `steps.*` framing is superseded.

`{{ trigger.* }}` is shorthand for `{{ nodes.<trigger-id>.output.* }}`.

`{{ trigger.data.* }}` from `apiVersion: workflow/v1` continues to work unchanged during the deprecation window.

## Consequences

### Positive

- Naming aligned with the workflow engine's internal model — no impedance mismatch between syntax and implementation.
- Authors writing branched/looped workflows (W2 groups) won't be misled by sequence-implying terminology.
- One namespace (`nodes.*`) for all referenceable workflow units; avoids parallel `steps.*` / `triggers.*` / `gates.*` taxonomy.

### Negative

- Authors who learned the WEFT vocabulary or read the draft 016 corpus will encounter a one-line mental remap.
- Existing internal docs that say `steps.*` need a sweep.

### Risks

- A future plugin / template that hardcodes `steps.*` (e.g., a marketplace template inherited from outside Rensei) would silently fail validation. Mitigation: workflow validator emits a clear error message ("did you mean `nodes.*`?") when it sees `{{ steps. }}` in a workflow/v2 doc.

## Alternatives considered

- **Keep `steps.*` as the documented syntax, update the implementation** — rejected. The implementation is already shipped; a rename now invalidates user-authored workflows in the wild and gains nothing semantically.
- **Allow both `steps.*` and `nodes.*` as synonyms** — rejected. Synonyms create confusion in audit/debugging — two paths to the same thing produce twice the surface area for bugs.

## Affected documents

- `016-workflow-engine.md` — §Templating, replace `{{ steps.<id>.output.<field> }}` with `{{ nodes.<id>.output.<field> }}` throughout. Update Open Question #1 from "open" to "resolved per ADR-2026-04-28-workflow-piping-uses-nodes."

## Affected work items

- REN-1296 (Workflow Engine inter-node piping — originator)
- REN-1300 (Active Backlog Management workflow — first consumer of the syntax)
- REN-1312 (Default SDLC YAML rewrite — will use this syntax when REN-1139 unblocks it)

## Implementation notes

- Validator error message for `steps.` references in workflow/v2 should suggest `nodes.` explicitly.
- Migration script (corpus 016 §Migration) v1 → v2 should automatically rewrite `trigger.data.*` references to use the canonical `nodes.<trigger>.output.*` form.
