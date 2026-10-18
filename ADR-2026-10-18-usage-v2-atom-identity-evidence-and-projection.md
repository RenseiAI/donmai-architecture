---
status: Accepted
date: 2026-10-18
boundary: shared
split: sibling-extensions
---

# ADR-2026-10-18 — Usage-v2 atom identity, evidence, and projection

**Status:** Accepted (part 1; no runtime availability implied)
**Date:** 2026-10-18
**Boundary:** shared
**Authors:** execution architecture contributors

## Context

One inference can be observed by a harness, a translating gateway, and a terminal
session summary. Retries and fallback can each consume tokens, even on failure.
Adding these observations counts the same work repeatedly; retaining only the
successful response loses consumption from failed attempts. Input, cached input,
output, and reasoning counts also overlap under some model-vendor definitions.

The [span contract](ADR-2026-06-28-per-llm-call-observability-span-contract.md)
and [session spine](ADR-2026-08-16-one-session-substrate-and-typed-event-spine.md)
provide correlations, but neither correlation nor an aggregate is an inference
identity. The [gateway contract](ADR-2026-07-24-translating-gateway-model-endpoint-host.md)
separates translation from model execution; usage must preserve that distinction.

This first part proposes fixed identity and counting vocabulary. A platform
companion ADR will reference this canonical contract for ingest, storage, and
retention without redefining its shared semantics. Its extension and mirrored
stub are separate deliverables; this proposal does not require a hosted service.

## Decision

Use one logical inference identity with separately identified physical attempts.
Count each attempt's selected usage once, preserving overlaps and unknown values.
The examples are proposed contract fixtures, not a complete production schema.

### D1 — Identity and correlation

A **logical inference** is one semantic model operation requested by a caller.
`logical_inference_id` is minted before dispatch, stable across retries, fallback,
stream chunks, replay, and observers. A new user operation gets a new identity,
even if its prompt is identical. `semantic_operation` names the actual operation
(e.g. `chat`, `embedding`, `rerank`); it is not inferred from the span kind.

A **physical attempt** is one separately tracked try to dispatch to a model endpoint.
`inference_attempt_id` is minted before dispatch, unique within the logical
inference, and stable on replay. `attempt_ordinal` starts at 1 and increases for
every retry or fallback, including a failed-before-dispatch attempt with unknown
usage. Changing endpoint or model never resets it. An SDK or gateway retry must
expose another attempt; hiding it cannot justify a complete accounting claim.
Forwarding the same request through a gateway is not a second execution attempt.

| Key | Meaning and rule |
|---|---|
| `logical_inference_id` | Durable logical identity, namespaced by the originating execution authority. |
| `inference_attempt_id` | Physical-attempt identity under that logical identity. |
| `usage_atom_id` | Stable accounting identity: authority + logical inference + attempt. All observers correlate to it. |
| `event_id` | One immutable observation event; retransmission preserves it. Different observers may have different events for one atom. |
| `idempotency_key` | Authority + `event_id`; identical replay is a no-op, different payload under the same key is a conflict. |
| `correction_of_event_id` | Prior event replaced by a new immutable event for the same atom; never an additional consumption delta. |
| `atom_revision` | Authority-assigned increasing revision; correction must reference the current revision or conflict. No timestamp-based winner. |
| `model_vendor_request_id`, `model_vendor_generation_id` | Optional vendor correlations, scoped to vendor and endpoint; never universal dedup keys. |
| `trace_id`, `span_id`, `execution_event_id` | Trace/span and execution-event correlations; do not replace usage identity or event cursors. |
| `native_session_id`, `native_turn_id`, `native_message_id` | Optional harness-native correlations, scoped by harness and session. |

The execution authority owns identity allocation and serializes atom revisions;
observers carry that identity rather than minting competing accounting atoms.
If a correlation is unavailable, preserve the gap instead of guessing from token
counts, prompt equality, model name, time proximity, or a native turn alone.
A turn may contain several logical inferences. A gateway must propagate or map
the incoming identity durably before its observations can be joined.

A correction replaces the selected value for an atom, not its attempt identity.
Concurrent corrections conflict rather than both counting. A logical rollup sums
the latest selected revision of each distinct attempt, including failed attempts.
Multiple observations of an attempt, cumulative stream snapshots, terminal
summaries, and logical rollups are never additional attempts. Selection between
competing evidence sources and its completeness policy remain part-2 work.

### D2 — Token vocabulary and containment

Counts are nonnegative integers (at most 2^53 - 1 in these JSON examples)
in tokens under the reporting model's tokenizer;
bytes, characters, requests, currency, and seconds are not tokens. Never retokenize
text and label it vendor-reported. The proposed JSON usage fields are:

| Field | Meaning |
|---|---|
| `input_tokens` | All input tokens under the explicit input definition. |
| `cache_read_input_tokens` | Input served from a cache. |
| `cache_write_input_tokens` | Input written to a cache; not an extra additive charge count. |
| `output_tokens` | All generated output under the explicit output definition. |
| `reasoning_output_tokens` | Reasoning tokens, with containment stated explicitly. |
| `total_tokens` | Vendor-reported total or explicitly derived input + output. |
| `accepted_prediction_output_tokens`, `rejected_prediction_output_tokens` | Vendor-defined speculative/predicted output counters; containment must follow that definition, never assumed. |
| `input_text_tokens`, `input_audio_tokens`, `input_image_tokens`, `input_video_tokens` | Optional modality breakdown of input. |
| `output_text_tokens`, `output_audio_tokens`, `output_image_tokens`, `output_video_tokens` | Optional modality breakdown of output. |

Modality breakdowns are not assumed exhaustive or disjoint. Do not sum breakdowns
into their parent or add cache/reasoning counts to input/output again. Unknown
vendor-specific counters remain separately qualified evidence, not invented
canonical tokens. Cache reads and writes need not be disjoint from each other.
Cache-write lifetime buckets are breakdowns, not extra input. Uncached input is
derivable only when the vendor defines exhaustive, disjoint cache partitions;
never subtract an unknown cache count or assume rejected predictions are free.

`token_semantics` accompanies each usage object and identifies the applicable
vendor definition by `definition`, with `cached_in_input` and
`reasoning_in_output` booleans. When true, cache read and cache write are each
<= input, and reasoning <= output. When false, preserve the vendor's disjoint
counter without forcing containment; do not manufacture an inclusive count.
Missing semantics is not permission to assume containment or disjointness.
Logical containment is asserted only when all contributing attempts share the
same containment semantics; incompatible definitions require separate rollups.

`total_basis` is `provider_reported` or `derived_input_plus_output` whenever a
numeric total is present. A derived total equals input + output and requires both
numeric parents. A reported total retains its vendor definition and need not
equal input + output. The fixtures identify the definition and reporting path;
part 2 will close the evidence and completeness enums, not infer them from values.

Three JSON states are distinct: an absent field means missing/unknown, `0` means
measured zero, and `null` means not applicable under the stated definition.
This supersedes “omitted when zero” **only for the new usage-v2 atom**; the frozen
span wire contract is unchanged. An unknown count never becomes zero on ingest.
For each rollup field: any missing contributing value makes the aggregate absent;
otherwise sum numeric contributions, ignoring explicitly inapplicable ones;
all-null contributions produce null. These are known-usage totals, not a claim
that a partial failed attempt accounts for all possible charges.

A streamed response has no zero usage merely because early chunks omit usage.
Its terminal cumulative snapshot replaces earlier snapshots for that attempt;
chunks are not summed. A failed attempt with partial usage retains those counts.
The successful fallback reports only its own consumption, never cumulative retry
consumption. Transport failure alone cannot prove that no charge occurred.

### D3 — Qualified nouns

Unqualified `provider_id`, `run_id`, and `agent_id` are forbidden in usage-v2.
Use the axis being described; do not copy one identifier into several axes.

| Ambiguous noun | Qualified replacement | Meaning |
|---|---|---|
| provider / model | `model_vendor_id`, `requested_model_id`, `resolved_model_id`, `model_revision` | Model origin and requested versus served identity. |
| provider / endpoint | `endpoint_operator_id`, `model_endpoint_id` | Entity operating the selected endpoint and its configured identity. |
| host | `inference_host_id` | Service or local process actually executing model inference. |
| gateway | `translating_gateway_id` | Protocol translator, nullable for a direct call; not the model vendor. |
| protocol | `upstream_wire_protocol`, `downstream_wire_protocol` | Caller-to-gateway and gateway-to-model protocols, explicitly oriented. |
| mode | `auth_mode`, `commercial_mode` | Credential mechanism versus metered, subscription, or local commercial arrangement; no secret values. |
| placement / provider / host | `placement_ref`, `execution_context_id`, `execution_context_provider_id`, `execution_host_id` | Agent execution placement, context supplier, and machine; distinct from inference hosting. |
| run | `execution_session_id`, `workflow_run_id`, `logical_inference_id`, `inference_attempt_id` | Select the actual lifetime rather than a generic run. |
| agent | `harness_id`, `harness_adapter_version`, `agent_definition_id`, `execution_session_id` | Harness implementation, its adapter version, authored role, or live session. |

An unavailable identity is absent; an inapplicable axis is null. Routing through
an operator does not establish model vendor, inference host, or commercial mode.
No endpoint URL, credential, or raw model content is needed in these fixtures.

## Consequences

### Positive

- Retries remain attributable without counting gateway observations twice.
- Explicit containment prevents cache and reasoning inflation.
- Local consumers and a platform companion can share identity and vocabulary.

### Negative

- Producers must expose hidden retries and propagate identities across gateways.
- Honest missing counts make some totals unavailable rather than deceptively zero.

### Risks

- A cumulative fallback value can inflate accounting; fixture mutation tests pin
  the independent-attempt sum, but cannot prove a live vendor report truthful.
- A producer can misdeclare containment; adapter-specific evidence is still needed.

## Alternatives considered

- **One atom per observer:** duplicates harness and gateway observations.
- **Successful attempt only:** discards failed-attempt consumption.
- **Add every token counter:** double counts contained cache and reasoning tokens.
- **Native request ids as identity:** unavailable before dispatch and not universal.
- **Treat missing as zero:** falsely asserts measurement and completeness.

## Affected documents

The span contract, session spine, and gateway contract linked above are inputs;
no Accepted document is amended by this part. Part 2 must reconcile their
projection and supersession notes, along with the execution-cell, durable-event,
harness-versioning, and session-data-lifecycle references. No synchronized region
changes here. The README generated ADR index gains this proposal.

## Affected work items

Architecture-owner review precedes part 2. The producer adapters and companion
ledger work can use these proposed identity and vocabulary fixtures for planning;
this document does not authorize release or activation.

## Implementation notes

[Golden fixtures](fixtures/usage-v2/README.md) exercise direct, terminal-stream,
and failed-retry/fallback accounting. Run `bash scripts/check-usage-v2-fixtures.sh`
and its `--selftest` mode. The checker is a corpus test, not runtime code.

Part 2 edits this same ADR after this part merges and receives owner review:
source/evidence and completeness enums; projection law for spans, `usage.recorded`
call/turn/session events, terminal summaries and billing; privacy; version skew;
producer/consumer matrix; unpriced/local and transcript-recovery fixtures; remaining
failure/cancellation semantics; and the decision whether to move to Accepted.
It must preserve the existing event identity and cursor laws rather than create
another independent telemetry plane. No storage-topology authority changes here.
