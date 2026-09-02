---
status: Accepted
date: 2026-09-02
boundary: shared
split: inline-addenda
---

# ADR-2026-09-02 — Session-shim recovery extensions

**Status:** Accepted
**Date:** 2026-09-02
**Boundary:** shared (the recovery protocol is OSS-canonical here; a composing
control plane may implement the committed-authority and operator-repair side)
**Authors:** session-continuity design lane
**Amends:** `ADR-2026-08-17-session-shim-adoption.md`, “Per-session shim
ownership and daemon adoption”

## Context

The adopted session-shim contract requires exact controller-generation fencing,
adopt-before-advertise, quarantine retention, and terminal proof before release.
Two recovery cases need a narrow extension without weakening those invariants.

First, a daemon can lose the response to a completed adoption batch. On restart
it may present the same complete lineage set at the next contiguous controller
generation. Treating that presentation as an unrelated replay can leave the
daemon unable to learn the authority that was already committed.

Second, an operator may need to repair a stored host projection after comparing
it with the current daemon assertion. That repair must not turn caller input,
absence evidence, malformed stored state, or a stale controller into authority
to remove quarantine.

## Decision

The heartbeat remains an exact authority assertion. A stale adoption revision
or different quarantine projection is refused; heartbeat never reconciles or
advances committed authority.

A complete adoption batch may return a typed contiguous-readoption replay only
when every outcome is compatible with the already-committed lineage set and
advances each controller generation contiguously. The response identifies both
the digest of the committed batch and the digest presented by the current
request. Digest ownership and canonicalization remain with the batch producer;
the receiver persists and echoes the value as opaque authority.

A composing control plane may expose a human-authorized, audited host repair
operation. It must bind the current host, controller, and committed adoption
revision; discard any caller-supplied quarantine list; and begin from the stored
quarantine authority. It may remove an entry only for a full
`(session, shim, process epoch, controller generation)` match backed by an
ordinary terminal receipt or a shim terminal tombstone on that host.
`shim_absent_attestation` is not terminal proof. Malformed stored authority and
concurrent authority changes fail closed without clearing quarantine.

## Consequences

### Positive

- A lost successful batch response can converge through a typed, bounded replay.
- Operator repair cannot import caller quarantine state or convert absence into
  proof of workload death.
- Exact heartbeat authority and stale-controller fencing remain unchanged.

### Negative

- Composers must retain producer-owned batch digests and full terminal lineage
  evidence.
- Repair remains an explicit exceptional operation rather than an automatic
  heartbeat side effect.

### Risks

- An implementation that matches fewer than all four lineage fields could clear
  the wrong generation; behavioral tests must exercise generation-zero evidence.
- A decoder that defaults malformed stored authority to an empty list would make
  repair destructive and must be rejected.

## Alternatives considered

- Reconcile on heartbeat: rejected because it lets a stale assertion mutate
  committed authority before the controller accepts the response.
- Treat absence attestation as terminal proof: rejected because absence from one
  discovery snapshot does not prove the harness process group was reaped.
- Replace stored quarantine with the caller projection: rejected because the
  repair request is evidence, not authority.

## Affected documents

- `ADR-2026-08-17-session-shim-adoption.md` — recovery preserves its shared core
  contract; no `BOUNDARY-SYNC`-marked text changes.

## Affected work items

The composing implementations and their release records track adoption replay
and host-authority repair independently of this public architecture record.

## Implementation notes

The wire representation may add typed replay metadata and an opaque canonical
batch digest. Implementations must prove the terminal-kind filter and malformed
decode path with revert-to-red tests against a real database.
