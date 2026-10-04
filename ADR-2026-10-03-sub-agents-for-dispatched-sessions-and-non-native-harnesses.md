---
status: Proposed
date: 2026-10-03
boundary: shared
split: sibling-extensions
---

# ADR-2026-10-03 — Sub-agents for dispatched sessions and for harnesses without native sub-agents

**Status:** Proposed. Architecture only; nothing is built. This ADR sets out
three options, recommends one combination, and leaves the choice to the
founder. Acceptance records the chosen option and lands the corpus edits under
"Affected documents" in the same commit.
**Date:** 2026-10-03
**Boundary:** shared. OSS-canonical here: the problem stated against the
accepted child-delegation contract, the three options, the harness-adapter
sub-agent events (Option C), how the stage sub-agent cap counts, and the
constraints any sub-agent path must meet. A control plane's spawn authority
for dispatched sessions, its ceilings and its cost roll-up are described here
only generically. The concrete control-plane delta lives in the platform
corpus's mirrored stub.
**Authors:** architecture lane, filed by the coordinator session.

## Context

### The accepted contract

1. **A child is a session.** `001` Principles 1 and 2,
   [`ADR-2026-08-05`](ADR-2026-08-05-versioned-execution-cell-and-session-reference.md)
   D7, [`ADR-2026-08-06`](ADR-2026-08-06-harness-adaptation-plan-and-receipt.md)
   D7 and `013` § Child-agent dispatch. Every child submits its own
   `DispatchIntent` and gets its own `AdmissionReceipt`, `SessionRef`,
   adaptation plan and receipt. The transport (`native_harness`,
   `platform_dispatch`, `a2a`, `host_cli`) is recorded on the parent/child
   edge. No child inherits credentials, placement, workarea or model because it
   shares a process.
2. **Native children are an optimization.** The universal child rule is
   `canRunHeadlessly` plus one admitted transport. Every production headless
   harness must prove at least one non-native child path (ADR-2026-08-06 D7).
3. **Sub-agent visibility already has a vocabulary.** The capability matrix
   carries `EmitsSubagentEvents` (`002`). The typed event spine has
   `subagent.started`, `subagent.completed` and `subagent.failed`
   ([`ADR-2026-08-16`](ADR-2026-08-16-one-session-substrate-and-typed-event-spine.md)).
   The span contract has a `subagent` kind
   ([`ADR-2026-06-28`](ADR-2026-06-28-per-llm-call-observability-span-contract.md)).
4. **Tools reach pi through the extension seam.**
   [`ADR-2026-08-12`](ADR-2026-08-12-pi-extension-delivery-seam-and-capability-pack-boundary.md)
   delivers operator-injected extensions by path or inline source, loads the
   policy extension first, and disables every other extension source (D1,
   D2). A pack whose tools speak a hosted control plane ships downstream
   (D5.2). The seam never names a pack (D5.3).
5. **A missing capability is recorded, never hidden.**
   [`ADR-2026-08-13`](ADR-2026-08-13-capability-realization-registry-and-viability-of-absence.md)
   D4.6: a non-essential capability that cannot be delivered is recorded as
   `not_delivered`, and the agent is never told about a faculty it does not
   have.
6. **A child is never weaker than its parent.**
   [`ADR-2026-09-27`](ADR-2026-09-27-execution-security-levels.md) D2 puts the
   parent session in the child's scope chain.

### Findings (audit of 2026-10-03)

Findings about a hosted control plane are stated as shapes. Findings about
the runner can be checked in the `donmai` source.

**F1. Dispatched sessions cannot spawn.** In the hosted control plane that
implements `platform_dispatch` today, spawn authority is a per-session record. It is attested at
launch, carries the session's lineage, and needs a ceiling above zero (spawn
depth, direct children, subtree size, child duration). Only the interactive
launch path writes that record. A session launched by a workflow dispatch is
offered the child-dispatch tools anyway, and every call is refused. No
dispatched session has been able to spawn a child.

**F2. Two budgets that never meet.** The stage budget's `maxSubAgents` caps
native sub-agents. The runner counts them by tool name. The control plane's
ceilings cap admitted children. Neither counts the other's children.

**F3. The stage cap had two defects.** The runner read an explicit
`maxSubAgents: 0` as unlimited. It counted only a tool named `Task`, so a
harness whose delegation tool is named `Agent` was never counted. A runner fix
in review makes an explicit zero mean "none" and counts both names. It still
counts by name.

**F4. Native capture is name-keyed and single-harness.** One harness declares
`EmitsSubagentEvents`, and its sub-agents are detected from its delegation
tool call. A hosted plane's capture of them has been silent for weeks. No
adapter puts the parent tool-use id on normalized events, so a sub-agent's own
tool calls cannot be tied to the call that started it.

**F5. pi has no native sub-agents.** Its adapter declares
`EmitsSubagentEvents: false`. The common pi sub-agent extension (the upstream
project's example and several community packages) spawns child
`pi --mode json` processes and returns only each child's final text to the
parent.

**F6. Such a child is outside the session contract.** The child process is
started by a tool, not by the runner. Unless the extension rebuilds the
runner's spawn sequence, the child gets no policy-extension handshake, no
extension-discovery lockdown and no per-session state isolation
(ADR-2026-08-12 D2, D4). It also gets no intent, receipt, `SessionRef`,
budget or cost record. It inherits the parent's environment, which carries
the parent's credentials. Where the parent harness runs under executor OS
confinement, the child stays inside it as a descendant process; nothing else
of the session contract reaches it.

### The two gaps

- **G1.** A dispatched session has no working child path on a control plane.
- **G2.** pi has no child path the contract accepts, so it does not meet
  ADR-2026-08-06 D7's "at least one non-native child path".

## Options

### Option A — a local sub-agent extension through the seam

A pack registers a sub-agent tool in the pi session. The tool starts child pi
processes on the same host, waits, and returns their output.

- **For.** Fast: no admission, placement or queueing per child. Works on one
  machine with no control plane.
- **Against.** As commonly built, the children are not sessions. They break
  ADR-2026-08-05 D7 and `013` § Child-agent dispatch (no intent, receipt,
  `SessionRef` or edge, and inheritance by process accident). They break
  ADR-2026-08-12 D2 and D2.1, because the child process loads without the
  verified policy boundary unless the tool rebuilds it. pi has no permission
  system of its own, so such a child runs weaker than its parent, against
  ADR-2026-09-27 D2. They are unbudgeted: the stage cap counts by
  tool name, and a control plane's ceilings never see them. Their usage reaches
  no cost record, because only the final text comes back.
- **What would make it admissible.** Each child would have to start through
  the runner's own spawn sequence, as an admitted session on a declared
  transport, with every shared resource a declared adaptation entry
  (ADR-2026-08-06 D7). At that point Option A is a runner-provided child
  launcher plus Option C, not an extension that starts processes.

### Option B — a sub-agent tool in a control-plane capability pack

The control plane's capability pack for pi registers a sub-agent tool. The
tool calls the control plane's existing child-dispatch contract, so each child
is a `platform_dispatch` child: an admitted session with its own receipt,
budget, cost record and place in the session graph. It can be watched and
cancelled like any other session.

What a control plane must provide, stated generically:

- **B1. Spawn authority at admission.** A dispatched session gets its spawn
  authority when it is admitted, derived from the workflow that launched it.
  The authority narrows from a default ceiling the operator sets. No session
  asserts its own parent or ceiling. An absent authority means "may not
  spawn".
- **B2. No tool without authority.** A session without spawn authority is not
  offered the sub-agent tool. Offering a tool that always refuses tells the
  agent about a faculty it does not have (ADR-2026-08-13 D4.6), which is what
  F1 describes today.
- **B3. The tool is headless-safe.** It returns a result or a typed refusal
  and never waits on a UI (ADR-2026-08-12 D3). Waiting for a child is bounded
  by the child's duration ceiling, and cancelling the parent cancels or
  detaches each child as its edge declares.
- **B4. The pack stays downstream.** The tool is the client half of a hosted
  service, so it ships in the composing binary and is delivered through the
  seam (ADR-2026-08-12 D5.2, ADR-2026-08-13 D2.2). Nothing in this corpus
  names it.

Trade-offs:

- **For.** Children are first-class: budgeted, costed, visible and
  cancellable. The same tool works for any harness the control plane can
  deliver a pack to. It is also the non-native child path pi lacks (G2).
- **Against.** Each child pays admission, placement and spawn, and may queue
  behind capacity. The parent waits on a remote child. It needs a control
  plane, so it does nothing for a standalone install. The control plane must
  change how it grants spawn authority (B1).

### Option C — the harness adapter emits sub-agent events

The OSS layer that makes A or B observable and countable. Option C delivers
no sub-agents on its own.

- **C1. Delegation tools are declared, not guessed.** An extension delivery
  may declare which of its tools start a child. The declaration is a typed,
  generic field on the delivery. The runner never branches on a pack's name
  (ADR-2026-08-12 D5.3), and a name list in the runner is not a declaration.
- **C2. The adapter emits the existing events.** When a declared delegation
  tool is called, the adapter emits `subagent.started`, then
  `subagent.completed` or `subagent.failed`, and a `subagent` span. When the
  tool result carries a child `SessionRef`, the events carry it. A native
  delegation call maps to the same events. The adapter, which is versioned
  with its harness, names that harness's own delegation tool (today `Task` or
  `Agent`); the runner does not.
- **C3. The parent tool-use id is on normalized events.** An adapter that
  knows which delegation call an event belongs to sets it. One that does not
  leaves it empty and says so in its manifest.
- **C4. The stage cap counts typed events.** The runner counts
  `subagent.started`, not tool names. Every harness that emits the event is
  counted the same way, whatever its tool is called.
- **C5. The bit is computed.** `EmitsSubagentEvents` is true for an adapter
  version only when its fixtures pass (ADR-2026-08-08 D4.2, ADR-2026-08-13
  D6). For pi that means a loaded delivery that declares a delegation tool,
  plus a passing fixture.

## Recommendation

Option B plus Option C. The founder decides.

- B is the only option that gives a dispatched session children that the
  contract recognizes, the budgets bound and the cost record sees. It also
  closes G2 for pi without a new transport.
- C is small, OSS, and needed by every option. Without it the stage cap and
  every view of the session graph stay blind to pi children.
- A is not recommended. As commonly built it contradicts three accepted ADRs
  (Context items 1, 4 and 6). Making it admissible turns it into a
  runner-provided child launcher, which is a different option (see "What this
  ADR does not decide").

## Decision points for the founder

**DP1. Which options.** A, B, C, or a combination. Recommended: B plus C.

**DP2. Spawn authority for dispatched sessions.** Whether a control plane
grants it at admission, as B1 describes. Recommended: yes. The grant comes
from the workflow that launched the session, narrows from an operator-set
default ceiling, and is never asserted by the session. The control plane's
corpus records the concrete shape.

**DP3. One budget or two.** Recommended: two layers, one count.

- The stage cap (`maxSubAgents`) stays the workflow's configuration of how
  many children a stage may start. Under C4 it counts every child start, on
  every transport, from typed events.
- The control plane's ceilings stay the authority on what a child may be:
  depth, direct children, subtree size, duration.
- A `platform_dispatch` child must pass both. The runner checks the stage cap
  and the control plane checks the ceiling at admission, so the lower one
  stops the next child. The refusal is typed and names the cap that stopped
  it.
- Merging them into one field was considered and rejected; see "Alternatives
  considered".

**DP4. Child cost roll-up.** Recommended:

- An admitted child's usage and cost stay on the child session. The parent's
  own usage events never include them, so nothing is counted twice.
- Parent and subtree totals are derived views over the delegation edges.
- A native sub-agent that runs inside the parent's process is already in the
  parent's usage. Its `subagent` span groups that usage; it does not add to
  it.
- A spend cap over a whole subtree, if wanted, is the control plane's to
  enforce. This corpus does not define one.

## What this ADR does not decide

- **An OSS-standalone child path for pi.** The local daemon already admits
  sessions. A sub-agent tool that asks it for an admitted child over
  `host_cli` would give a standalone install budgeted, recorded children, and
  is the admissible form of Option A. It needs its own authorization for an
  agent calling the daemon:
  [`ADR-2026-10-03-executor-os-confinement.md`](ADR-2026-10-03-executor-os-confinement.md)
  D2.5 leaves the daemon API and spawn authority to their own authorization.
  That is a later amendment.
- **A2A as a child path for pi.**
- **Multiplexed pi hosting.** Still deferred by ADR-2026-08-12 D7.
- **Children across a parent restart or recovery.**

**OSS defaults under the recommendation.** With no control plane, a pi
session has no sub-agent tool, and its stage cap counts nothing because
nothing emits `subagent.started`. That is the same behaviour as today, now
stated. Nothing here needs a control plane, as `001` requires.

## Consequences (if B plus C is chosen)

### Positive

- Dispatched sessions can delegate, within ceilings, and every child is a
  session the operator can see, budget and cancel.
- pi gains its non-native child path (G2).
- One counting rule for the stage cap on every harness, keyed on typed events
  rather than tool names (F3, F4).
- A sub-agent's tool calls can be tied to the delegation call that started it.

### Negative

- Delegation from pi is slower than an in-process child: admission, placement
  and spawn per child, and possible queueing.
- A standalone pi install still has no sub-agents.
- Every adapter that already emits sub-agent events must move to the typed
  path, and the matrix generator gains a computed bit with fixtures.
- The control plane must change how it grants spawn authority, and its corpus
  must record that change.

### Risks

- **Fan-out cost.** A dispatched session that can spawn can multiply spend.
  Mitigation: ceilings at admission, the stage cap counted on typed events,
  and a default of "may not spawn" when no authority is granted.
- **A delegation tool that is not declared.** Its children go uncounted.
  Mitigation: C1 makes the declaration part of the delivery's digest, and a
  fixture asserts that an undeclared tool that starts a child fails
  conformance for that adapter version.
- **A parent that waits forever.** Mitigation: B3's bound, and the child's
  own duration ceiling.
- **Double-counted cost.** Mitigation: DP4's rule that child usage never
  enters the parent's own usage events.

## Alternatives considered

- **Option A alone.** Rejected: see "Recommendation".
- **Option A plus C.** Not recommended. It makes the children visible but
  leaves them outside the session contract, the ceilings and the cost record.
- **Wait for native sub-agents upstream in pi.** Rejected as a plan. It
  leaves G1 open for every harness, and ADR-2026-08-06 D7 would still require
  a non-native path.
- **Add more tool names to the runner's list.** Rejected. F3 shows name-keyed
  counting failing silently: a delegation tool under a second name was never
  counted. Every new harness or rename repeats that.
- **One budget field for both layers.** Rejected. The stage cap is workflow
  configuration and works with no control plane. The ceilings are an
  authority the workflow may narrow but never widen. One field would either
  push control-plane authority into OSS configuration or leave standalone
  sessions with no cap.

## Affected documents

Edited in the accepting commit, according to the option chosen:

- `013-orchestrator-and-governor.md` § Child-agent dispatch: the counting rule
  (C4), declared delegation tools (C1), and the requirement that a dispatched
  session be offered a child tool only with spawn authority (B2).
- `002-provider-base-contract.md` § Capability matrix: `EmitsSubagentEvents`
  as a computed bit (C5), and the parent tool-use id on normalized events
  (C3).
- `016-workflow-engine.md` § Topology view (cross-link): sub-agents appear
  from typed `subagent.*` events, not from one harness's delegation-tool
  events.
- `ADR-2026-08-12-pi-extension-delivery-seam-and-capability-pack-boundary.md`:
  an addendum for the declared-delegation-tool field on a delivery (C1).
- `README.md`: index entry (this commit) and status at acceptance.
- `AGENTS.md`: a read-order row for sub-agents and child delegation, at
  acceptance.

No `BOUNDARY-SYNC` region is touched.

## Affected work items

This corpus carries no tracker identifiers. The delivery work, by shape:

- the runner fix in review for an explicit zero cap and the second delegation
  tool name, which is compatible with every option and lands on its own;
- the runner counting `subagent.started` instead of tool names (C4);
- the declared-delegation-tool field on an extension delivery (C1);
- the pi adapter's mapping to typed events and spans (C2), and the parent
  tool-use id (C3);
- the matrix generator's computed bit and its fixtures (C5);
- downstream, by shape only: spawn authority for dispatched sessions (B1,
  B2), the pack's sub-agent tool (B3, B4), and cost roll-up over edges (DP4).

## Implementation notes

- **Fixtures, written on the input and watched to fail first.** A stage with
  `maxSubAgents: 0` refuses the first `subagent.started` on a harness whose
  delegation tool is neither `Task` nor `Agent`. A session with no spawn
  authority is not offered the sub-agent tool. A delegation call whose result
  carries a child `SessionRef` produces a `subagent.started` event that carries
  it.
- **The child `SessionRef` in a tool result.** It is a typed field in the
  tool's structured result, read by the adapter, never parsed from prose.
- **Ordering.** C needs nothing from B and can land first. B's tool can ship
  before C, but its children are then uncounted by the stage cap until C4
  lands.
