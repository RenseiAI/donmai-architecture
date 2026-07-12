---
title: interactive-attach-v1 — interactive PTY session attach wire protocol
status: Proposed
date: 2026-07-12
revision: v1.0-draft3 (2026-07-12) — post W4/W5 re-review (both SIGN-OFF-WITH-AMENDMENTS)
protocol-version: interactive-attach-v1
boundary: OSS-only
derived-from: asciinema ALiS live-stream protocol (shape only; NOT byte-compatible)
normative-for: donmai (PTY session host + framing library + generic attach client), the relay, web viewers, iOS viewers
sign-off:
  W4-owner: SIGNED 2026-07-12 (v1.0-draft3) — re-review verdict SIGN-OFF-WITH-AMENDMENTS; all five binding conditions (R1 host-leg lane, R2 §13 disjunct, R3 §2 out-of-namespace rule, R4 §15 identity-based jti re-presentation, R5 §12 local-attach scope) verified landed in draft3; R6 modes-bitmap also landed
  W5-owner: SIGNED 2026-07-12 (v1.0-draft3) — re-review verdict SIGN-OFF-WITH-AMENDMENTS; binding conditions (R1 scope ruling = host legs carried, R2 §13 wording, R3 SSE resume carriage) verified landed in draft3; all four nits applied
---

# interactive-attach-v1 — interactive PTY session attach wire protocol

**Status:** Proposed
**Date:** 2026-07-12
**Revision:** v1.0-draft3 (2026-07-12) — post W4/W5 re-review (both SIGN-OFF-WITH-AMENDMENTS)
**Protocol version:** `interactive-attach-v1`
**Normative for:** the OSS PTY session host and framing library in `donmai`, the
relay, and every viewer (web, iOS).
**Owning ADR:** [`../ADR-2026-07-12-interactive-pty-session-host.md`](../ADR-2026-07-12-interactive-pty-session-host.md)
(execution-layer contract). Platform extensions (relay service, control plane,
quotas, iOS client) live in the mirrored platform ADR
`rensei-architecture/ADR-2026-07-12-interactive-sessions-platform.md`.
**Arbitration semantics:** platform-defined — see
`rensei-architecture/protocol/interactive-attach-v1-arbitration.md`. This spec
carries only the wire encoding and the wire-visible security invariants for
multi-writer arbitration (§ 5, § 6, § 11.1); who may take the pen and how it
moves is out of the OSS scope by design (owning-ADR decision D7).

## Sign-off (required before this spec leaves `Proposed`)

| Wave | Owner responsibility | Sign-off |
|---|---|---|
| **W4** | runner / PTY host + generic attach client implement the host side of every `v1-frozen` section | **pending** |
| **W5** | relay + control plane implement the relay side of every `v1-frozen` section | **pending** |

A `v1-frozen` section is not "done" until both owners have signed. A `v1-draft`
section may be amended by its owning wave via PR to this file **with the sign-off
cell updated in the same PR** — never silently.

## Changelog

### v1.0-draft3 (2026-07-12) — W4/W5 re-review amendments

Both re-reviews of v1.0-draft2 returned **SIGN-OFF-WITH-AMENDMENTS**. The
residual findings land here (attribution: W5 re-review R1–R3 + 4 nits; W4
re-review R1–R6 + 2 nits; W4-R1/R2 and W5-R1/R2 were the same items — the
coordinator ruled option (b) on scope for R1, and the two R2 wordings are
merged into one rule):

| Item(s) | Disposition |
|---|---|
| W5-R1 = W4-R1 | host legs ARE carried by the degraded lane: host POST-up batch (host-seq-keyed, contiguity + rejected-whole + `batchId` idempotency, ack = highest contiguous host seq), host SSE-down (relay-originated frames, at-least-once + idempotent handling with named keys), pinned `/host/sse` + `/host/output` endpoints, header-only auth, same jti/epoch rules; `room_state:"degraded"` DEFINED = host on the degraded carrier (§ 14, § 7) |
| W5-R2 + W4-R2 (merged) | § 13 contiguity rule disambiguated with three disjuncts: in-ring, current-with-stream-head (tail empty for now), and post-Exit ended (tail empty permanently) |
| W5-R3 | SSE GET carries resume position: `?resume_from=<seq>&epoch=<epoch>` (§ 14) |
| W4-R3 | § 2 generalized: any frame outside a § 4 namespace (all Control frames in every direction; non-host-produced Resize) carries seq=0/rel_time=0, receivers ignore both |
| W4-R4 | § 15 jti re-presentation eligibility is identity-based (subscribe with ANY `resumeFrom` incl. null; same (userId, sessionId) / host (sessionId, epoch)) — applied-nothing reconnects and re-dialing hosts qualify |
| W4-R5 | § 12 outbound mandate scoped to the relay attach path; OSS standalone local-attach (in-process / loopback-only) is outside it |
| W4-R6 | snapFormat 0x01 gains terminal-modes bitmap + `mouseProto` + saved primary cursor; conformance fixture recomputed (26 bytes) (§ 12.1) |
| W5-nit1 + W4-n1 | § 9 dangling-introducer hold cap named `sanitizerHoldMaxBytes`; at-cap disposition = STRIPPED at the cap |
| W5-nit2 | UI-rendered protocol strings (Marker labels, `error.message`, presence names) pinned to length-capped, control-char-stripped treatment (§ 9) |
| W5-nit3 | § 15: relay MUST reject `aud` ≠ `"relay"` |
| W5-nit4 | § 6.2: same-process reconnect latency after a silent drop is bounded by the relay keepalive cadence (relay-owned, tuned tight in the relay runbook) |
| W4-n2 | § 14 downstream reworded: host-produced frames in host seq order; relay-originated Control interleaves |

### v1.0-draft2 (2026-07-12) — post implementer review

Both implementer reviews (W4 host-side, W5 relay-side) returned REJECT on
v1.0-draft1. Because the protocol has not yet been ratified (sign-off pending),
their findings land as this in-place revision rather than a version bump.
Findings applied, by id:

| Finding(s) | Disposition |
|---|---|
| W4-F1 + W5-B2 | role enum extended to `host\|driver\|viewer`; host-token claim posture defined; per-role frame-provenance admission matrix added (new § 6) |
| W4-F10 + W5-B4/B5 | host stream epoch: JWT claim + subscribe echo; seq/rel_time continuity bound to the epoch; room-binding CAS on (sessionId, epoch) (§ 4.1, § 6.2, § 13, § 15) |
| W4-F8.3/F9 + W5-M1/m2/m3 | `jti` single-use scoped to initial room admission; reconnect-with-resume within `exp` re-presents the token; "in-band" refresh deleted — reconnect-with-resume is THE refresh path (§ 15) |
| W4-F2 | arbitration semantics moved to the platform corpus; OSS keeps wire encoding + wire-visible invariants + the standalone single-local-driver minimum (§ 5, § 7, § 11) |
| W5-B1 | input admission is dual-condition: current `penGeneration` AND sender connection is the pen-holder connection; `penGeneration` demoted to staleness guard (§ 5) |
| W5-M5 | pen holder / presence identity is a CONNECTION `(userId, jti)`, not a user (§ 5, § 6, § 7) |
| W5-M2/M4/M8 | new frozen control messages `kill`, `room_state`, `pen_state` (§ 7) |
| W5-B3 + W5-M10 | sanitization frozen stateful across frame boundaries; scope = all viewer-bound terminal bytes incl. Snapshot payloads; snapFormat 0x01 escape-safe by construction AND viewer-side filtering (§ 9, § 12.1) |
| W4-F4 | host VT is also the terminal-query responder (§ 12) |
| W4-F5 | Snapshot gains `echoMode`; predicate P narrowed to wire-observable conditions; password-flash hazard pinned (§ 10, § 12.1) |
| W4-F3 | snapFormat 0x01 byte layout authored, with conformance fixture (§ 12.1) |
| W4-F7 | Exit / teardown ordering frozen; `exitCode = 128+signum` convention (§ 12.2) |
| W4-F6 | relay-originated frames to the host carry seq=0/rel_time=0, host ignores; host ignores Input header seq (§ 2, § 5) |
| W4-F8 (1,2,4,5,6) + W5-M6/m6 | degraded lane completed: endpoint derivation, auth carriage, batch envelope with out-of-band controls, POST response taxonomy, upgrade-back dedup, single inputSeq space (§ 14) |
| W4-F16 | degraded-lane version carrier = the `/v1/` URL path segment (§ 1, § 14) |
| W5-M9/M7/m4 + W4-F1 | `alg` pinned exactly `EdDSA`; roomId namespace + relay room key (orgId, sessionId) + orgId-mismatch rejection; `exp` leeway ≤ 5 s; `iat` added (§ 15) |
| W5-M3 + W4-F11 | snapshot+tail contiguity invariant frozen; `resumeFrom` null ≡ 0 (§ 13) |
| W5-m1/n2 | per-viewer send-queue bound named + `backpressure` terminal disconnect; Resize cols==0\|\|rows==0 is a framing error (§ 8, § 11.2) |
| W4-F12/F13 | admission matrix covers the host leg; host trust posture for the relay stamp reworded; standalone local stamp defined (§ 5, § 6) |
| W4-F14/F15 | rel_time anchored at process spawn; varint truncation = framing error like overflow (§ 2, § 2.1) |
| W5-m5 | room-before-host and post-Exit room windows marked relay policy with pinned observable behavior (§ 7 `room_state`, § 12.2) |
| W5-n1 | sessionId + roomId both kept, justified (§ 15) |

## Derivation

The framing is **derived from** asciinema's ALiS live-stream protocol (shipped
Sep 2025): binary, length-prefixed, LEB128-varint frames carrying a sequence and
a relative timestamp, a server-side headless-VT snapshot for late joiners, and
resume-from-sequence on reconnect. We adopt that **shape** because it is the only
surveyed protocol purpose-built for resumable, multi-viewer, live terminal over
an outbound relay.

**This protocol is NOT byte-compatible with ALiS.** The event-type values, the
`Snapshot` / `Control` / `Input` additions, the two sequence namespaces, the
sanitization allowlist, the predictive-echo state machine, and the auth model are
our own. An ALiS decoder cannot read this stream, and that is expected. Every
byte-level fact below is authoritative here regardless of what ALiS does.

## Frozen vs draft — how to read this document

Every normative section is tagged:

- **`v1-frozen`** — immutable for the life of protocol version `interactive-attach-v1`.
  Changing a frozen rule requires minting a **new** protocol version
  (`interactive-attach-v2`) with its own version-negotiation token (§ Version
  negotiation). Implementations MUST reject any frame or behavior that violates a
  frozen rule rather than tolerate it. (Frozen text became mutable one last time
  in this revision because the protocol is not yet ratified — the sign-off table
  above is still `pending`. After both sign-offs, frozen means frozen.)
- **`v1-draft`** — normative in intent and detailed enough to build against, but
  amendable **within** v1 by the owning wave (W4 host-side, W5 relay-side) through
  a PR to this file that updates the sign-off table. Draft sections never change
  silently; a builder may rely on a draft section until a PR supersedes it.

Where a section is mostly frozen with a draft sub-part (e.g. backpressure), the
frozen invariant and the draft policy are called out separately.

---

## 1. Transport & version negotiation — `v1-frozen`

- Every leg is **WebSocket over TLS (WSS/443)**. The host dials OUT to the relay;
  viewers dial IN to the relay; the relay is the only endpoint reachable by both.
  No leg ever opens an inbound listener on the host (see § Snapshot authority and
  the owning ADR's outbound-only mandate).
- **Version is negotiated by WebSocket subprotocol.** The client offers
  `Sec-WebSocket-Protocol: interactive-attach-v1`. The relay echoes
  `interactive-attach-v1` back to confirm. A client that offers only an unknown
  version receives no matching subprotocol echo → the handshake is rejected and
  the client MAY fall back to the degraded lane (§ Degraded SSE fallback).
- **The degraded lane carries the version in the URL path.** HTTP/SSE has no
  subprotocol slot, so the attach URL embeds a version path segment (`/v1/`),
  and the degraded endpoints derived from it (§ 14) inherit that segment. The
  path segment is the degraded lane's version-negotiation token; a relay that
  does not serve `/v1/` degraded endpoints returns 404 and the client treats the
  lane as unavailable.
- The version subprotocol token carries **no** auth material. Auth travels in a
  **separate** channel (§ Auth) — a header for native clients, a **distinct**
  subprotocol slot for browsers. Version negotiation and auth are orthogonal:
  never overload one onto the other.
- A single WSS connection frames **exactly one session** (one room). A viewer that
  watches N sessions opens N connections or relies on relay-side multiplexing;
  cross-session multiplexing is a relay concern, **out of this spec** in v1.

---

## 2. Binary frame format — `v1-frozen`

Every message on the wire (both directions, both host and viewer legs) is a single
binary WebSocket frame with this layout:

```
+----------+--------------+------------------+-------------------+
| type:u8  | seq:varint   | rel_time:varint  | payload:bytes...  |
+----------+--------------+------------------+-------------------+
```

- **`type`** — one unsigned byte; the event type (§ 3).
- **`seq`** — unsigned varint (LEB128, § 2.1). Interpreted in the **producer's**
  sequence namespace (§ 4): host-produced frames use the host output sequence;
  viewer-produced `Input` frames set `seq` to the highest host output sequence the
  viewer has applied (the "based-on" anchor for echo reconciliation), and carry
  their own monotonic `inputSeq` in the payload (§ 5).
- **`rel_time`** — unsigned varint; microseconds since the producer's stream
  epoch anchor. For the host, the anchor is **process spawn** — the same zero
  point as the parallel asciinema cast (§ 16) — so the host's **first emitted
  frame MAY carry `rel_time > 0`** (spawn-to-first-output latency is real time).
  Monotonic non-decreasing within a producer. Used for replay pacing and
  recording; never for security decisions.
- **`payload`** — type-specific bytes (§ 3). Length is the remainder of the
  WebSocket frame; the framing does not repeat a total length because WebSocket
  already delimits the message.
- **Out-of-namespace frames carry zeroed headers.** Any frame not assigned to a
  § 4 sequence namespace — **all `Control` frames in every direction**
  (host-produced `subscribe`/`error`; viewer-produced `grab`/`release`/
  `resume_from`; relay-produced `presence`/`input_ack`/`pen_granted`/
  `pen_revoked`/`pen_state`/`room_state`/`snapshot_request`/`kill`) **and
  non-host-produced `Resize`** (viewer viewport advertisements, relay
  authoritative geometry) — carries `seq = 0` and `rel_time = 0`, and receivers
  MUST ignore both header fields on such frames. A receiver that validates
  monotonicity on out-of-namespace frames is non-conformant. Likewise the host
  MUST ignore the header `seq` on relay-forwarded `Input` (attribution is
  `(userId, inputSeq)`, § 4/§ 5). The § 12.2 post-Exit `Snapshot` reuses this
  same convention.

### 2.1 Varint encoding — `v1-frozen`

Varints are **unsigned LEB128**, byte-for-byte identical to Go's
`encoding/binary` `Uvarint` / `PutUvarint`:

- Little-endian base-128: 7 payload bits per byte, low group first.
- The high bit (`0x80`) of each byte is the continuation flag: set on every byte
  except the last.
- **No ZigZag.** There are no signed varints anywhere in this protocol; every
  varint field is a non-negative integer. A decoder that applies ZigZag is wrong.
- Maximum width is **10 bytes** (a full `uint64`). A varint that does not
  terminate within 10 bytes, or whose 10th byte has any bit above the single
  legal top bit, is an **overflow**; a frame that ends mid-varint (the buffer is
  exhausted while the continuation bit is still set) is a **truncation**. Both
  are framing errors → the receiver MUST close the connection with an `error`
  control message (§ 7) code `framing`. (In Go terms: `Uvarint` returning
  `n < 0` — overflow — and `n == 0` with bytes expected — truncation — map to
  the same disposition.)

**Boundary-value fixtures (authoritative — conformance MUST reproduce these):**

| Value (decimal) | Value (hex) | LEB128 bytes |
|---|---|---|
| `0` | `0x0` | `0x00` |
| `127` | `0x7F` | `0x7F` |
| `128` | `0x80` | `0x80 0x01` |
| `16383` | `0x3FFF` | `0xFF 0x7F` |
| `16384` | `0x4000` | `0x80 0x80 0x01` |
| `4294967295` (2³²−1) | `0xFFFFFFFF` | `0xFF 0xFF 0xFF 0xFF 0x0F` |
| `18446744073709551615` (2⁶⁴−1) | `0xFFFFFFFFFFFFFFFF` | `0xFF 0xFF 0xFF 0xFF 0xFF 0xFF 0xFF 0xFF 0xFF 0x01` |

A conformance test that encodes each left-column value and compares against the
right column, and decodes each right column back to the left value, is the gate
for any new implementation.

---

## 3. Event types — `v1-frozen`

The `type` byte is pinned. Values `0x00` and `0x08`–`0xFF` are **reserved**; a
receiver MUST treat an unknown type as a framing error (a new type is a
protocol-version bump, not a v1 addition).

| `type` | Name | Producer | Payload summary |
|---|---|---|---|
| `0x01` | **Output** | host | raw terminal output bytes (post-sanitization on the viewer leg, § 9) |
| `0x02` | **Input** | viewer | keystroke bytes + `inputSeq` + `penGeneration` + relay-stamped `userId` (§ 5) |
| `0x03` | **Resize** | viewer → relay (advertise) / relay → host (authoritative) / host → relay (applied) | terminal geometry (policy hook, § 8) |
| `0x04` | **Marker** | host | asciinema-style annotation label |
| `0x05` | **Exit** | host | process exit code + optional signal name (§ 12.2) |
| `0x06` | **Snapshot** | host | current-screen snapshot at a sequence (§ 12, § 12.1) |
| `0x07` | **Control** | any | JSON control-plane message (§ 7) |

Which producer may emit which type on which leg is governed by the § 6
admission matrix; a leg producing a type outside its role's producer set is a
protocol violation the relay MUST answer by closing the leg with
`error.code = framing`.

### 3.1 Payload layouts — `v1-frozen`

All lengths are varints; all byte fields are raw (no NUL termination).

- **Output** `0x01`: `[data:bytes]` — the remainder of the frame is terminal
  output. On the **host→relay** leg these are the raw PTY master bytes. On the
  **relay→viewer** leg they MUST have passed the § 9 sanitization allowlist.
- **Input** `0x02`: `[inputSeq:varint][penGeneration:varint][userIdLen:varint][userId:bytes][dataLen:varint][data:bytes]`
  — see § 5 for field semantics and the relay-stamping rule.
- **Resize** `0x03`: `[cols:varint][rows:varint][pxWidth:varint][pxHeight:varint]`
  — `pxWidth`/`pxHeight` MAY be `0` when unknown. `cols == 0 || rows == 0` is a
  **framing error** on every leg (a 0×N terminal does not exist; a sub-1×1
  geometry is a DoS vector, not a viewport). Direction-dependent meaning in § 8.
- **Marker** `0x04`: `[labelLen:varint][label:bytes]` — a UTF-8 annotation for
  recording/replay; display-only, never executed.
- **Exit** `0x05`: `[exitCode:varint][signalLen:varint][signal:bytes]` — the PTY
  child exited. `signal` is the empty string for a normal exit; on signal death
  `signal` carries the signal name and `exitCode = 128 + signum` (§ 12.2).
- **Snapshot** `0x06`: `[atSeq:varint][snapFormat:u8][snapLen:varint][snap:bytes]`
  — the screen as of host output sequence `atSeq` (§ 12). The envelope
  (`atSeq` + `snapFormat` + length) is **`v1-frozen`**; the `snap` serialization
  for a given `snapFormat` is **`v1-draft`** (VT-owned, format-tagged so it can
  evolve without a version bump). `snapFormat = 0x01` = VT-serialized screen —
  byte layout in § 12.1.
- **Control** `0x07`: `[jsonLen:varint][json:bytes]` — one UTF-8 JSON object whose
  `type` field selects the message (§ 7).

---

## 4. Sequence namespaces — `v1-frozen`

There are **two** independent monotonic sequence spaces. Conflating them is the
defect this section exists to prevent.

- **Host output sequence** — assigned by the host to every host-produced frame
  (`Output`, `Resize` it applied, `Marker`, `Exit`, `Snapshot`). Starts at `1`,
  strictly increasing by 1 per host frame, **within one host stream epoch**
  (§ 4.1). This is the space the relay ring buffer is keyed on and the space
  `resume_from` addresses (§ 13). The sole exception to "every host-produced
  frame" is the post-Exit final-screen `Snapshot`, which carries header
  `seq = 0` (§ 12.2).
- **Viewer input sequence (`inputSeq`)** — assigned by each viewer connection to
  its own `Input` frames. Per-connection, starts at `1`, strictly increasing by 1
  per input, and spans carriers: switching between the WSS lane and the degraded
  lane MUST NOT reset it (§ 14). Acknowledged independently per connection via
  the `input_ack` control message (§ 7).

An `Input` frame's **header `seq`** is NOT an input sequence — it is the host
output sequence the viewer had applied when it produced the keystroke (the
reconciliation anchor for predictive echo, § 10). The viewer's own ordering lives
in the payload `inputSeq`. The relay MUST attribute, order, and de-duplicate input
by `(userId, inputSeq)` per connection, never by the header `seq`; the host MUST
ignore the header `seq` on relay-forwarded `Input` (§ 2).

### 4.1 Host stream epoch — `v1-frozen`

The host output sequence and `rel_time` are meaningful only relative to **one
host stream epoch**: the lifetime of one PTY-owning host process.

- The **epoch** is a monotonic non-negative integer, assigned by the control
  plane at host-token mint and carried as the `epoch` claim in the host's JWT
  (§ 15). It increments on every new host process for the session (restart,
  respawn, sandbox re-provision) and is preserved across token re-mints for the
  same still-running process. The host also echoes it in its `subscribe`
  payload (§ 7); a mismatch between the claim and the echo is an auth error.
- **Within one epoch**, `seq` and `rel_time` are continuous for the life of the
  epoch — including across dropped-and-redialed WSS connections. A host WSS
  reconnect within an epoch **never resets** either counter. Delivery gaps
  caused by a mid-epoch reconnect are permitted (the host does not retransmit);
  the relay MUST truncate its ring at any such gap so that a gap can never be
  replayed across (it resolves as a ring miss, § 13), and SHOULD request a fresh
  `Snapshot` (`reason: "resync"`) after a host reconnect.
- **A new epoch is a new room generation.** `seq` restarts at `1`, `rel_time`
  restarts against the new process's spawn, the relay MUST discard the prior
  generation's ring, MUST emit `room_state` and force a fresh `Snapshot` to
  every attached viewer, and MUST resolve any `resume_from` that references a
  prior epoch — or that carries no epoch — as a ring miss (§ 13). The relay
  MUST NOT serve pre-restart `resume_from` positions against post-restart
  sequence numbers.
- How the relay decides which host connection owns the room — the
  **(sessionId, epoch) compare-and-swap** — is § 6.2.

---

## 5. Input frames — `v1-frozen`

`Input` payload: `[inputSeq:varint][penGeneration:varint][userIdLen:varint][userId:bytes][dataLen:varint][data:bytes]`

- **`inputSeq`** — the producing connection's monotonic input sequence (§ 4).
- **`penGeneration`** — the pen generation the sender believes is current
  (§ 11.1). **`penGeneration` is a staleness guard, not an authorization
  credential** — the generation value is broadcast to every leg (it has to be,
  for echo suppression), so knowing it proves nothing.
- **Input admission rule (frozen).** The relay MUST drop an `Input` frame —
  and MUST NOT forward it to the host — unless **both** hold:
  1. the frame's `penGeneration` equals the current server-authoritative
     generation, **and**
  2. the **sending connection** — identified as `(userId, jti)` from the
     verified token (§ 6.1, § 15) — is the current **pen-holder connection**.
  Dropped input is not an error; the relay MAY inform the sender via a
  `pen_revoked` control message. Condition 1 alone is insufficient: without
  condition 2, any read-only leg that observed `pen_granted` could inject
  keystrokes by echoing the broadcast generation.
- **`userId`** — **relay-stamped, never client-supplied.** A viewer MUST send
  `Input` with `userIdLen = 0`. On receipt the relay verifies the sender's token
  (§ Auth), stamps the verified `userId`, and re-emits the frame toward the host
  with `userId` populated. Any `userId` bytes a client puts on the wire are
  ignored and overwritten. A `role: "host"` token has no `userId` (§ 15) and its
  leg may not produce `Input` at all (§ 6), so a host principal can never be
  stamped onto a keystroke. This makes every keystroke that touches the PTY
  attributable to a verified user for audit.
- **Host trust posture.** The **host MUST reject** any `Input` arriving with
  `userIdLen = 0` — an unstamped input frame never reaches the PTY. This is a
  presence check, not an independent verification: the host **trusts** the stamp
  because the only party that can deliver frames on its authenticated outbound
  connection is the relay, which enforced the admission rule above. The host
  performs **no** pen arbitration of its own — it writes whatever admitted,
  stamped input the relay forwards.
- **Standalone (no relay).** When the OSS host is attached locally with the
  generic attach client and no relay is present, the local attach endpoint
  plays the stamper: it stamps a fixed local user id (`"local"`) and applies the
  trivial single-local-driver policy (exactly one local connection may write).
  The invariant "no unstamped input reaches the PTY" holds identically.
- **`data`** — the already-encoded terminal input bytes (UTF-8 text and/or the
  escape sequences a terminal emits for special keys). The host writes `data`
  verbatim to the PTY stdin sink; it is NOT re-sanitized (input to a PTY is the
  user's own; the sanitization allowlist governs **output** toward viewers, § 9).

**Input acknowledgement.** The relay sends each viewer connection an `input_ack`
control message (§ 7) carrying the highest **contiguous** `inputSeq` it has
accepted and forwarded for that connection. A gap (a missing `inputSeq`) freezes
the ack at the last contiguous value; the viewer resends from `ack + 1`. This is
the ordering guarantee predictive echo and the degraded lane both build on.

---

## 6. Roles, connection identity & the admission matrix — `v1-frozen`

### 6.1 Roles and connection identity

- Every leg authenticates with a token whose `role` claim is exactly one of
  **`"host"` | `"driver"` | `"viewer"`** (§ 15).
- A **connection** is identified as **`(userId, jti)`** — the verified user (or
  the host principal, which has no `userId`) plus the token's per-connection
  nonce. Everything per-connection — presence entries, the pen holder, input
  sequencing, degraded-lane leg correlation — is keyed on the connection, never
  on the bare `userId`. The same user attached from a laptop and a phone is two
  connections; at most one of them can hold the pen. In control messages the
  connection id (`connId`) is the token `jti`.
- The relay admits **at most one live `role: "host"` leg per room**; which host
  connection wins is the epoch CAS (§ 6.2). `role` is a ceiling (§ 15): a
  viewer-role connection can never write, a driver-role connection can never
  produce host frames, and no leg can escalate over the wire.

### 6.2 Host-leg room binding — the (sessionId, epoch) CAS

The relay maintains one host-leg binding per room: the epoch and the live host
connection, updated by compare-and-swap. When a new connection presents a
`role: "host"` token with epoch `E` for a room whose highest observed epoch is
`E_cur`:

- **No live host leg bound:** accept iff `E ≥ E_cur`. `E == E_cur` **resumes**
  the same stream (the same process re-dialing after a WSS drop; `seq` continues
  per § 4.1). `E > E_cur` begins a **new room generation** (§ 4.1).
- **A live host leg with epoch `E_cur` is bound:**
  - `E > E_cur` → the new connection **supersedes**: the relay MUST close the
    old leg (it is a zombie by definition — a newer process exists) and begin a
    new room generation.
  - `E ≤ E_cur` → the new connection is a **zombie or duplicate**: the relay
    MUST reject it (close with `error.code = epoch-stale`). A host whose prior
    leg is half-open re-dials into this rejection until the relay's keepalive
    collapses the dead leg; the host's reconnect discipline retries with
    backoff. Keepalive/ping cadence is relay policy (`v1-draft`) — note the
    consequence: after a silent drop, the same-process host's reconnect latency
    is bounded by that cadence, so the relay runbook tunes it tight
    (relay-owned).
- The epoch the connection presents is the JWT `epoch` claim; the `subscribe`
  echo must match it (§ 4.1). Because the claim is control-plane-minted, a
  client cannot assert an arbitrary epoch.

### 6.3 Frame-provenance admission matrix

What each leg may **produce** (relay-enforced; violation = close with
`error.code = framing`):

| Frame / message | host leg | driver leg | viewer leg |
|---|---|---|---|
| `Output` 0x01 | ✓ | ✗ close | ✗ close |
| `Input` 0x02 | ✗ close | ✓ (forwarded only per § 5 admission rule) | ✓ accepted at framing level, **never forwarded** (role ceiling) |
| `Resize` 0x03 | ✓ (applied-geometry echo) | ✓ (viewport advertisement) | ✓ (viewport advertisement) |
| `Marker` 0x04 | ✓ | ✗ close | ✗ close |
| `Exit` 0x05 | ✓ | ✗ close | ✗ close |
| `Snapshot` 0x06 | ✓ | ✗ close | ✗ close |
| Control `subscribe` | ✓ | ✓ | ✓ |
| Control `resume_from` | ✗ ignore | ✓ | ✓ |
| Control `grab` / `release` | ✗ ignore | ✓ | ✓ (grab refused `pen-denied`) |
| Control `error` | ✓ | ✓ | ✓ |
| any other Control type | ✗ ignore | ✗ ignore | ✗ ignore |

Frame-type violations (a viewer emitting `Output`, a host emitting `Input`) are
**hard** violations → close with `error.code = framing`. Mis-routed but known
Control messages (a viewer sending `snapshot_request`) are **soft** — the relay
MUST ignore them (and MAY answer with an `error`), preserving
forward-compatibility.

What each leg **receives** (and must accept):

| Direction | Frames / messages |
|---|---|
| relay → host | `Input` (stamped), `Resize` (authoritative), Control `snapshot_request`, `kill`, `error` — all with header `seq = 0`, `rel_time = 0` (§ 2) |
| relay → driver/viewer | `Output` (sanitized), `Resize` (applied geometry), `Marker`, `Exit`, `Snapshot`, Control `presence`, `input_ack`, `pen_granted`, `pen_revoked`, `pen_state`, `room_state`, `error` |

The **host MUST ignore** any known Control message other than
`snapshot_request` / `kill` / `error` arriving on its leg (forward-compat — a
future relay may fan out messages the host doesn't consume), and MUST treat an
unknown frame **type byte** as a framing error (§ 3) — those two rules are
different layers and both hold.

---

## 7. Control-plane messages — message SET `v1-frozen`, individual fields `v1-draft`

Control messages ride inside `Control` frames (`type 0x07`) as a single JSON
object with a `type` discriminator. **The set of message `type` values below is
`v1-frozen`** — adding or removing a message is a protocol-version bump. **Adding
an optional field to an existing message is `v1-draft`** — the owning wave may do
it via PR; receivers MUST ignore unknown fields (forward-compatibility).

| `type` | Direction | Purpose | Shape (v1 fields) |
|---|---|---|---|
| `subscribe` | any leg → relay | join a room | `{ "type":"subscribe", "sessionId":str, "asRole":"host"\|"driver"\|"viewer", "epoch":int (host legs only; MUST equal the token claim), "resumeFrom":int\|null, "resumeEpoch":int\|null, "viewport":{"cols":int,"rows":int} }` |
| `resume_from` | viewer → relay | request replay from a sequence | `{ "type":"resume_from", "seq":int, "epoch":int\|null }` |
| `snapshot_request` | relay → host | ask the host to emit a `Snapshot` | `{ "type":"snapshot_request", "reason":"join"\|"resync"\|"ring-miss"\|"backpressure" }` |
| `kill` | relay → host | terminate the session | `{ "type":"kill", "reason":"stopped"\|"quota"\|"revoked", "signal":str\|null }` |
| `grab` | viewer → relay | take the pen | `{ "type":"grab" }` |
| `release` | viewer → relay | drop the pen | `{ "type":"release" }` |
| `presence` | relay → viewers | roster changes | `{ "type":"presence", "op":"join"\|"leave"\|"list", "members":[{"userId":str,"connId":str,"role":str,"driving":bool}] }` |
| `input_ack` | relay → viewer | ack highest contiguous `inputSeq` | `{ "type":"input_ack", "ackInputSeq":int }` |
| `pen_granted` | relay → all | pen assigned | `{ "type":"pen_granted", "userId":str, "connId":str, "penGeneration":int }` |
| `pen_revoked` | relay → all | pen lost/stale | `{ "type":"pen_revoked", "userId":str, "connId":str, "penGeneration":int }` |
| `pen_state` | relay → leg on join/reconnect | current pen holder | `{ "type":"pen_state", "holderUserId":str\|null, "holderConnId":str\|null, "penGeneration":int }` |
| `room_state` | relay → viewers | host-leg / room lifecycle | `{ "type":"room_state", "state":"live"\|"host-reconnecting"\|"degraded"\|"host-gone"\|"ended", "sinceSeq":int\|null }` |
| `error` | any → any | typed error | `{ "type":"error", "code":str, "message":str, "retryable":bool }` |

Notes that are themselves `v1-frozen`:

- `snapshot_request` and `kill` are **relay → host Control frames carried on the
  host's existing outbound stream** — never requests the relay makes to a
  host-side listener (§ 12).
- On receiving `kill`, the host MUST terminate the PTY **process group** and
  answer with the normal Exit flow (flush → `Exit`, § 12.2). Signal choice and
  escalation (e.g. SIGTERM → SIGKILL) are host policy (`v1-draft`); a non-null
  `signal` field is a request, not a mandate.
- `room_state` MUST be emitted to every viewer leg on **every host-leg state
  transition**, and to each viewer on join. `sinceSeq` is the last host `seq`
  the relay holds. `state: "degraded"` is **defined**: the host leg is
  currently attached via the degraded SSE+POST carrier (§ 14) — the room is
  live, but viewers should expect higher input-echo latency. Room behavior
  around the edges is relay policy (`v1-draft`) with this pinned observable
  shape: a viewer subscribing before any host leg exists is **held** in
  `room_state: "host-reconnecting"`, not rejected; after `Exit` the room
  persists in `room_state: "ended"` for a bounded window for final-screen
  reads, then tears down.
- `pen_state` MUST be pushed to every leg on join and on reconnect, so no client
  ever has to infer the holder from message history. The pen may change at any
  time; `pen_granted` / `pen_revoked` / `pen_state` are the only signals, and a
  client MUST treat whichever it saw last as current.
- `subscribe.asRole` is a **request**, honored only if the token grants that
  capability (§ 15) — `asRole` above the token's `role` ceiling is refused
  (`pen-denied` for driver-capability requests by viewer tokens; `auth` for
  host requests by non-host tokens).
- **Arbitration semantics are platform-defined.** `grab`, `release`,
  `pen_granted`, `pen_revoked`, and `pen_state` are carried here as an opaque
  message-type registry — their payload schemas above are normative for
  **routing and parsing only**. The rules for who may take the pen, when a grab
  succeeds, cooldowns, auto-release on disconnect, and presence derivation are
  the platform's arbitration policy:
  `rensei-architecture/protocol/interactive-attach-v1-arbitration.md`. The OSS
  layer implements: the § 5 admission invariant (relay-side; local-stamper-side
  in standalone), the § 6 role ceilings, and the standalone single-local-driver
  policy — nothing more.
- `error.code` values in v1: `framing`, `auth`, `room-mismatch`, `pen-denied`,
  `ring-miss`, `backpressure`, `rate-limited`, `epoch-stale`, `internal`. The
  code set is `v1-draft` (extendable); the `error` message itself is frozen.

---

## 8. Resize is a policy hook — hook `v1-frozen`, clamp policy out-of-spec

Resize is a **hook**, not a fixed geometry rule.

- **Viewer → relay `Resize`** = a viewport advertisement: "this viewer can display
  `cols`×`rows`." Advisory input to the relay's policy.
- **Relay → host `Resize`** = the **authoritative** geometry. The host applies it
  **verbatim** to the PTY (`TIOCSWINSZ`) with no second-guessing. The host never
  computes geometry from viewer advertisements itself.
- **Host → relay `Resize`** = the applied-geometry echo, emitted into the host
  output sequence so viewers (and the recording) learn the geometry at the right
  point in the stream.
- **Frozen (the hook):** the host applies exactly the geometry the relay tells it;
  `Resize` is the sole carrier of geometry in both directions. `Resize` with
  `cols == 0 || rows == 0` is a **framing error** on every leg (§ 3.1).
- **Out of spec (the policy):** the function mapping the set of attached viewer
  viewports → the one authoritative geometry (e.g. clamp to the smallest viewer,
  clamp to the driver's viewport, an operator-pinned size) lives **in the relay**
  and MAY change without a protocol revision. The known pathology of a naive
  "smallest viewer" clamp (a phone shrinks everyone) is a policy problem the relay
  owns, deliberately kept out of the frozen wire so it can be fixed without a v2.

---

## 9. Terminal-escape sanitization allowlist — `v1-frozen`

Output bytes originate in an **untrusted** process (an agent's PTY running
arbitrary commands over attacker-influenceable repository content). Before
host-originated terminal bytes reach any viewer (web/xterm.js, iOS/libghostty),
they MUST pass this allowlist. Enforcement is **identical** at the relay and at
every viewer — a viewer MUST NOT assume the relay sanitized, and the relay MUST
NOT assume the viewer will. Defense in depth: both apply it.

**Scope (frozen):** the allowlist governs **all viewer-bound terminal bytes** —
`Output` frames **and** any escape-bearing bytes a viewer reconstructs from a
`Snapshot` payload. `snapFormat = 0x01` is additionally required to be
escape-safe **by construction** (§ 12.1): its cell-grid encoding cannot carry
C0/ESC/OSC/DCS/APC bytes at all, so a conformant snapshot has nothing to filter
— but a viewer that renders a snapshot by synthesizing escape sequences (e.g.
replaying SGR runs into an emulator) MUST run this filter over what it
synthesizes, belt and braces.

**Statefulness (frozen):** the sanitizer MUST be a stateful VT/escape parser
that carries partial-sequence state **across `Output` frame boundaries** within
a leg. An escape sequence split across frames MUST be classified exactly as if
it had arrived contiguously (`ESC ] 5 2 ;` at the tail of frame N plus payload
and terminator at the head of frame N+1 is OSC 52 and is stripped). A dangling
incomplete OSC/DCS/APC/PM introducer at a frame boundary MUST be **held
pending** — never passed through — until its terminator arrives or the hold
reaches the named sanity cap **`sanitizerHoldMaxBytes`** (value `v1-draft`;
existence frozen), at which point the entire held sequence is **stripped at
the cap** — an over-cap dangling sequence is never flushed through.
Per-frame stateless filtering is **non-conformant**: it passes exactly
the split-sequence bypass this rule exists to close. The conformance corpus
includes, for every strip-row fixture below, **split variants at every interior
byte offset**; an implementation passes only if every split placement yields
the same disposition as the contiguous form.

**The governing invariant (frozen):** a viewer emulator is a **display-only
mirror**. It NEVER emits input in response to output bytes. Every escape sequence
whose terminal-standard effect is "the terminal writes a reply back on its input"
is answered **only** by the host-side headless VT (the real terminal, § 12);
viewers strip/ignore the trigger and never reply. This single rule closes the
entire output-triggers-input injection class (cursor-position reports, device
attributes, status reports, color queries).

Disposition vocabulary: **pass** (render normally) · **strip** (remove entirely) ·
**neutralize** (render an inert placeholder / rate-limited signal, no side effect) ·
**display-only** (render but never auto-action).

| Escape class | Examples | Disposition | Rationale |
|---|---|---|---|
| Printable text, C0 formatting | UTF-8, `HT` `LF` `CR` `BS` | **pass** | normal terminal content |
| `BEL` (0x07) | audible bell | **neutralize** | rate-limited visual bell only; no auto-audio, no notification side effect |
| SGR (color/attributes) | `ESC[…m` | **pass** | cosmetic; bounded to the cell grid |
| Cursor addressing / erase | `CUP`/`ED`/`EL`/scroll region | **pass**, VT-bounded | applied within the emulator grid; the VT clamps out-of-bounds moves |
| Private modes | alt-screen `?1049`, bracketed paste `?2004`, mouse `?1000–?1006` | **pass** | required by real TUIs; only pen-holding driver input is honored |
| **OSC 52 (clipboard)** | `ESC]52;c;<b64>BEL` | **strip** | paste-jacking / clipboard theft — never write a viewer clipboard from the stream |
| **OSC 8 (hyperlink)** | `ESC]8;;<url>ESC\` | **display-only** | render link text; no auto-navigation; on explicit user gesture only, `http`/`https` scheme allowlist, full URL shown |
| OSC 0/1/2 (title set) | `ESC]0;<title>BEL` | **neutralize** | never retitle the viewer window/tab; MAY show a length-capped, control-char-stripped session-title chip |
| OSC 4/10/11/12 (palette/fg/bg/cursor color **set**) | `ESC]10;…` | **pass** | cosmetic |
| OSC color/title **query** forms | `ESC]10;?BEL`, `ESC]4;n;?BEL` | **strip** | query variants make the terminal reply on input — injection vector |
| OSC 7 (cwd), OSC 9 (notify), OSC 777, OSC 1337 (proprietary: file xfer, clipboard, inline image, exec) | iTerm/rxvt extensions | **strip** | carry file-transfer / clipboard / notification / exec side effects |
| Cursor-position / device-attributes / status **reports** | `DSR` `CSI 6n`, `DA` `CSI c`, `CSI >c` | **strip at viewer** | the host VT answers these (§ 12); a viewer that replied would inject input |
| Window manipulation | xterm `CSI …t` (resize/move/raise/**report**), title stack `CSI 22/23 t` | **strip** | can move/resize the viewer window and the report forms inject input; geometry is owned by § 8 only |
| DCS: DECUDK (programmable keys), DECRQSS (setting reports) | `ESC P … ESC\` | **strip** | remap keys / trigger input replies |
| DCS: Sixel graphics | `ESC Pq … ESC\` | **pass**, size-capped | display-only image; bounded by backpressure (§ 11.2) |
| APC / PM strings (Kitty-graphics APC, terminal-multiplexer passthrough) | `ESC _ … ESC\`, `ESC ^ … ESC\` | **strip** | arbitrary application protocols; graphics/exec side channels |

Anything not enumerated defaults to **strip** if it is an OSC/DCS/APC/PM string
form, and **pass** if it is a standard CSI/SGR cell-grid operation. When in doubt,
a sequence that could cause the terminal to *emit input* or *touch host resources
outside the grid* is stripped. W4/W5/iOS ship the **same** table; a conformance
corpus of hostile sequences (one per row, plus the split-at-every-interior-byte
variants of every strip row) is the shared test fixture.

**UI-rendered protocol strings (frozen).** The "length-capped,
control-char-stripped" treatment on the title-chip row applies to **every
protocol string a viewer renders as UI text** — `Marker` labels,
`error.message`, and presence display names included. A protocol string is
never rendered raw into viewer UI chrome.

---

## 10. Predictive local echo state machine — `v1-frozen`

Predictive echo decouples *perceived* keystroke latency from network RTT by
rendering a driver's printable keystrokes locally and reconciling against the
authoritative stream (the Mosh/sshx technique). It is **only** safe under tight
conditions; the state machine enforces them.

**The echo-mode signal.** Whether the PTY is echoing (cooked/ECHO) or not
(raw/ECHO-off, e.g. a password prompt) is a termios property set by `ioctl` on
the PTY slave — it is **invisible in the output byte stream**. The only
wire-visible signal is the `echoMode` field of the `Snapshot` payload (§ 12.1).
A mid-stream termios change is conveyed by the **next** `Snapshot`; the host
SHOULD emit a Snapshot promptly when it observes an echo-mode change
(`v1-draft` behavior) to bound the stale window. Because the signal can lag,
the state machine below is **biased to suppression**: predicting a glyph into
an ECHO-off password prompt flashes a secret on screen, and rollback is not a
sufficient mitigation for a secret that was displayed. When in any doubt —
no Snapshot applied yet, `echoMode` unknown, buffer state ambiguous —
prediction is SUPPRESSED.

**Predicate `P` (all must hold to predict; every condition is
wire-observable):**

1. this connection is the pen holder at the current `penGeneration`
   (per the last `pen_granted` / `pen_state`), **and**
2. the **last applied `Snapshot`** reported `echoMode = on`, and no
   later authoritative frame has entered the alt screen or switched buffers,
   **and**
3. the active buffer is the **primary** buffer (not alt-screen), per the last
   Snapshot plus subsequent private-mode (`?1049`) tracking, **and**
4. no IME composition is in progress, **and**
5. the keystroke is a **printable ASCII** glyph (0x20–0x7E).

If no Snapshot has been applied yet, or the last Snapshot's `echoMode` is
`unknown` (0xFF), `P` is false.

States:

- **`SUPPRESSED`** (default) — no prediction; all input passes through unpredicted.
- **`ARMED`** — `P` holds; eligible to predict, none outstanding.
- **`PREDICTED`** — one or more speculative glyphs rendered locally, awaiting the
  authoritative frame that should confirm them.

| From | Trigger / guard | To | Action |
|---|---|---|---|
| `SUPPRESSED` | `P` becomes true | `ARMED` | enable prediction |
| `ARMED` | `P` becomes false (alt-screen enter, `echoMode` no longer known-on, pen lost / `penGeneration` change, IME start) | `SUPPRESSED` | disable prediction |
| `ARMED` | printable-ASCII keystroke while driving | `PREDICTED` | render speculative glyph; record prediction keyed by its `inputSeq` and the current host `seq` anchor |
| `PREDICTED` | further printable-ASCII keystroke, `P` still holds | `PREDICTED` | extend speculative buffer |
| `PREDICTED` | authoritative `Output`/`Snapshot` advancing host `seq` past a prediction's anchor | `ARMED` (or stays `PREDICTED` if predictions remain) | **reconcile**: matched predictions commit silently; on mismatch **roll back** (repaint from the authoritative frame); drain confirmed predictions |
| `PREDICTED` | `P` becomes false | `SUPPRESSED` | **immediately roll back all** outstanding speculative glyphs, repaint from the last authoritative frame |
| any | `Snapshot` received (join/resync) | `SUPPRESSED` then re-evaluate `P` | snapshot is authoritative; discard all predictions before applying it (its `echoMode` feeds `P`) |
| `PREDICTED` | prediction TTL elapsed with no reconciling frame | `PREDICTED`→`ARMED` | roll back the expired prediction (bounded wait; never keep a phantom glyph indefinitely) |

Frozen rules: **predict only when `P` holds; reconcile or roll back on every
authoritative frame; never predict on alt-screen, during IME composition, when
this connection does not hold the pen at the current `penGeneration`, or when
the last Snapshot did not report `echoMode = on`.** A prediction is a local
rendering optimization only — it is never sent to the host as if authoritative,
and it is always subordinate to the next authoritative frame.

---

## 11. Multi-writer arbitration (the pen) & backpressure

### 11.1 The pen — wire-visible invariants `v1-frozen`; policy platform-defined

The OSS wire carries exactly these arbitration facts, and they are frozen:

- Everyone attached sees live `Output`. **Exactly one connection** — the
  **pen-holder connection**, keyed `(userId, jti)` (§ 6.1) — may write input at
  a time; all others are read-only. The pen belongs to a connection, not a
  user: the same user's second device is a different connection and does not
  inherit the pen.
- `penGeneration` is a monotonic counter the relay increments on **every** pen
  change. It is broadcast to all legs (`pen_granted` / `pen_revoked` /
  `pen_state`) so that non-holders can suppress predictive echo and mark their
  in-flight input stale. It is a **staleness guard, not an authorization
  credential** (§ 5) — input admission always also checks holder-connection
  identity.
- The relay forwards `Input` to the host only under the § 5 dual-condition
  admission rule. Stale input from a reconnecting previous holder is harmless
  by construction.
- `role` is a ceiling (§ 15): a `role: "viewer"` connection that sends `grab`
  is refused with `error.code = pen-denied` and can never escalate to writing
  over the wire. Taking the pen requires a driver-capable grant expressed as
  `role: "driver"` in the token.
- `pen_state` is pushed to every leg on join/reconnect (§ 7); the pen may
  change at any time, signaled only by `pen_granted` / `pen_revoked` /
  `pen_state`.

Everything else about the pen — grab eligibility beyond the role ceiling,
grab-with-notice vs approval, cooldowns, auto-release when a holder disconnects,
handoff, presence derivation — is **arbitration policy, platform-defined**:
`rensei-architecture/protocol/interactive-attach-v1-arbitration.md`. It rides
the opaque control-message registry of § 7 and can evolve without touching this
wire. The OSS standalone path (no relay) ships the trivial **single-local-driver
policy**: one local connection, stamped `"local"`, holds the pen for the life of
the attach (§ 5).

### 11.2 Backpressure — invariant `v1-frozen`, parameters `v1-draft`

- **Frozen invariant:** buffering toward any single viewer is **never unbounded**.
  A viewer that cannot keep up must never grow relay memory without limit and must
  never stall the host or other viewers (head-of-line isolation per viewer).
- **Frozen bound and terminal state:** the per-viewer send queue is bounded by
  the named parameter **`viewerSendQueueMaxBytes`** (value `v1-draft`; existence
  and enforcement frozen). A viewer whose queue overflows and for which even a
  catch-up `Snapshot` cannot be flushed is **disconnected** with
  `error.code = backpressure` — a slow consumer's terminal state is
  disconnection, never unbounded buffering.
- **Mechanism (`v1-draft`):** a per-viewer **token bucket**; when a slow viewer's
  bucket is exhausted, the relay **coalesces/drops** intermediate `Output` frames
  for that viewer and brings it current with a **fresh `Snapshot`** (§ 12)
  (requesting one with `snapshot_request.reason = "backpressure"` if needed)
  rather than queuing history. The bucket rate/burst and the drop-vs-snapshot
  threshold are draft (W5 tunes against measured traffic).

---

## 12. Snapshot authority & the outbound-only mandate — `v1-frozen`

- The **host-side headless VT is the single snapshot authority** (decision D3). The
  host consumes its own PTY output into a headless terminal emulator and can
  serialize the current screen (primary + alt buffer, cursor, SGR, bounded
  scrollback tail) into a `Snapshot` frame tagged with the host `seq` it reflects
  (`atSeq`). Neither the relay nor any viewer computes the authoritative screen.
- **The host VT is also the terminal-query responder.** When the PTY child
  emits a query whose terminal-standard effect is "the terminal replies on
  input" — CPR (`DSR CSI 6n`), DA (`CSI c` / `CSI >c`), DECRQSS, color/title
  queries — the host VT answers it **locally, directly to the PTY master**,
  exactly as a real attached terminal would. The query and its answer never
  reach the wire, and no viewer ever replies (§ 9). Without this, any TUI that
  probes its terminal hangs. This is W4 host scope with a conformance fixture:
  a child that emits `CSI 6n` receives a correct CPR.
- **`snapshot_request` is a relay → host `Control` frame carried on the host's
  own, already-open outbound stream.** The relay asks; the host answers with a
  `Snapshot` frame on the same outbound stream.
- **Outbound-only mandate invariant (stated explicitly):** the host exposes **no
  inbound listener** for attach of any kind. Everything the relay needs from the
  host — snapshots, applied resize, pen state effects, termination (`kill`) — is
  requested via `Control` frames the relay writes onto the connection **the host
  dialed out**, and answered on that same outbound connection. The relay never
  dials into the host. A design that adds a host-side listener to serve
  snapshots violates this protocol. This mandate governs the **relay attach
  path**; the OSS standalone local-attach surface is in-process or
  loopback-only (the existing localhost daemon control API) and is outside
  this mandate's scope.

### 12.1 `snapFormat = 0x01` byte layout — `v1-draft` (owned by the host VT)

The Snapshot envelope is frozen (§ 3.1); this payload layout is `v1-draft`,
authored now so W4 can emit and W7/W11 can decode, and format-tagged so it can
evolve behind a new `snapFormat` value without a protocol bump.

All multi-byte integers are varints (§ 2.1) unless marked `u8`.

```
snap := [epoch:varint]              ; host stream epoch this snapshot belongs to (§ 4.1)
        [echoMode:u8]               ; 0x00 = echo-off/raw, 0x01 = echo-on/cooked, 0xFF = unknown (§ 10)
        [cols:varint][rows:varint]  ; grid dimensions
        [activeBuffer:u8]           ; 0x00 = primary active, 0x01 = alt active
        [cursorRow:varint][cursorCol:varint]   ; 0-based, in the active buffer
        [cursorVisible:u8]          ; 0x00 hidden, 0x01 visible
        [cursorShape:u8]            ; 0x00 default, 0x01 block, 0x02 underline, 0x03 bar
        [modes:u8]                  ; terminal-modes bitmap (below)
        [mouseProto:u8]             ; mouse tracking protocol + encoding (below)
        [savedCursorRow:varint][savedCursorCol:varint]  ; primary-buffer cursor restored on ?1049 exit
        [primary: rows × cols cells, row-major]
        [altPresent:u8]             ; 0x00 = no alt buffer follows, 0x01 = alt buffer follows
        [alt: rows × cols cells, row-major]     ; only if altPresent = 0x01
        [sbLines:varint]            ; scrollback-tail line count (oldest first)
        { [cellCount:varint][cells...] } × sbLines

cell := [runeLen:varint][runeBytes: UTF-8]     ; runeLen = 0 permitted only on continuation cells
        [style:u8]                  ; bit flags below
        [fgMode:u8][fg...]          ; color encoding below
        [bgMode:u8][bg...]
```

- **Rune encoding: length-prefixed UTF-8** (not fixed-width UTF-32).
  Justification: terminal content is overwhelmingly single-byte — len-prefixed
  UTF-8 costs 2 bytes for an ASCII cell where UTF-32 costs 4; it matches the
  protocol's pervasive length-prefixed idiom; and a cell MAY carry a
  multi-codepoint grapheme cluster (ZWJ emoji, combining marks) in `runeBytes`,
  which fixed-width encoding cannot. `runeLen` counts bytes.
- **`modes` bit flags** (the terminal modes a viewer must know to render and
  to route driver input correctly): `0x01` bracketed paste (`?2004`) ·
  `0x02` application cursor keys (DECCKM) · `0x04` pending wrap (the
  autowrap "wrap on next glyph" state — required for exact cursor fidelity at
  the right margin) · `0x08` mouse tracking enabled · `0x10` focus-event
  reporting (`?1004`) · `0x20`–`0x80` reserved (MUST be 0).
- **`mouseProto`** — meaningful only when `modes & 0x08` is set; MUST be
  `0x00` otherwise. Low nibble = tracking mode: `0x1` = `?1000` (normal) ·
  `0x2` = `?1001` (highlight) · `0x3` = `?1002` (button-event) · `0x4` =
  `?1003` (any-event). High nibble = coordinate encoding: `0x0` = legacy
  X10 · `0x1` = `?1005` (UTF-8) · `0x2` = `?1006` (SGR). Example: SGR
  any-event tracking = `0x24`.
- **`savedCursor`** — the primary-buffer cursor position that will be restored
  when the alt screen exits (`?1049` restore semantics). When the primary
  buffer is active it equals the active cursor. Always present (fixed field —
  decoders never branch on buffer state to parse).
- **`style` bit flags:** `0x01` bold · `0x02` italic · `0x04` underline ·
  `0x08` reverse · `0x10` dim · `0x20` strikethrough · `0x40` wide-glyph
  continuation · `0x80` reserved (MUST be 0).
- **Colors** (`fgMode` / `bgMode`, each followed by its operand bytes):
  `0x00` default (no bytes) · `0x01` indexed-256 (`[idx:u8]`) · `0x02`
  truecolor (`[r:u8][g:u8][b:u8]`). A discriminated union, so indexed and
  truecolor cells coexist losslessly.
- **Wide glyphs:** the base cell carries the rune; the following cell sets the
  continuation flag (`style & 0x40`), carries `runeLen = 0`, and repeats the
  base cell's colors.
- **Scrollback tail:** line-framed, oldest first; each line is `cellCount`
  cells (lines may be shorter than `cols`). The tail is capped (cap value
  `v1-draft`, default 200 lines); it MUST be bounded. Alt buffers have no
  scrollback.
- **Escape-safe by construction (conformance requirement on the host VT
  serializer, § 9):** `runeBytes` MUST contain only printable content — no C0
  (0x00–0x1F), no DEL (0x7F), no C1, no ESC. A snapshot containing any such
  byte is non-conformant. Viewers additionally run the § 9 filter over any
  escape-bearing reconstruction they synthesize from a snapshot.

**Conformance fixture (authoritative for this layout revision).** A 2×1
primary-active screen in epoch 1, echo-on; cursor at row 0, col 1, visible,
block; no terminal modes set, no mouse tracking; saved primary cursor equal to
the active cursor (primary is active); cell 1 = `"A"` bold with indexed-256
foreground color 1 and default background; cell 2 = `" "` all-default; no alt
buffer; no scrollback:

```
snap bytes (26):
01 01 02 01 00 00 01 01 01    ; epoch=1 echoMode=on cols=2 rows=1 primary cursor(0,1,visible,block)
00 00                         ; modes=none  mouseProto=none
00 01                         ; savedCursor(row=0, col=1) — equals the active cursor
01 41 01 01 01 00             ; cell "A": runeLen=1 'A' style=bold fg=indexed(1) bg=default
01 20 00 00 00                ; cell " ": runeLen=1 ' ' style=0 fg=default bg=default
00                            ; altPresent=0
00                            ; sbLines=0
```

Wrapped in the frozen envelope at `atSeq = 42`:
`2A 01 1A` + the 26 bytes above (atSeq=42, snapFormat=0x01, snapLen=26).

### 12.2 Exit & teardown ordering — `v1-frozen`

- **Flush-before-Exit.** The host MUST drain the PTY master to EOF and emit
  every pending `Output` frame before emitting `Exit`. (This matches the
  existing PTY-harness precedent: drain → wait → terminal event.)
- **Exit is the final seq-bearing host frame.** Its `seq` is strictly greater
  than every preceding host frame's; after `Exit` the host MUST NOT emit any
  further `Output`, `Resize`, `Marker`, or `Exit`.
- **Post-Exit final screen.** The host MUST continue answering
  `snapshot_request` with the final screen until teardown. These post-Exit
  `Snapshot` frames are the single exception to "final frame": they carry
  header `seq = 0` (outside the output sequence, reusing the § 2 out-of-namespace
  convention) and `atSeq =` the `Exit` frame's `seq`. Receivers key snapshots
  on `atSeq`, so the zero header is inert. (This resolves the otherwise-circular
  "Exit is final, yet snapshots continue" requirement: the output sequence ends
  at Exit; post-Exit snapshots live outside it.)
- **Exit code convention.** Normal exit: `exitCode` = the process exit code,
  `signal` empty. Signal death: `signal` = the signal name (e.g. `"SIGKILL"`)
  and `exitCode = 128 + signum` (e.g. 137). The varint `exitCode` therefore
  always encodes the effective shell-convention code.
- **Teardown.** After `Exit`, the host holds the outbound stream open for a
  bounded final-screen window (duration `v1-draft`), then closes it. The relay's
  post-Exit room window is relay policy (§ 7 `room_state` notes).
- `kill` (§ 7) enters this same flow: terminate the process group → drain →
  `Exit` (with the death signal per the convention above).

---

## 13. Resume — `v1-frozen`

- The relay keeps a bounded, seq-keyed **ring buffer** of host output frames for
  the **current room generation** (§ 4.1). The ring is contiguous by
  construction: on a mid-epoch host-reconnect delivery gap the relay truncates
  and restarts the ring after the gap (§ 4.1), so no resume can silently span a
  gap.
- On (re)connect a viewer sends `resume_from` (or `subscribe` with
  `resumeFrom`) carrying the highest host `seq` it has applied and the epoch it
  observed (from the last applied `Snapshot`'s epoch field, § 12.1). The relay:
  - **ring hit** (same epoch, requested `seq` still buffered, and `seq + 1`
    onward contiguous in the ring) → replays buffered frames from `seq + 1`,
    then live tail.
  - **ring miss** (requested `seq` evicted, `seq > ` the current `atSeq`,
    `epoch` ≠ the current room generation, or `epoch` absent) → **snapshot +
    tail** (below).
- **`resumeFrom` null ≡ 0 ≡ "no applied history"** → always snapshot + tail.
  `seq = 0` never addresses a buffered frame (the host sequence starts at 1).
- **Snapshot + tail contiguity invariant (frozen).** When serving a join or a
  ring miss, the relay MUST NOT deliver a `Snapshot` unless at least one of:
  1. the frame `snapshot.atSeq + 1` is still in the ring, **or**
  2. no frame later than `atSeq` exists yet — the snapshot is current with the
     stream head, and the tail is (for now) empty, **or**
  3. `atSeq` equals the final `Exit` frame's `seq` — the stream has ended and
     no tail will ever follow (the permanent, post-Exit `ended` case of 2).

  The tail then starts **exactly at `atSeq + 1`** (empty in cases 2–3 until —
  in case 2 — later frames exist). If `atSeq + 1` has been evicted by the time
  the snapshot would be served, the relay requests a newer `Snapshot` and
  retries, looping until snapshot and tail are contiguous. A non-contiguous
  handoff — a stale cached snapshot with a gap to the tail — is
  **non-conformant**: it silently corrupts the viewer screen with no error
  signal.
- Resume cost is therefore **O(1) in session age** — a viewer joining a 2-hour
  session never replays 2 hours of bytes; it gets the current screen + tail.
- **Relay restart:** the ring and pen state are relay-local; after a relay
  restart every viewer resume is a ring miss and resolves as snapshot + tail
  once the host leg re-attaches. This is the designed repair path, sound
  because ring misses are always safe (they cost a snapshot, never
  correctness).
- Ring-buffer depth and any persistence for surviving a relay restart are relay
  policy (draft); the resume **contract** above is frozen.

---

## 14. Degraded SSE fallback lane — `v1-draft` (first-class; frozen sub-rules marked)

When WSS is unavailable (handshake blocked, Upgrade stripped by a proxy, or the
live stream declared dead after N failed reconnects within a window), the client
**auto-falls-back** to a degraded lane. This lane is a **first-class** transport,
built against the same framing (§ 2) and the same event/control semantics — only
the carrier changes. **It carries both viewer legs and the host leg**: the
WSS-hostile network the lane exists for is at least as likely to sit in front
of the daemon (the BFSI case) as in front of a viewer. Batching sizes and
timers are `v1-draft`; the contract rules below marked **frozen** are
`v1-frozen`.

**Endpoint derivation (frozen).** Given the attach URL
`ATTACH_URL = wss://<host>/<path>` (whose `<path>` contains the `/v1/` version
segment, § 1), the degraded endpoints are derived mechanically — never
separately configured:

- scheme map: `wss → https` (and `ws → http` for local development);
- viewer **SSE-down:** `https://<host>/<path>/sse`
- viewer **POST-up:** `https://<host>/<path>/input`
- host **SSE-down:** `https://<host>/<path>/host/sse`
- host **POST-up:** `https://<host>/<path>/host/output`

The `/v1/` path segment is the degraded lane's version carrier (§ 1) — with a
room path of `/v1/rooms/<roomId>`, the host endpoints are
`/v1/rooms/<roomId>/host/sse` and `/v1/rooms/<roomId>/host/output`.

**Auth carriage (frozen).**

- **Native clients** set `Authorization: Bearer <jwt>` on both legs (the SSE
  GET and every POST).
- **Host legs are always native** (hosts are never browsers): `Authorization`
  header on both host legs, no query-parameter carriage. The same `jti` and
  `epoch` rules as the WSS lane apply unchanged (§ 6.2, § 15).
- **Browsers:** `EventSource` can set neither headers nor subprotocols, so the
  browser SSE-down leg authenticates with a **short-lived, single-use
  `?access_token=<jwt>` query parameter**, verified identically to header
  carriage with the same `jti` accounting. Token-in-URL caveat: URLs leak into
  logs — the relay MUST NOT log (or MUST redact) the query string of `/sse`
  requests, and the token's `exp` MUST be short. The browser POST-up leg uses
  the `Authorization` header (`fetch` can set headers).
- **Leg correlation (frozen):** the SSE-down leg and the POST-up requests MUST
  present the **same token (same `jti`)** — together they form **one logical
  connection** `(userId, jti)` (§ 6.1). Presenting different tokens on the two
  legs splits the connection identity and is rejected.

**Downstream (relay → viewer): Server-Sent Events.**
- The relay serves an SSE stream; each event is one base64-encoded binary frame:
  `event: frame` / `data: <base64(frame)>`. Host-produced frames arrive in host
  `seq` order; relay-originated Control (`presence`, `pen_*`, `room_state`,
  `input_ack`, `error`) interleaves among them.
- **Resume-position carriage:** the SSE GET carries the viewer's resume
  position as `?resume_from=<seq>&epoch=<epoch>` query parameters (alongside
  `access_token` for browsers); native clients MAY carry the equivalent in
  request headers. `EventSource` cannot send a `subscribe` Control before the
  stream opens, so the resume position must ride the GET; § 13 semantics
  (including null ≡ 0) apply unchanged.
- A `: heartbeat` comment every 15 s defeats idle-proxy timeouts.
- Snapshot/resume work identically — the first SSE event after (re)connect is the
  `Snapshot` (or the replayed tail) the relay chose per § 13.

**Upstream (viewer → relay): batched HTTP POST.**
- The viewer POSTs a batch envelope carrying `Input` frames and, separately,
  `Control` messages:
  ```json
  { "batchId": "<unique-id, stable across retries>",
    "firstInputSeq": <int>, "lastInputSeq": <int>,
    "inputs":   [ "<base64(Input frame)>", ... ],
    "controls": [ "<base64(Control frame)>", ... ] }
  ```
- **Ordering (frozen for inputs):** `inputs` are in contiguous `inputSeq` order,
  and a batch's `firstInputSeq` MUST equal `lastAck + 1`. A batch that opens a
  gap is rejected whole (nothing applied, `batchId` unconsumed) with the current
  ack so the client resends from `lastAck + 1`. This preserves the § 5
  contiguity guarantee across the POST carrier.
- **Controls ride outside the contiguity rule (frozen).** `Control` messages
  have no `inputSeq`; they travel in the `controls` array, are processed in
  array order when the batch is accepted, and are **not covered by
  `ackInputSeq`** — acks cover inputs only. A batch MAY be control-only
  (`inputs: []`, `firstInputSeq`/`lastInputSeq` omitted; the contiguity check is
  skipped). Idempotency for controls comes from `batchId` dedup.
- **POST response taxonomy (frozen):**
  - `200` `{ "batchId": "<echoed>", "ackInputSeq": <highest contiguous inputSeq applied and forwarded> }` — success; advance the send window.
  - `409` `{ "batchId": "<echoed>", "ackInputSeq": <current ack> }` — gap; the batch was rejected whole; resend from `ackInputSeq + 1`.
  - `401` — token invalid/expired; re-mint (§ 15) and retry.
  - `429` — backpressure/rate limit; back off (honor `Retry-After`).
- **Retry / idempotency (frozen):** `batchId` is a jti-style unique batch
  identifier. The relay de-duplicates by `batchId` **and** by
  `(connection, inputSeq)`; re-POSTing a batch with the same `batchId` after a
  timeout is a no-op that returns the same ack. The client retries with the
  **same** `batchId` — never a new one — so a lost response can never
  double-apply keystrokes.
- **One `inputSeq` space across carriers (frozen).** A connection has exactly
  one `inputSeq` counter for the life of the attach; switching WSS ↔ degraded
  MUST NOT reset it (§ 4). A client that restarts `inputSeq` on carrier switch
  corrupts its own ordering guarantee.
- **penGeneration admission** (§ 5) and **relay-stamped userId** (§ 5) apply
  unchanged: the POST is authenticated and the relay stamps `userId`; input
  failing the dual-condition admission rule is dropped exactly as on the WSS
  lane.

**Host leg on the degraded lane — `v1-draft`.** The host's shape mirrors the
viewer's with the directions inverted (the host *produces* the seq-bearing
stream and *consumes* relay-originated frames):

- **Host POST-up (`…/host/output`):** the host POSTs batch envelopes of its
  seq-bearing frames — `Output`, applied `Resize`, `Marker`, `Exit`,
  `Snapshot` — keyed by **host `seq`**:
  ```json
  { "batchId": "<unique-id, stable across retries>",
    "firstSeq": <int>, "lastSeq": <int>,
    "frames":   [ "<base64(host frame)>", ... ],
    "outOfSeq": [ "<base64(Control or post-Exit Snapshot)>", ... ] }
  ```
  The rules mirror the viewer batch exactly: `frames` are in contiguous host
  `seq` order and `firstSeq` MUST equal `lastAck + 1`; a gap-opening batch is
  **rejected whole** (nothing applied, `batchId` unconsumed); `batchId`
  idempotency and same-`batchId` retry apply unchanged; the ack is the
  **highest contiguous host `seq`** the relay has applied
  (`200 { "batchId", "ackSeq" }` / `409 { "batchId", "ackSeq" }` / `401` /
  `429` — the § "POST response taxonomy" with `ackSeq` in place of
  `ackInputSeq`). Out-of-namespace frames (host Control such as `subscribe`
  and `error`, post-Exit `Snapshot` replies) ride `outOfSeq`, outside the
  contiguity rule and uncovered by the ack. One host `seq` space across
  carriers, exactly as § 4/§ 4.1 — switching carriers never resets it.
- **Host SSE-down (`…/host/sse`):** delivers the relay-originated frames the
  host would receive on WSS — stamped `Input`, authoritative `Resize`,
  `snapshot_request`, `kill` — all under the § 2 zeroed-header rules,
  unchanged. Delivery is **at-least-once** (an SSE reconnect may replay);
  the host MUST handle each idempotently with these keys:
  - `Input` — de-duplicate by `(userId, jti, inputSeq)`; a repeat is dropped,
    never written to the PTY twice.
  - `snapshot_request` / `kill` — safe to repeat by construction (a second
    snapshot answer is harmless; a second kill of a dead process group is a
    no-op).
  - `Resize` — last-writer-wins; applying the same geometry twice is
    idempotent at the `TIOCSWINSZ` level.
- **Room state signaling:** while the host leg rides this carrier the relay
  emits `room_state: "degraded"` to viewers (§ 7) — the room is live at
  higher latency. The host's auto-fallback and upgrade-back triggers are the
  same as the viewer's (below); on upgrade-back the relay de-duplicates
  upstream frames by `batchId` and host `seq` during the overlap.
- **W4 scope note:** the OSS generic attach client implements this host lane
  **behind the same attach interface** as the WSS lane — carrier fallback is
  invisible to the PTY host core (this is already a W4 plan requirement; the
  degraded lane is what makes "no VPN" true on WSS-hostile networks).

**Auto-fallback triggers & upgrade-back:**
- **Trigger down:** the WSS handshake fails, or the live WSS stream produces no
  frame and no pong within the reconnect window after N attempts (N and the window
  are draft). The client switches to SSE-down + POST-up transparently; session
  identity, `sessionId`/room, connection identity (same token/jti when within
  `exp`, § 15), and both sequence spaces are preserved.
- **Upgrade back:** the client periodically re-attempts the WSS handshake in the
  background. On success it `resume_from`s the last applied host `seq`, drains and
  awaits acks for any in-flight POST batches (dedup by `batchId` covers upstream
  overlap), then stops POSTing and closes the SSE leg. **Downstream overlap
  dedup (frozen):** while both carriers are briefly live, the client MUST
  de-duplicate downstream frames by host `seq` — a frame already applied from
  one carrier is discarded on the other. Predictive echo (§ 10) stays
  `SUPPRESSED` on the degraded lane unless the client can meet predicate `P`
  with acceptable POST latency (draft; default: predict only on WSS).

---

## 15. Auth — `v1-frozen`

- Attach is authorized by a **short-lived, per-session JWT** minted by the
  platform control plane when a user starts viewing/driving a session, or when
  a host process starts hosting one.
- **Frozen claim set (exactly these claims):**
  ```json
  {
    "sessionId": "<the session/PTY id — platform-UUID namespace>",
    "roomId":    "<the relay room; MUST equal sessionId>",
    "userId":    "<verified end-user id — the value the relay stamps onto Input; ABSENT on role:host tokens>",
    "role":      "host" | "driver" | "viewer",
    "epoch":     "<host stream epoch (§ 4.1) — REQUIRED on role:host tokens, ABSENT on others>",
    "orgId":     "<tenant id — the relay room key is (orgId, sessionId)>",
    "iat":       "<unix-seconds mint time>",
    "exp":       "<unix-seconds, short-lived>",
    "aud":       "relay",
    "jti":       "<per-connection nonce — single-use for initial room admission>"
  }
  ```
  `iat` is included deliberately: it costs nothing and lets the relay measure
  token age for observability and anomaly detection. `nbf` is deliberately
  absent: attach tokens are minted for immediate use; `iat` + a short `exp`
  bound the validity window, and `nbf` would only add a clock-skew failure mode
  with no security win at these lifetimes.
- **Host-token posture.** A `role: "host"` token carries `sessionId`, `roomId`,
  `role`, `epoch`, `orgId`, `iat`, `exp`, `aud`, `jti` — and **no `userId`**:
  the host is not an end-user principal and can never be stamped onto `Input`
  (§ 5). The control plane assigns `epoch` at mint, monotonic per
  host-process-start for the session; a re-mint for the same still-running host
  process preserves the epoch, a mint for a new host process assigns a strictly
  higher one (§ 4.1). The relay admits at most one live `role: "host"` leg per
  room (§ 6.2).
- **Dedicated relay signing key (asymmetric).** The token is signed with a key
  **dedicated to the relay** — never the platform's shared session/service secret.
  Asymmetric is mandated: the platform holds the private key, the relay holds
  **only the public key**, so a relay compromise cannot mint tokens. **The
  signing `alg` is pinned to exactly `EdDSA` (Ed25519).** The relay MUST reject
  every other value — `none`, all `HS*`, all `RS*`/`PS*`, all `ES*` — as a
  rejection, not a fallback (RFC 8725: one key, one algorithm, no negotiation).
- **Clock skew.** The relay applies at most **5 seconds** of leeway when
  evaluating `exp`. No other claim gets leeway.
- **Audience.** The relay MUST reject any token whose `aud` claim is not
  exactly `"relay"`.
- **`jti`: single-use at initial admission; re-presentable for
  reconnect-with-resume.** Precisely:
  - On a connection's **initial room admission** the relay records the `jti` as
    consumed (keyed `(jti, "admitted")`) until the token's `exp`, and refuses
    any other initial admission with the same `jti`. A token replayed to join
    fresh — by another party, or after revocation — fails.
  - A **reconnect** within the same token's `exp` MAY re-present the same
    token: the relay permits a consumed `jti` **only** for a reconnect
    (`subscribe`, with **any** `resumeFrom` value **including null**) for the
    **same** `(userId, sessionId)` — for host legs, the same
    `(sessionId, epoch)` — as the original admission. Eligibility is
    **identity-based, not resume-based**: an applied-nothing viewer reconnect
    (`resumeFrom: null`) and a re-dialing host both qualify. At most one live
    logical connection per `jti`: on the degraded lane the SSE-down leg plus
    its POST-up requests are that one logical connection (§ 14); a second
    concurrent live leg presenting the same `jti` is rejected.
  - **Residual replay bound (documented, accepted):** within `exp`, an attacker
    who exfiltrates a token could race the legitimate client's reconnect; this
    is bounded by TLS everywhere, the short `exp`, the one-live-connection
    rule, and the same-identity resume constraint. A **relay restart** clears
    the in-memory consumed-`jti` store and reopens the *initial-admission*
    window until `exp` — `exp` MUST therefore be short enough that this window
    is acceptable, or the consumed-`jti` store moves to the relay's ephemeral
    keyspace if `exp` is ever lengthened (relay policy, draft).
- **Room binding.** The relay MUST verify `sessionId == roomId == the room being
  joined`. `roomId` is in the **platform-UUID namespace and globally unique**;
  the relay's room key is **`(orgId, sessionId)`**, and the relay MUST scope
  every room and all fan-out by the owning `orgId`, rejecting any token whose
  `orgId` does not match the room's — two tenants presenting the same
  session-id string can never share a room. Both `sessionId` and `roomId` are
  kept deliberately (they are equal by rule): `sessionId` names the session in
  the platform namespace, `roomId` names the relay room resource that appears
  in the attach URL path, and the relay checks path-room == `token.roomId` ==
  `token.sessionId` — a cross-field integrity check that survives URL
  manipulation and copy-paste mistakes at zero cost.
- **`role` is a ceiling.** `role: "viewer"` can never be promoted to driver over
  the wire (§ 11.1); `role: "driver"` grants driver capability (still subject to
  the § 5 admission rule); `role: "host"` is accepted only on the host leg and
  admits none of the viewer/driver behaviors (§ 6.3).
- **Header carriage vs subprotocol slot (the three-client asymmetry):**
  - **Native clients** (the Go host, the iOS viewer) set
    `Authorization: Bearer <jwt>` on the WSS handshake **and** offer the
    `interactive-attach-v1` version subprotocol.
  - **Browsers** cannot set handshake headers. The browser offers **two**
    subprotocol tokens: `interactive-attach-v1` (version) **and** a **distinct**
    auth slot `bearer.<base64url(jwt)>`. The relay reads the bearer slot, verifies
    it, and echoes back **only** `interactive-attach-v1` — never the bearer token.
    The auth slot is deliberately separate from version negotiation so the two
    never collide.
  - **Degraded lane:** § 14 (native: `Authorization` header on both legs;
    browser SSE-down: single-use `?access_token=` query parameter; POST-up:
    header; same `jti` on both legs).
- **Lifecycle.** The WSS connection may outlive the JWT; **reconnect-with-resume
  is the refresh path** — the one and only one. Within `exp` a reconnect
  re-presents the same token under the `jti` rule above; at or after `exp` the
  client reconnects with a freshly-minted token (new `jti`) and resumes. There
  is **no in-band re-authentication message** (§ 7's frozen set contains none,
  deliberately) — a design that "refreshes" a live connection's identity
  mid-stream is out of v1. Token minting is a platform concern; the claim set,
  key posture, `jti` rules, room binding, and carriage above are frozen here.

---

## 16. Parallel recording (asciinema v2) — `v1-draft`

Independently of the live protocol, the host MAY emit a parallel **asciinema v2**
cast of the session (the `Output` stream + `Resize`/`Marker` events with their
`rel_time`s) for later replay and audit. This is **out of the wire scope** of this
spec — it is a host-emitted, side-channel artifact, not a frame type on the attach
stream — but it is called out here so W4/W5 keep the live path and the durable
record aligned: the cast and the wire share the **same `rel_time` epoch anchor
(process spawn, § 2)** and the same marker labels. Retention, access, redaction,
and per-org opt-out for recordings are platform policy (see the platform ADR and
the D13 relay-data-residency ruling).

---

## Appendix A — conformance checklist (for W4/W5 sign-off)

- [ ] Varint encode/decode reproduces every § 2.1 fixture exactly; overflow AND
      truncation both map to `error.code = framing`.
- [ ] Event-type byte values (§ 3) pinned; unknown type → framing error.
- [ ] Two sequence namespaces kept distinct (§ 4); input attributed by
      `(userId, inputSeq)` per connection; every out-of-namespace frame (all
      Control in every direction, non-host-produced Resize) carries
      seq=0/rel_time=0 and receivers ignore both header fields.
- [ ] Host stream epoch (§ 4.1): seq/rel_time continuous within an epoch across
      WSS reconnects; new epoch → new room generation, seq restarts at 1, ring
      discarded, forced Snapshot; prior-epoch/absent-epoch resume = ring miss.
- [ ] Host-leg CAS on (sessionId, epoch) (§ 6.2): equal-epoch duplicate while a
      live leg is bound → `epoch-stale` reject; higher epoch supersedes and
      closes the old leg; vacant-binding equal-epoch re-dial resumes.
- [ ] `Input` `userId` is relay-stamped; host rejects unstamped input; input
      admission is dual-condition (current `penGeneration` AND sender connection
      is the pen-holder connection) (§ 5).
- [ ] Admission matrix (§ 6.3) enforced: frame-type violations close with
      `framing`; mis-routed known Control ignored; host receives only
      snapshot_request/kill/error.
- [ ] Every § 7 control message round-trips, including `kill`, `room_state`,
      `pen_state`; unknown fields ignored; `pen_state` pushed on every
      join/reconnect; `room_state` on every host-leg transition.
- [ ] Host applies relay `Resize` verbatim; no host-side clamp; cols/rows == 0
      → framing error (§ 8).
- [ ] Sanitization allowlist (§ 9) enforced identically relay/web/iOS against
      the hostile-sequence corpus **including the split-at-every-interior-byte
      variants**; sanitizer state carries across frame boundaries; dangling
      introducers held pending and STRIPPED at `sanitizerHoldMaxBytes`; scope
      covers Snapshot-reconstructed bytes; UI-rendered protocol strings
      (Marker labels, error.message, presence names) length-capped and
      control-char-stripped.
- [ ] snapFormat 0x01 (§ 12.1) reproduces the 26-byte conformance fixture
      byte-for-byte incl. modes/mouseProto/savedCursor; serializer emits no
      C0/ESC bytes in `runeBytes`; `echoMode` populated.
- [ ] Host VT answers CPR/DA/DECRQSS locally to the PTY master (§ 12); fixture:
      child probing `CSI 6n` receives a correct CPR; no query reply on the wire.
- [ ] Predictive-echo state machine (§ 10) suppresses on alt-screen / IME /
      pen-loss / unknown-or-off `echoMode` and rolls back on mismatch; never
      predicts without a Snapshot-confirmed echo-on.
- [ ] Exit ordering (§ 12.2): flush-before-Exit; Exit final seq-bearing frame;
      post-Exit snapshots carry seq=0 with atSeq=Exit.seq; signal death encodes
      `exitCode = 128 + signum` + signal name; `kill` → process-group
      termination → Exit.
- [ ] Backpressure never buffers unboundedly (§ 11.2); overflow terminal state
      is disconnect with `error.code = backpressure`.
- [ ] Resume (§ 13): ring hit replays from `seq+1`; ring miss → snapshot + tail
      with the frozen `atSeq+1` contiguity invariant (loop until contiguous);
      `resumeFrom` null ≡ 0.
- [ ] Degraded lane (§ 14): endpoints derived from ATTACH_URL (scheme map +
      `/sse` `/input` and `/host/sse` `/host/output` suffixes, `/v1/` version
      segment); auth carriage per client class (host legs header-only); same
      jti on both legs; SSE GET carries `?resume_from=&epoch=`; batch envelope
      with out-of-band controls; acks cover inputs only; POST taxonomy
      200/409/401/429; one `inputSeq` space across carriers; upgrade-back
      dedups downstream by host `seq`.
- [ ] Host leg on the degraded lane (§ 14): host-seq-keyed POST batches
      (contiguity, rejected-whole on gap, batchId idempotency, ackSeq);
      `outOfSeq` array for Control + post-Exit Snapshot; SSE-down
      at-least-once with idempotent handling — Input by (userId, jti,
      inputSeq), kill/snapshot_request repeat-safe, Resize last-writer-wins;
      `room_state:"degraded"` emitted to viewers while the host is on this
      carrier; same host `seq` space across carriers.
- [ ] JWT (§ 15): frozen claim set incl. `iat` + host `epoch`; role enum
      host/driver/viewer with host-token posture (no userId); dedicated
      asymmetric relay key; `alg` exactly `EdDSA`; ≤5 s exp leeway; `aud` ≠
      "relay" rejected; jti single-use-at-admission + identity-based
      re-presentation (any resumeFrom incl. null);
      room key (orgId, sessionId) with orgId-mismatch rejection;
      `sessionId == roomId == joined room`; header vs subprotocol carriage;
      no in-band reauth.
