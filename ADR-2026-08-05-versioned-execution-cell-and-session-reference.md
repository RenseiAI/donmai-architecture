---
status: Accepted
date: 2026-08-05
boundary: shared
split: inline-addenda
---

# ADR-2026-08-05 — Versioned execution cell, admission receipt, SessionRef, and delegation edge

**Status:** Accepted — architecture decision; implementation, generated
contracts, migration, promotion, and release remain pending
**Date:** 2026-08-05
**Boundary:** shared (OSS-canonical contract here; the downstream control-plane
implications live in the mirrored platform stub)
**Authors:** mixed-agent execution architecture lane

## Context

The two-axis provider model correctly separates the harness that drives an
agent loop from the model endpoint it drives. It does not, by itself, identify
one executable run. Authentication, placement, session mode, requested
capabilities, evidence tier, and fallback decisions remain separate inputs.
Current callers can still infer one axis from another, rely on ambient endpoint
or credential state, silently strip an unsupported field, or select a default
harness after an explicit selector failed.

The same ambiguity appears in child delegation. A harness-native child, a new
local session, a remote A2A task, and a host CLI launch are different transports
for creating work, but transport must not define the child's semantic identity
or force it to inherit the parent's harness/model/endpoint/auth/placement by
process accident. Conversely, native child support is useful but cannot be the
requirement for acting as a child: any harness the runtime can drive headlessly
can be delegated to through another admitted transport.

Operators also need one lifecycle handle. Autonomous and human-controlled
sessions currently expose overlapping start, watch, input, cancel, and replay
surfaces. Interactivity is a capability and lease on a session, not a reason to
invent a second session identity.

## Decision

Adopt one additive, versioned execution-cell contract at the OSS boundary. A
caller submits a `DispatchIntent`; the admission layer resolves each independent
axis into a `ResolvedExecutionCell`, persists an immutable `AdmissionReceipt`
before enqueue, and returns one `SessionRef`. Every child uses the same contract.
Delegation transport is recorded on the parent/child graph edge, never fused
into the child cell.

This ADR accepts the architecture only. It does not claim that current Donmai
or downstream artifacts implement the types, receipts, adapters, or promotion
gates below.

### D1 — Contract version and closed decoding

The initial schema family is `donmai.execution-cell/v1alpha1`. Every top-level
object carries `contractVersion`. Decoders reject an unsupported version,
unknown field, unknown discriminator, duplicate field, or missing required
field with a typed `ContractError`; they do not ignore or silently reinterpret
it. This strictness applies at the admission boundary, where an ignored selector
can change what code, credential, or endpoint executes.

Additive migration is achieved with explicit adapters and a new compatible
schema revision, not permissive decoding. Existing queue payloads remain valid
through a legacy adapter until their callers emit the new contract directly.

```ts
type ContractErrorCode =
  | 'unsupported_contract_version'
  | 'unknown_field'
  | 'unknown_discriminator'
  | 'missing_required_field'
  | 'invalid_reference'
  | 'secret_material_forbidden'
```

### D2 — Independent reference types

The contract names each axis with a stable, non-secret reference. A reference
is not permission to use its target; admission must prove access and health.

```ts
interface HarnessRef {
  id: string
  version: string
}

interface ModelRef {
  id: string
  author: string
}

interface ServingEndpointRef {
  id: string
  protocol: string
  operator: string
  revision: string
}

interface AuthBindingRef {
  id: string
  mechanism: 'api_key' | 'oauth' | 'cli_session' | 'service_account' | 'federated' | 'none'
  commercialMode: 'usage_billed' | 'subscription' | 'platform_metered' | 'self_hosted' | 'free'
  authority: string
  bindingScope: 'process' | 'session' | 'harness' | 'endpoint' | 'host' | 'pool' | 'project' | 'org'
  portability: 'portable' | 'endpoint_bound' | 'harness_bound' | 'host_bound'
  delivery: 'environment' | 'endpoint_header' | 'brokered_token' | 'host_cli_home_reference' | 'platform_gateway' | 'none'
}

interface PlacementRef {
  id: string
  kind: 'host' | 'pool' | 'sandbox' | 'remote_peer'
  resolution: 'exact' | 'claim_bound'
}
```

`ServingEndpointRef` identifies routing configuration but never carries a
secret-bearing URL or header in a receipt. `AuthBindingRef` identifies the
technical mechanism separately from commercial mode, authority, scope, and
portability. It also names delivery independently: process environment,
endpoint header, brokered token, a host CLI-home reference, a platform gateway,
or no delivery for a no-auth endpoint. Delivery identifies the runtime boundary
without carrying credential bytes, tokens, file contents, headers, or
environment values. A runtime receives the actual binding through the named
secret-delivery boundary after admission.

Mechanism and commercial mode are deliberately orthogonal. A subscription for
an agent harness may use `oauth` or an already-authenticated `cli_session` and
be `harness_bound`; an API key is commonly `usage_billed` and
`endpoint_bound`; a local OpenAI-compatible server may be `none` or `api_key`
with `self_hosted`. `platform_metered` is a commercial mode, never an auth
mechanism. A subscription appearing in more than one harness catalog does not
make it portable: the binding's declared portability still controls admission.
Delivery is likewise orthogonal: `api_key` may arrive through an environment,
endpoint header, broker, or gateway, while `cli_session` commonly references a
host CLI home. `none` requires `delivery='none'`; it never authorizes ambient
credentials.

The legacy five-value `AuthMode` remains an adapter input; this ADR does not
rename that shipped wire. The adapter must project it into explicit auth-binding
metadata and record every inferred value as a resolver decision. In particular,
endpoint locality is not an authentication method.

### D3 — DispatchIntent and explicit fallback

`DispatchIntent` expresses requested identity and constraints without assuming
that model author, endpoint operator, credential authority, harness, or
placement are the same entity.

```ts
type SessionMode = 'autonomous' | 'human_controlled'

interface CapabilityRequirement {
  name: string
  parametersDigest?: string
}

interface FallbackAlternative {
  id: string
  harness?: HarnessRef
  model?: ModelRef
  endpoint?: ServingEndpointRef
  authBinding?: AuthBindingRef
  placement?: PlacementRef
}

interface DispatchIntent {
  contractVersion: 'donmai.execution-cell/v1alpha1'
  requestId: string
  harness?: HarnessRef
  model: ModelRef
  endpoint?: ServingEndpointRef
  authBinding?: AuthBindingRef
  placement?: PlacementRef
  sessionMode: SessionMode
  requiredCapabilities: CapabilityRequirement[]
  optionalCapabilities: CapabilityRequirement[]
  fallbackAlternatives: FallbackAlternative[]
}
```

Fallback is denied by default. Each permitted alternative is named in advance;
there is no implicit primary provider, ambient endpoint, or default harness
after an explicit selector fails. One admission may select only one complete
named alternative: it may not assemble a cross-product from axes that appear in
different alternatives. Applying an alternative produces a resolver decision
that names the rejected choice, selected alternative, and reason.

### D4 — ResolvedExecutionCell and admission equation

An execution cell is the exact result at the granularity known before enqueue:

```ts
type EvidenceTier =
  | 'declared'
  | 'implemented'
  | 'unit_verified'
  | 'integration_verified'
  | 'smoked'
  | 'production_eligible'

interface ResolvedExecutionCell {
  contractVersion: 'donmai.execution-cell/v1alpha1'
  harness: HarnessRef
  model: ModelRef
  endpoint: ServingEndpointRef
  authBinding: AuthBindingRef
  placement: PlacementRef
  sessionMode: SessionMode
  grantedCapabilities: CapabilityRequirement[]
  evidenceTier: EvidenceTier
  compatibilityDigest: string
  runtimeInventoryDigest: string
}
```

Admission is an intersection, never a provider-name rewrite:

```text
declared compatibility ceiling
AND live runtime inventory
AND exact auth-binding proof
AND placement reachability/capabilities
AND requested session/capability support
AND required evidence tier
```

The two-axis capability matrix is the declared compatibility ceiling, not live
availability or proof of production eligibility. Code shape or a manifest row
alone cannot promote a cell.

`PlacementRef.resolution='claim_bound'` is the explicit compatibility bridge
for a routed pool whose concrete host is selected only at claim. The pre-enqueue
receipt binds the pool/reservation and immutable machine-policy ceiling. The
claiming host re-runs the narrow-only gate and writes a separate immutable
`ClaimReceipt` with the concrete host and effective cell. It never mutates the
admission receipt. A denied claim never receives credentials and never spawns.

### D5 — Immutable receipts before side effects

Admission produces exactly one durable receipt before enqueue:

```ts
type AdmissionDenialCode =
  | 'unsupported_contract_version'
  | 'unknown_harness'
  | 'unsupported_harness_version'
  | 'unknown_model'
  | 'unknown_endpoint'
  | 'unknown_auth_binding'
  | 'unknown_placement'
  | 'unsupported_session_mode'
  | 'harness_unavailable'
  | 'endpoint_unreachable'
  | 'auth_unavailable'
  | 'placement_unsatisfied'
  | 'capability_unsupported'
  | 'evidence_insufficient'
  | 'fallback_not_allowed'

interface ResolverDecision {
  kind: 'explicit' | 'default' | 'inheritance' | 'fallback' | 'legacy_inference'
  field: string
  selectedRef: string
  sourceRef?: string
  reason: string
}

interface AdmissionReceipt {
  contractVersion: 'donmai.execution-cell/v1alpha1'
  receiptId: string
  requestId: string
  decision: 'admitted' | 'denied'
  intentDigest: string
  operationalPayloadDigest: string
  cell?: ResolvedExecutionCell
  denialCode?: AdmissionDenialCode
  denialDetail?: string
  resolverDecisions: ResolverDecision[]
  recordedAt: string
}

type ClaimDenialCode =
  | 'claim_conflict'
  | 'host_ineligible'
  | 'inventory_changed'
  | 'auth_unavailable'
  | 'capability_regressed'
  | 'evidence_regressed'

interface ClaimReceipt {
  contractVersion: 'donmai.execution-cell/v1alpha1'
  claimReceiptId: string
  admissionReceiptId: string
  claimId: string
  decision: 'claimed' | 'denied'
  effectiveCell?: ResolvedExecutionCell
  denialCode?: ClaimDenialCode
  denialDetail?: string
  recordedAt: string
}
```

An admitted receipt has `cell` and no denial fields. A denied receipt has a
typed denial and no cell. Receipts are append-only evidence: retry, claim,
spawn, adaptation, cancellation, and result records link to them instead of
rewriting them. Receipt serializers reject values matching secret-bearing
fields or delivery payloads; stable resource references and digests are the
only credential/endpoint configuration evidence they carry.

A claimed receipt has an exact-host `effectiveCell` and no denial fields. A
denied claim receipt has a typed claim denial and no effective cell. Its
effective cell must be a narrow-only subset of the admission cell: it may bind
the pool to one host and replace the pool inventory digest with that host's
inventory digest, but may not change the harness, model, endpoint, auth binding,
session mode, granted capabilities, evidence tier, compatibility digest, or fallback result.
Any capability regression is a claim denial; a change to an admitted axis
requires a new dispatch intent and admission receipt.

#### D5.1 — Applied harness adaptation links to admission

Per `ADR-2026-08-06-harness-adaptation-plan-and-receipt.md`, an admitted (and,
where applicable, claimed) cell does not proceed directly to credential
delivery and spawn. The exact harness/version compiles and applies a
`HarnessAdaptationPlan`, then persists an immutable initial
`AppliedAdaptationReceipt` linked by `admissionReceiptId` and optional
`claimReceiptId`. Only `decision='ready'` permits secrets and spawn.

Adaptation cannot change any admitted axis or fallback decision. A required
application failure is an adaptation denial, not permission to select a new
cell behind the receipt. Runtime and cleanup outcomes are append-only records
linked to the initial adaptation receipt.

### D6 — One SessionRef for every session mode

`SessionRef` is the common lifecycle handle for autonomous,
human-controlled, child, and remote-peer execution:

```ts
interface SessionCapabilities {
  watch: boolean
  replay: boolean
  cancel: boolean
  takeControl: boolean
}

interface SessionRef {
  contractVersion: 'donmai.execution-cell/v1alpha1'
  sessionId: string
  admissionReceiptId: string
  claimReceiptId?: string
  mode: SessionMode
  capabilities: SessionCapabilities
}
```

Autonomous sessions are watchable and replayable when the selected cell proves
those capabilities. Human control is a capability and lease represented by
`takeControl`; it does not create another storage model or session identity.
Structured events and terminal bytes may remain distinct evidence artifacts,
but both are addressed through the same session lifecycle.

### D7 — Delegation transport belongs on the edge

```ts
type DelegationTransport =
  | 'native_harness'
  | 'platform_dispatch'
  | 'a2a'
  | 'host_cli'

interface DelegationEdgeIntent {
  contractVersion: 'donmai.execution-cell/v1alpha1'
  edgeId: string
  parent: SessionRef
  childRequestId: string
  transport: DelegationTransport
  inheritedFields: string[]
  detached: boolean
}
```

Every child submits a normal `DispatchIntent`, receives its own
`AdmissionReceipt`, and obtains its own `SessionRef`. An inherited field is an
explicit resolver input listed on the edge and recorded as an `inheritance`
decision; no child inherits credentials, placement, workarea, or model merely
because it shares a process.

Track native support and child eligibility separately:

- `canSpawnNativeChildren`: the harness exposes a child primitive and its
  events/lifecycle have a Donmai adapter.
- `canRunHeadlessly`: Donmai can start, observe, cancel, and obtain a terminal
  result without a human control lease.

The universal child rule is `canRunHeadlessly` plus at least one admitted
delegation transport. Native support may reduce latency or share context, but
it is an optimization. A native child still gets a logical `SessionRef`, an
admission receipt, and an edge; any shared process, context, workarea, auth, or
continuation domain is explicit in its cell and resolver decisions.

### D8 — Legacy adapter and cutover discipline

The first implementation is additive. A legacy adapter maps current queued-work
and resolved-profile fields into `DispatchIntent`. The execution contract is a
sidecar to the existing operational payload: prompt/body, repository/ref,
stage, budget, kit, policy/tool, MCP, skill, memory, continuation, and other
non-axis fields remain on the existing payload and are forwarded unchanged.
The adapter binds their stable byte digest into admission evidence; it does not
copy them into an execution-cell object or silently decode/re-encode them.

The required legacy projection is:

| Existing input | v1alpha1 projection |
|---|---|
| `resolvedProfile.harness`, else documented legacy provider mapping | `HarnessRef`; inferred mapping is a `legacy_inference` decision |
| `resolvedProfile.model` + `company`/provider catalog identity | `ModelRef`; model author is not inferred from endpoint operator |
| `servingHost` + matrix endpoint revision/protocol/operator | `ServingEndpointRef` |
| `authMode` + stable `credentialId`/pool binding + non-secret credential requirements | `AuthBindingRef`; the adapter derives mechanism, commercial mode, and delivery from endpoint/credential metadata because legacy `authMode` conflates them; values remain outside payload and receipt |
| scheduler route/pool/host/sandbox selection | `PlacementRef`; an unresolved pool is `claim_bound` |
| `mode` (`interactive`/`interview` versus headless) | `SessionMode` plus required watch/input/control capabilities |
| allowed/disallowed tools, MCP servers, skills, kits, and service blocks | required/optional capability names and parameter digests; definitions remain on the operational payload |
| legacy `subAgent` override | explicit child intent fields or explicit inheritance decisions on the edge |
| `platformAllowed` and machine narrowing inputs | admission policy ceiling; preserved for the claim gate, never broadened |

For every known current payload fixture, `legacy payload → intent + untouched
payload → legacy projection` must be field-for-field equal under the existing
wire semantics, including absent versus present-empty distinctions. A field
without a lossless projection blocks adapter promotion; it is not dropped.
Specifically:

- fused provider/model and derived harness values become separate refs;
- scalar auth mode becomes an explicit inferred `AuthBindingRef`, including its
  independent delivery boundary;
- serving host and capacity selector become endpoint/placement refs;
- absent selectors use only existing documented defaults and record
  `legacy_inference` decisions;
- no adapter may silently substitute an unknown explicit selector or drop a
  required capability.

The adapter is a migration boundary, not the final authoring model. A receipt
shows exactly which values came from legacy inference so operators can remove
those defaults safely.

### D9 — Normative semantic fixtures

The generated contract suite must materialize these semantic fixture families.
The examples below use stable references only; strings beginning `auth_` are
resource identifiers, never credential values.

**Fixture F1 — every ownership axis may differ.** The following cell is valid
when live inventory and evidence gates pass:

```json
{
  "contractVersion":"donmai.execution-cell/v1alpha1",
  "harness":{"id":"opencode","version":"pinned-v1"},
  "model":{"id":"llama-large","author":"meta"},
  "endpoint":{"id":"lmstudio-main","protocol":"openai-chat","operator":"local-operator","revision":"rev-7"},
  "authBinding":{"id":"auth_lmstudio_optional_key","mechanism":"api_key","commercialMode":"self_hosted","authority":"local-user","bindingScope":"endpoint","portability":"endpoint_bound","delivery":"endpoint_header"},
  "placement":{"id":"mac-studio","kind":"host","resolution":"exact"},
  "sessionMode":"autonomous",
  "grantedCapabilities":[],
  "evidenceTier":"smoked",
  "compatibilityDigest":"fixture-f1-compatibility-digest",
  "runtimeInventoryDigest":"fixture-f1-runtime-inventory-digest"
}
```

No resolver may rewrite model author to `local-operator`, endpoint operator to
`meta`, auth authority to either, or harness to an endpoint-branded id. A second
variant changes the auth-binding mechanism to `none` while preserving every other
axis except delivery, which becomes `none`, proving optional-key
OpenAI-compatible endpoints are explicit cells, not new model providers and do
not inherit ambient credentials.

**Fixture F2 — child semantics do not depend on transport.** Four edge fixtures
share one parent `SessionRef`, one child request semantic digest, and one child
`DispatchIntent`; their only differing semantic field is edge `transport`:

| Fixture | Edge transport | Required result |
|---|---|---|
| F2-native | `native_harness` | independently resolved child cell + receipt + `SessionRef` |
| F2-dispatch | `platform_dispatch` | same child semantic digest and independently resolved lifecycle |
| F2-a2a | `a2a` | same child semantic digest and independently resolved lifecycle |
| F2-host-cli | `host_cli` | same child semantic digest and independently resolved lifecycle |

Transport-specific correlation metadata may differ and belongs on the edge.
The child identity, cell rules, denial taxonomy, and lifecycle contract do not.

**Fixture F3 — fail closed before spawn.** Unknown contract version, harness,
harness version, model, endpoint, auth binding, placement, session mode,
required capability, and any fallback not named in `fallbackAlternatives` each
produce a typed denial receipt. Generated negative fixtures assert zero enqueue,
credential-delivery, claim, and spawn side effects and scan every object for
secret-bearing values.

An unsupported version or malformed closed-schema payload that still exposes a
valid `requestId` produces a denied receipt in the responder's supported
version. A payload too malformed to identify a request produces a typed
`ContractError` instead. Both are pre-enqueue, pre-credential, and pre-spawn
outcomes.

## Consequences

### Positive

- Model author, endpoint operator, auth authority, harness, and placement can
  differ without provider-specific branches.
- Every default, inheritance, and fallback becomes reviewable evidence.
- Autonomous, interactive, native-child, platform-dispatched, A2A, and host-CLI
  execution share one lifecycle identity.
- Any headlessly drivable harness can participate in mixed-agent delegation.
- A routed pool retains the existing claim-time host choice without mutating or
  weakening the pre-enqueue receipt.

### Negative

- Admission becomes a durable step rather than an in-memory resolver result.
- Strict decoding requires coordinated schema revisions instead of silently
  accepting new fields.
- Native children need logical session/receipt adapters even when the upstream
  harness exposes only an event nested in the parent process.
- Legacy defaults remain temporarily, but their inferred decisions increase
  receipt size and surface existing ambiguity.

### Risks

- **Receipt without exact host.** A claim-bound placement could be mistaken for
  a concrete-host proof. Mitigation: the resolution discriminator is required,
  the claim receipt is separate, and credentials/spawn remain after the host's
  narrow-only gate.
- **Secret leakage through evidence.** Endpoint/auth configuration could be
  copied into a receipt. Mitigation: refs and digests only, closed schemas, and
  serializer rejection of secret-bearing material.
- **Logical native-child identity without lifecycle fidelity.** Some harnesses
  may not emit enough information to correlate a child. Such a harness may
  remain headless-child eligible through a non-native transport but cannot
  claim `canSpawnNativeChildren` until its adapter passes conformance.
- **Compatibility matrix mistaken for availability.** Mitigation: evidence tier
  and live inventory digest are required fields of every admitted cell.

## Alternatives considered

- **Keep the two-axis cell as the complete run identity.** Rejected: it omits
  auth binding, placement, mode, capability request, evidence, and resolver
  provenance.
- **Fuse auth and endpoint into a provider instance.** Rejected: it makes
  endpoint locality, subscription authority, and harness portability implicit
  again and does not survive distributed placement.
- **Make native sub-agent support the child gate.** Rejected: it excludes every
  headlessly drivable harness that can be launched through the orchestrator,
  A2A, or host CLI.
- **Use a separate interactive session identity.** Rejected: watch, replay,
  cancel, and terminal evidence are shared lifecycle concerns; control is a
  capability, not a storage model.
- **Mutate the admission receipt when a host claims.** Rejected: it destroys the
  evidence of what was known before enqueue and makes retries race on one row.

## Affected documents

- `001-layered-execution-model.md` — orchestration principles and Layer 3 gain
  execution-cell, child-delegation, and common-session semantics.
- `002-provider-base-contract.md` — gains the versioned execution-cell wire
  contract, strict admission rules, evidence tiers, and legacy adapter.
- `006-cross-provider-interactions.md` — gains the intent → admission → claim →
  spawn seam and delegation-edge invariant.
- `013-orchestrator-and-governor.md` — dispatch and sub-agent sections consume
  admission receipts and `SessionRef`.
- `ADR-2026-06-06-two-axis-provider-model.md` — the two-axis matrix becomes the
  declared compatibility ceiling inside the broader cell.
- `ADR-2026-04-27-plugin-and-workflow-architecture.md` — the original
  intra-session-only child discipline is amended to the typed session graph.
- `ADR-2026-08-06-harness-adaptation-plan-and-receipt.md` — defines the linked
  post-admission/pre-spawn plan and applied receipt.

No `BOUNDARY-SYNC` region changes in this ADR. The platform corpus carries a
mirrored stub with a small downstream implication section under the
dual-publish rule.

## Affected work items

Downstream tracker linkage and implementation sequencing live in the platform
mirror. This OSS corpus intentionally carries no platform tracker identifiers.

## Implementation notes

Implementation should begin with generated/hand-shared fixture shapes and
legacy adapters without a scheduling behavior change. Required proof fixtures
include host-bound subscription cells, direct and translated API cells, a
generic OpenAI-compatible endpoint with no auth and API-key auth, a claim-bound
pool, and native/non-native child delegation. Production promotion requires
negative admission tests and at least one non-native child smoke for every
production-eligible headless harness. The same fixtures feed exact-harness
adaptation plans so admission and applied configuration cannot drift into two
unrelated contract suites.
