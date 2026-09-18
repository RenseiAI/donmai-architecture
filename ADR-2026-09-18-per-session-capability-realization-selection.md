---
status: Proposed
date: 2026-09-18
boundary: shared
split: sibling-extensions
---

# Per-session capability realization selection

## Context

A process-wide protected MCP profile cannot express two simultaneously valid
adapter versions for different admitted sessions. Enabling a newer process-wide
selector must not reinterpret older work. The admission producer already knows
the chosen realization, but the host compiler and child runner need the same
independently bound choice before producing their adaptation evidence.

This proposal extends the selection boundary of
[refreshable protected HTTP MCP authorization](ADR-2026-09-16-refreshable-protected-http-mcp-authorization.md).
It does not replace the v2 file/helper/materialization checks in that decision.
No implementation, release or activation is authorized by Proposed status.

## Decision

### 1. One closed selection inside the operational payload

Use the existing canonical operational payload, whose digest is bound by the
admission receipt, rather than adding a receipt-side compatibility mirror.
Its optional member `capabilityRealizationSelection` carries exactly:

```json
{
  "contractVersion": "donmai.capability-realization-selection/v1",
  "capabilityId": "workflow.draft.authoring/v1",
  "harnessId": "codex",
  "adapterVersion": "codex/interactive/tool-lifecycle-v2",
  "mode": "human_controlled",
  "recipeDigest": "<64 lowercase hexadecimal characters>",
  "declaredSurfaceDigest": "<64 lowercase hexadecimal characters>",
  "observationDigest": "<64 lowercase hexadecimal characters>"
}
```

The example names one realization; it is not a universal default. Identifiers
must satisfy their existing registry contracts and match exactly, without
trimming or case folding. Mode uses the existing closed execution mode.
The complete selection is limited to 8192 UTF-8 bytes. Missing required fields,
unknown fields, unsupported version/mode, duplicate JSON members at the outer
selection key or inside the object, invalid identifiers and digests refuse.
Duplicate detection occurs on raw input before normalization could erase it.
Absent and present-null are distinct: null is invalid, never legacy absence.

A trusted admission producer projects this tuple from its already selected
immutable realization. Caller-authored input cannot override it. Standalone
composition must ship a working local producer over the same admitted registry;
no hosted service is required to construct or verify the contract.

New protected V1 and V2 admissions both carry an explicit selection. The field
participates in the existing canonical payload digest; no separate selector
digest, new permission source or mutable environment override is introduced.
A producer must retain the exact historical payload rather than insert this
field during replay.

### 2. Verification precedes effects

Host preflight and child execution decode the same retained raw operational
bytes independently. Before provider/profile selection or any credential,
materialization or spawn effect, both paths must establish:

1. valid immutable admission, exact request identity and operational digest;
2. valid claim/runtime binding and the matching effective execution cell;
3. exactly one matching target capability and exact admitted harness/mode;
4. an exact registered realization for the selection tuple; and
5. equality of recipe, declared-surface and observation digests to the local
   compiled registry entry.

A pure provisional intent may be parsed earlier, but it is not authority and
must not escape into an effect before these checks. Every auxiliary provider
view/config-requirement/retained-admission entrypoint obeys the same boundary;
checking only the principal preflight method is insufficient.

The runtime-only profile field remains private and nonserialized. It is the
result of verification, never an alternate caller-controlled selector.
A retained host receipt must agree with the independently selected profile at
child recomputation. Compatibility mirrors cannot override raw payload bytes.
Removing or changing a new selection while retaining its admission digest
must refuse before effects.

### 3. One process-owned dual policy

A dual protected-MCP policy replaces neither individual selector's historical
semantics. It explicitly names one V1 and one V2 registered adapter for the
same capability/harness/mode. The adapter versions must differ; the V2 entry
must have its required common-file support. Construction rejects ambiguous
mixtures of the dual policy with either legacy individual-selector option.
Enabling the two old mutually exclusive fields together remains invalid.

The exact explicit per-session selection chooses one of those two entries.
Unknown, mismatched or unavailable entries refuse; no nearest-version or
process-default fallback is permitted. Selection is stateless across sessions,
including concurrent host preflight and child execution. Non-target work and
other harnesses retain their existing behavior.

The embedding application supplies identical policy and registry configuration
to host preflight and child execution. Advertising a V2 host capability requires
all actual consumers and v2 evidence checks, not just recognition of this field.

### 4. Historical absence has an explicit compatibility boundary

A dual policy defaults to refusing targeted work without explicit selection.
It may instead enable the process-owned `historical_v1` absence mode only as a
compatibility decision for a source whose unselected retained work is known to
mean V1. This is composition-time behavior, not a request field or permission
UI. The mode chooses exactly the configured historical V1 entry after all
existing raw-admission checks; it never chooses V2 or relaxes other evidence.

Before enabling this mode, the producer/operator must establish that every
retained or replayable targeted payload without the field belongs to V1.
Unselected work previously produced for a V2-only development configuration
cannot be moved silently onto such a host. It must remain on its original
compatible consumer or be explicitly refused before claim until a separate
migration decision resolves it. Draining current processes alone does not
account for durable queue/replay history.

Malformed/present-null/unknown selections never use the absence mode. New V2
selection stripped in transit fails its original payload digest, so absence
cannot become a downgrade path. Old V1-only binaries remain eligible only for
V1 work; placement must exclude them from explicit V2 work before claim.
A modern V1-only consumer refuses explicit V2 selection before effects.

### 5. Evidence and staged delivery

Freeze exported codec/API names and byte-identical golden vectors before
sibling implementations. Required controls include:

- exact V1 and V2 sessions handled sequentially and concurrently by one
  configured process, with matching host and child profiles;
- literal removal of raw-digest/selection binding causing a downgrade control
  to fail, restored to refusal;
- malformed, duplicate, null, foreign, unsupported and digest-mismatched
  selections refusing before credential/materialization/spawn counters;
- raw bytes preserved through queue, host detail and child recomputation,
  despite altered compatibility mirrors;
- absent historical V1 accepted only with the explicit compatibility mode,
  default absence refused, and unselected historical V2 never relabelled;
- old producer/V1-only consumer behavior retained; new explicit V1 on old
  consumer retains original canonical payload digest; V2 never reaches an
  incapable host; and
- the complete same-process refresh/OAuth-conflict proof from the existing
  protected-MCP ADR, without skipped native controls.

Protocol, producer, host/child consumer, embedding configuration, capability
advertisement and activation are separate stages. No capability advertisement
or production mapping may precede its actual consumer proof.

## Consequences and alternatives

One admitted tuple now selects behavior across process boundaries. This adds
closed decoding and a compatibility audit, but avoids process-global upgrades
of historical sessions. A host receipt is too late to select the compiler that
creates it. Environment booleans and mutable per-session maps are unbound
alternatives and are rejected. Rewriting historical receipts or payloads would
invalidate retained authority and is not a migration mechanism.

## Affected documents

On acceptance, amend the selection/rollout discussion in
`ADR-2026-09-16-refreshable-protected-http-mcp-authorization.md` and add the
implementation protocol/vectors. No synchronized core region changes are
proposed. The private companion owns hosted producer and rollout mechanics.
