---
status: Proposed
date: 2026-09-09
boundary: shared
split: sibling-extensions
---

# Controller-registered host preflight before materialization

## Context

A host can compile and durably record a valid adaptation plan without its controller having recorded that fact. A controller requiring durable registration must not substitute a declaration, a capability advertisement, or an arbitrary non-null receipt reference for the actual host receipt.

The existing `host-adaptation/v1` producer is `runner.ProviderView.PreflightExecution`. It compiles the actual `PreparedHarness`, whose plan is digest-only, validates it, and returns ready/denied evidence. The daemon validates the request/worker/placement/claim binding and fsyncs the receipt before credentials or child spawn. This ADR proposes an additional, explicitly negotiated controller acknowledgement for callers that require it. It changes no v1 behavior and grants no implementation or activation authority while Proposed.

## D1 — Closed runtime-binding version

Keep `execution-runtime-binding/v1` byte-compatible. Add a separately decoded v2:

```json
{
  "contractVersion": "execution-runtime-binding/v2",
  "requestId": "request-1",
  "workerId": "worker-1",
  "placementId": "placement-1",
  "claimId": "claim-1",
  "preflightRegistration": {
    "contractVersion": "execution-preflight-registration/v1",
    "required": true,
    "challengeId": "challenge-1"
  }
}
```

All objects are closed; duplicate fields, unknown versions, missing fields and `required:false` refuse. `claimId` is omitted only for an exact admission that genuinely has no claim. Other identities are nonempty stable refs. The challenge is minted once by the authority owning the admitted execution context and is immutably bound to that exact request, worker, placement and claim. It is public correlation, **not a bearer token or an independent grant**. It cannot be chosen from a workarea or queued caller input.

A registrar capability states which codec/order a build implements. Runtime readiness separately proves the selected worker, placement, current admission and actual plan are eligible. Neither fact substitutes for the other. Require both before selecting v2. Old v1 decoders reject the unknown binding version before materialization; never downgrade v2 to v1 because registration is unavailable.

## D2 — Register actual bytes, then acknowledge

Preserve `host-adaptation/v1`. After compiling/validating and fsyncing the actual receipt, but before any credential hook or child spawn, submit:

```ts
{
 contractVersion:'execution-preflight-registration/v1',
 runtimeBinding:RuntimeBindingV2,
 receiptBytesBase64:string,
 receiptSha256:Hex64,
 operationalPayloadDigest:Hex64
}
```

The receiver authenticates the execution context through its existing authority, resolves the live admission/claim, and compares every binding field and challenge. A challenge alone never authenticates the sender. It strictly decodes the actual HostAdaptationReceipt, PreparedHarness, PromptDeliveryReceipt and ToolLifecycleReceipt and verifies all nested identity, decision and digest relations. The operational digest must match the actual admitted/forwarded execution payload. A ready outer receipt cannot hide denied or mismatched inner evidence.

Retain the original receipt bytes: `planDigest` hashes the original serialized plan. Parsing and reserializing through an unordered object store is not byte preservation. The plan contains digests/declared channel metadata, not prompt, environment, credential or config values. Reject unsupported fields rather than placing arbitrary submitted JSON in evidence.

The authority commits receipt evidence and its authorization transition atomically before returning:

```ts
type RegistrationResponse =
 | {contractVersion:'execution-preflight-registration/v1'; decision:'authorized';
    registrationId:StableRef; receiptSha256:Hex64; runtimeBinding:RuntimeBindingV2;
    authorizationRevision:PositiveInteger}
 | {contractVersion:'execution-preflight-registration/v1'; decision:'refused';
    code:'binding_mismatch'|'receipt_invalid'|'receipt_denied'|'claim_retired'|
         'authorization_unavailable'|'already_started'};
```

The host compares the complete response with its retained receipt and binding. Unknown/missing/refused/ambiguous responses authorize **zero credential materialization and zero spawn**. `authorizationRevision` identifies a real committed authority preimage, not a host-minted token.

## D3 — Replay and lifecycle conservation

A retry with the same bytes/binding/challenge may retrieve the same committed acknowledgement while that exact pre-start authorization is still live. Divergent bytes, a different worker/claim, or retired authorization refuse. A local receipt store must read/reaffirm the exact existing receipt; it cannot overwrite or recompile it into a different plan on retry.

An ambiguous acknowledgement leaves a protected admission. It does not create a new session, reset a queue generation, prove a process exists, or prove termination. Existing local process ownership/adoption and controller claim fences still govern duplicate-start prevention. Already-running or terminal receipt readback is not fresh start permission. A genuine denied-preflight or failed-start report may establish its own failure fact; a task/work result alone cannot establish session termination.

## D4 — Operational bytes and compatibility

The existing raw operational projection excludes only receipt/effective-cell/runtime-binding/operational-payload/host-receipt sidecars. Preserve all other fields, including unknown-but-permitted transport fields and present empty/false values, before typed `omitempty` mirrors. The registration handshake does not redefine that projection or reuse an unrelated logical-request digest as the operational digest.

V1 callers retain their existing local preflight order. V2 must be selected from actual advertised codec support plus separately verified readiness. The implementation must include an OSS-usable registrar over local admitted-session authority and durable storage, plus a connector-neutral registration hook/client; a hosted-only implementation or mock-only reference is insufficient under the layered model. No new provider family or general session authority is created.

## Verification and adoption

Before implementation acceptance, prove: old-version refusal before compiler/credential/spawn effects; malformed/duplicate/unknown fields; raw plan byte preservation; wrong worker/placement/claim/challenge/digest; denied inner receipt; forged authorized response; receiver rollback; lost ACK and exact replay; changed receipt retry; already-started/terminal refusal; local store persistence failure; and two contenders producing at most one start. Removing registration from the v2 path must produce RED with observed credential/spawn effects, then restored GREEN. Capability negotiation tests and real runtime-readiness tests are distinct.

Source baseline: donmai v0.72.26 (commit `f33d4524b4b10c794b63a1630b2d71a10a10175f`; annotated tag object `9b236cd9ed57189b4c308b72659a7500752f89bc`), `executioncell/runtime_binding.go`, `daemon/daemon.go`, `daemon/execution_preflight_store.go`, `runner/provider_view.go`, `agent/prepared_harness.go`. Architecture acceptance, implementation, release/internal-build qualification and activation remain separate.

## Reference updates at acceptance

The accepting change must update the relevant preflight/adaptation sections of `002-provider-base-contract.md`, `011-local-daemon-fleet.md`, `ADR-2026-08-05-versioned-execution-cell-and-session-reference.md` and `ADR-2026-08-06-harness-adaptation-plan-and-receipt.md`. This Proposed change adds no normative v2 behavior to those Accepted references yet. The hosted storage/permission/root-admission counterpart lives in the private extension corpus.

### Observed legacy refusal

A disposable checkout of that exact source ran the real daemon preflight harness with a future version and a complete future binding. Both refused at runtime-binding decode with compiler=0, local receipt writes=0, credential hooks=0 and no spawn marker. The existing denied-adaptation control reached its compiler/store before refusing. This proves the old decoder ordering, not v2 registration implementation.
