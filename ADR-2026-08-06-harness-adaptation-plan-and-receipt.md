---
status: Accepted
boundary: shared
split: sibling-extensions
date: 2026-08-06
---

# ADR-2026-08-06 — Harness adaptation plan and applied receipt

**Status:** Accepted (architecture; implementation and promotion evidence pending)
**Date:** 2026-08-06
**Boundary:** shared (OSS-canonical contract here; the platform corpus carries a
thin mirrored stub and control-plane implications)
**Authors:** mixed-agent execution architecture lane

## Context

An admitted execution cell proves that one harness, model, endpoint, auth
binding, placement, session mode, and capability set may run together. It does
not yet prove that the selected harness has received the instructions, hooks,
tools, services, files, environment, and lifecycle adapters required for that
specific session.

Those concerns are currently projected through provider-specific code paths.
Some harnesses accept native system instructions, some expose only an append
flag, and some PTY paths receive only a seeded user turn. MCP may be a native
configuration, a temporary file, a gateway, or a runner-authored in-box stdio
server. Tool policy may be a native allow/deny grammar or a handshake-verified
injected boundary. Skills and intelligence services may become prompt text,
tools, environment, or files. Unsupported fields are sometimes stripped with a
warning. A role card can currently become a whole-system-prompt override and
therefore displace the harness operating protocol.

That last behavior conflates two different authorities:

- the **harness operating protocol** says how this harness works safely and how
  it participates in the execution layer; and
- **role intent** says what role the agent performs and what output it owes.

The same separation is required for child work. A harness-native child can
inherit mechanics from its parent process, while any headlessly drivable
harness can also be invoked as a child through an orchestrated, A2A, or host-CLI
edge. Neither path may bypass adaptation or evidence.

## Decision

After execution-cell admission (and after the claim gate for a claim-bound
placement) but before credential delivery and process spawn, the execution
layer MUST compute and apply a closed, versioned `HarnessAdaptationPlan`. It
MUST persist an initial `AppliedAdaptationReceipt` before spawn and append
runtime/cleanup outcome records as the session proceeds.

The plan is selected by the exact harness manifest, pinned harness version,
session mode, admitted capability grants, and operational-payload digest. It is
never inferred from a vendor/provider family name. Required entries that cannot
be applied deny spawn. An alternate delivery is legal only when the caller or
policy explicitly authorized that named downgrade before admission.

### D1 — Layered instruction authority

Instruction composition has four separately owned layers:

1. **Harness operating protocol** — harness/version-owned safety, lifecycle,
   control, and tool-use instructions. It is always preserved. No role card,
   kit, capability, model profile, or ordinary caller prompt may replace it.
2. **Base instructions** — execution-policy and session-mode instructions. The
   plan names `preserve`, `append`, or `replace`. `replace` requires an explicit
   `ReplacementAuthorizationRef` from the mode/policy authority and still does
   not replace the harness operating protocol.
3. **Role intent** — purpose, responsibilities, output contract, and behavioral
   emphasis, carried by `RoleIntentRef`. It is structured context or an ordered
   append, never implicit replacement authority.
4. **User turn** — the task prompt plus ordered prepend/append amendments. A
   user-turn amendment cannot be silently promoted into system/base authority.

```ts
type BaseInstructionStrategy = 'preserve' | 'append' | 'replace'
type UserPromptPosition = 'prepend' | 'append'

interface ContentRef {
  ref: string
  digest: string
  mediaType: 'text/plain' | 'text/markdown' | 'application/json'
}

interface ReplacementAuthorizationRef {
  id: string
  authority: 'session_mode' | 'execution_policy'
  scopeDigest: string
}

interface RoleIntentRef {
  id: string
  version: string
  purposeDigest: string
  responsibilityDigest?: string
  outputContractDigest?: string
}

interface BaseInstructionAdaptation {
  entryId: string
  strategy: BaseInstructionStrategy
  contentRef?: ContentRef
  replacementAuthorizationRef?: ReplacementAuthorizationRef
}

interface UserPromptAmendment {
  entryId: string
  amendmentId: string
  position: UserPromptPosition
  order: number
  contentRef: ContentRef
}
```

`preserve` means use the harness/version baseline unchanged. `append` preserves
that baseline and adds content after it. `replace` replaces only the replaceable
base-instruction layer and is invalid without explicit authorization. Content is
referenced by stable ref and digest; receipts do not copy prompt bodies.
`append` and `replace` require `contentRef`; `preserve` forbids it. A role-intent
ref names digests of role-owned content, not a rendered prompt or replacement
authorization.
The matching base entry uses `preserve_existing` only for `preserve`; append or
replace name the exact native API/config/CLI/prompt delivery used by the
harness profile.

Ordering is deterministic: ascending `order`, then `amendmentId` as a stable
tie-break. The receipt records the ordered digests actually applied.

### D2 — Closed adaptation plan

```ts
type AdaptationChannel =
  | 'base_instruction'
  | 'role_intent'
  | 'user_prompt_amendment'
  | 'lifecycle_hook'
  | 'mcp_server'
  | 'native_tool_definition'
  | 'tool_permission'
  | 'skill'
  | 'prompt_partial'
  | 'service'
  | 'credential_binding'
  | 'environment_binding'
  | 'config_file'
  | 'config_home'
  | 'endpoint_binding'
  | 'interactive_input'
  | 'event_normalization'
  | 'replay'
  | 'resume'
  | 'approval'
  | 'child_adapter'
  | 'cleanup'

type DeliveryStrategy =
  | 'preserve_existing'
  | 'native_api'
  | 'native_config'
  | 'cli_flag'
  | 'config_file'
  | 'environment'
  | 'gateway'
  | 'runner_in_box_stdio'
  | 'prompt_append'
  | 'injected_boundary'
  | 'host_adapter'

type AdaptationPhase =
  | 'pre_spawn'
  | 'spawn'
  | 'runtime'
  | 'shutdown'
  | 'cleanup'

interface AdaptationPlanEntry {
  entryId: string
  channel: AdaptationChannel
  required: boolean
  phase: AdaptationPhase
  delivery: DeliveryStrategy
  sourceRefs: string[]
  contentDigest?: string
  capabilityRef?: string
  permissionGrammarId?: string
  hookLocus?: 'host' | 'runner' | 'harness'
  cleanupEntryId?: string
  downgradeAlternatives?: string[]
  parametersDigest?: string
}

interface HarnessAdaptationProfileRef {
  id: string
  version: string
  manifestDigest: string
  wireProtocol: string
  transport: string
}

interface HarnessAdaptationPlan {
  contractVersion: 'donmai.harness-adaptation/v1alpha1'
  planId: string
  admissionReceiptId: string
  claimReceiptId?: string
  operationalPayloadDigest: string
  harness: HarnessRef
  harnessVersion: string
  upstreamBinaryVersion?: string
  adaptationProfile: HarnessAdaptationProfileRef
  sessionMode: SessionMode
  roleIntentEntryId?: string
  roleIntentRef?: RoleIntentRef
  baseInstructions: BaseInstructionAdaptation
  userPromptAmendments: UserPromptAmendment[]
  entries: AdaptationPlanEntry[]
  planDigest: string
  createdAt: string
}
```

The schema is closed. Unknown `contractVersion`, channel, delivery strategy,
phase, or field is a typed pre-spawn denial. Every entry has a stable identity
so application and cleanup are idempotent.

The specialized instruction fields are closed projections of `entries`, not a
second source of truth: `baseInstructions.entryId` matches exactly one
`base_instruction` entry; every amendment `entryId` matches one
`user_prompt_amendment` entry; and `roleIntentEntryId` plus `roleIntentRef` are
both present or both absent and match one `role_intent` entry. Any digest,
required flag, source, or delivery mismatch is a malformed plan denial.

An adaptation manifest attached to the exact harness/version contains one or
more profiles keyed by wire protocol, transport, session mode, endpoint/auth
mechanism constraints, and observed evidence. This is what keeps a shared raw
loop, multi-protocol harness, local subscription, API key, optional-key local
endpoint, and gateway path from collapsing into one provider-name guess. Each
profile declares:

- supported instruction strategies by headless and interactive mode;
- hook loci and lifecycle phases;
- MCP delivery strategies;
- native tool-definition and permission grammars;
- skill, partial, and service delivery strategies;
- credential-reference binding plus environment, config-file, config-home,
  endpoint, and cleanup behavior;
- interactive input, event, replay, resume, approval, and child adapters; and
- the evidence tier for each claim.

The plan compiler intersects that profile with the admitted cell, grants, and
operational payload. A generic harness or provider-family default may narrow
behavior, but may not create a capability absent from the exact profile. Raw
Gemini, raw Ollama, and an OpenAI-compatible local endpoint therefore use
different profile refs even when they share implementation machinery.
Commercial mode and auth mechanism come from the admitted `AuthBindingRef`:
harness-bound subscription/local OAuth, portable API key, self-hosted optional
key, and no-auth bindings remain distinct even when a product or harness offers
more than one of them.

### D3 — Services, skills, tools, and MCP are separate channels

The plan preserves the distinction between:

- a **service grant** (Memory, Code Intelligence, Architectural Intelligence,
  A2A, Kits, SCM, or another typed service), plus any separate credential
  binding that authorizes it;
- its **delivery mechanism** (native tool, MCP, gateway, CLI/config, in-box
  server, environment, file, or prompt amendment); and
- **usage guidance** explaining when the agent should call it.

Prompt guidance never proves that a service or tool is active. For example, a
required MCP-delivered capability cannot be replaced with “run this CLI” text
unless that exact CLI downgrade was named in advance, admitted, applied, and
recorded. A capability partial is attached automatically when its capability is
granted; users do not need to select a second magic partial to make the service
work. Optional explanatory partials may remain separately selectable.

Tool definitions and permissions are also independent. A harness can know a
tool exists while lacking a deny-preserving policy grammar. Autonomous spawn is
denied when the admitted policy cannot be enforced through a native grammar or
a handshake-verified injected boundary. Broad bypass flags are not an
adaptation strategy.

Secret material is delivered only after a successful initial receipt. Plans and
receipts contain secret/resource references and non-secret parameter digests,
never keys, tokens, credential payloads, auth headers, or rendered secret files.

### D4 — Applied receipt and truthful denial

```ts
type AdaptationOutcome =
  | 'installed'
  | 'preserved'
  | 'amended'
  | 'denied'
  | 'downgraded'
  | 'pending_runtime'
  | 'pending_cleanup'
  | 'cleaned'

type AdaptationDenialCode =
  | 'unsupported_contract_version'
  | 'unknown_harness_adaptation_manifest'
  | 'unsupported_harness_version'
  | 'unsupported_instruction_strategy'
  | 'replacement_not_authorized'
  | 'delivery_unsupported'
  | 'permission_boundary_unavailable'
  | 'required_entry_denied'
  | 'downgrade_not_authorized'
  | 'application_failed'
  | 'secret_material_detected'

interface AppliedAdaptationEntry {
  entryId: string
  outcome: AdaptationOutcome
  appliedDelivery?: DeliveryStrategy
  artifactRefs?: string[]
  evidenceDigest?: string
  downgradeToEntryId?: string
  denialCode?: AdaptationDenialCode
  detail?: string
}

interface AppliedAdaptationReceipt {
  contractVersion: 'donmai.harness-adaptation/v1alpha1'
  receiptId: string
  planId: string
  admissionReceiptId: string
  claimReceiptId?: string
  planDigest: string
  decision: 'ready' | 'denied'
  entries: AppliedAdaptationEntry[]
  recordedAt: string
}

interface AdaptationOutcomeRecord {
  contractVersion: 'donmai.harness-adaptation/v1alpha1'
  outcomeRecordId: string
  receiptId: string
  entryId: string
  outcome: Extract<AdaptationOutcome, 'installed' | 'denied' | 'cleaned'>
  evidenceDigest?: string
  denialCode?: AdaptationDenialCode
  recordedAt: string
}
```

The initial receipt is immutable and is persisted before credential delivery
and spawn. Pre-spawn entries must already be terminal (`installed`, `preserved`,
`amended`, `downgraded`, or `denied`). Runtime and cleanup entries may be
`pending_runtime` or `pending_cleanup`; their transitions are append-only
`AdaptationOutcomeRecord`s, never mutations to the initial receipt.

A `ready` receipt contains no denied required entry. Any required entry denial
produces `decision='denied'` and zero credential-delivery/spawn side effects.
Optional denial is truthful and visible. `downgraded` is valid only when it
names the original entry, selected alternative, and pre-authorized alternative
from the plan. There is no warn-and-strip path for a required entry.

If a required runtime entry later records `denied` (for example, a verified
policy boundary or hook bridge loses integrity), the host stops the session and
records a typed terminal failure. If required cleanup cannot be evidenced, the
affected process/config-home/workarea resource is quarantined from reuse and
the cleanup retry remains bounded and idempotent. Optional runtime/cleanup
failures remain visible but follow the caller's admitted continuation policy.

### D5 — Orchestration order

```text
DispatchIntent
  → execution-cell admission and immutable AdmissionReceipt
  → [claim-bound] narrow-only host claim and immutable ClaimReceipt
  → resolve exact harness/version adaptation manifest
  → compile HarnessAdaptationPlan
  → apply pre-spawn entries
  → persist initial AppliedAdaptationReceipt
  → if ready: deliver secrets and spawn exact admitted cell
  → append runtime and cleanup outcome records
```

Admission proves the requested capability can exist in the cell. Adaptation
proves how this harness instance received it. The adaptation plan cannot change
the admitted harness, model, endpoint, auth binding, placement, session mode,
capability grants, or fallback result. A required adaptation failure requires a
new dispatch/admission attempt if a different cell is desired.

### D6 — Interactive, replay, and approval adapters

Headless and interactive execution are modes of the same admitted harness, but
may require different adaptation entries. A PTY path that cannot carry the same
base instructions, policy boundary, tools, services, events, or endpoint pin as
the headless path must declare that gap. It may not inherit headless evidence.

`interactive_input`, `event_normalization`, `replay`, `resume`, and `approval`
entries bind the selected mode to the common `SessionRef` lifecycle. A session
is watchable/replayable only when the exact mode has evidence for the relevant
adapter. Terminal byte capture does not by itself prove structured-event,
resume, or approval fidelity.

### D7 — Native and non-native children

Every child execution cell gets its own adaptation plan and receipt. The
parent/child edge still owns the delegation transport:

- `native_harness` adds a native-child adapter entry that maps child identity,
  events, cancel, and terminal state onto the child `SessionRef`;
- `platform_dispatch`, `a2a`, and `host_cli` run the ordinary pre-spawn
  adaptation sequence for the independently admitted child.

A native child may explicitly reuse a parent process, config home, tool bridge,
or service connection. Each reuse is a referenced adaptation entry and resolver
decision, not inheritance by process accident. Native support remains an
optimization. Every production headless harness must prove at least one
non-native child path even if it also supports native children.

### D8 — Normative conformance fixtures

The generated conformance suite MUST include positive and negative fixtures for
each pinned harness/version and each supported session mode. Current
implementation work must cover at least these fixture families without treating
the list as a capability claim:

| Fixture family | Required proof |
|---|---|
| Claude Code | append/base behavior, CLI tool allow/deny, MCP config, endpoint env, headless and PTY differences, native-child event mapping |
| Codex | base-instruction/app-server behavior, approval bridge, MCP config, output/event mapping, headless and PTY differences |
| Amp | user/base instruction truth, MCP config, deny-preserving policy or typed denial, endpoint lockout, event/teardown behavior |
| Antigravity | PTY prompt/policy behavior, local-auth isolation, unsupported channel denials, teardown |
| OpenCode | config-home isolation, native permission map, MCP/config path truth, endpoint lockout, event/replay behavior |
| pi | RPC policy-handshake boundary, config-home isolation, tool registration, no-MCP truth, replay/resume |
| Raw API | native system/user/tool projection per exact protocol; Ollama and Gemini remain separate exact endpoint/protocol fixtures |
| Shell | interactive-only truth, no model/tool/service claims, terminal lifecycle |
| OpenAI-compatible local endpoint | exact harness × openai-compatible protocol × optional-key endpoint binding, including LM-Studio-shaped local inventory; never a provider-name shortcut |

The deterministic stub adapter may serve as a schema/conformance oracle but is
never production eligible and does not satisfy any real-harness fixture.

For every fixture family, tests assert:

1. preserve/append/authorized-replace instruction outcomes and an unauthorized
   replacement denial;
2. ordered user-prompt amendments;
3. each declared hook, MCP, tool, permission, skill, service, credential,
   environment, config, endpoint, and cleanup channel;
4. required-channel denial has zero spawn and secret-delivery side effects;
5. optional denial and authorized downgrade appear in the receipt;
6. secret-bearing fields cannot serialize into plan/receipt evidence;
7. cleanup is idempotent and evidenced; and
8. native-child conformance where claimed plus at least one non-native child
   smoke for every headlessly drivable production harness.

Fixtures must be generated from the exact adaptation manifest and pinned
binary, then checked against observed behavior. A fixture may lower evidence or
deny a channel; it may not edit the manifest into truth after the fact.

## Consequences

### Positive

- The admitted cell and the applied harness configuration become separate,
  auditable facts.
- Role cards can express rich role intent without replacing harness safety and
  operating protocol.
- Harness asymmetry is explicit without forcing a lowest-common-denominator
  abstraction.
- Interactive and child sessions use the same lifecycle while retaining
  mode-specific proof.
- “Service requested” can no longer silently mean “prompt mentioned a CLI.”

### Negative

- Each harness/version needs another manifest surface and more conformance
  fixtures.
- Plans and append-only receipts add durable records and cleanup bookkeeping.
- Existing warn-and-strip behavior must migrate behind the legacy adapter until
  all callers express required versus optional intent.

### Risks

- A manifest may overstate delivery until observed conformance gates it; routing
  therefore continues to use the evidence ladder, not declarations alone.
- Prompt layering can still duplicate instructions if content identities are
  not stable; digest-based fixtures and deterministic ordering are mandatory.
- Native-child adapters may lack upstream correlation fidelity. Such harnesses
  remain eligible through a non-native child path but cannot claim native-child
  lifecycle support.

## Alternatives considered

- **Continue translating a single generic spawn spec.** Rejected: omission and
  silent stripping hide real harness differences and cannot evidence cleanup.
- **Treat role-card system prompt as the whole harness prompt.** Rejected: role
  intent does not own the harness operating protocol or safety boundary.
- **Make every capability MCP.** Rejected: some services are native tools,
  gateways, hooks, files, or in-box processes, and some harnesses lack MCP.
- **Require native child support.** Rejected: any headlessly drivable harness
  can be a child through another admitted transport.
- **Put adaptation fields into `ResolvedExecutionCell`.** Rejected: the cell is
  identity/admission truth. Application is a later side effect with its own
  evidence and failure modes.

## Affected documents

- `002-provider-base-contract.md` — adds the harness adaptation surface and
  removes required-field warn-and-strip as a valid v1alpha1 outcome.
- `005-kit-manifest-spec.md` — kit contributions become source-addressed plan
  entries with deterministic prompt order and explicit failure semantics.
- `006-cross-provider-interactions.md` — adds the admission → adaptation → spawn
  seam.
- `007-intelligence-services.md` — service activation and usage guidance become
  separate, receipted channels.
- `013-orchestrator-and-governor.md` — inserts adaptation between claim/admission
  and credential delivery/spawn.
- `ADR-2026-06-15-kit-session-start-context.md` — amends graceful fragment loss
  when a required contribution was admitted.
- `ADR-2026-07-05-self-referential-stdio-mcp-in-box-capability.md` — amends
  prompt-only fallback and version-skew behavior to require explicit downgrade.
- `ADR-2026-07-24-harness-addition-v2-checklist.md` — adds adaptation manifest,
  fixture, receipt, and child gates.
- `ADR-2026-08-05-versioned-execution-cell-and-session-reference.md` — binds the
  post-admission adaptation record before spawn.

No synchronized `BOUNDARY-SYNC` section changes.

## Affected work items

The mixed-agent execution program tracks implementation by execution layer,
control plane, and smoke suite. Tracker identifiers remain in the project
tracker rather than the brand-neutral OSS corpus.

## Implementation notes

The current `Spec`, prompt builder, harness manifests, kit loader, MCP builder,
and per-harness spawn adapters become legacy inputs to the first plan compiler.
Migration should preserve old payload bytes while emitting `legacy_inference`
and optional-denial evidence. The control plane resolves role intent, explicit
required/optional capability intent, and authorized alternatives; the OSS
execution layer owns exact-harness application, pre-spawn denial, lifecycle
records, and platform-free conformance fixtures.

Current implementation deltas that the first compiler must close include the
whole-baseline `SystemPromptOverride`, headless/PTY prompt asymmetry, coarse
boolean manifest claims, warn-and-strip spec translation, and harness-specific
temporary config/config-home cleanup. Existing read sites are evidence inputs,
not proof that a channel is supported in every mode.
