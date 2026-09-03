---
status: Accepted
boundary: shared
---

# ADR-2026-08-17 amendment: readiness degrades to unknown; heartbeat is independent

## Decision

A daemon heartbeat is a liveness signal and MUST remain independent from the
session-shim readiness resolver. A resolver timeout, network failure, or
upstream server error is represented in the heartbeat projection as
`readinessState: "unknown"`, with a bounded `readinessReason` and the
`readinessObservedAt` timestamp of the attempt. The heartbeat is still sent on
its normal schedule.

The readiness projection has three states: `ready`, `not-ready`, and
`unknown`. A definite `not-ready` result follows the existing withdrawal and
admission-pause rules. A transient resolver failure MUST NOT withdraw a
previously established readiness by itself. Implementations MAY apply a
configured staleness bound; the default bound is ten minutes, after which the
projection becomes `not-ready` with reason `stale`.

Readiness resolution runs on its own cadence and uses bounded retry backoff;
the backoff cap is thirty seconds. Recovery is reported by the next successful
resolver attempt and the following heartbeat. The healthy path and the
heartbeat interval remain unchanged.

## Wire compatibility

The readiness fields are additive members of the existing session-shim
projection. Consumers that do not understand them continue to read the stable
authority fields. A heartbeat response MUST echo the complete projection it
accepted, including the readiness state and metadata.

## Consequences

An unavailable readiness dependency no longer makes a host disappear from the
heartbeat stream. Operators and control planes can distinguish a transient
unknown answer from a definite withdrawal, while the existing safety rails
continue to apply to explicit not-ready answers and stale state.
