---
title: interactive-continuation-v1 — complete terminal checkpoint and raw-tail rail
status: Accepted
date: 2026-09-28
revision: v1.0-draft1
protocol-version: interactive-continuation-v1
boundary: OSS-only
normative-for: donmai checkpoint producer and mirror, compatible self-hosted relays and viewers
---

# interactive-continuation-v1 — complete terminal checkpoint and raw-tail rail

**Status:** Accepted contract; implementation, release and downstream live
acceptance remain separate gates. **Owning decision:** [complete terminal continuation](../ADR-2026-09-28-interactive-vt-continuation.md).
**Local prerequisite:** [session-shim selected v5](session-shim-v5.md) for a
shim-backed producer. **Predecessors:** [interactive attach v1](interactive-attach-v1.md)
and [v2](interactive-attach-v2.md) remain independent and unchanged.

This rail gives an explicitly selecting, read-only consumer complete terminal
state at host sequence K, followed by the **original** accepted host-frame
bytes beginning at K+1. It does not introduce a new legacy Snapshot format,
put a 20 MiB body into the attach host mailbox, expose raw terminal output to
the user's terminal, or make the consumer an input/resize/pen authority. The
PTY owner remains the only source of terminal state and host sequence.

## 1. Selection and host eligibility

The viewer opens one WSS connection at the separately versioned path
`/v3/rooms/{roomId}/continuation` and offers the continuation wire token
`Sec-WebSocket-Protocol: interactive-continuation-v1` for this rail. The server
must echo it exactly. The path's `/v3/` segment is an endpoint namespace; it
does **not** turn this into attach-v3 or local shimwire v3. A viewer authenticates
with the ordinary short-lived per-session attach credential, bound to the same
room and organization, in the established header or browser bearer-subprotocol
slot. Host-role credentials cannot join this viewer route. Version selection
and bearer carriage are separate. The connection admits no legacy driver leg.

Viewer credentials share the existing viewer admission identity and JTI ledger
across legacy and continuation routes. A credential already owning a live
viewer connection cannot open another route concurrently. Failed admission
releases only its own reservation; once-only connection cleanup cannot release
a successor's ownership. This shared admission does not create a legacy viewer
leg, filtered fanout subscription, or input authority for continuation readers.

The first viewer message is a bounded **text** WebSocket message containing
exactly `{"schema":"donmai-vt/continuation-v1"}` (JSON object field order is
irrelevant). The server rejects a missing, unknown, duplicate or `null` field,
extra field, trailing JSON, or message larger than 1024 bytes. A subprotocol
echo or an offered schema is not a completed handoff. The first positive
selection response is the `Accepted` phase in §4, emitted only after the
checkpoint's transport envelope and contiguous tail have been selected
together. The consumer commits no cursor until all chunks arrive and complete
state restores with picture agreement.

The active host must positively advertise `donmai-vt/continuation-v1` on its
**existing authenticated outbound** attach leg. Native host WSS does so with
`Subscribe.continuationSchemas` containing that literal string. A degraded
v1 host SSE-down leg may use the exact
`continuation_schema=donmai-vt%2Fcontinuation-v1` query value on its
authenticated `/v1/rooms/{roomId}/host/sse` request. An absent/unknown
advertisement is unsupported; a relay does not probe an old host with new
request metadata. Selected local shim v5 plus a valid optional
`Hello.extensions.values["continuation_checkpoint"]` capability is required to back a shim-owned host advertisement. Mere maximum
version 5 or a screen-only producer is insufficient. No host inbound listener
is introduced.

## 2. Host request and request-scoped upload authority

The relay requests complete state over the host's outbound control leg by
adding an optional `continuation` object to the already-defined
`snapshot_request` control (normally `reason:"join"`):

```json
{
  "type": "snapshot_request",
  "reason": "join",
  "continuation": {
    "requestId": "URL-safe id",
    "schema": "donmai-vt/continuation-v1",
    "uploadGrant": "43-character unpadded base64url secret"
  }
}
```

The request id is 1–128 characters from `[A-Za-z0-9_-]`. `uploadGrant` is the
canonical unpadded base64url encoding of 32 random bytes. The grant is minted
for this request, delivered **only** inside this authenticated relay→host
control frame, and retained by the relay as a digest. The mandatory legacy
screen Snapshot (`snapFormat 0x01`) answer to `snapshot_request` stays exactly
as before. The complete checkpoint is an additional out-of-band response and
never replaces that answer or enters legacy Snapshot cache/fan-out.

The host sends bounded JSON chunks to the same-origin HTTPS endpoint
`POST /v3/rooms/{roomId}/continuation/{requestId}` (loopback HTTP is allowed
for local self-hosted operation). Every POST carries exactly one
`X-Continuation-Upload-Grant: <uploadGrant>` header and **no** `Authorization`
header. An attach JWT, including one still valid, is not POST authority here;
mixed grant/bearer headers are refused. In particular, an expired admission
JWT is never accepted as a POST credential. A WSS host leg may outlive that
JWT, so the grant authorizes its narrowly scoped upload without changing JWT
verification, refreshing the leg, consuming another admission JTI, or minting
a host-facing server JWT.

The relay binds the grant to one `(organization, session, active physical host
leg, PTY epoch, carrier epoch, host-leg JTI, requestId)` tuple. PTY, process
and carrier epochs are distinct; none may be inferred from another. Each
chunk rechecks that exact current binding. Grant comparison is constant time
against the stored digest. The grant expires **30 seconds from request
creation**, cannot be extended by retries, and is invalid after cancellation,
room teardown, or host replacement, including a replacement at the same PTY
epoch. One room retains at most one pending/latest checkpoint; an active reader
may retain an older validated checkpoint under bounded reference accounting.

The grant never enters a URL, query parameter, viewer phase, log, diagnostic,
error detail or tracing header dump. A formatter's redaction does not make it
safe to log the serialized host control frame: that frame necessarily contains
the grant. Redirects are not followed on upload. A changed replay cannot
reuse an old grant or mutate the first immutable upload.

## 3. Upload JSON, acknowledgement and bounds

Each chunk body is one strict JSON object with every field present, no
duplicates, `null`, unknown keys or trailing data:

```json
{
  "schema": "donmai-vt/continuation-v1",
  "requestId": "same id as URL and host request",
  "hostEpoch": 0,
  "offset": 0,
  "total": 1,
  "sha256": "64 lowercase hexadecimal characters",
  "data": "base64 of the exact chunk bytes"
}
```

`hostEpoch` is an explicit unsigned PTY epoch, including zero. `total` is
1–20 MiB. Offsets start at zero, are multiples of 256 KiB and are contiguous;
each chunk has exactly `min(256 KiB, total-offset)` decoded bytes. The same
schema, request id, epoch, total and SHA-256 must hold for the entire upload.
The JSON body is limited to `4*ceil(256 KiB/3)+2048` bytes, covering base64
expansion plus bounded metadata. Its `sha256` covers the **entire encoded
checkpoint**, not an individual chunk. No partial upload can be served to a
viewer. On every accepted chunk the response is a strict JSON object
`{"nextOffset":N,"complete":false|true}`; `N` is the next exact byte offset.
The host checks both fields. An identical retry of the same chunk is allowed
within the same live grant and returns the already-known next offset; a changed
byte, digest, total or offset is refused.

The HTTP status taxonomy of this profile is: `200` exact chunk/ack, `400`
malformed or mismatched chunk body, `401` missing/malformed/wrong/expired grant
or any mixed bearer header, `404` unknown room, `409` conflicting request,
producer state or checkpoint memory refusal, `413` request body over its bound,
and `503` relay draining. An uploader may retry transport failures,
`429`, and `5xx` with identical bytes inside the original 30-second request;
`4xx` refusals do not authorize an altered retry. A receiver may impose
stricter admission limits but must refuse visibly rather than truncate state.

## 4. Viewer binary phase framing

Every server→viewer continuation WebSocket message is **binary**. The first
byte is a closed phase tag; no legacy attach frame header surrounds it:

| Tag | Remaining bytes | Meaning |
|---:|---|---|
| `0x01 Accepted` | Strict JSON `{schema,requestId,hostEpoch,atSeq,total,sha256}` | Complete checkpoint framing/digest/epoch/boundary checked and paired atomically with its starting tail; opaque state restoration remains the consumer's gate. |
| `0x02 CheckpointChunk` | `[offset:u32 big-endian][1..256 KiB opaque bytes]` | Byte-exact checkpoint slice at a multiple-of-256-KiB offset. |
| `0x03 HostFrame` | One complete original encoded attach host frame | Canonical host-sequence observation after `atSeq`; raw bytes are never sanitized on this rail. |
| `0x04 Error` | One ASCII code from the closed set below | Terminal refusal; discard the uncommitted handoff and close. |

`Accepted` names the same schema/request id, PTY host epoch, total and whole
payload SHA-256 verified on upload. `atSeq` comes from decoding that payload.
Its JSON has all fields explicit, including zero `hostEpoch`/`atSeq`, no
duplicates, unknowns, `null`, or trailing bytes, and is at most 2048 bytes.
There is **no upload grant** in `Accepted` or any other viewer phase.

The legal order is exactly one `Accepted`, `CheckpointChunk` messages covering
offsets `0..total` without overlap or gap, then zero or more `HostFrame`
messages whose sequences begin at `atSeq+1` and remain contiguous. A complete
post-Exit checkpoint at `atSeq == Exit.seq` has an empty tail. A strict reader
validates tag, size, exact chunk offsets, digest, schema, epoch and the
restored state/picture agreement before committing `atSeq`. It rejects raw
host frames before the complete checkpoint, an unexpected second `Accepted`,
unknown phase, missing chunk, gap, eviction, epoch change or changed producer.
The connection may close only after a complete final Exit or with a visible
error; a transport loss before completion is not a successful checkpoint.

`HostFrame` payload is limited to a decodable positive-sequence host-produced
`Output`, applied `Resize`, `Marker`, ordinary `Snapshot`, or `Exit` frame.
An originating attach-v1 frame accepted by its decoder keeps its **original
bytes**, including a decoder-valid nonminimal varint spelling; the continuation
relay does not decode-and-re-encode it. A selected-v3 shim sender still obeys
its own canonical-encoder requirement in [session-shim v3](session-shim-v3.md).
This rule preserves actual provenance without widening either sender's
original validity rules. Sequence-zero control frames and post-Exit screen
Snapshots are not raw-tail `HostFrame` phases.

`Error` is one of `unsupported`, `unavailable`, `timeout`, `gap`, `invalid`,
`busy`. It carries no free-form terminal bytes or secret detail. It may be
sent before `Accepted` or abort a later phase; the viewer discards any
incomplete state and does not advance its cursor. The sender then closes the
continuation connection. No error code can turn an incomplete upload or a
noncontiguous suffix into a successful handoff.

## 5. Complete checkpoint bytes and read-only restoration

The opaque payload whose digest and `total` are named above has this exact
outer layout. All lengths and integer values here are unsigned LEB128
varints; there is no ZigZag or compression:

```text
[schema_len][schema UTF-8 bytes]
[host_epoch][at_seq]
[picture_len][legacy screen-format 0x01 Screen bytes, without Snapshot envelope]
[state_len][complete state bytes]
[exit_len][Exit payload bytes, or length 0 while live]
```

The only selected outer schema is `donmai-vt/continuation-v1`. The picture is
the existing escape-safe screen projection at the same PTY epoch. `state_len`
is nonzero and holds a complete owned headless-terminal engine checkpoint,
including both buffers, pens/cursors, margins, modes, tabs, character sets,
scrollback, pending parser/UTF-8 state and the host title-filter/mode state.
The current owned engine's nested schema is
`charm-x-vt/b16d026a9d2e+ansi0.11.7+uvf5a850f9c2b7/continuation-v1`.
This is an exact engine/ANSI/Ultraviolet interpretation profile, not a
promise that arbitrary newer dependency selections are compatible. Producer
and consumer must use an identical effective profile or prove compatibility;
Go's effective module selection, not declarations alone, is the release
evidence. A different complete-state representation requires a new selected
schema. Unknown, incomplete or noncanonical owned state is refused, never
filled from a picture.

Reachable terminal-originated bytes are lossless even when they are not valid
UTF-8. Link fields, OSC metadata and cell content use byte-valued fields in the
owned state representation (base64 in its JSON encoding), not JSON strings
that replace malformed bytes. This preserves parser behavior rather than
changing OSC interpretation or normalizing the producer's state.

The first implementation profile's effective dependency check includes
`github.com/charmbracelet/x/ansi` `v0.11.7`,
`github.com/charmbracelet/ultraviolet`
`v0.0.0-20260703014108-f5a850f9c2b7`,
`github.com/clipperhouse/displaywidth` `v0.11.0`,
`github.com/mattn/go-runewidth` `v0.0.23`, and `github.com/rivo/uniseg`
`v0.4.7`. These are interpretation inputs, not extra wire fields. A consumer
whose selected module graph differs needs explicit compatibility evidence or
a new schema before it advertises support; matching `go.mod` declarations
alone is insufficient when minimal version selection chooses another version.

The PTY owner captures state, picture, `atSeq` and optional Exit atomically
under its session lock, without allocating a host sequence or changing its
canonical journal/acknowledgement. A local subscriber requested from
`atSeq+1` must return the exact contiguous suffix or fail before exposing a
checkpoint. A relay verifies the complete digest and strict outer checkpoint
framing, schema, PTY epoch and `atSeq`; it does **not** claim to restore the
opaque VT state or prove picture agreement. It then pairs that envelope with
retained raw frames from `atSeq+1` under one room lock;
no network I/O runs under that lock. If the ring has evicted that boundary,
contains a gap, exceeds the bounded tail budget, or belongs to a replaced
host binding, the relay refuses/retries with a fresh request **without cursor
advance**. An existing reader's cursor remains bound to its captured producer
and survives another reader's fresh checkpoint request. Producer replacement
invalidates it.

The consumer restores the complete owned state and verifies that its derived
picture byte-for-byte matches the carried picture. It then applies each
contiguous raw host frame to a **headless mirror only**. Terminal query replies
go to a discard sink; the mirror cannot write PTY input, resize the live host,
or hold the pen. Legacy picture `Snapshot` frames after the checkpoint consume
their ordinary host sequence and validate `atSeq`/epoch; they do not repaint
or reset the complete continuation state. Echo changes are ancillary metadata.
Exit applies once, closes further frame application, and preserves the final
screen. A checkpoint preceding Exit may remain usable after host detachment
only when the retained suffix is complete through the **same producer's**
final Exit. A later producer binding invalidates it even with the same PTY
epoch. Only the mirror's validated screen projection may be rendered.

## 6. Limits, isolation and conformance

The fixed wire bounds are 20 MiB per encoded checkpoint, 256 KiB decoded
upload/viewer chunk, 30 seconds per upload grant/request, and the inherited
local 1 MiB shimwire message cap. A compatible relay bounds both pending
assembly and retained reader ownership. The current receiver profile uses
one pending/latest state per room, at most 64 MiB of process-wide retained
checkpoint payloads, at most 16 simultaneous continuation readers and an
8 MiB contiguous tail-copy budget per reader. These concurrency limits are
receiver policy, not new attach-v1/v2 wire fields. A large checkpoint is never
inserted into the legacy host mailbox or filtered viewer queue.

Old attach routes continue their exact frame registry, `snapFormat 0x01`
screen, sanitizer, Snapshot cache, tail projection, input arbitration and
viewer behavior. Raw continuation bytes exist only on the negotiated rail.
Standalone local PTY capture, restore and raw replay remain usable without a
hosted relay or control plane.

Conformance must show a literal state-removal RED and restored GREEN for
hidden terminal state; selected-local-v5 and older-version refusal; positive
host advertisement; an actual checkpoint and same-suffix mirror; malformed
chunk/phase/digest/epoch/gap refusal; exact raw-byte identity through live
ingest and durable reload; post-Exit behavior; concurrent-reader ownership;
grant wrong/stale/expired/cross-request/replaced-host refusal; and a host
whose admission JWT expired while its active connection remained bound
uploading successfully with a **fresh grant only**. Passing tests or a
locally composed source do not by themselves prove released downstream
consumer behavior or production activation.
