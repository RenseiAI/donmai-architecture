---
title: session-shim selected v5 — correlated complete terminal inspection
status: Proposed
date: 2026-09-28
revision: v5.0-draft1
protocol-family: session-shim-v1
selected-version: 5
boundary: OSS-only
normative-for: donmai session shim and daemon controller
---

# session-shim selected v5 — correlated complete terminal inspection

**Status:** Proposed; implementation, release and consumer acceptance are separate
gates. **Owning decision:** [complete terminal continuation](../ADR-2026-09-28-interactive-vt-continuation.md).
**Transport predecessor:** [selected v3 full host frames](session-shim-v3.md).

This is an additive selected-version delta inside the existing `session-shim-v1`
protocol family. Selected v5 retains the v1–v4 message meanings, including v3
`HostFrame` and v4 `AttributedInput`. It adds a read-only, request-correlated
checkpoint exchange. It does not allocate a host sequence, change the canonical
host-frame stream, or replace the v2 authoritative screen request.

## 1. Selection and capability

The daemon continues to select the highest common version from `Hello` and its
own supported range. The protocol-family token remains `session-shim-v1` and
the minimum remains 1; a v5 implementation may advertise maximum 5. Only a
connection **actually selected at 5** may send `CheckpointRequest` or
`CheckpointResult`. A peer selected at v1–v4 keeps that version's exact bytes
and refuses either v5 type. A maximum of 5 is not proof of checkpoint support.

An actual producer may advertise the optional `continuation_checkpoint` key
inside the existing `Hello.extensions.values` map. Its value is a JSON string,
not a new top-level Hello member:

```json
{"extensions":{"values":{"continuation_checkpoint":"{\"schema\":\"donmai-vt/continuation-v1\",\"hostEpoch\":0}"}}}
```

The value is bounded to 256 bytes and contains exactly `schema` and `hostEpoch`.
Both are required. `hostEpoch` is an explicit unsigned PTY-stream epoch,
including when zero; omission or `null` is invalid. It is distinct from
`Hello.processEpoch`, controller generation, and any external carrier epoch.
Unknown members, malformed JSON and trailing data are refused. The controller
reports support only when v5 is selected **and** this optional value names the
supported schema. It checks every completed checkpoint against the advertised
host epoch. A shim without an owned complete-state engine omits the key and
remains fully functional on the legacy stream.

The key must not appear in the required-extension list. The required-extension
registry remains unchanged: a required `continuation_checkpoint` is refused.
Older controllers ignore the optional map entry and can select v1–v4; a new
top-level member would instead break their strict Hello decoder before version
selection. The Go `Hello.Continuation` convenience field is derived from this
extension and is not a top-level wire field. Encoding must preserve unrelated
extension values and refuse conflicting representations.

The daemon may carry a composing controller's positive support as immutable
prepublication capability evidence so an outbound host connection can
advertise it during initial dial. That fact grants no inspection authority.
An actual inspection still requires the exact currently adopted session,
shim id, process epoch and controller generation, checked before the local
request and again before returning the result.

## 2. Closed v5 message delta and envelope

The inherited local envelope is unchanged:

```text
[message_length:u32 big-endian][type:u8][body:message_length-1 bytes]
```

`message_length` includes the type byte, is nonzero and at most 1 MiB. The
receiver checks it before allocating. Selected v5 assigns exactly these new
values; the inherited `0x01`–`0x10` registry stays legal under its existing
rules.

| Type | Direction | Meaning |
|---|---|---|
| `0x11 CheckpointRequest` | daemon → shim | Inspect one complete state at the current generation. |
| `0x12 CheckpointResult` | shim → daemon | One bounded chunk or a closed refusal for that request. |

`CheckpointRequest` is generation-bearing authority, even though capture
does not mutate the PTY. A selected v5 receiver refuses the request if that
generation is not its current committed controller generation.

## 3. Exact binary bodies

`CheckpointRequest` has no length prefix inside the body:

```text
offset  bytes  field
0       8     request_id, nonzero u64 big-endian
8       8     controller_generation, nonzero u64 big-endian
16      rest  literal UTF-8 bytes "donmai-vt/continuation-v1"
```

The body length is exactly `16 + len(schema bytes)`. An unknown schema, extra
byte, zero id or zero generation is malformed. The request id is local to
this controller connection; it is not a host sequence or external upload id.

`CheckpointResult` has a fixed 57-byte header followed by zero to 256 KiB of
checkpoint bytes:

```text
offset  bytes  field
0       8     request_id, u64 big-endian
8       8     controller_generation, u64 big-endian
16      4     total checkpoint bytes, u32 big-endian
20      4     chunk offset, u32 big-endian
24      32    SHA-256 of the entire encoded checkpoint
56      1     status code
57      rest  chunk bytes
```

On success, status is `0`, request id and generation are nonzero, total is
1–20 MiB, offsets begin at zero and are multiples of 256 KiB, and each chunk
has exactly `min(256 KiB, total-offset)` bytes. Every chunk of the request
repeats the same total and digest. The last chunk ends exactly at total. The
outer 1 MiB message limit still applies. On refusal, total, offset, digest and
chunk bytes are all zero; only id, generation and a nonzero status remain.
The decoder rejects any other shape before allocating the complete state.

The status byte shares the closed v2 `SnapshotResult` code mapping, without
changing that older message:

| Byte | Code | Meaning for this exchange |
|---:|---|---|
| `0` | success | Valid checkpoint chunk. |
| `1` | `malformed` | Invalid request or result shape. |
| `2` | `stale_generation` | Request generation is no longer authorized. |
| `3` | `duplicate_changed` | Reused id names changed request content. |
| `4` | `request_ledger_full` | Receiver cannot retain another correlation. |
| `5` | `exited` | Operation is unavailable for this terminal disposition; Exit alone is not a blanket refusal. |
| `6` | `internal` | Complete capture or encoding failed. |
| `7` | `request_mismatch` | Result or correlation does not match the request. |
| `8` | `timeout` | The bounded operation expired. |

Only these bytes are valid. An unknown code, a refusal with checkpoint bytes,
or an error after partial successful chunks is a protocol failure; the
controller cannot treat a partial result as a checkpoint. The current shim
emits `stale_generation`, `duplicate_changed` and `internal` on its explicit
refusal paths; the shared codec reserves the full table above.

## 4. Correlation, replay and completion

The controller permits one unfinished checkpoint request at a time and assigns
strictly increasing nonzero request ids. Cancellation stops its caller's wait
but does not free the unfinished correlation for a different request to claim.
The controller sends under the inherited serialized writer without holding a
state lock over stream I/O. A same-connection exact retry of the last shim
request replays its retained immutable result chunks. Reusing its id with a
changed generation or schema returns `duplicate_changed`; an older or unknown
correlation cannot claim the chunks.

The shim captures the `ContinuationCheckpoint` under the PTY session mutex so
the complete state, picture, PTY epoch, `AtSeq`, and optional final Exit name
one boundary. It emits no new host frame or ordinary Snapshot as part of this
inspection. It encodes the checkpoint once, hashes those exact bytes, then
sends contiguous bounded chunks. The controller accepts only the current
request id and generation, contiguous offsets and unchanged total/digest. It
checks the final SHA-256, decodes the complete checkpoint, matches the `Hello`
host epoch and restores the owned headless terminal to verify complete state
and picture agreement **before** returning it. Any gap, changed field,
malformed state, digest mismatch or restore failure refuses without a cursor
advance.

The complete checkpoint byte layout and downstream transport are specified in
[interactive continuation v1](interactive-continuation-v1.md). A post-Exit
checkpoint is valid when its `AtSeq` is the final Exit sequence and it carries
that Exit; the final screen remains inspectable without inventing a new host
sequence.

## 5. Compatibility and proof obligations

- Selected v1–v4 keep their exact vocabulary, canonical observations and
  legacy `SnapshotRequest`/`SnapshotResult` behavior. No peer may send a v5
  type merely because its binary advertises a v5 maximum.
- The externally visible PTY epoch, local process epoch, controller generation
  and carrier epoch are separate authorities. No implementation may infer one
  from another.
- A Gap on the ordinary host stream remains a Gap. A checkpoint result does
  not fill a missing canonical sequence or advance durable host-frame ACKs.
- A producer that cannot serialize *all* continuation state refuses support
  rather than substituting a screen picture or guessed parser defaults.

Conformance must include mixed-version selection, missing/false `Hello`
capability, stale generation, changed duplicate, partial and reordered chunks,
digest/epoch mismatch, cancellation under writer backpressure, post-Exit
inspection, and byte-for-byte unchanged selected-v1–v4 traffic.
