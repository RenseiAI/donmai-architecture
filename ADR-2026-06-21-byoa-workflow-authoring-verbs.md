---
status: Proposed
boundary: shared
split: sibling-extensions
date: 2026-06-21
---

# ADR-2026-06-21 — BYOA workflow-authoring verbs: the `workflow:author` capability

**Status:** Proposed
**Date:** 2026-06-21
**Boundary:** shared (canonical here; mirrored stub in the platform corpus)
**Authors:** agent:claude (design session)

## Context

`ADR-2026-06-19-requester-provider-inbound-agent-family.md` defines the `RequesterProvider`
family: a registered external agent dispatches *into* the engine, submitting a unit of work
against a project's capacity pool and workflow inventory. The external agent is a consumer of
installed workflows, never their author. The registration record (`ADR-2026-06-20`) carries
an `allowed_workflow_template_slugs` whitelist — the set of workflows the agent may *invoke*.
That whitelist is currently populated by a human operator at registration time.

A new class of use case emerges: an agent that is itself a **workflow builder** — an AI-
driven orchestrator, a migration tool, or a BYOA client that generates task-specific
compositions on behalf of its users. These agents need to AUTHOR and UPDATE workflow
definitions, not merely invoke them. The current inbound surface offers no authoring verb; an
agent that tries to create or update a workflow has no sanctioned path.

Three forces bound the design:

1. **Safety.** A workflow definition is an execution graph that can trigger agent dispatch,
   write to version control, and emit issue-tracker mutations. An agent that auto-publishes a
   workflow to the live default slot of a project can alter the project's live behavior without
   human review. This is unacceptable without an explicit operator signal.
2. **Governance.** The existing Cedar PEP (`ADR-2026-06-19`, `ADR-2026-06-20`) gates *invoke*
   operations on the registered principal's allowed surface. Authoring is a different capability
   class: it is a write to the workflow inventory, not a dispatch into it. It needs a distinct
   capability declaration.
3. **Autonomy contract.** The engine already distinguishes draft and published workflow
   states (per `ADR-2026-05-03-locus-of-workflow-definition.md` and
   `016-workflow-engine.md`). A safe authoring verb must land the agent's output in the draft
   state and leave publish as a human (or explicitly-granted operator) act.

The MCP adapter archetype (`ADR-2026-06-21-mcp-adapter-archetype.md`) defines the fix
three-tool facade for *invoke* use cases. Authoring is a separate capability that would add
tools to that surface — but only if the OSS contract explicitly sanctions and bounds them.
This ADR establishes that contract.

## Decision

**Registered external agents MAY author and update workflow definitions into the DRAFT state,
gated by a distinct `workflow:author` capability declaration on the registration. Auto-publish
to any live or default slot is unconditionally prohibited by the contract. The minimal-safe
subset for v1 is: author a new draft, update an existing draft, and read the agent's own
drafts.** Concretely, the OSS-canonical contract is:

### 1. A new capability class: `workflow:author`

The registration record (canonical in `ADR-2026-06-20`) gains an optional capability
declaration. OSS-canonical domain:

```
capabilities: ('dispatch:invoke' | 'workflow:author')[]
```

`dispatch:invoke` is the existing default (every registered principal can dispatch). A
registration that additionally declares `workflow:author` is permitted to exercise the
authoring verb set. A registration without `workflow:author` is denied authoring verbs at the
engine boundary, regardless of any credential scopes. The capability is additive, never
implied.

### 2. The v1 minimal-safe verb set

Three authoring verbs constitute the v1 surface. No verb in this set publishes a workflow to
any live or default slot.

**`workflow.draft.create`** — author a new workflow definition into the draft state.

Input contract (OSS-canonical shape):
```
{
  projectSlug: string,          # target project; must be in the registration's allowedProjectIds
  templateSlug?: string,        # optional stable identifier for republish-stable referencing
  definition: WorkflowDefinition  # the workflow/v1 graph (016-workflow-engine.md grammar)
}
```

Output: `{ draftId: string, templateSlug: string, validationResult: ValidationResult }`.
The draft is created in the `draft` lifecycle state and is invisible to the live dispatch
path. `validationResult` carries the compile-time validation result (type-check, edge
validation, required-provider check per `016`) — the engine validates the definition at
author time.

**`workflow.draft.update`** — update the definition of an existing draft the same registration
authored.

Input: `{ draftId: string, definition: WorkflowDefinition }`.
Output: `{ draftId, validationResult }`.

A registration may only update drafts it authored (attributed by the registration's
`actorHandle`). Update of another principal's draft, or of a published (non-draft) workflow
version, is denied.

**`workflow.draft.read`** — read the current definition of a draft the same registration
authored.

Input: `{ draftId: string }`.
Output: `{ draftId, templateSlug, definition, validationResult, createdAt, updatedAt }`.

Read access is scoped to the registration's own drafts. Enumeration of drafts the
registration has not authored is not part of v1.

### 3. The invariants that bound the surface

These invariants are OSS-canonical and load-bearing. An implementation that violates them
has broken the safety envelope, not extended it:

**I-1. NEVER auto-publish.** No authoring verb — in v1 or in any future extension — may
transition a draft to `published` or to any live dispatch slot without an explicit human
confirmation step. An agent that calls `workflow.draft.create` followed by any
`workflow.publish.*` verb (including a hypothetical future `workflow.publish.confirm`) may
only reach the publish step if the registration explicitly carries a `workflow:publish`
capability (which is NOT defined in v1 and requires a separate ADR to introduce).

**I-2. NEVER touch the live default.** No authoring verb may set a workflow as the live
default workflow for a project. The live default is always operator-controlled.

**I-3. Posture gates authoring.** An agent whose registration carries `cedarPosture:'strict'`
is denied `workflow:author` by the engine's policy layer regardless of the capability
declaration. The `workflow:author` capability is only exercisable under the `light` posture
(the default). The `strict` posture is reserved for dispatch-only, maximally-governed agents
that should never mutate the workflow inventory.

**I-4. Validation is mandatory at author time.** A `workflow.draft.create` or
`workflow.draft.update` that fails compile-time validation (type mismatch, broken edge,
missing required provider) MUST be rejected with a `ValidationResult` carrying the failure
details; the draft is NOT persisted in an invalid state. The engine does not accept a
`skipValidation` override from an external principal.

**I-5. Attribution is the registration.** Every authored draft carries `authoredBy:
external:<org>:<actorHandle>` in its metadata (the `016` grammar's `metadata.authoredBy`
field). The engine stamps this; the external principal may not override it.

**I-6. Project scope is honored.** A `workflow.draft.create` whose `projectSlug` resolves to
a project outside the registration's `allowedProjectIds` whitelist is denied before the
definition is parsed. The authoring scope cannot exceed the dispatch scope.

### 4. OSS / platform split

**OSS-canonical (this ADR):** the `workflow:author` capability class, the three-verb v1
surface and their input/output contract shapes, the six invariants, and the posture gate
rule (I-3). The definition grammar `WorkflowDefinition` remains canonical in
`016-workflow-engine.md`; this ADR does not amend it.

**Platform-only (mirrored stub in the platform corpus):** the storage of the capability
declaration on the registration record, the Cedar policy for `workflow:author`, the
validation pipeline implementation, the draft lifecycle state machine, the human-publish UI
and API, and the `authoredBy` stamp implementation.

## Consequences

### Positive

- A registered external agent can generate and update workflow definitions without a
  human-in-the-loop at the authoring step, while the publish step remains gated — the
  automation-autonomy tradeoff that regulated deployments require.
- A distinct capability class (`workflow:author`) means the existing `dispatch:invoke` default
  is not widened: agents that only need to invoke workflows gain no new attack surface by
  default.
- Mandatory at-author-time validation catches graph errors before a human reviews a draft,
  raising the signal-to-noise ratio of the human review step.
- Posture I-3 lets the operator choose per-registration whether an agent may touch the
  workflow inventory at all: flip `cedarPosture:'strict'` and the agent is dispatch-only,
  regardless of the capability list.

### Negative

- A three-verb v1 surface is deliberately constrained (no list-all-drafts, no diff, no
  partial-update). Agents that need richer authoring ergonomics must wait for v2 extensions
  under a future ADR, or author via a human-facing editor.
- The "author owns their drafts" attribution model (I-5, update-own-draft rule) means a
  second agent cannot revise a first agent's draft. Collaborative multi-agent authoring is
  explicitly out of scope for v1.

### Risks

- If I-1 (never auto-publish) is not enforced at the capability-check layer (before the
  workflow definition is even written), a bug in the publish path could inadvertently flip a
  draft live. Defense-in-depth: the invariant should be enforced at both the capability check
  and at the publish API — if the requesting credential carries no `workflow:publish`
  capability, the publish path returns a hard error independent of draft state.
- An agent that floods `workflow.draft.create` with large definitions can inflate storage.
  Rate limiting and per-registration draft quotas (platform-only, not specified here) are
  required before production deployment.

## Alternatives considered

- **No authoring surface; agents compose workflows client-side and a human pastes them in.**
  Eliminates the entire safety concern but also eliminates the automation value. Rejected for
  the agent-builder and migration-tool use cases where the composition step is the entire
  value.
- **Allow auto-publish under `strict` posture, reasoning that `strict` adds more checks.**
  Inverts the posture model: `strict` is maximum governance (human steps required at every
  gate), not a license for broader autonomous capability. Rejected; posture gating (I-3) runs
  in the opposite direction.
- **Extend the MCP `dispatch` tool with an `author` mode flag.** A mode flag on `dispatch`
  conflates two distinct capability classes (invoke vs. author), making Cedar policy
  expressions fragile and capability-declaration ambiguous. Rejected in favor of a separate
  capability and a separate verb set.
- **Grant `workflow:author` implicitly to any registration that holds an authoring-related
  workflow slug in its allowed list.** An implicit grant derived from the slug whitelist is
  not a capability declaration — it is a capability inference that is opaque to operators
  and hard to audit. Rejected; capabilities must be explicit.

## Affected documents

Edits land in the commit that flips this ADR to Accepted:

- `ADR-2026-06-20-byoa-requester-registration-record.md` — the registration record gains a
  `capabilities` field (the capability class enum including `workflow:author`) in the
  "contract-level fields" enumeration.
- `016-workflow-engine.md` — add a subsection under "Grammar" documenting `authoredBy` in
  `metadata` and noting the authoring verb set as the external-principal authoring entry
  point; link to this ADR.
- `002-provider-base-contract.md` — the `RequesterProvider` identity section notes
  `workflow:author` as the second member of the capability class domain (alongside
  `dispatch:invoke`).

No edit here touches a `BOUNDARY-SYNC`-marked region, so no synchronized-section ceremony is
required; on acceptance, paired commits (OSS-side first) per `BOUNDARY.md`.

## Affected work items

To be filed on acceptance (the platform corpus carries the platform-side tracker references).

## Implementation notes

The authoring verbs are the natural extension of the MCP facade (`ADR-2026-06-21-mcp-adapter-
archetype.md`): when the registration's capabilities include `workflow:author`, the MCP server
adds `workflow.draft.create`, `workflow.draft.update`, and `workflow.draft.read` to its tool
surface. When the capability is absent, the tools are not advertised and calls to them are
rejected with a capability-error. Storage shape, draft lifecycle state machine, validation
pipeline wiring, and the human-publish UI are platform-only and belong in the platform corpus.
