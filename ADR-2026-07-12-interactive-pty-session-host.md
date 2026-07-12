---
status: Proposed
date: 2026-07-12
boundary: shared
split: synchronized-mirror
---

# ADR-2026-07-12-interactive-pty-session-host

**Status:** Proposed
**Date:** 2026-07-12
**Boundary:** shared (cross-cutting; canonical here, mirrored stub in `rensei-architecture`)
**Authors:** Claude (Opus 4.8) — W1 foundations/contracts author

> Normative wire protocol: [`protocol/interactive-attach-v1.md`](protocol/interactive-attach-v1.md) (this corpus).
> Platform extensions (relay service, control plane, session/quota policy, iOS client):
> `rensei-architecture/ADR-2026-07-12-interactive-sessions-platform.md`.
> Driving program: `runs/2026-07-11-ios-interactive-sessions-program/` (W1 — Foundations & contracts).

## Context

The OSS `donmai` runtime is **headless by design**. A session clones a repo, spawns
the provider over pipes, consumes events to a terminal status, and tears down. Two
facts from the current code frame this decision:

1. **There is exactly one PTY-backed execution path today — the `agy` harness**
   (`provider/harness/agycli`): it calls `pty.Start`, holds the master fd, and
   drains it in a read loop. It also **forbids injection** and exposes no stdin or
   resize sink. Every other provider (claude, codex) runs over pipes. There is no
   byte-accurate terminal stream shipped anywhere — only normalized semantic
   activity events — and there is no live stdin rail into a running agent.
2. **The daemon is outbound-only by explicit code, not just doctrine.** It opens no
   inbound listener for work; it polls and posts. The one persistent connection it
   already holds is an **outbound SSE client** (credential rotate-stream) with
   reconnect-with-reset-on-success discipline — the direct precedent for a
   persistent relay connection.

A new product class — **platform-managed interactive terminal sessions** (attach
from another device to a live PTY running the harness's own interactive UI) —
needs three primitives the OSS layer does not yet ship: a real **PTY session host**
that exposes a byte stream plus stdin/resize sinks and a late-joiner snapshot; a
**framing library** for the attach wire; and a **generic outbound attach client**.
A live terminal cannot ride a 1–5 s poll (keystroke echo needs a live channel), so
the session host must hold a persistent **outbound** stream to a relay.

Per the corpus-wins rule and the `001` boundary discipline, softening the headless
posture and adding a persistent outbound stream requires an ADR before code. This
ADR is the **OSS-substance execution-layer contract**. The relay service,
arbitration/policy engine, control plane, quotas, and iOS client are the
platform-extension delta (mirrored ADR in `rensei-architecture`).

## Decision

Establish, in the OSS `donmai` binary, a **PTY session host**, a **framing
library**, and a **generic outbound attach client**, and amend the outbound-only
mandate to admit a persistent outbound attach stream. Concretely:

### 1. PTY session host (OSS)

A session host that runs the harness (or a shell) **under a real PTY**, extending
the `agy` PTY precedent and generalizing it to `claude`/`codex`/shell:

- **Spawn-under-PTY.** Own the PTY master; the child's stdio is the PTY slave.
  This reuses the `agycli` mechanics (`pty.Start`, master fd, read loop) but
  generalizes them into an interactive host rather than an ANSI-stripping
  event source.
- **Ring buffer.** Maintain a bounded, sequence-numbered ring buffer of output
  frames so late/multiple viewers and reconnects are served without replaying
  history from byte zero.
- **Resize application.** Apply the geometry the host is told (`TIOCSWINSZ`)
  **verbatim** — resize is a policy hook (the clamp policy lives upstream, in the
  relay); see the protocol spec § 8.
- **Stdin sink.** Write inbound keystroke bytes to the PTY master. This is the
  live stdin rail that does not exist today.
- **Headless VT as snapshot authority.** Consume the PTY output into a host-side
  headless terminal emulator that can serialize the current screen; the host is
  the **single snapshot authority** (decision D3). A relay requests a snapshot via
  a Control frame on the host's outbound stream — never via a host-side listener.
- **`sessionClass` on the host `SessionState`.** The host `SessionState` struct
  carries a `sessionClass` discriminator (e.g. `"interactive"`). This is a
  **named cross-repo dependency**: the reaper / idle-watchdog exemptions key off
  it, so both the OSS `SessionState` struct **and** the platform's session-state
  store must stamp `sessionClass:"interactive"`, or the activity-stall reaper
  evicts an interactive session during human think-time. The exemption is
  meaningless if either side fails to stamp it.

The host contract extends the existing `agent.Handle` seam (`SessionID`,
`Events`, `Stop`) with the interactive methods it lacks — a stdin write sink, a
resize sink, and a snapshot request — or adds a sibling `InteractiveHost`
interface alongside it. Either shape is acceptable; the requirement is that the
OSS layer ships a **working standalone** interactive host with no control-plane
dependency (a local dashboard could attach to it directly).

### 2. Framing library (OSS, brand-neutral)

A single Go framing library implements
[`protocol/interactive-attach-v1.md`](protocol/interactive-attach-v1.md), which is
**normative**. The library is the shared codec for the host and the (closed) relay
— the relay consumes the same OSS-published, brand-neutral framing rather than
re-implementing it, so host and relay cannot drift. The protocol is derived from
asciinema's ALiS shape but is **not** byte-compatible with it (see the spec's
Derivation section).

### 3. Generic outbound attach client (OSS)

A generic client that **dials OUT** to an attach URL with a bearer token and
speaks the framing library:

- **`ATTACH_URL` + bearer env precedent**, mirroring the existing
  `DONMAI_DAEMON_URL` convention: the composing binary supplies the relay URL and
  the per-session token; the OSS client is brand-neutral and points at no default
  endpoint.
- **Dial-out only.** The client opens a persistent outbound connection and holds
  it; it **never** opens an inbound listener. Reconnect follows the shipped
  reset-on-success backoff discipline (the rotate-stream template): re-resolve the
  bearer per attempt, reset backoff after any successful frame, cancel-aware.
- The client is standalone-usable (donmai without the platform can attach a local
  viewer to a local host over this client) — satisfying the OSS boundary rule that
  the layer never ships a half-working, platform-dependent client.

### 4. OSS / closed split (decision D7)

<!-- BOUNDARY-SYNC-START: adr-2026-07-12-interactive-outbound-mandate -->
<!-- Mirrored verbatim across
     donmai-architecture/ADR-2026-07-12-interactive-pty-session-host.md and
     rensei-architecture/ADR-2026-07-12-interactive-sessions-platform.md.
     Any change MUST land simultaneously in both corpora via paired commits,
     OSS-side first. See BOUNDARY.md § "Mechanism 3: synchronized verbatim mirror"
     and § "BOUNDARY-SYNC inline marker syntax". -->

**Interactive-session boundary + outbound-stream mandate.**

Layer ownership:

- **OSS (the execution layer):** the PTY session host (spawn-under-PTY, ring
  buffer, resize application, stdin sink, headless-VT snapshot authority), the
  framing library that implements the interactive-attach wire protocol, and the
  generic outbound attach client (dial-out with a bearer token, reconnect
  discipline, no inbound listener). All three ship working standalone, with no
  dependency on the control plane.
- **Closed (the platform):** the relay service, the multi-writer arbitration and
  session-policy engine, and the session control plane (lifecycle, grants,
  presence, quotas, admin). These extend the OSS layer; they are never required
  for the OSS layer to run.

Outbound-stream mandate (amends the 2026-06-22 pull-model decision):

1. A session host MAY open and hold **one persistent outbound stream per
   interactive session**, dialed OUT from the host to the relay over TLS, for the
   lifetime of that session. This is a third category of persistent outbound
   connection, alongside the worker poll and the verb poll.
2. The host opens **no inbound listener** for session attach. Everything the relay
   needs from the host — snapshot requests, authoritative resize, driver/pen
   effects — arrives as control frames on the connection the **host dialed out**,
   and is answered on that same outbound connection. The relay never dials into the
   host.
3. Viewers never connect to the host. Viewers dial IN to the relay; the host dials
   OUT to the relay; the relay is the only component reachable by both.
4. The stream carries only framed session bytes and the control frames the
   interactive-attach protocol defines. It is authenticated by a short-lived,
   per-session, single-use token verified by the relay against a dedicated
   asymmetric key, and is torn down when the session ends.
5. Removing the relay leaves the host with no inbound surface and no live attach —
   the single-machine product is unchanged and the outbound-only posture is
   preserved. Inbound listeners remain forbidden.

<!-- BOUNDARY-SYNC-END: adr-2026-07-12-interactive-outbound-mandate -->

## Consequences

### Positive

- Interactive terminal streaming becomes an **OSS capability** with a working
  standalone implementation, not a platform-only bolt-on — and `claude`/`codex`
  gain an interactive PTY mode as a byproduct of generalizing the `agy` path.
- Host and relay **share one Go framing library**, so the two ends of the wire
  cannot drift; the protocol spec is the single source of truth.
- The persistent outbound stream reuses shipped rails (the rotate-stream reconnect
  discipline, the bounded fan-out/drop-on-full backpressure precedent), so the
  net-new is a byte-accurate PTY host + a framing codec, not a runtime rewrite.
- The outbound-only posture — the load-bearing property behind the 2026-06-22
  mandate — is preserved intact; this ADR extends "poll" to "daemon-initiated
  outbound stream," never to an inbound listener.

### Negative

- A second, long-lived, byte-accurate execution path to maintain alongside the
  one-shot headless path and the interview streaming path.
- The `sessionClass` reaper-exemption is a **cross-repo coupling**: the OSS
  `SessionState` struct and the platform session-state store must both stamp it or
  interactive sessions are silently reaped during think-time. This is a named W4
  dependency precisely because it fails quietly.
- Raw terminal bytes now transit a relay — a new data-egress path the original
  outbound-only mandate never contemplated. The residency posture is a platform
  ruling (D13); the OSS layer keeps the relay client portable (no control-plane
  dependency in the data path) so a self-hosted relay stays possible.

### Risks

- **Snapshot fidelity on alt-screen TUIs** (vim/htop): the headless VT must
  reproduce alt-screen + scrollback correctly or late joiners see a corrupt
  screen. Gated by the W4 vim/htop go/no-go spike before the host lands.
- **Reconnect/idle bounds**: a long interactive session can exceed provider/sandbox
  idle timeouts; the host's idle-grace and the reaper `sessionClass` exemption
  bound the worst case, but both must be wired together.

## Alternatives considered

- **Relay-side headless VT** (relay consumes bytes into its own VT per session):
  rejected per D3 — pushes a VT dependency and per-session CPU into the relay and
  splits snapshot logic away from the PTY. Host-side keeps snapshot logic once, in
  Go, beside the PTY, identical for local and sandbox hosts.
- **Client-side raw byte replay** (broadcast the byte stream; joiners replay
  history): rejected — O(history) join cost and breaks on alt-screen. Prior art
  (asciinema, VibeTunnel) converged away from it.
- **A host-side inbound listener to serve snapshots/attach**: rejected — violates
  the outbound-only mandate. Snapshots are served on the host's own outbound stream.
- **TypeScript framing in the relay** (no Go reuse): rejected — the daemon,
  in-sandbox runner, and relay all speak Go; a shared framing library is the
  decisive reason the relay is Go.
- **Extending the deprecating TS libraries** for any of this: rejected — the Go
  binaries cannot import the TS libraries, and client-side execution is Go-native.

## Affected documents

- `001-layered-execution-model.md` — a new long-lived, byte-accurate interactive
  PTY host variant of the execution loop; the daemon posture gains a persistent
  outbound attach stream (the synchronized outbound-stream mandate above).
- `011-local-daemon-fleet.md` — the daemon gains a third persistent outbound loop
  (the attach stream) and a per-session `sessionClass`.
- `ADR-2026-06-02-interactive-agent-run-mode.md` — interactive PTY sessions are a
  byte-accurate sibling to the interview streaming mode (both are long-lived,
  non-terminating run paths); this ADR adds the terminal-byte transport the
  interview mode deliberately did not.
- `ADR-2026-06-22-daemon-per-session-cancel-wire.md` — the idle/no-progress
  watchdog gains a `sessionClass:"interactive"` exemption so human think-time is
  not read as a stall.
- `protocol/interactive-attach-v1.md` — the normative wire protocol (new; this
  ADR is its owning decision).
- Platform extensions: `rensei-architecture/ADR-2026-07-12-interactive-sessions-platform.md`.

## Affected work items

Program `runs/2026-07-11-ios-interactive-sessions-program/` — W1 foundations
(this ADR + the protocol spec), consumed by W3 (session core), W4 (PTY host +
attach client), W5 (relay), W7 (web viewer), W11 (iOS viewer). Tracker IDs live in
the platform corpus, not here.

## Implementation notes

- Generalize the `agycli` PTY handle (`pty.Start`, master fd, read loop,
  process-group teardown) into an interactive host package; do not fork a second
  PTY mechanism.
- The framing library is a new brand-neutral OSS Go package implementing the
  protocol spec; the generic attach client wraps it with the rotate-stream
  reconnect template and the `ATTACH_URL` + bearer convention.
- The `sessionClass` stamp is the one cross-repo item that must land on both sides
  in the same wave (W4) — treat it as a contract, not a follow-up.
