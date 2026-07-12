---
title: interactive-attach-v1 — interactive PTY session attach wire protocol
status: Proposed
date: 2026-07-12
protocol-version: interactive-attach-v1
boundary: OSS-only
derived-from: asciinema ALiS live-stream protocol (shape only; NOT byte-compatible)
normative-for: donmai (PTY session host + framing library + generic attach client), the relay, web viewers, iOS viewers
sign-off:
  W4-owner: pending
  W5-owner: pending
---

# interactive-attach-v1 — interactive PTY session attach wire protocol

**Status:** Proposed
**Date:** 2026-07-12
**Protocol version:** `interactive-attach-v1`
**Normative for:** the OSS PTY session host and framing library in `donmai`, the
relay, and every viewer (web, iOS).
**Owning ADR:** [`../ADR-2026-07-12-interactive-pty-session-host.md`](../ADR-2026-07-12-interactive-pty-session-host.md)
(execution-layer contract). Platform extensions (relay service, control plane,
quotas, iOS client) live in the mirrored platform ADR
`rensei-architecture/ADR-2026-07-12-interactive-sessions-platform.md`.

## Sign-off (required before this spec leaves `Proposed`)

| Wave | Owner responsibility | Sign-off |
|---|---|---|
| **W4** | runner / PTY host + generic attach client implement the host side of every `v1-frozen` section | **pending** |
| **W5** | relay + control plane implement the relay side of every `v1-frozen` section | **pending** |

A `v1-frozen` section is not "done" until both owners have signed. A `v1-draft`
section may be amended by its owning wave via PR to this file **with the sign-off
cell updated in the same PR** — never silently.

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
  frozen rule rather than tolerate it.
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
- **`rel_time`** — unsigned varint; microseconds since the producer's stream epoch
  (the producer's first frame carries `rel_time = 0`). Monotonic non-decreasing
  within a producer. Used for replay pacing and recording; never for security
  decisions.
- **`payload`** — type-specific bytes (§ 3). Length is the remainder of the
  WebSocket frame; the framing does not repeat a total length because WebSocket
  already delimits the message.

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
  legal top bit, is a framing error → the receiver MUST close the connection with
  an `error` control message (§ 7) code `framing`.

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
| `0x03` | **Resize** | viewer → relay (advertise) / relay → host (authoritative) | terminal geometry (policy hook, § 8) |
| `0x04` | **Marker** | host | asciinema-style annotation label |
| `0x05` | **Exit** | host | process exit code + optional signal name |
| `0x06` | **Snapshot** | host | current-screen snapshot at a sequence (§ 12) |
| `0x07` | **Control** | any | JSON control-plane message (§ 7) |

### 3.1 Payload layouts — `v1-frozen`

All lengths are varints; all byte fields are raw (no NUL termination).

- **Output** `0x01`: `[data:bytes]` — the remainder of the frame is terminal
  output. On the **host→relay** leg these are the raw PTY master bytes. On the
  **relay→viewer** leg they MUST have passed the § 9 sanitization allowlist.
- **Input** `0x02`: `[inputSeq:varint][penGeneration:varint][userIdLen:varint][userId:bytes][dataLen:varint][data:bytes]`
  — see § 5 for field semantics and the relay-stamping rule.
- **Resize** `0x03`: `[cols:varint][rows:varint][pxWidth:varint][pxHeight:varint]`
  — `pxWidth`/`pxHeight` MAY be `0` when unknown. Direction-dependent meaning in § 8.
- **Marker** `0x04`: `[labelLen:varint][label:bytes]` — a UTF-8 annotation for
  recording/replay; display-only, never executed.
- **Exit** `0x05`: `[exitCode:varint][signalLen:varint][signal:bytes]` — the PTY
  child exited. `signal` is the empty string for a normal exit.
- **Snapshot** `0x06`: `[atSeq:varint][snapFormat:u8][snapLen:varint][snap:bytes]`
  — the screen as of host output sequence `atSeq` (§ 12). The envelope
  (`atSeq` + `snapFormat` + length) is **`v1-frozen`**; the `snap` serialization
  for a given `snapFormat` is **`v1-draft`** (VT-owned, format-tagged so it can
  evolve without a version bump). `snapFormat = 0x01` = VT-serialized screen
  (primary + alt buffer, cursor, SGR, bounded scrollback tail).
- **Control** `0x07`: `[jsonLen:varint][json:bytes]` — one UTF-8 JSON object whose
  `type` field selects the message (§ 7).

---

## 4. Sequence namespaces — `v1-frozen`

There are **two** independent monotonic sequence spaces. Conflating them is the
defect this section exists to prevent.

- **Host output sequence** — assigned by the host to every host-produced frame
  (`Output`, `Resize` it applied, `Marker`, `Exit`, `Snapshot`). Starts at `1`,
  strictly increasing by 1 per host frame. This is the space the relay ring buffer
  is keyed on and the space `resume_from` addresses (§ 13).
- **Viewer input sequence (`inputSeq`)** — assigned by each viewer to its own
  `Input` frames. Per-viewer, starts at `1`, strictly increasing by 1 per input.
  Acknowledged independently per viewer via the `input_ack` control message (§ 7).

An `Input` frame's **header `seq`** is NOT an input sequence — it is the host
output sequence the viewer had applied when it produced the keystroke (the
reconciliation anchor for predictive echo, § 10). The viewer's own ordering lives
in the payload `inputSeq`. The relay MUST attribute, order, and de-duplicate input
by `(userId, inputSeq)`, never by the header `seq`.

---

## 5. Input frames — `v1-frozen`

`Input` payload: `[inputSeq:varint][penGeneration:varint][userIdLen:varint][userId:bytes][dataLen:varint][data:bytes]`

- **`inputSeq`** — the producing viewer's monotonic input sequence (§ 4).
- **`penGeneration`** — the pen generation the viewer believes it holds
  (§ 11). The relay MUST drop any `Input` whose `penGeneration` is not the current
  server-authoritative generation (stale input from before a reconnect or a pen
  change) and MUST NOT forward it to the host. Dropped input is not an error; the
  relay MAY inform the viewer via a `pen_revoked` control message.
- **`userId`** — **relay-stamped, never client-supplied.** A viewer MUST send
  `Input` with `userIdLen = 0`. On receipt the relay verifies the sender's token
  (§ Auth), stamps the verified `userId`, and re-emits the frame toward the host
  with `userId` populated. Any `userId` bytes a client puts on the wire are
  ignored and overwritten. The **host MUST reject** any `Input` arriving with
  `userIdLen = 0` — an unstamped input frame never reaches the PTY. This makes
  every keystroke that touches the PTY attributable to a verified user for audit.
- **`data`** — the already-encoded terminal input bytes (UTF-8 text and/or the
  escape sequences a terminal emits for special keys). The host writes `data`
  verbatim to the PTY stdin sink; it is NOT re-sanitized (input to a PTY is the
  user's own; the sanitization allowlist governs **output** toward viewers, § 9).

**Input acknowledgement.** The relay sends each viewer an `input_ack` control
message (§ 7) carrying the highest **contiguous** `inputSeq` it has accepted and
forwarded for that viewer. A gap (a missing `inputSeq`) freezes the ack at the
last contiguous value; the viewer resends from `ack + 1`. This is the ordering
guarantee predictive echo and the degraded lane both build on.

---

## 6. (reserved)

*Section intentionally reserved so § numbers align with the control-message and
policy sections that waves cross-reference.*

---

## 7. Control-plane messages — message SET `v1-frozen`, individual fields `v1-draft`

Control messages ride inside `Control` frames (`type 0x07`) as a single JSON
object with a `type` discriminator. **The set of message `type` values below is
`v1-frozen`** — adding or removing a message is a protocol-version bump. **Adding
an optional field to an existing message is `v1-draft`** — the owning wave may do
it via PR; receivers MUST ignore unknown fields (forward-compatibility).

| `type` | Direction | Purpose | Shape (v1 fields) |
|---|---|---|---|
| `subscribe` | viewer → relay | join a room | `{ "type":"subscribe", "sessionId":str, "asRole":"viewer"\|"driver", "resumeFrom":int\|null, "viewport":{"cols":int,"rows":int} }` |
| `resume_from` | viewer → relay | request replay from a sequence | `{ "type":"resume_from", "seq":int }` |
| `snapshot_request` | relay → host | ask the host to emit a `Snapshot` | `{ "type":"snapshot_request", "reason":"join"\|"resync"\|"ring-miss" }` |
| `grab` | viewer → relay | take the pen | `{ "type":"grab" }` |
| `release` | viewer → relay | drop the pen | `{ "type":"release" }` |
| `presence` | relay → viewers | roster changes | `{ "type":"presence", "op":"join"\|"leave"\|"list", "members":[{"userId":str,"role":str,"driving":bool}] }` |
| `input_ack` | relay → viewer | ack highest contiguous `inputSeq` | `{ "type":"input_ack", "ackInputSeq":int }` |
| `pen_granted` | relay → all | pen assigned | `{ "type":"pen_granted", "userId":str, "penGeneration":int }` |
| `pen_revoked` | relay → all | pen lost/stale | `{ "type":"pen_revoked", "userId":str, "penGeneration":int }` |
| `error` | any → any | typed error | `{ "type":"error", "code":str, "message":str, "retryable":bool }` |

Notes that are themselves `v1-frozen`:

- `snapshot_request` is a **relay → host Control frame carried on the host's
  existing outbound stream** — never a request the relay makes to a host-side
  listener (§ 12).
- `subscribe.asRole = "driver"` is a **request** for the pen, honored only if the
  token grants driver capability (§ 11); a viewer token that asks for `driver` is
  admitted as a viewer and refused the pen.
- `error.code` values in v1: `framing`, `auth`, `room-mismatch`, `pen-denied`,
  `ring-miss`, `backpressure`, `rate-limited`, `internal`. The code set is
  `v1-draft` (extendable); the `error` message itself is frozen.

---

## 8. Resize is a policy hook — hook `v1-frozen`, clamp policy out-of-spec

Resize is a **hook**, not a fixed geometry rule.

- **Viewer → relay `Resize`** = a viewport advertisement: "this viewer can display
  `cols`×`rows`." Advisory input to the relay's policy.
- **Relay → host `Resize`** = the **authoritative** geometry. The host applies it
  **verbatim** to the PTY (`TIOCSWINSZ`) with no second-guessing. The host never
  computes geometry from viewer advertisements itself.
- **Frozen (the hook):** the host applies exactly the geometry the relay tells it;
  `Resize` is the sole carrier of geometry in both directions.
- **Out of spec (the policy):** the function mapping the set of attached viewer
  viewports → the one authoritative geometry (e.g. clamp to the smallest viewer,
  clamp to the driver's viewport, an operator-pinned size) lives **in the relay**
  and MAY change without a protocol revision. The known pathology of a naive
  "smallest viewer" clamp (a phone shrinks everyone) is a policy problem the relay
  owns, deliberately kept out of the frozen wire so it can be fixed without a v2.

---

## 9. Terminal-escape sanitization allowlist — `v1-frozen`

Output bytes originate in an **untrusted** process (an agent's PTY running
arbitrary commands over attacker-influenceable repository content). Before Output
reaches any viewer (web/xterm.js, iOS/libghostty), it MUST pass this allowlist.
Enforcement is **identical** at the relay and at every viewer — a viewer MUST NOT
assume the relay sanitized, and the relay MUST NOT assume the viewer will. Defense
in depth: both apply it.

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
| Cursor-position / device-attributes / status **reports** | `DSR` `CSI 6n`, `DA` `CSI c`, `CSI >c` | **strip at viewer** | the host VT answers these; a viewer that replied would inject input |
| Window manipulation | xterm `CSI …t` (resize/move/raise/**report**), title stack `CSI 22/23 t` | **strip** | can move/resize the viewer window and the report forms inject input; geometry is owned by § 8 only |
| DCS: DECUDK (programmable keys), DECRQSS (setting reports) | `ESC P … ESC\` | **strip** | remap keys / trigger input replies |
| DCS: Sixel graphics | `ESC Pq … ESC\` | **pass**, size-capped | display-only image; bounded by backpressure (§ 11-backpressure) |
| APC / PM strings (Kitty-graphics APC, terminal-multiplexer passthrough) | `ESC _ … ESC\`, `ESC ^ … ESC\` | **strip** | arbitrary application protocols; graphics/exec side channels |

Anything not enumerated defaults to **strip** if it is an OSC/DCS/APC/PM string
form, and **pass** if it is a standard CSI/SGR cell-grid operation. When in doubt,
a sequence that could cause the terminal to *emit input* or *touch host resources
outside the grid* is stripped. W4/W5/iOS ship the **same** table; a conformance
corpus of hostile sequences (one per row) is the shared test fixture.

---

## 10. Predictive local echo state machine — `v1-frozen`

Predictive echo decouples *perceived* keystroke latency from network RTT by
rendering a driver's printable keystrokes locally and reconciling against the
authoritative stream (the Mosh/sshx technique). It is **only** safe under tight
conditions; the state machine enforces them.

**Predicate `P` (all must hold to predict):** the client holds the current
`penGeneration` **and** the screen is the **primary** buffer (not alt-screen)
**and** the terminal is in **echo-on** (cooked/line-echo, not a raw-mode TUI)
**and** no IME composition is in progress **and** the keystroke is a **printable
ASCII** glyph (0x20–0x7E).

States:

- **`SUPPRESSED`** (default) — no prediction; all input passes through unpredicted.
- **`ARMED`** — `P` holds; eligible to predict, none outstanding.
- **`PREDICTED`** — one or more speculative glyphs rendered locally, awaiting the
  authoritative frame that should confirm them.

| From | Trigger / guard | To | Action |
|---|---|---|---|
| `SUPPRESSED` | `P` becomes true | `ARMED` | enable prediction |
| `ARMED` | `P` becomes false (alt-screen enter, echo-off, pen lost / `penGeneration` change, IME start) | `SUPPRESSED` | disable prediction |
| `ARMED` | printable-ASCII keystroke while driving | `PREDICTED` | render speculative glyph; record prediction keyed by its `inputSeq` and the current host `seq` anchor |
| `PREDICTED` | further printable-ASCII keystroke, `P` still holds | `PREDICTED` | extend speculative buffer |
| `PREDICTED` | authoritative `Output`/`Snapshot` advancing host `seq` past a prediction's anchor | `ARMED` (or stays `PREDICTED` if predictions remain) | **reconcile**: matched predictions commit silently; on mismatch **roll back** (repaint from the authoritative frame); drain confirmed predictions |
| `PREDICTED` | `P` becomes false | `SUPPRESSED` | **immediately roll back all** outstanding speculative glyphs, repaint from the last authoritative frame |
| any | `Snapshot` received (join/resync) | `SUPPRESSED` then re-evaluate `P` | snapshot is authoritative; discard all predictions before applying it |
| `PREDICTED` | prediction TTL elapsed with no reconciling frame | `PREDICTED`→`ARMED` | roll back the expired prediction (bounded wait; never keep a phantom glyph indefinitely) |

Frozen rules: **predict only when `P` holds; reconcile or roll back on every
authoritative frame; never predict on alt-screen, during IME composition, or when
the client does not hold the current `penGeneration`.** A prediction is a local
rendering optimization only — it is never sent to the host as if authoritative,
and it is always subordinate to the next authoritative frame.

---

## 11. Multi-writer arbitration (the pen) & backpressure

### 11.1 The pen — `v1-frozen`

- Everyone attached sees live `Output`. **Exactly one** viewer holds the **pen**
  (may write input) at a time; all others are read-only.
- Taking the pen requires a **driver-capable grant** in the token (§ Auth). A
  viewer-only token that sends `grab` is refused with `error.code = pen-denied`; a
  pure viewer can never escalate to driver over the wire.
- The pen is **server-authoritative** via `penGeneration`: a monotonic counter the
  relay increments on every pen change. On `grab`/`release`/handoff the relay
  increments `penGeneration`, emits `pen_granted`/`pen_revoked` to all, and
  thereafter **drops any `Input` not carrying the current generation** (§ 5) — this
  is what makes stale input from a reconnecting old driver harmless.
- Grab is **grab-with-notice** (no approval round-trip), subject to a relay-side
  **cooldown** to prevent pen thrashing. Cooldown duration is relay policy (draft);
  the generation-guard and driver-grant requirement are frozen.

### 11.2 Backpressure — invariant `v1-frozen`, parameters `v1-draft`

- **Frozen invariant:** buffering toward any single viewer is **never unbounded**.
  A viewer that cannot keep up must never grow relay memory without limit and must
  never stall the host or other viewers (head-of-line isolation per viewer).
- **Mechanism (`v1-draft`):** a per-viewer **token bucket**; when a slow viewer's
  bucket is exhausted, the relay **coalesces/drops** intermediate `Output` frames
  for that viewer and brings it current with a **fresh `Snapshot`** (§ 12) rather
  than queuing history. The bucket rate/burst and the drop-vs-snapshot threshold
  are draft (W5 tunes against measured traffic).

---

## 12. Snapshot authority & the outbound-only mandate — `v1-frozen`

- The **host-side headless VT is the single snapshot authority** (decision D3). The
  host consumes its own PTY output into a headless terminal emulator and can
  serialize the current screen (primary + alt buffer, cursor, SGR, bounded
  scrollback tail) into a `Snapshot` frame tagged with the host `seq` it reflects
  (`atSeq`). Neither the relay nor any viewer computes the authoritative screen.
- **`snapshot_request` is a relay → host `Control` frame carried on the host's
  own, already-open outbound stream.** The relay asks; the host answers with a
  `Snapshot` frame on the same outbound stream.
- **Outbound-only mandate invariant (stated explicitly):** the host exposes **no
  inbound listener** for attach of any kind. Everything the relay needs from the
  host — snapshots, applied resize, pen state effects — is requested via `Control`
  frames the relay writes onto the connection **the host dialed out**, and answered
  on that same outbound connection. The relay never dials into the host. A design
  that adds a host-side listener to serve snapshots violates this protocol.

---

## 13. Resume — `v1-frozen`

- The relay keeps a bounded, seq-keyed **ring buffer** of host output frames.
- On (re)connect a viewer sends `resume_from` (or `subscribe` with
  `resumeFrom`) carrying the highest host `seq` it has applied. The relay:
  - **ring hit** (requested `seq` still buffered) → replays buffered frames from
    `seq + 1`, then live tail.
  - **ring miss** (requested `seq` evicted) → sends a fresh `Snapshot` at the
    current `atSeq` (requesting one from the host if needed), then the live tail
    from `atSeq + 1`. The viewer discards predictions and repaints (§ 10).
- Resume cost is therefore **O(1) in session age** — a viewer joining a 2-hour
  session never replays 2 hours of bytes; it gets the current screen + tail.
- Ring-buffer depth and any persistence for surviving a relay restart are relay
  policy (draft); the resume **contract** above is frozen.

---

## 14. Degraded SSE fallback lane — `v1-draft` (first-class)

When WSS is unavailable (handshake blocked, Upgrade stripped by a proxy, or the
live stream declared dead after N failed reconnects within a window), the client
**auto-falls-back** to a degraded lane. This lane is a **first-class** transport,
built against the same framing (§ 2) and the same event/control semantics — only
the carrier changes. It is `v1-draft` (W4/W5 may refine batching sizes and
timers) but the contract below is complete enough to build against now.

**Downstream (relay → viewer): Server-Sent Events.**
- The relay serves an SSE stream; each event is one base64-encoded binary frame:
  `event: frame` / `data: <base64(frame)>`. Frames arrive in host `seq` order.
- A `: heartbeat` comment every 15 s defeats idle-proxy timeouts.
- Snapshot/resume work identically — the first SSE event after (re)connect is the
  `Snapshot` (or the replayed tail) the relay chose per § 13.

**Upstream (viewer → relay): batched HTTP POST.**
- The viewer POSTs an array of `Input`/`Control` frames as a batch envelope:
  ```json
  { "batchId": "<unique-id>", "firstInputSeq": <int>, "lastInputSeq": <int>,
    "frames": [ "<base64(frame)>", ... ] }
  ```
- **Ordering:** frames within a batch are in contiguous `inputSeq` order, and a
  batch's `firstInputSeq` MUST equal `lastAck + 1`. A batch that opens a gap
  (`firstInputSeq > lastAck + 1`) is rejected with the current ack so the client
  resends from `lastAck + 1`. This preserves the § 5 contiguity guarantee across
  the POST carrier.
- **Ack:** the POST response is `{ "batchId": "<echoed>", "ackInputSeq": <highest
  contiguous inputSeq applied and forwarded to the host> }`. The client advances
  its send window to `ackInputSeq`.
- **Retry / idempotency:** `batchId` is a jti-style unique batch identifier. The
  relay de-duplicates by `batchId` **and** by `(userId, inputSeq)`; re-POSTing a
  batch with the same `batchId` after a timeout is a no-op that returns the same
  ack. The client retries with the **same** `batchId` — never a new one — so a lost
  response can never double-apply keystrokes.
- **penGeneration** rules (§ 11) and **relay-stamped userId** (§ 5) apply
  unchanged: the POST is authenticated (§ Auth) and the relay stamps `userId`;
  input carrying a stale `penGeneration` is dropped exactly as on the WSS lane.

**Auto-fallback triggers & upgrade-back:**
- **Trigger down:** the WSS handshake fails, or the live WSS stream produces no
  frame and no pong within the reconnect window after N attempts (N and the window
  are draft). The client switches to SSE-down + POST-up transparently; session
  identity, `sessionId`/room, and sequences are preserved.
- **Upgrade back:** the client periodically re-attempts the WSS handshake in the
  background. On success it `resume_from`s the last applied host `seq`, drains and
  awaits acks for any in-flight POST batches (dedup by `batchId` covers overlap),
  then stops POSTing. Predictive echo (§ 10) stays `SUPPRESSED` on the degraded
  lane unless the client can meet predicate `P` with acceptable POST latency
  (draft; default: predict only on WSS).

---

## 15. Auth — `v1-frozen`

- Attach is authorized by a **short-lived, per-session JWT** minted by the
  platform control plane when a user starts viewing/driving a session.
- **Frozen claim set (exactly these claims):**
  ```json
  {
    "sessionId": "<the session/PTY id>",
    "roomId":    "<the relay room; MUST equal sessionId>",
    "userId":    "<verified end-user id — the value the relay stamps onto Input>",
    "role":      "driver" | "viewer",
    "orgId":     "<tenant id>",
    "exp":       <unix-seconds, short-lived>,
    "aud":       "relay",
    "jti":       "<single-use nonce>"
  }
  ```
- **Dedicated relay signing key (asymmetric).** The token is signed with a key
  **dedicated to the relay** — never the platform's shared session/service secret.
  Asymmetric is mandated: the platform holds the private key, the relay holds
  **only the public key**, so a relay compromise cannot mint tokens. The signing
  `alg` is pinned (an EdDSA or ECDSA family value); the relay MUST reject `none`
  and any HMAC/`HS*` token (RFC 8725 — algorithm confusion is a rejection, not a
  fallback).
- **Single-use `jti`.** The relay records consumed `jti`s until their `exp` and
  refuses replay. A token replayed to rejoin after revocation fails.
- **Room binding.** The relay MUST verify `sessionId == roomId == the room being
  joined`. A token minted for session A can never join room B.
- **`role` is a ceiling.** `role: "viewer"` can never be promoted to driver over
  the wire (§ 11); `role: "driver"` grants driver capability (still subject to the
  pen/generation rules).
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
- **Lifecycle.** The WSS connection outlives the JWT; the client refreshes with a
  freshly-minted token (new `jti`) before `exp`, either in-band or by reconnecting
  with `resume_from`. Token minting/refresh is a platform concern; the claim set,
  key posture, single-use `jti`, room binding, and carriage above are frozen here.

---

## 16. Parallel recording (asciinema v2) — `v1-draft`

Independently of the live protocol, the host MAY emit a parallel **asciinema v2**
cast of the session (the `Output` stream + `Resize`/`Marker` events with their
`rel_time`s) for later replay and audit. This is **out of the wire scope** of this
spec — it is a host-emitted, side-channel artifact, not a frame type on the attach
stream — but it is called out here so W4/W5 keep the live path and the durable
record aligned (same `rel_time` epoch, same marker labels). Retention, access,
redaction, and per-org opt-out for recordings are platform policy (see the platform
ADR and the D13 relay-data-residency ruling).

---

## Appendix A — conformance checklist (for W4/W5 sign-off)

- [ ] Varint encode/decode reproduces every § 2.1 fixture exactly.
- [ ] Event-type byte values (§ 3) pinned; unknown type → framing error.
- [ ] Two sequence namespaces kept distinct (§ 4); input attributed by
      `(userId, inputSeq)`.
- [ ] `Input` `userId` is relay-stamped; host rejects unstamped input (§ 5).
- [ ] Every § 7 control message round-trips; unknown fields ignored.
- [ ] Host applies relay `Resize` verbatim; no host-side clamp (§ 8).
- [ ] Sanitization allowlist (§ 9) enforced identically relay/web/iOS against the
      hostile-sequence corpus; viewers never emit input in reply to output.
- [ ] Predictive-echo state machine (§ 10) suppresses on alt-screen / IME /
      pen-loss and rolls back on mismatch.
- [ ] Backpressure never buffers unboundedly (§ 11).
- [ ] `snapshot_request` served on the host's outbound stream only; no host inbound
      listener (§ 12).
- [ ] Resume: ring hit replays from `seq+1`; ring miss → snapshot + tail (§ 13).
- [ ] Degraded lane: contiguous `inputSeq`, `batchId` idempotency, ack window,
      auto-fallback + upgrade-back (§ 14).
- [ ] JWT: frozen claim set, dedicated asymmetric relay key, single-use `jti`,
      `sessionId==roomId`, `alg` pinned, header vs subprotocol carriage (§ 15).
