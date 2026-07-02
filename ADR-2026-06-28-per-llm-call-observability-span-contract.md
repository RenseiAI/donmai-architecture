---
status: Accepted
date: 2026-06-28
boundary: shared
split: synchronized-mirror
---

# ADR-2026-06-28 — Per-LLM-call observability span contract

**Status:** Accepted
**Date:** 2026-06-28
**Boundary:** shared (canonical here; synchronized mirror in the platform corpus)
**Authors:** agent:claude (P2-WS1 wire-contract design session)

## Context

The execution layer emits a coarse **session-event projection** today — a flat
stream of `model_request`, `tool_call`, and similar kinds that reconstructs
*what a session did* at the granularity of the whole run. That projection is
sufficient for the operator dashboard and the TUI activity stream, but it is the
wrong shape for the observability questions that matter for cost, latency, and
governance:

1. **Per-LLM-call cost and latency.** "How many input/output tokens did *this
   one* turn burn, how long did it take, and what did it cost?" cannot be
   answered from a session-level projection. Cost accounting, percentile latency
   analytics, and cache-hit accounting all need one durable record *per model
   call*, not per session.
2. **Causal tree, not a flat list.** A turn spawns tool invocations; a session
   spawns sub-agents; a composed step groups retrievals and calls. The
   session-event stream flattens that structure. Answering "which tool call
   inside which turn under which sub-agent failed" needs a real parent/child
   span tree with stable ids.
3. **Interop with the wider tracing ecosystem.** Any serious observability
   backend (and every downstream consumer we might integrate) speaks
   OpenTelemetry. A bespoke event shape forces a lossy translation at every
   boundary. Aligning the wire contract to the **OpenTelemetry GenAI semantic
   conventions** (`gen_ai.*`) from the start means an OTLP-speaking consumer can
   dispatch off our spans directly.
4. **Governance context the GenAI semconv does not cover.** Tenancy
   (`org_id`/`workspace_id`), the authorization decision that permitted the call
   (`cedar_decision_id`), the work classification, the pool, and the
   content-by-digest hashes are all first-class to *our* governance story and
   have no home in the GenAI semconv. They need a stable, namespaced extension
   group.

This work is **P2-WS1** — the *wire contract only*. It ships the Go types, the
codec, and a golden fixture that pins the on-the-wire bytes. **Emission** (the
harness poster that populates spans from live runs) and **ingest** (the columnar
store / OTLP receiver that consumes them) are separate workstreams that target
this contract; see Open Items. Fixing the wire shape first — with a golden
fixture as the cross-language parity anchor — lets emission and ingest be built
independently against a frozen contract.

The contract shipped in **donmai v0.49.3** as the `agent` package's `Span`
types (`agent/span.go`, `agent/span_test.go`,
`agent/testdata/llm_call_span.golden.json`).

## Decision

Adopt a **sealed, discriminated union of six span kinds** as the canonical
per-LLM-call observability record. Every span is OTLP-shaped: it carries an OTel
trace/span id spine and an OTel status, maps cleanly to an OTLP span with an OTel
`SpanKind`, carries the GenAI semconv attribute group on LLM spans, and carries a
`donmai.*` extension attribute group on **every** kind. The wire form is
camelCase JSON with a stored `kind` discriminator; a companion golden fixture
pins the exact bytes and is the byte-for-byte parity anchor for any language
mirror.

This span layer is **additive**. It does **not** replace the legacy
session-event projection; the two coexist. The span `kind` values (`llm`,
`tool`, …) are deliberately distinct from the legacy projection kinds
(`model_request`, `tool_call`, …) so the two layers never collide on the wire.

### D1 — Six span kinds and their OTel SpanKind mapping

`SpanKind` is a stable string discriminant. The six kinds and their OTel
`SpanKind` mapping:

| `kind` (wire) | Meaning | OTel `SpanKind` |
| --- | --- | --- |
| `llm` | One LLM request/response turn. The only kind carrying GenAI usage attributes. | `CLIENT` |
| `tool` | One tool invocation inside a turn. `parentSpanId` is the enclosing `llm` span. | `CLIENT` |
| `chain` | A composed step grouping child spans. | `INTERNAL` |
| `retrieval` | A context/document retrieval step. | `INTERNAL` |
| `agent` | The whole-session root span. | `INTERNAL` |
| `subagent` | A spawned sub-agent; `parentSpanId` is the enclosing `agent` span. | `INTERNAL` |

`llm` and `tool` are `CLIENT` because they represent a call out of the process
(to a model provider, or to a tool boundary). `chain`, `retrieval`, `agent`, and
`subagent` are `INTERNAL` — they organize the tree but do not themselves cross a
process boundary. The mapping is a projection applied when serializing to an OTLP
backend; the wire `kind` field is the source of truth and an OTLP consumer
derives the `SpanKind` from it.

The set is **closed**: the union is sealed (D5) so no consumer can add a seventh
kind out-of-band, and a validation helper enumerates exactly these six.

### D2 — `SpanCore`: the field set common to every kind

Every variant embeds `SpanCore`, whose JSON fields flatten onto the variant
object on the wire:

| Wire key | Type | Notes |
| --- | --- | --- |
| `traceId` | string | 16-byte trace id, hex-encoded (OTLP `traceId`). |
| `spanId` | string | 8-byte span id, hex-encoded (OTLP `spanId`). |
| `parentSpanId` | string | Parent span's id; **omitted** on a root span. |
| `kind` | string | The span-kind discriminator (D1). A **stored** field (D5). |
| `name` | string | Display name (e.g. `chat anthropic/claude-opus`). |
| `startTimeUnixNano` | string | Start time as **decimal unix-nanoseconds in a string** (D4). |
| `endTimeUnixNano` | string | End time, same encoding. |
| `status` | object | OTel span status: `{ code, message? }`. |
| `donmai` | object | The `donmai.*` extension group (D3); present on **every** kind. |

`status.code` is the OTel status vocabulary: `UNSET`, `OK`, or `ERROR`.
`status.message` is an optional human-readable detail, typically set only on
`ERROR`.

The per-variant additive fields:

- **`llm` (`LlmCallSpan`)** — adds `genAi` (D3), the GenAI semconv group.
- **`tool` (`ToolSpan`)** — adds `toolName` (e.g. `Bash`, `Edit`), `toolUseId`
  (the cross-process hook-bus correlation id that pairs the tool span with its
  hook-bus events), and `isError`.
- **`chain` (`ChainSpan`)** — adds `chainName`.
- **`retrieval` (`RetrievalSpan`)** — adds `queryHash` and `documentCount`.
- **`agent` (`AgentSpan`)** — adds `agentProvider` (the harness/provider that ran
  the session).
- **`subagent` (`SubagentSpan`)** — adds `subagentProvider`.

### D3 — Two attribute groups: GenAI semconv + `donmai.*` extensions

Attributes are grouped into two nested objects so the OTLP attribute-name mapping
is mechanical and unambiguous.

**`genAi` — OpenTelemetry GenAI semantic conventions (LLM spans only).** The
camelCase wire keys map to OTLP `gen_ai.*` attribute names at serialization:

| Wire key (`genAi.*`) | OTLP attribute | Notes |
| --- | --- | --- |
| `system` | `gen_ai.system` | GenAI system id (e.g. `anthropic`). |
| `requestModel` | `gen_ai.request.model` | Requested model id (e.g. `claude-opus-4`). |
| `usageInputTokens` | `gen_ai.usage.input_tokens` | Prompt/input token count. |
| `usageOutputTokens` | `gen_ai.usage.output_tokens` | Completion/output token count. |
| `usageCacheReadInputTokens` | `gen_ai.usage.cache_read_input_tokens` | Cache-read input tokens; omitted when zero. |
| `responseFinishReason` | `gen_ai.response.finish_reason` | Provider finish reason (e.g. `end_turn`, `max_tokens`); omitted when empty. |

**`donmai` — the `donmai.*` extension group (present on every kind).** Carries
tenancy and governance context the GenAI semconv does not cover. The OSS
namespace is `donmai.*`; a normalizer at the ingest boundary may remap these to a
deployment's own attribute namespace (out of scope for WS1). Wire keys → OTLP:

| Wire key (`donmai.*`) | OTLP attribute | Notes |
| --- | --- | --- |
| `orgId` | `donmai.org_id` | Owning organization id. |
| `workspaceId` | `donmai.workspace_id` | Workspace id (equals `orgId` in the current tenant model). |
| `sessionId` | `donmai.session_id` | Agent session this span belongs to. |
| `workType` | `donmai.work_type` | Work classification (e.g. `sdlc`); omitted when empty. |
| `poolId` | `donmai.pool_id` | Worker-pool id the session ran in; omitted when empty. |
| `cedarDecisionId` | `donmai.cedar_decision_id` | Links the call to the authorization decision that permitted it; omitted when empty. |
| `promptHash` | `donmai.prompt_hash` | Digest of the prompt (content-by-digest — raw prompt text stays off the hot path); omitted when empty. |
| `contextHash` | `donmai.context_hash` | Digest of the assembled context; omitted when empty. |
| `modelSnapshotId` | `donmai.model_snapshot_id` | Exact model-snapshot identifier used; omitted when empty. |

`orgId`, `workspaceId`, and `sessionId` are always present; the rest are
`omitempty`. Content is carried **by digest** (`promptHash`, `contextHash`): the
span is a governance/observability record, not a transcript, so raw prompt and
context text never ride the span hot path.

### D4 — Wire/JSON stability guarantees

The following are contractual and pinned by the golden fixture (D6):

- **camelCase JSON keys.** Every wire key is fixed camelCase. Renames are a
  breaking change and require a new ADR.
- **Timestamps are decimal-nanosecond *strings*.** `startTimeUnixNano` /
  `endTimeUnixNano` are JSON strings holding decimal unix-nanoseconds (matching
  OTLP/JSON's `fixed64` encoding). This is deliberate: a 64-bit nanosecond count
  exceeds the 53-bit integer range a JSON-number consumer can hold without
  precision loss, so encoding as a string keeps every consumer exact. Producers
  set these to the string form of the nanosecond count.
- **Stable `kind` literals.** The six `kind` string values are frozen; any
  OTLP-speaking consumer can dispatch off the JSON `kind` field.
- **`omitempty` is part of the contract.** The always-present keys (`traceId`,
  `spanId`, `kind`, `name`, `startTimeUnixNano`, `endTimeUnixNano`, `status`,
  `donmai`, and — on `llm` — `genAi`, plus `donmai.orgId/workspaceId/sessionId`)
  are guaranteed present; the rest are omitted when empty. A consumer keys off
  presence, and the golden fixture's fully-populated span makes the absence of
  any optional field detectable.
- **Closed union, discriminated by a stored field.** Only the six kinds exist;
  the `kind` field is authoritative and always emitted.

### D5 — Sealed union, stored discriminator, validated codec

`Span` is a **sealed interface**: an unexported marker method seals it so
external packages cannot introduce new variants, keeping the union closed. Each
variant reports its canonical `kind`.

The discriminator is a **stored `SpanCore` field**, not a value the codec injects.
Consequences:

- A plain marshal of any variant already carries the `kind` discriminator, so the
  bytes round-trip through the decoder without any injection step.
- The decoder (`UnmarshalSpan`) reads the `kind` field and dispatches to the
  matching variant struct. A **missing** `kind` and an **unknown** `kind` are
  both distinct, wrapped errors — a producer that forgets to set the
  discriminator fails loudly rather than silently decoding to a zero value.
- The encoder (`MarshalSpan`) is a thin validated wrapper: it rejects a nil span
  and a span whose canonical kind is not one of the six.

Producers **MUST** set the `kind` field to the variant's canonical kind. The
round-trip tests (D6) assert that every variant preserves every field through
marshal → unmarshal.

### D6 — Golden-fixture parity discipline

A single fully-populated `LlmCallSpan` — every optional field set, so the absence
of any field on the wire is detectable — is the **canonical span**. Its marshaled
bytes are pinned in `agent/testdata/llm_call_span.golden.json`. The discipline:

- **The fixture is the cross-language parity anchor.** Any language mirror of
  this contract copies the golden bytes **byte-for-byte**; a mirror that drifts
  from the fixture is by definition wrong. The fixture — not prose — is the
  source of truth for the wire shape.
- **Regeneration is explicit and reviewed.** The golden test regenerates the
  fixture only under an `-update` flag; a normal test run *asserts byte
  equality* against the committed fixture and fails on any drift. Changing the
  wire shape therefore shows up as a reviewable diff to a checked-in file, never
  as a silent change.
- **The fixture must round-trip.** The golden bytes must decode back to a span
  deep-equal to the canonical one, so the fixture cannot encode a shape the codec
  cannot read.
- **Every kind is covered.** A round-trip table exercises all six variants
  through marshal → unmarshal, asserting the decoded concrete type and that no
  field is lost; a wire-value test guards each variant's `kind` literal; a
  required-keys test asserts the canonical LLM span serializes every required
  top-level and nested key and that the timestamps serialize as JSON strings; and
  error-path tests pin the missing-kind, unknown-kind, and bad-field decode
  errors.

## Consequences

### Positive

- Per-LLM-call cost, latency, and cache-hit accounting become answerable from one
  durable record per model call, with a real parent/child tree instead of a flat
  event stream.
- OTel GenAI-semconv alignment means an OTLP-speaking backend can consume the
  spans with a mechanical attribute-name mapping and no bespoke translation.
- The `donmai.*` extension group carries tenancy/governance context (including the
  authorization-decision link) as first-class span attributes, so cost and
  governance queries hang off the same records.
- The golden fixture freezes the wire shape and anchors every language mirror to
  byte-identical bytes, so emission and ingest can be built independently against
  a contract that cannot silently drift.
- The sealed union + stored discriminator make the codec total and the kind set
  closed; malformed or unknown input fails loudly.

### Negative

- Two observability layers now coexist (the legacy session-event projection and
  the span tree). Until emission is wired, the span layer is types-and-fixture
  only — a contract with no live producer yet.
- The `donmai.*` namespace is OSS-specific; a deployment that wants its own
  attribute namespace needs a normalizer at the ingest boundary (deferred).
- camelCase-JSON + string-encoded nanosecond timestamps require a serialization
  step to reach canonical OTLP/protobuf; the contract is OTLP-*shaped*, not raw
  OTLP on the wire.

### Risks

- **Mirror drift.** A language mirror that diverges from the golden fixture
  breaks cross-language parity silently. Mitigation: the fixture is the byte-level
  anchor and the golden test fails on any drift; mirrors assert against the same
  bytes.
- **Timestamp mishandling.** A consumer that parses the nanosecond fields as JSON
  numbers loses precision. Mitigation: the fields are strings by contract and the
  required-keys test asserts the string type.
- **Discriminator omission.** A producer that fails to set `kind` produces
  undispatchable JSON. Mitigation: `kind` is a stored, validated field; both
  encode (nil/unknown-kind) and decode (missing/unknown) reject it.

## Alternatives considered

- **Extend the legacy session-event projection instead of adding a span layer.**
  Rejected: the projection is session-grained and flat; retrofitting per-call
  granularity and a parent/child tree onto it would either break existing
  consumers or bolt a second shape onto the same kinds. A distinct, additive span
  layer with its own kind vocabulary keeps the two cleanly separated.
- **Emit raw OTLP/protobuf spans directly.** Rejected for the wire contract: raw
  OTLP is harder to eyeball, diff, and golden-pin, and couples the OSS wire type
  to a specific protobuf runtime. camelCase JSON that maps *mechanically* to OTLP
  keeps the contract legible and golden-testable while staying OTLP-shaped.
- **Put GenAI usage attributes flat on `SpanCore`.** Rejected: only `llm` spans
  carry usage, and flattening would either pollute every kind with empty usage
  fields or make presence ambiguous. A dedicated `genAi` group on `LlmCallSpan`
  keeps usage exactly where it applies.
- **An open/extensible kind enum (allow arbitrary `kind` strings).** Rejected: a
  closed, sealed union with exactly six kinds lets the codec be total and lets
  consumers exhaustively switch. An open enum trades that for an extensibility we
  do not need at the wire layer.
- **Numeric (int64) nanosecond timestamps.** Rejected: 64-bit nanoseconds exceed
  the 53-bit safe-integer range of JSON-number consumers, causing silent
  precision loss. String-encoded decimal nanoseconds (OTLP/JSON's own choice)
  keep every consumer exact.
- **Ship emission + ingest together with the wire types.** Rejected: freezing the
  wire shape first (with a golden anchor) lets the poster and the store be built
  in parallel against a stable contract, instead of co-evolving three moving
  parts at once.

## Affected documents

- `007-intelligence-services.md` — the observability/tracing surface gains the
  per-LLM-call span contract as the canonical per-call record; note that it is
  additive to (not a replacement for) the session-event projection.
- `ADR-2026-05-12-cross-process-hook-bus-bridge.md` — the `tool` span's
  `toolUseId` reuses the hook-bus correlation spine defined there; cross-referenced,
  no content edit required.
- `README.md` § ADRs and `AGENTS.md` § Read order (ADRs) — add the index line for
  this ADR.

No edit touches a `BOUNDARY-SYNC`-marked region. The span *wire types, codec, and
golden fixture* are OSS-execution-layer substance and ship in the OSS `agent`
package; the platform-side consumers (emission poster wiring, the columnar
ingest/OTLP receiver, and the language mirror of these types) are platform
extensions tracked in the platform corpus. This ADR is the canonical wire
contract for both.

## Affected work items

Shipped as **P2-WS1** in donmai v0.49.3 (`agent/span.go`, `agent/span_test.go`,
`agent/testdata/llm_call_span.golden.json`). The emission poster (WS2) and the
ingest store (the keystone columnar/OTLP workstream) target this contract and are
deferred (see Open Items); they are tracked in the platform corpus.

## Open Items

- **Emission poster (WS2) — deferred.** The harness poster that populates spans
  from live runs (mapping the harness cost/usage data into `genAi.*`, stamping the
  `donmai.*` governance group, and wiring the trace/span id spine) is a separate
  workstream. WS1 ships the types and does **not** wire that mapping.
- **Ingest (keystone) — deferred.** The columnar store / OTLP receiver that
  consumes spans is the dependency that activates the whole trace cluster in
  production. It is not built or provisioned; downstream read/query/analytics
  surfaces sit behind in-memory seams awaiting it.
- **`donmai.*` → deployment-namespace normalizer — deferred.** Remapping the OSS
  `donmai.*` extension attributes to a deployment's own attribute namespace at the
  ingest boundary is out of scope for WS1.

## Implementation notes

- The contract lives in the OSS `agent` package: `agent/span.go` (the sealed
  `Span` interface, the six variant structs, `SpanCore`, the `genAi` and `donmai`
  attribute groups, and `MarshalSpan`/`UnmarshalSpan`), `agent/span_test.go` (the
  round-trip, wire-value, required-keys, golden, and error-path tests), and
  `agent/testdata/llm_call_span.golden.json` (the canonical pinned bytes).
- Regenerate the golden fixture with the test's `-update` flag; a normal run
  asserts byte equality and fails on drift.
- The `kind` discriminator is a stored field on `SpanCore`; producers must set it
  to the variant's canonical kind. The codec rejects nil, unknown-kind, and
  missing-kind input.
