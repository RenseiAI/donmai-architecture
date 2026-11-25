---
status: Accepted
date: 2026-11-24
boundary: shared
split: sibling-extensions
amends: 013-orchestrator-and-governor.md
---

# ADR-2026-11-24 — Session chat-readiness report on the session status wire

**Status:** Accepted (2026-11-24). The affected-document edit to `013` landed in the accepting commit. Both halves are built.
**Date:** 2026-11-24
**Boundary:** shared. This file is the canonical ADR. The sibling corpus carries a `status: Mirrored` stub and the hosted consumer delta.
**Authors:** Donmai Agent

## Context

A client that wants to reach a running session has two delivery choices: hand the
message to the live harness now, or hold it in a queue until the session can take
it. Today the session status wire carries lifecycle status but no readiness
signal, so that choice is a guess. A guess in the live direction interrupts a
harness that cannot take input. A guess in the queue direction parks a message
for a session that sits idle.

The runner already reads this state. It watches the harness notice path and knows
which delivery a notice would take. The contract below publishes that read on the
wire the runner already posts, so the daemon and the hosted consumer implement
live delivery against one report.

## Decision

The runner reports per-session chat readiness on the existing session status wire,
`POST /api/sessions/{id}/status`, as an optional top-level `chatReadiness` field.

### D1 — The report shape (version 1)

```json
"chatReadiness": {
  "version": 1,
  "channel": "<NoticeDelivery value>",
  "state": "idle | busy | modal | ended | unknown",
  "liveSupported": true,
  "queueSupported": true,
  "reason": "<ChatReason token; empty when live>",
  "observedAt": "<RFC3339 UTC>"
}
```

- `version` is the report schema version. Today it is `1`.
- `channel` is the delivery channel token the runner read from the harness
  notice path (the `NoticeDelivery` value in the OSS runner). It is a closed
  set. Consumers reject a report with an unknown `channel` value.
- `state` is the runner's readiness read: `idle` (ready for live input now),
  `busy` (working, but live input is still accepted), `modal` (blocked on a
  modal prompt, live input not accepted), `ended` (the harness run loop ended,
  teardown pending), or `unknown` (the runner cannot read readiness). The
  producer never posts `ended`.
- `liveSupported` and `queueSupported` are the runner's capability flags for
  this session.
- `reason` is an opaque token naming why live delivery is unavailable. It is
  empty when the report is live-eligible. Consumers never branch on unknown
  values.
- `observedAt` is the runner-clock time of the read, RFC 3339 in UTC.

### D2 — Producer cadence

The runner sends the field for interactive sessions posting a `running` status:
on every change of the readiness read, and at least every 60 seconds while the
session is live. It never sends the field on terminal posts. A typed permanent
(4xx) rejection counts as answered. The producer does not re-post the same read
until it changes or the 60-second refresh is due. Transient failures retry with
backoff capped at the refresh interval. A daemon that does
not send the field keeps working. The field is optional end to end.

### D3 — Consumer validation and freshness

The consumer validates strictly. A report with an unknown `version`, an unknown
`channel`, or one that fails shape validation, is ignored and the last good
report is kept. The consumer stores the latest accepted report per session with
the server receive time. Freshness is 180 seconds measured from `observedAt`.
A report older than 180 seconds, a report with `observedAt` in the future
(negative age), or a session that is not active, is not live.

### D4 — Live versus queue-only

The consumer derives one delivery decision per session:

| Report | Derived delivery |
|---|---|
| Fresh, `liveSupported` true, `state` `idle` or `busy` | `available: true`, mode `live` |
| No fresh report, or a fresh report with `queueSupported` true | `available: true`, mode `queue_only` |
| Fresh report, not live-eligible, `queueSupported` false | `available: false` |

The third row is fail-closed: when the runner explicitly reports that queuing
is unsupported and live delivery is not eligible, the consumer must not claim
queue-only delivery it cannot honor.

## Consequences

### Positive

- One contract for live delivery. The daemon and the hosted consumer read the
  same field and derive the same decision.
- Old peers keep working. The field is optional, terminal posts never carry it,
  and unknown versions are ignored with the last good report kept.
- Stale reads fail safe. A 180-second freshness bound turns a dead reporter
  into queue-only instead of a live send into silence.

### Negative

- The report is advisory freshness, not a reservation. A live-eligible read can
  go stale between the report and the send. Senders keep their own refusal path.
- The consumer must keep per-session receive-time state it did not keep before.

### Risks

- A runner that reports `idle` while its harness is modal misroutes live input
  into a prompt that cannot take it. The `modal` state exists so the runner can
  say so. Conformance for the runner's read is implementation work, not this
  contract.

## Alternatives considered

- **A separate readiness endpoint polled by the consumer.** Rejected. It adds a
  second wire with its own auth, caching, and freshness story for state the
  runner already posts on every beat.
- **Required field on every status post.** Rejected. It would break every
  daemon that has not upgraded. Optional keeps the wire additive.
- **Consumer branches on `channel` and `reason` values.** Rejected. The
  `reason` space belongs to the runner and will grow. The live decision branches
  only on version, state, and the two booleans. An unknown `channel` is a shape
  failure and the report is ignored.

## Affected documents

- `013-orchestrator-and-governor.md` — new subsection on the `chatReadiness`
  field under "Completion contracts and backstop". Landed in the accepting
  commit.

## Affected work items

The tracker references are in the platform companion ADR.

## Implementation notes

The daemon half implements D2 against the OSS runner's readiness read. The
hosted half implements D3 and D4 storage and derivation. Queue delivery itself
is a hosted capability and lives in the sibling stub, not here.
