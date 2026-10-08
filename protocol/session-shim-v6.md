---
title: session-shim selected v6 — headless workload profile and credential update
status: Accepted
date: 2026-10-08
revision: v6.0-draft1
protocol-family: session-shim-v1
selected-version: 6
boundary: OSS-only
normative-for: donmai session shim and daemon controller
---

# session-shim selected v6 — headless workload profile and credential update

**Status:** Accepted contract; implementation, release and live acceptance are
separate gates. **Owning decision:**
[headless session-shim adoption](../ADR-2026-10-07-headless-session-shim-adoption.md)
(its D2, D3, D4 and founder decision 5). **Transport predecessor:**
[selected v5](session-shim-v5.md).

This is an additive selected-version delta inside the existing
`session-shim-v1` protocol family. It does two things:

1. it adds a correlated credential push, `CredentialUpdate` and
   `CredentialResult`, for every shim selected at 6, interactive or headless;
   and
2. it defines the **headless workload profile**: a shim with no PTY, no host
   output stream and one terminal observation, `HeadlessExit`.

Selected v1–v5 keep their exact bytes. Nothing here changes an interactive
shim selected below 6.

## 1. Selection and the workload profile

The daemon still selects the highest common version from `Hello` and its own
range. The family token stays `session-shim-v1`.

- An **interactive** shim that implements v6 advertises `[1, 6]`. Selected at
  6 it keeps the complete v5 vocabulary and gains the two credential types.
- A **headless** shim advertises exactly `[6, 6]`. A controller whose maximum
  is below 6 has no overlap and quarantines it as `protocol_mismatch` without
  dialling past the record check; it never treats a headless shim as a PTY
  session and never kills it.

A headless shim declares its profile in the existing optional extension map,
never as a new top-level `Hello` member (a new member would break older strict
`Hello` decoders before selection):

```json
{"extensions":{"values":{"workload":"headless"}}}
```

The value is exactly `headless`. An interactive shim omits the key; absence
means the PTY profile. Any other value, or the key on a shim whose range
includes a version below 6, is malformed. The key must not appear in the
required-extension list; the `[6, 6]` range is what keeps older controllers
from selecting a headless shim.

The discovery record of a headless shim carries one additional member,
`"workload":"headless"`, and `schemaVersion` 2. Interactive records keep
schema version 1 and stay byte-identical, so an older daemon still decodes
them. An older daemon's strict record decoder refuses a headless record and
quarantines it as `record_malformed`, which is the intended outcome. Headless
tombstones carry the `HeadlessExit` members of § 4 under the same rule.

## 2. Closed v6 message delta

The inherited envelope is unchanged:

```text
[message_length:u32 big-endian][type:u8][body:message_length-1 bytes]
```

Selected v6 assigns exactly these new values. Bodies are strict JSON objects,
like the other control messages: unknown members, duplicate members, trailing
data and wrong types are malformed.

| Type | Direction | Profiles | Meaning |
|---|---|---|---|
| `0x13 CredentialUpdate` | daemon → shim | both | Replace the runner's control-plane credential. |
| `0x14 CredentialResult` | shim → daemon | both | Correlated outcome of one update. |
| `0x15 HeadlessExit` | shim → daemon | headless only | The one immutable terminal observation. |

**Legal vocabulary under the headless profile:** `Hello`, `Welcome`,
`Adopted`, `Stop`, `Heartbeat`, `Error`, `CredentialUpdate`,
`CredentialResult`, `HeadlessExit`. `Output`, `Gap`, `Snapshot`, `Input`,
`Resize`, `Exit`, `SnapshotRequest`, `SnapshotResult`, `HostFrame`,
`AttributedInput`, `CheckpointRequest` and `CheckpointResult` are refused
with `Error{code:"malformed"}` and are never acted on. Under the interactive
profile `HeadlessExit` is refused the same way.

## 3. CredentialUpdate and CredentialResult

```json
{"requestId":7,"generation":3,"workerId":"wrk_...","bearer":"...","expiresAt":1760000000000000000}
```

- `requestId`: nonzero, strictly increasing per controller connection.
- `generation`: the controller generation the shim committed at adoption. It
  is authority-bearing: a shim refuses an update whose generation is not its
  current committed generation, so a controller that lost adoption can never
  install a credential.
- `workerId`: 1–256 bytes; the worker registration the bearer belongs to. It
  may differ from the registration the session was claimed under.
- `bearer`: 1–16384 bytes of opaque credential.
- `expiresAt`: signed Unix nanoseconds, nonzero.

```json
{"requestId":7,"generation":3,"status":"success"}
```

`status` uses the closed v2 result code set by name: `success`, `malformed`,
`stale_generation`, `duplicate_changed`, `request_ledger_full`, `internal`,
`request_mismatch`, `timeout`. `exited` is not used; a shim that has written
its terminal observation answers `internal`. `success` means the runner's
credential provider now returns the new pair for every later control-plane
call. An exact retry of the last request id on the same connection returns
the first result without reinstalling; a reused id with changed content is
`duplicate_changed`.

The shim holds the bearer in memory only. It never writes it to the discovery
record, a tombstone, a sidecar, a log or the environment, and it never
forwards it to the harness. The controller sends an update after every
routine credential refresh and once immediately after adoption, before the
host reports ready. A shim-owned runner that has received any update stops
re-reading its credential from the daemon's session-detail route.

## 4. HeadlessExit and its acknowledgement

```json
{"seq":1,"processEpoch":1,"exitCode":0,"signal":"","groupReaped":true,
 "cause":"completed","outboxKey":"...","outboxState":"delivered","observedAt":1760000000000000000}
```

- `seq` is always `1`. The headless profile has no host output stream; the
  terminal observation is its only sequence-bearing message.
- `cause` is one of `completed` (the runner reached its own end, successful or
  not), `orphaned` (the orphan deadline ended the run), `stopped_for_resume`
  (ADR-2026-10-07 D8) and `shim_failure` (written only by an adopting
  controller's janitor, never sent on the wire).
- `outboxKey` and `outboxState` name the session's terminal-status outbox
  record and its state, `delivered`, `pending` or `none`. `none` is valid only
  with `stopped_for_resume`, which writes no session terminal.
- `groupReaped` is true only after the harness process group was proved gone.

The shim sends `HeadlessExit` once per controller connection, after it has
written the tombstone carrying the same members. The controller acknowledges it
with a generation-fenced `Heartbeat` whose `ackedSeq` is `1`, sent only after
it has durably recorded the terminal evidence. The shim waits for that
acknowledgement within its existing finalize bound, then exits; a missing
acknowledgement leaves the tombstone for the next adoption, as for an
interactive `Exit`.

## 5. Compatibility and proof obligations

- Selected v1–v5 traffic is byte-for-byte unchanged. No peer sends a v6 type
  merely because its binary advertises 6.
- A headless shim is never selected below 6, and an interactive shim never
  carries `workload`.
- `CredentialUpdate` never travels on an unauthenticated or stale-generation
  connection, and never reaches disk.
- `HeadlessExit` is the sole terminal authority of a headless lineage; no
  legacy `Exit` accompanies it.

Conformance must include mixed-version selection (headless shim with a v5
controller, interactive v6 shim with a v5 controller), the strict record
decode by an older daemon, a stale-generation and a changed-duplicate update,
every refused PTY-shaped type on a headless connection, the acknowledgement
wait and its timeout, and byte-for-byte unchanged selected v1–v5 traffic.
