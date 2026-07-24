---
status: Accepted
boundary: shared
split: sibling-extensions
date: 2026-06-21
---

# ADR-2026-06-21 — MCP adapter archetype: a facade over the inbound dispatch primitive

**Status:** Accepted
**Date:** 2026-06-21
**Boundary:** shared (canonical here; mirrored stub in the platform corpus)
**Authors:** agent:claude (design session)

> **Implementation status — Accepted / shipped (2026-07-24).** The platform's
> `POST /api/cli/mcp` endpoint implements exactly the fixed three-tool surface
> this ADR mandates (`dispatch` / `get_receipt` / `list_workflows`, no fourth
> tool) as a facade over the identical auth/authz pipeline as
> `POST /api/cli/dispatch`: bearer/session auth → `dispatch:invoke` scope →
> org-scoped project resolution → registration allowlist → the fail-closed
> Cedar PEP, returning a JSON-RPC error before any instance is created on a
> deny; `list_workflows` is scoped to the resolved registration's allowlist
> when one is bound. Status flips Proposed → Accepted to match this shipped
> reality. File:line evidence (closed-source platform paths, not citable in
> this OSS corpus per `guard-b-lint`) is recorded in the mirrored stub,
> `rensei-architecture/ADR-2026-06-21-mcp-adapter-archetype.md`.

## Context

`ADR-2026-06-19-requester-provider-inbound-agent-family.md` defines the inbound
`RequesterProvider` family: an external agent authenticates, submits a unit of work
into the engine via an `agent.request` trigger, is an attributable principal, and
expects a result back. That ADR enumerates three protocol adapters
(`acceptedProtocols: ('a2a' | 'mcp' | 'http')`, per `002-provider-base-contract.md` §
"RequesterProvider — inbound contract") but specifies only the `http`/CLI shape in
depth; it names the MCP adapter without pinning its archetype. `ADR-2026-06-20-byoa-requester-registration-record.md`
then anchors every inbound dispatch on a resolved registration (handle, allowed
projects/workflows, posture) — the authorization + attribution bound that any adapter
must inherit unchanged.

The MCP adapter is the ecosystem-reach lever: the broad population of external agent
front-ends speak the Model Context Protocol, and an MCP server is how they discover and
call tools. The risk is that an MCP server, being a separate process surface with its
own tool list, becomes a **side-door** — a second entry path that re-implements
dispatch, skips the registration resolution, or exposes capabilities the native
`agent.request` entry does not gate. `002` already flags the adjacent concern in the
*outbound* direction (the gemini "MCP→functionDeclaration bridge is a follow-up"); the
*inbound* MCP facade is the dual and is unspecified.

The question this ADR answers: what is the OSS-canonical **shape** of an MCP server that
fronts the inbound dispatch primitive, such that it is a thin facade — never a parallel
execution path?

## Decision

**An MCP adapter for the `RequesterProvider` family is a FACADE over the same inbound
dispatch primitive, not a new entry path. It exposes a fixed, minimal tool surface that
maps one-to-one onto already-defined inbound operations, and every tool call traverses
the identical registration-resolution, authorization, and governance gates as the native
`agent.request` entry.** Concretely, the OSS-canonical archetype is:

1. **A fixed three-tool surface.** An MCP adapter declares exactly these tools, and no
   broader capability:
   - **`dispatch`** — submit a unit of work. Input is the lightweight inbound contract
     `{ project, goal, workType? }` (the same `request` payload an `agent.request`
     trigger declares in `016-workflow-engine.md`). Returns the inbound response envelope
     `{ result, receipt? }` (`RequesterResponse` in `002`) — synchronously for fast work,
     or a tracking handle for long-running work (see tool 2).
   - **`get_receipt`** — given a tracking handle from a prior `dispatch`, return the
     completed inbound response envelope `{ result, receipt? }`. This is the MCP framing
     of the poll/stream affordance the family contract already requires for long-running
     requests; it does not introduce a new long-poll mechanism, only names the lookup.
   - **`list_workflows`** — enumerate the `agent.request`-triggered workflows the *calling
     principal* may invoke, by their republish-stable template identifier (the
     allowed-workflow slug of `ADR-2026-06-20`). The list is the resolved registration's
     allowed surface, never the org's full workflow inventory.

2. **The tool surface is a projection of inbound operations, not new verbs.** `dispatch`
   is the `agent.request` dispatch; `get_receipt` is the family's poll/stream lookup;
   `list_workflows` is a read over the resolved registration's allowed-workflow set. No
   MCP tool performs an operation the native inbound entry cannot. There is no
   `cancel`, no `mutate_workflow`, no raw-execution tool — authoring and lifecycle verbs
   are out of scope for the facade (a separate concern; see Alternatives).

3. **Identity is carried by the MCP transport's auth, resolved to a registration.** The
   MCP server authenticates the caller via the transport's credential (the same scoped
   bearer the family mints, bound to a registration per `ADR-2026-06-20`). Before any
   tool executes, the adapter resolves the registration from that credential. A call that
   resolves to no active registration is rejected — the facade is **fail-closed**,
   exactly as the native entry. The MCP server never trusts a client-supplied identity
   claim in the tool input.

4. **The same governance gates apply, in the same order.** A `dispatch` tool call enters
   the identical path the native `agent.request` entry takes: registration resolution →
   allowed-project / allowed-workflow check → principal-attribution stamp
   (`external:<org>:<handle>`) → the engine's authorization decision (the platform's
   policy enforcement point) → dispatch onto the workflow. The MCP framing changes the
   *transport*, never the gate sequence. There is exactly one governed dispatch path; MCP
   is a client of it.

5. **`list_workflows` is registration-scoped, by stable slug.** It returns only the
   allowed-workflow set of the resolved registration, identified by the republish-stable
   template slug (`ADR-2026-06-20`), so the discovery surface matches the dispatchable
   surface and survives workflow republish. An empty result for an active registration
   means "registered but no inbound workflows whitelisted," not an error.

6. **OSS owns the facade shape; the platform owns governance.** OSS-canonical: the
   three-tool surface, the one-to-one mapping onto inbound operations, the
   resolve-then-gate ordering, the fail-closed rule, and that the facade adds no
   capability beyond the native entry. **Platform-only and out of scope here:** the
   concrete MCP server route, the transport-auth wiring, how the policy enforcement point
   evaluates the dispatch, receipt generation, and the onboarding that issues the
   registration-bound credential. See the mirrored stub in the platform corpus.

## Consequences

### Positive

- The broad MCP-speaking agent ecosystem gets a first-class inbound surface with zero
  new governance code — the facade reuses the one dispatch path, so every gate that
  protects the native entry protects MCP automatically.
- A fixed three-tool surface is small enough to audit: a reviewer can confirm by
  inspection that no tool bypasses registration resolution or adds capability.
- `list_workflows` returning the registration's allowed set (not the org inventory) means
  discovery and dispatch agree — an external agent cannot see, much less call, a workflow
  it is not whitelisted for.

### Negative

- The facade is deliberately minimal; MCP clients that want richer affordances (cancel,
  streaming progress events, workflow authoring) are not served by v1 and must wait for
  later verbs (out of scope here). A minimal surface is a feature, but it is a constraint.
- Two transports (native CLI/HTTP and MCP) now front one primitive; the contract must
  keep them in lockstep so a gate added to one is added to both. The "exactly one
  governed dispatch path" rule is what makes that tractable, but it is a discipline to
  hold.

### Risks

- The whole value of the facade is that it is *not* a side-door. If an MCP tool ever
  performed a dispatch that skipped registration resolution or the authorization gate,
  the inbound authorization bound would be bypassed for every MCP caller. The
  resolve-then-gate ordering and the fail-closed rule are load-bearing and must not
  regress; a test that the MCP `dispatch` and the native entry share the same gate path
  is the guard.
- MCP tool-schema drift across client implementations can make the surface brittle. The
  fixed three-tool contract with the inbound payload shapes (`{ project, goal, workType? }`
  in, `{ result, receipt? }` out) pins the schema for exactly this reason.

## Alternatives considered

- **Expose a broad MCP tool surface (one tool per workflow, plus authoring/admin tools).**
  Rejected: it turns the MCP server into a second, divergent API of the engine — a
  side-door whose capability set drifts from the native entry and whose gates must be
  re-implemented per tool. The facade exposes the *primitive* (`dispatch`), not a tool
  per capability.
- **Let the MCP server hold its own credential and call the engine as a trusted service.**
  Rejected: that erases the external principal — the dispatch would be attributable to
  the MCP server, not to `external:<org>:<handle>`. The facade carries the *caller's*
  registration-bound credential through, preserving attribution.
- **Define MCP as a distinct provider family.** Rejected for the same reason the inbound
  family itself rejected folding into AgentRegistry: MCP is a *transport flavor* of the
  one inbound family (`acceptedProtocols` already lists it), not a new scheduling or
  governance axis. It reuses the family's identity, registration, and dispatch path.

## Affected documents

Edits land in the commit that flips this ADR to Accepted:

- `002-provider-base-contract.md` — the `RequesterProvider` inbound contract section
  gains the MCP adapter archetype: the fixed `dispatch` / `get_receipt` / `list_workflows`
  tool surface as a projection of the inbound operations, sharing the family's identity
  and response envelope.
- `006-cross-provider-interactions.md` — A2A is the outbound dual (Seam 3); cross-reference
  the inbound MCP facade as a transport flavor of the inbound family, not a new seam.
- `016-workflow-engine.md` — the `agent.request` trigger note records that the MCP
  `dispatch` tool maps onto the same trigger and input contract; MCP adds no new trigger
  kind.

No edit here touches a `BOUNDARY-SYNC`-marked region, so no synchronized-section
ceremony is required; on acceptance, paired commits (OSS-side first) per `BOUNDARY.md`.

## Affected work items

To be filed on acceptance (the platform corpus carries the platform-side tracker
references).

## Implementation notes

The MCP adapter is a thin server in front of the inbound dispatch primitive. A `dispatch`
tool call resolves the registration from the transport credential, runs the same
allowed-surface and authorization gates as the native `agent.request` entry, and dispatches
onto the matched `agent.request`-triggered workflow; long-running work returns a tracking
handle that `get_receipt` later redeems for the `{ result, receipt? }` envelope.
`list_workflows` reads the resolved registration's allowed-workflow slug set. The concrete
MCP server route, transport-auth wiring, the policy enforcement point, and receipt
generation are platform-only; see the mirrored stub in the platform corpus.
