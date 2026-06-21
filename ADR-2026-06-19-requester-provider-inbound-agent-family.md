---
status: Accepted
boundary: shared
split: sibling-extensions
date: 2026-06-19
---

# ADR-2026-06-19 — RequesterProvider: the inbound agent-request family

**Status:** Accepted
**Date:** 2026-06-19
**Boundary:** shared (canonical here; mirrored stub in `rensei-architecture`)
**Authors:** agent:claude (design session)

## Context

The provider taxonomy (`002-provider-base-contract.md`, extended by
`ADR-2026-06-06-two-axis-provider-model.md`) defines nine families. Every one is
either **outbound** (the engine calls out: Sandbox, Workarea, AgentRuntime/Harness,
ModelEndpoint, AgentRegistry, Kit) or **engine-initiated bidirectional** (VersionControl,
IssueTracker, Deployment — where inbound webhooks are *event signals*, not
identity-bearing requesters that expect a result).

No family models the inverse: **an external agent (or external system) that
authenticates and submits a unit of work *into* the engine, is an attributable
principal, and expects a result back.** This is the inbound dual of A2A. A2A lives in
the AgentRegistry family as `entry.kind:'remote'` with
`protocol: 'a2a' | 'mcp' | 'http'` and is purely outbound — the engine is the caller.
The inbound direction is unspecified; `004-sandbox-capability-matrix.md` flags the
adjacent gap ("A2A capability shape … not yet specified; revisit when A2A becomes
load-bearing").

The driving use case: external chat/agent front-ends (which own conversation,
messaging-channel breadth, and skill-learning) delegate durable, governed, *measured*
execution work to the engine with a lightweight request (an org/project reference plus
a natural-language goal), inheriting the project's capacity pool, model configuration,
issue-tracker binding, and version-control binding. Issue tracking is an **optional
output**, never a required input. The closed platform additionally returns a verifiable
**receipt** (model, cost, evaluation verdict, policy rulings, audit reference) so the
requester can prove the work ran, and ran well.

## Decision

1. **Define a new inbound family, `RequesterProvider`** (provisional name; "inbound
   agent requester"). A `RequesterProvider` accepts a structured request from a
   registered external requester, maps it onto a workflow dispatch, and returns a
   structured response. It is the inbound dual of A2A and is a peer of the existing
   families, not an overload of AgentRegistry (which stays outbound discovery).

2. **Reuse existing primitives.** The wire protocols reuse the AgentRegistry `remote`
   vocabulary (`protocol: 'a2a' | 'mcp' | 'http'`). The requester's identity reuses the
   provider-signing model in `002` (`authorIdentity` + signature / Ed25519 public key
   or shared signing secret). The dispatch target reuses the existing workflow grammar
   (`016-workflow-engine.md`); no new execution path.

3. **Add an `agent.request` trigger type** to the workflow grammar, parallel to `schedule`,
   `webhook`, and `manual`. (The kind was originally named `requester`; per the
   2026-06-20 amendment below it is `agent.request`, with `requester` retained as a
   deprecated back-compat read alias.) A workflow whose entry is an `agent.request`
   trigger declares the
   lightweight input contract `{ project, goal, workType? }` and binds those into its
   first executable node (typically an `agent.invoke` composition). The request carries
   no tracker/issue context; project-inherited context resolves from the project
   reference alone.

4. **Registration is a two-sided handshake** (contract-level here; mechanism in the
   platform corpus):
   - *Identity, requester → engine:* the external requester registers once per org with
     a human-readable identity, a cryptographic identity (public key or signing secret),
     and a capability declaration (which workflows/projects it may invoke). It receives a
     scoped credential. Every request is attributable to that registered identity.
   - *Verification, engine → requester:* the requester is given the adapter
     (CLI verb / MCP server config / `SKILL.md` archetype) and the engine's audit public
     key so it can independently verify any signed receipt in the response.

5. **Response envelope carries an optional `receipt`.** The OSS contract defines the
   response shape `{ result, receipt? }`. The `receipt` is populated by the
   implementation; its generation (signing, evaluation grading, cost/provenance binding)
   is **platform-only** and out of scope for the OSS contract.

6. **OSS owns the contract; the platform owns governance.** OSS-canonical: the family
   contract, the `agent.request` trigger (alias `requester`), the protocol adapters, the CLI verb, the
   `SKILL.md` archetype, and the handshake shape. Platform-only: governed execution,
   receipt generation, evaluation grading, policy enforcement and principal scoping,
   decision-provenance attribution, the onboarding flow, and policy posture. See the
   mirrored stub in `rensei-architecture`.

## Consequences

### Positive

- A single inbound surface lets any external agent ecosystem (over mcp/a2a/http) submit
  governed work, rather than a per-vendor connector. New ecosystems are new adapters.
- The contract is symmetric with A2A, so identity, capability declaration, and the
  `remote` protocol vocabulary are shared rather than reinvented.
- Issue tracking demoted from required input to optional output removes the
  synthetic-issue workaround the SDLC composition would otherwise force.
- The verifiable-receipt handshake makes an external requester a first-class,
  attributable principal — the primitive needed for agents acting across organizational
  boundaries.

### Negative

- A new family widens the provider surface and the conformance matrix. The inbound
  contract is genuinely different from the outbound families and cannot fully share
  their lifecycle hooks.
- Capacity/quota semantics for inbound requesters are new (an external requester does
  not declare VCpu/Memory; the engine must rate-limit and quota per registered identity).

### Risks

- An inbound execution surface is a high-value abuse target; the contract MUST be paired
  with per-requester authentication, capability scoping, and rate limiting before any
  deployment. These live in the platform corpus but the contract must not invite a
  bypass of them.
- Protocol-dialect drift across mcp/a2a/http clients can make the inbound transport
  brittle; favor a stateless request/response shape with explicit poll/stream for
  long-running work.

## Alternatives considered

- **Extend AgentRegistry instead of a new family.** AgentRegistry is outbound discovery
  ("fetch agent definitions the engine then calls"). Folding an inbound request-acceptance
  contract into it conflates two opposite directions on one family. Rejected; kept as a
  distinct family that *reuses* AgentRegistry's `remote`/protocol vocabulary.
- **Model inbound requests as another `webhook` trigger.** Webhooks are unauthenticated-
  principal event signals with no result-back and no receipt. An external requester is an
  authenticated principal expecting a returned, attributable result. Rejected.
- **Dispatch the external agent as an outbound AgentRuntime/ACP peer.** This is the
  outbound vector (the engine drives the external agent). It does not serve the use case
  (the external agent drives the engine) and was the dead end of the prior exploration.

## Affected documents

Edits land in the commit that flips this ADR to Accepted:

- `001-layered-execution-model.md` — family enumeration gains the inbound `RequesterProvider`.
- `002-provider-base-contract.md` — family list + the inbound request/response contract and identity reuse.
- `006-cross-provider-interactions.md` — A2A is the outbound dual; cross-reference the inbound family.
- `015-plugin-spec.md` — plugin manifests may declare `requester`-family implementations.
- `016-workflow-engine.md` — the new `agent.request` trigger type (alias `requester`) and its input contract.

No edit here touches a `BOUNDARY-SYNC`-marked region, so no synchronized-section
ceremony is required; on acceptance, paired commits (OSS-side first) per `BOUNDARY.md`.

## Affected work items

To be filed on acceptance (platform corpus carries the platform-side tracker references).

## Implementation notes

The dispatch target is an ordinary workflow whose entry is an `agent.request` trigger
(alias `requester`); the
first executable node is typically an `agent.invoke` composition that inherits the
project's capacity/model/tracker/version-control bindings from the project reference
alone. Long-running requests use poll or stream over the response; the synchronous
response returns immediately with a tracking handle.

## Amendment 2026-06-20 — trigger kind renamed to `agent.request`

The inbound trigger **kind** is renamed `requester` → **`agent.request`** (canonical).
`requester` is retained **only** as a deprecated back-compat **read alias** on the
free-text `trigger_type` column — no migration, no rename of stored rows; the engine
reads both spellings and treats them as the same kind.

- **Rationale (design delta #1).** The kind names the generic *cross-org agentic
  governance* category, so the verb belongs in the dotted `agent.*` namespace
  alongside `agent.invoke` and `agent.session.await_complete`. The trigger **node id**
  is correspondingly `agent.request` (dir `trigger/agent.request/`), matching the
  dotted-id norm.
- **Unchanged.** The Provider Family name **`RequesterProvider`** / `requester-provider`,
  the principal/actor **`external_agent`** (actor_id `external:<org>:<agent>`), the
  **`dispatch:invoke`** scope, and the **`requester.respond`** delivery-action node are
  **not** renamed. Only the user-facing trigger **kind** / verb / contract changed.

Implementation shipped ahead of this amendment (trigger node moved to
`trigger/agent.request/`; `requester` kept as a deprecated read alias).
