---
status: Accepted
date: 2026-10-18
boundary: shared
split: sibling-extensions
---

# ADR-2026-10-18 — Usage-v2 atom identity, evidence, and projection

**Status:** Accepted (founder approval 2026-10-18; no runtime availability implied)
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

This ADR fixes identity, counting vocabulary, evidence, and projections. A platform
companion ADR will reference this canonical contract for ingest, storage, and
retention without redefining its shared semantics. Its extension and mirrored
stub are separate deliverables; this ADR does not require a hosted service.

## Decision

Use one logical inference identity with separately identified physical attempts.
Count each attempt's selected usage once, preserving overlaps and unknown values.
The examples are contract fixtures, not a complete production schema.

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
summaries, and logical rollups are never additional attempts. D4 defines selection between competing evidence sources and completeness.

### D2 — Token vocabulary and containment

Counts are nonnegative integers (at most 2^53 - 1 in these JSON examples)
in tokens under the reporting model's tokenizer;
bytes, characters, requests, currency, and seconds are not tokens. Never retokenize
text and label it vendor-reported. The JSON usage fields are:

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
D4 closes evidence and completeness enums; neither is inferred from values.

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

### D4 — Evidence, completeness, and selection

Every observation carries `event_id`, `observer`, `usage_atom_id`, `source`,
`completeness`, and an authority-assigned `selected` flag. The closed source enum
is `provider_reported | gateway_reported | transcript_derived |
terminal_aggregate | estimated`. Source describes how counts were obtained:
forwarded native provider counters remain `provider_reported`; a gateway's own
measurement is `gateway_reported`. Observer identifies the reporting component.
These are usage evidence, separate from the spine's event-origin evidence kinds.

| Completeness | Claim |
|---|---|
| `complete` | Final observation accounts for the attempt under its stated definition; optional inapplicable counters may be null. |
| `partial` | Some consumption is known, but coverage or finality is incomplete. |
| `unavailable` | No reliable consumption counts; never synthesized as zero. |

Selection precedence is native per-attempt provider evidence, then correlated
gateway evidence, then transcript recovery, then terminal fallback, then an
explicit estimate. Lower-priority observations never add to a selected atom.
Gateway observations reconcile by `usage_atom_id`, not by creating another
attempt. Native evidence arriving later replaces fallback through a D1 correction.
A late transcript after native evidence is retained unselected. Equal-priority
conflicting evidence raises a typed conflict; wall-clock arrival never decides.
Completeness is independent of source and outcome: partial native evidence does
not become complete merely because a terminal aggregate exists.

Exactly one current observation is selected per atom; immutable observation
payloads remain intact and selection revisions are authority-owned. Do not mix
fields across sources to manufacture a complete observation. Terminal aggregates
are fallback and session cross-checks only. A summary without per-attempt identity
cannot be allocated to known atoms or added to their totals; preserve it as an
unreconciled session check. Missing correlation is a typed unresolved/double-count
risk, excluded from authoritative sums until reconciled. No heuristic join.

### D5 — Attempt lifecycle and possible charges

Usage completeness describes measurement, not session success or billing status.
Each attempt records whether **charge may have occurred**: `yes | no | unknown`.
Only positive evidence that dispatch never reached model execution permits `no`;
a transport error, cancellation acknowledgement, or zero counters does not.

| Case | Usage and identity rule | Charge may have occurred |
|---|---|---|
| Streaming | One atom; terminal cumulative snapshot replaces earlier snapshots; never sum chunks. | yes after execution; unknown if reachability is unknown |
| Retry | New attempt and ordinal, including failed attempts; sum distinct selected atoms. | yes or unknown per dispatched attempt |
| Fallback | New attempt even when model/endpoint changes; no cumulative retry counts. | yes or unknown independently |
| Timeout | Keep known counts partial; missing terminal evidence remains unknown. | unknown unless execution is confirmed, then yes |
| Cancel | Preserve consumption before cancellation; no refund inferred. | yes or unknown after dispatch |
| Partial response | Preserve measured fields; absent fields poison only their rollups under D2. | yes when execution is observed |
| Failed before provider | Keep attempt identity, unavailable counts and dispatch-failure evidence. | no only with proof of no execution; otherwise unknown |

Unavailable -> partial -> complete measurements advance only through immutable
observations and serialized selection revisions. Duplicate delivery is a no-op;
a correction can revise counts downward without a negative consumption attempt.
Terminal session state never prevents a late correction or recovery. A correction
recomputes affected rollups and exposes their new revision, without reopening the
session. Conflicts and unresolved correlations retain the previous valid selection
and surface a typed condition; they never silently increase charges.

### D6 — Projection law and authority

For a given revision, every projection uses the same distinct selected atom set
and D2 field-wise rollup. Carry identities, source, completeness, revision and
coverage alongside counts. Call, turn, session and terminal totals overlap and
MUST NOT be summed together. A turn groups logical inferences by explicit native
correlation; an absent turn correlation stays absent.

| Projection | Authoritative question and limits |
|---|---|
| Usage-v2 atoms and selection revisions | What measured consumption belongs to each physical attempt and logical inference? Canonical accounting input, including failures. |
| Six-kind span tree | Where did latency, errors and causality occur? `llm` projects selected attempt usage with atom correlations; gateway spans link the same atom. `tool`, `chain`, `retrieval`, `agent`, `subagent` add no consumption. A logical `llm` rollup lists its contributing atoms and is not another attempt. |
| `usage.recorded`, scope `call` | Durable usage observation/correction notification for a logical inference, with attempt/atom references and revision; replay preserves event identity. |
| `usage.recorded`, scope `turn` or `session` | Versioned rollup over named covered atoms; authoritative for that event's declared coverage only, never extra billing input. |
| Terminal session summary | Completion-time snapshot and reconciliation check, not final usage authority; exposes partial/unavailable coverage and later revision links. |
| Billing input | Distinct selected atoms at named revisions plus commercial mode; a separate pricing/settlement authority determines money and invoice commitments. Tokens alone never establish price or payment. |

The execution-event log remains replay authority with its existing event IDs and
cursors. Usage identity does not replace those laws or create a fifth telemetry
plane. Trace/analytics/export paths are rebuildable projections. Billing commitments
remain separately auditable; later corrections require explicit billing adjustment
rather than rewriting a settled invoice. OSS persists and projects usage locally;
hosted ingest, tenant policy, pricing and storage mechanics belong downstream.

**Supersession:** for usage-v2, any claim that Redis delivery, Collector receipt,
ClickHouse analytics, or a terminal/Postgres session-summary row alone establishes
canonical consumption is superseded by selected atom identity and revisions.
Postgres may implement a durable ledger, but a product name confers no authority.
This does not replace the session event log, lifecycle tiers, archive obligations,
or existing committed-cost authority; store topology is a companion decision.

### D7 — Privacy and version skew

Usage is metrics-only by default: identities, numeric counters, qualified resource
references, evidence and completeness. No raw prompt, output, tool arguments or
results, credentials, endpoint headers, or provider request/response body belongs
in an atom, span usage attributes, or usage event. Content capture is separate,
opt-in, access-controlled and governed by its own retention/deletion policy.
A pre-persistence redaction hook rejects forbidden content, including optional
extensions; failure is typed and fails closed. Digest hooks use approved keyed
or otherwise privacy-reviewed digests, with algorithm/key-version references;
never hash raw low-entropy content as a privacy substitute. Digests cannot join
otherwise uncorrelated calls. Exports inherit redaction and deletion obligations.

Usage envelopes declare `usage_version: 2`. Existing part-1 examples are vocabulary
examples; upgraded observation fixtures carry this version explicitly.

| Compatibility case | Required behavior |
|---|---|
| New producer, old consumer | Negotiate a supported version; an explicit lossy legacy projection declares lost evidence/completeness. Never silently reinterpret v2 or use that projection as canonical billing input. |
| Old producer, new consumer | Explicit legacy adapter preserves missing/zero/null, declares inferred evidence and unavailable coverage; never invents attempt correlation or completeness. |
| Unknown version | Typed `unsupported_usage_version`, no accounting/charge side effects; retain only bounded redacted diagnostic metadata and request supported replay. |
| Additive optional fields | Ignore unknown optional fields only within a supported version; preserve opaque metrics-only extensions when forwarding. Required semantics or enum changes require version negotiation. |
| Corrections | New immutable event with D1 keys and expected revision; unsupported correction handling blocks accounting promotion, never treats replacement as a delta. |
| Unsupported source cell | Typed `unsupported_usage_source` keyed by harness adapter version, endpoint/protocol and source; report unavailable coverage, never synthesize measured zeros or silently promote estimates. |

### Producer and consumer matrix

This table defines shared obligations, not hosted implementation availability.

| Component | Produces or consumes | Contract obligation |
|---|---|---|
| OSS runner | Produces native attempt observations and local rollups | Allocate D1 identities before dispatch; expose unsupported cells and retries. |
| Closed composing binary | Produces/forwards the same wire envelope | Preserve identity, revisions and redaction; composition adds no accounting atom. |
| Translating gateway | Produces correlated observations | Propagate/map atom identity; distinguish forwarded native counters from own evidence. |
| Platform trace path | Consumes span projection | Causality and latency; never sum gateway and harness usage. |
| Platform event path | Consumes durable usage events | Idempotent replay/corrections under existing spine cursors. |
| Platform billing path | Consumes selected atoms | Price eligible revisions under explicit commercial rules; audit adjustments. |
| Platform analytics path | Consumes rollups | Rebuildable analysis with source, completeness and revision. |
| Web | Consumes session/turn/call projections | Display unknown and unpriced explicitly; refresh on corrections. |
| iOS | Consumes the same projections | Same coverage and revision semantics; no client-side token pricing inference. |
| Customer OTLP/export | Consumes trace and/or accounting projections | Label projection type, retain atom correlation and privacy controls; never imply spans are invoices. |

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

The span contract, session spine, durable-event bus, execution-cell and data-lifecycle
docs carry dated amendment notes outside synchronized regions; those notes take
contract effect with this acceptance. Gateway and harness-versioning contracts supply
endpoint and adapter identities without amendment. The generated README index lists
this ADR as Accepted.

## Affected work items

Architecture-owner approval was recorded 2026-10-18. The producer adapters and
companion ledger work build on this accepted identity and vocabulary; this document
does not authorize release or activation.

## Implementation notes

[Golden fixtures](fixtures/usage-v2/README.md) exercise all six examples. Run
`bash scripts/check-usage-v2-fixtures.sh` and its `--selftest` mode. The checker is
a corpus test, not runtime code or live vendor conformance. Implementation, release and
activation remain separate from this acceptance.
