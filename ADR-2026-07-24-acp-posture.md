---
status: Accepted
boundary: OSS-only
date: 2026-07-24
---

# ADR-2026-07-24-acp-posture

**Status:** Accepted (founder decision 2026-07-24, runs/2026-07-21-open-harness-strategy)
**Date:** 2026-07-24
**Boundary:** OSS-only
**Authors:** open-harness strategy run, filed by the coordinator session

## Context

The Agent Client Protocol (ACP; JSON-RPC over stdio, editor-agent oriented)
has been studied twice in this corpus's history without a verdict: once as a
rejected alternative for the inbound requester family
(ADR-2026-06-19 §Alternatives), and once as a candidate native protocol for
the harness family in a research note whose promised ADR was never filed.
Meanwhile the harness roster is growing (two open-source harnesses are being
added natively), several major agents including both in-house-supported CLIs
are listed in public ACP registries, and one candidate harness ships native
ACP today while another has it only as a community adapter under an open
native-support proposal. The open thread needs closing so future harness work
stops re-litigating it.

## Decision

1. **Native, per-harness adapters remain the primary integration surface.**
   Fleet control needs steer/queue injection, durable event replay with
   cursors, session resume, permission mediation, structured one-shot output,
   and cost/usage telemetry. Every native surface we drive (stream-json,
   subprocess JSON-RPC, REST/SSE with a permission API, JSONL RPC with
   fork/replay) is strictly richer than ACP on these axes. ACP is
   editor-client oriented, 1:1 stdio by design, and lacks fleet primitives;
   adopting it as the primary surface would be a lowest-common-denominator
   regression (contra ADR-2026-05-10, native-rich providers).
2. **Prototype ONE `acp-generic` harness as a breadth play.** A single ACP
   client adapter (`provider/harness/acpgeneric/`) yields basic-fidelity
   coverage of any ACP-registered agent for the cost of a manifest row per
   agent: spawn/prompt/event-stream/teardown, permission round-trips where
   the agent supports ACP's permission-request method, no injection/resume
   guarantees. Cells anchored by `acp-generic` are capped at `experimental`
   stability and enter the capability-tier ladder at `untested` like every
   other cell; the adapter itself is smoke-gated against one pinned reference
   agent.
3. **Promotion criteria (revisit trigger, not calendar):** re-evaluate ACP as
   a first-class surface only when (a) both actively-added open harnesses
   ship native, maintained ACP with parity to their bespoke surfaces on the
   fleet-control axes above, or (b) ACP itself grows fleet primitives
   (durable replay, multi-session, steer semantics). Until then, no native
   harness adapter is deprecated in favor of ACP.

## Consequences

### Positive

- The stale thread is closed with a recorded posture.
- Long-tail harness requests get a cheap answer.
- No native adapter work is displaced.

### Negative

- `acp-generic` is a real maintenance line item for a deliberately
  basic-fidelity surface — accepted because it converts "new harness"
  requests from adapter-projects into manifest rows.

### Risks

- ACP evolves faster than the revisit trigger anticipates — mitigated by
  tying the trigger to capability parity rather than to a date.

## Alternatives considered

- **Adopt ACP as the single harness protocol.** Rejected: fleet-primitive
  gaps above; would discard the richest control surfaces we already ship.
- **Ignore ACP entirely.** Rejected: a one-adapter breadth play is cheap, and
  the registry ecosystem makes basic coverage of many agents nearly free.

## Affected documents

Closes the unfiled-ADR thread from the prior research note; adds
`acp-generic` to the harness roster in `001-layered-execution-model.md`
§ families when the prototype lands; no changes to `002` or the matrix spec
beyond ordinary harness rows.

## Affected work items

Tracked under the open-harness strategy program
(`runs/2026-07-21-open-harness-strategy/`); the `acp-generic` prototype is
Wave 5 breadth work in `12-work-breakdown.md`. No fleet tracker issue is
cited inline per this corpus's brand-neutral discipline.

## Implementation notes

The prototype adapter and its single pinned reference agent are specced in
`runs/2026-07-21-open-harness-strategy/` (open-harness strategy). Detailed
implementation belongs in the `donmai` repo, not here.
