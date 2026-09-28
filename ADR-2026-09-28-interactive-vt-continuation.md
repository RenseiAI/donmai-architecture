---
status: Proposed
date: 2026-09-28
boundary: shared
split: sibling-extensions
---

# ADR-2026-09-28 — Complete terminal continuation

**Status:** Proposed — the separate read-only continuation approach is approved;
wire specification, implementation verification, release and activation remain pending.
**Date:** 2026-09-28
**Boundary:** shared; terminal state, local inspection and generic transport are
OSS-canonical. Hosted admission and deployment composition extend this contract.

## Context

A screen picture cannot capture all state that determines the next terminal
operation. Identical grids can have different current pens, saved cursors,
scroll margins, character sets, pending wraps or partially consumed escape and
UTF-8 sequences. Replaying a suffix into a terminal initialized from the picture
can therefore produce a different screen from the PTY-owning host.

Viewer sanitization also carries state across chunks. Resetting that filter at
a picture boundary does not reproduce the host parser's continuation. Existing
display-only viewers must retain their current filtering behavior.

## Decision

Complete continuation is an explicitly selected, versioned facility. It carries
a complete checkpoint out of band, then unchanged original host frames after
the checkpoint's sequence boundary. It does not add a new canonical Snapshot
format or reinterpret the existing screen format.

### State and authority

The PTY owner captures the checkpoint atomically with its PTY epoch, last
consumed host sequence, picture projection and optional final Exit. Complete
state includes both screens, current and saved cursor/pen state, modes, margins,
character sets, tabs, scrollback, pending parser and UTF-8 state, and the host's
filtering and mode state. Unknown or inaccessible state cannot be replaced by
guessed defaults. Inspection allocates no host sequence and changes no journal
receipt or durable acknowledgment.

The local shim protocol gains an additive selected version for correlated,
bounded checkpoint inspection. Older selected versions keep their exact wire
behavior. The controller must positively establish actual producer support;
an advertised maximum version alone does not establish a usable checkpoint.
Daemon access uses the existing exact session/process/controller reference,
and refuses stale references before inspection and before exposing the result.
PTY epoch, process epoch and carrier epoch remain separate values.

### Handoff and transport

The separate `interactive-continuation-v1` subprotocol selects the
`donmai-vt/continuation-v1` checkpoint schema explicitly. Host capability is
advertised on its existing authenticated outbound connection before any
checkpoint request. There is no new inbound host listener. An old peer receives
no unknown optional request metadata unless it positively advertises support.

Checkpoint uploads are bounded and correlated to an immutable request, producer
binding, total length and digest. An auxiliary upload does not consume a second
connection-admission credential. The receiver pairs a complete checkpoint at K
with a contiguous retained suffix starting at K+1. Missing state, eviction,
gaps, changed producer binding, unsupported selection and malformed input refuse
the handoff without advancing the consumer cursor. Memory ownership includes
payloads retained by active readers after a newer checkpoint replaces the
room's current checkpoint.

Original accepted frame bytes are preserved, including through durable reload.
Decoding and re-encoding cannot substitute for the original receipt bytes.
Another viewer requesting a checkpoint does not invalidate an existing viewer's
cursor; replacement of the authoritative producer binding does.

### Read-only consumer

The consumer validates framing, digest, sequence, epoch, complete engine state
and its agreement with the picture before committing the checkpoint boundary.
Raw output is fed only into the headless mirror. Terminal-query replies are
discarded there; the mirror cannot acquire input, resize or pen authority.
Only validated, escape-safe screen projections may reach a terminal renderer.

Ordinary screen Snapshots in the suffix consume their canonical sequence and
validate their boundary without replacing the complete parser state. Ancillary
display metadata follows the authoritative observation. Exit is applied once;
the final picture stays available and later frames are refused. A retained
checkpoint preceding Exit is usable after host detachment only if the complete
contiguous suffix reaches the same producer's final Exit. A later producer
binding invalidates that retained authority even if its PTY epoch is equal.

The existing attach protocols retain their frame registry, screen payload,
sanitizer, snapshot cache and viewer behavior. No opaque checkpoint or raw
continuation output enters their filtered viewer queues.

## Consequences

Faithful continuation requires a maintained complete-state engine API and a
versioned schema. Owned engine code must retain upstream licensing and pinned
provenance. This is more state and compatibility work than a screen-only reader.
Checkpoint storage, parser allocations, reader counts and tail copies require
explicit bounds; a compressed byte limit alone is insufficient.

Every public interface has a usable OSS implementation. Standalone PTY capture,
checkpoint serialization, mirror restoration and raw-tail replay must work
without a hosted service. Hosted transport integration and downstream UI
acceptance remain separate proof obligations.

## Alternatives considered

- Picture-only initialization loses hidden continuation state.
- Changing legacy sanitizer behavior breaks the existing viewer contract.
- Checkpointing a sanitized viewer model would define a different state
  machine, rather than continuing the PTY owner's exact state.
- Forwarding raw output to the user's terminal grants terminal side effects
  and violates the read-only display boundary.

## Affected documents

- [Interactive PTY session host](ADR-2026-07-12-interactive-pty-session-host.md).
- The selected local shim and separate continuation wire specifications must
  be finalized alongside the implementation before this ADR becomes Accepted.
- A companion discoverability stub and hosted extension carry deployment and
  admission details outside this public decision.

## Verification and activation

Required evidence includes same-prefix/checkpoint/same-suffix parity for hidden
state, malformed reachable parser states, title-filter boundaries, screen and
echo metadata, final Exit, stale local references, old/new peer negotiation,
raw-byte identity, gap refusal, carrier replacement, concurrent readers,
cancellation and bounded memory reclamation. State-removal controls must fail
before restored implementations pass. A local prototype or passing unit suite
does not establish a released downstream consumer or production activation.
