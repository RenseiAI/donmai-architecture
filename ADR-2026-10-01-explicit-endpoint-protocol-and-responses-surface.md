---
status: Accepted
boundary: shared
split: inline-addenda
date: 2026-10-01
---

# ADR-2026-10-01 — Explicit endpoint protocol and Responses gateway surface

**Status:** Accepted architecture. Implementation, release, conformance promotion and consumer adoption remain pending.
**Boundary:** shared; this public file is canonical.

## Context

One serving host can expose different wire protocols. Existing endpoint resolution and matrix validation select a host without an explicit protocol, while the native Codex custom-provider schema requires Responses. A Chat binding cannot become a Responses binding by changing a client configuration string. The gateway decision in [ADR-2026-07-24](ADR-2026-07-24-translating-gateway-model-endpoint-host.md) reserved Responses for a follow-up; this decision admits that real surface through the existing gateway and canonical intermediate representation.

The pinned Codex `rust-v0.157.1` [configuration schema](https://github.com/openai/codex/blob/36650394c5b38c2990ccf2a3457165ca3e9d9726/codex-rs/core/config.schema.json) declares Responses as its wire protocol. Its `model_provider`/`model_providers` configuration supports a base URL and environment-key/header references. This is an upstream contract reference, not evidence that the new endpoint or gateway is implemented or that an account can run a model.

## Decision

### D1 — Source-compatible explicit protocol selection

Preserve the layouts of `EndpointRequest`, `EndpointBinding`, `HostDesc`, `CellKey` and `HarnessEndpointCell`, and preserve the existing `ModelEndpointProvider.Resolve(context.Context, EndpointRequest)` interface. Add an optional endpoint capability and a working public helper:

```go
// package agent
 type ProtocolEndpointResolver interface {
     ProtocolManifest() ModelEndpointManifest
     ResolveProtocol(context.Context, EndpointRequest, WireProtocol) (EndpointBinding, error)
 }
 func ResolveEndpointProtocol(context.Context, ModelEndpointProvider,
     EndpointRequest, WireProtocol) (EndpointBinding, error)
// package matrix
 type ProtocolCellKey struct { Cell CellKey; Protocol agent.WireProtocol }
 func (cell HarnessEndpointCell) QualifiedKey() ProtocolCellKey
 func BuildProtocolView() (*ProtocolMatrixView, error)
```

These are accepted target signatures, not a claim that they already ship. The helper and shipped endpoint implementations land together; the optional interface must not exist only for an external implementation.

The helper uses the optional capability's full `ProtocolManifest()` when present; otherwise it uses the legacy `Manifest()`. The full manifest retains the same company identity and declares the opt-in `model-endpoint/v2` contract; the legacy manifest retains `model-endpoint/v1`. Both are projections from one declaration source. The explicit helper requires a nonempty declared protocol and exactly one manifest row matching `(request.Host, protocol)`. Unknown protocol or missing row refuses. Duplicate host/protocol rows refuse even if metadata is equal. The selected protocol must belong to the manifest's declared `Speaks` surface. No first/last-row selection, protocol relabeling, host fallback, process-environment read or credential lookup is allowed.

If the provider implements the optional capability, invoke it for that exact tuple. Otherwise the old `Resolve` may be used only when the requested host has one unambiguous declared protocol and it matches the explicit request. An old-only provider with several protocol variants refuses. Verify the returned company, host, protocol, model and resolved request axes against the selected declaration; a mismatch returns no binding. Preserve existing URL, auth, cost and admission validation. Errors support `errors.Is` (`ErrEndpointProtocolRequired`, `ErrEndpointProtocolUnsupported`, `ErrEndpointHostProtocolAmbiguous`, `ErrEndpointProtocolMismatch`) and contain no credential values.

The shipped OpenAI implementation supports explicit protocol selection. Its old `Resolve` retains its original defaults: OAuth-CLI selects Responses; direct, Azure and gateway select Chat. The actual legacy `Manifest()` also retains exactly one original default row per host; it never exposes all variants to old first/last-host consumers. Defaults are explicit references to the existing source declarations, not row-order behavior. A new ambiguous host without a legacy default refuses through the old interface. Adding a new row never changes a legacy default.

### D2 — Typed identity and one declaration source

In the opt-in `ProtocolManifest()` and qualified generated view, several `HostDesc` rows may share a host, but `(Host, Protocol)` is unique. Each row retains its own auth, cost and environment-key declaration. Cell validation selects the exact host/protocol tuple and applies the existing two-axis intersection and host rules. No serving-host alias is introduced.

`CellKey` and `Key()` retain the legacy three-field identity. `ProtocolCellKey` and `QualifiedKey()` add protocol for the qualified view; exact `(harness, endpoint company, host, protocol)` tuples are unique. There is no new textual ID format, parser or URL-escaping API. Existing endpoint bindings and execution-cell references already carry protocol; no new caller-essential or closed-wire field is introduced.

One authoritative source declaration references each original legacy default tuple. Generation validates exactly one retained default for every published legacy triple/host and derives both views from that source. There is no separately maintained legacy roster. A missing, duplicate or ambiguous default refuses; neither a unique new candidate nor its position supplies a default. Legacy allows apply only to their retained protocol; denies remain at least as restrictive. New variants never inherit a legacy allow automatically.

**Retired compatibility exception:** an original declaration may be source-marked legacy-only under an accepted retirement decision. Its exact default and aliases remain validated against the legacy manifest and retained v1 output, but it is not an active qualified cell. The optional full manifest may omit that exact retired tuple only when no active declaration uses it. Unsupported active tuples, unmarked missing defaults and duplicate pairs still refuse; adding a retired protocol to `Speaks` merely to satisfy validation is not allowed. The marker is internal source classification, not a runtime permission, exported capability field or second roster.

### D3 — Compatible generated views and evidence

The retained v1 projection covers **harness, endpoint and matrix artifacts**, not only the cell array. In particular, `EndpointManifest`/`EndpointRow.Hosts` in that view contain exactly the original single legacy-default row per host: exposing all variants there would let an old first/last-host map silently select a different protocol. Preserve current v1 semantic bytes and unique triples, apart from explicitly required existing version metadata. Existing `Manifest()`/`Resolve`, build APIs, artifact paths, aliases and struct layouts remain compatible. The full tuple manifest is visible only through the optional capability; generating a v1 projection alone does not protect direct legacy manifest consumers.

`BuildProtocolView` produces a separately named `capability-matrix/v2`, schema `p2.0` view with all declared host/protocol rows and qualified cells. `ProtocolMatrixView` is a new view type, not a change to the existing matrix struct. Both views come from the same declarations and are deterministically sorted: compare protocol after the legacy triple. Refuse duplicate qualified cells and duplicate host/protocol rows. Parity checks include both views and their default projections; a changed-identity view must not overwrite a v1 artifact.

New variants remain experimental and `Smoked=false` until executed evidence warrants promotion. Existing evidence tiers, receipts, actual inventory, auth, placement and narrowing predicates determine execution eligibility. No `liveEligible` field, caller permission boolean or presence-of-row grant is added. Consumers without qualified selection cannot enable new variants. Existing v1 consumers remain on their retained view; v2 consumers adopt the new semantic matrix ABI explicitly and pass paired parity/link checks before live use. A matrix row alone is never an admission receipt.

The active qualified projection excludes source-marked retired cells, their qualified default/alias references, and a harness whose authored cells are explicitly all legacy-only. A harness without an endpoint cell is not retired by inference. Full endpoint rows contain only supported active tuples; arbitrary rows must not be silently filtered because they fail validation. Both historical v1 retention and active v2 omission derive from the same declarations. This compatibility classification does not revive a retired implementation or grant execution.

### D4 — Real Responses surface through the existing gateway

Add the actual Responses HTTP surface to the existing loopback gateway, selecting and returning the exact requested inbound protocol in its binding. Preserve existing `Bind(BindConfig)` behavior as the Chat-only legacy path. Add `BindProtocol(BindConfig, agent.WireProtocol) (agent.EndpointBinding, error)` as an explicit opt-in: the protocol is required and implemented; a nonempty conflicting `BindConfig.Surface` refuses, and the returned binding must carry the exact selected protocol. There is no implicit protocol fallback or mutation of the caller's configuration. Preserve its per-session bearer routing, policy, credential pool, cancellation, cleanup and cost attribution. Decode Responses requests into the same canonical IR and encode actual Responses replies/SSE from it. A real Chat upstream may serve Responses inbound through this IR; a native Responses upstream codec is required only for a selected backend that needs it. Do not add a second proxy, admission store or credential authority.

Preserve supported item identity, tool calls/arguments/results, reasoning, usage, finish/error and streaming semantics. Unsupported or unrepresentable fields fail closed; never silently discard them or fabricate a successful result. Extend the existing IR only where concrete pinned-client behavior requires it. Inspect continuation semantics before adding any response-state support; this decision does not invent a history authority.

Interactive Codex model-provider configuration consumes an explicitly resolved compatible binding through its existing private configuration and process lifecycle. Named and unnamed paths share that selection. Credential values stay in private child environment or protected stores, never argv, configuration values or diagnostics. Zero-endpoint legacy and shared headless behavior remain separate. A genuine Responses implementation and truthful cell are prerequisites for the complete gateway-backed outcome.

## Consequences and alternatives

The additive capability preserves old provider implementers and unkeyed literals of the retained structs. Qualified identity changes matrix semantics, so generators, admission/policy consumers and downstream selectors need explicit adoption; unchanged v1 readers must not consume the new view implicitly. New codec/conformance work is required. Deferring the entire feature remains possible until the existing gateway prerequisite is implemented, but a client-only patch or Chat-to-Responses relabeling is not completion.

## Verification and adoption gates

Require exact dual-protocol selection, legacy-default/alias preservation, empty/wrong/ambiguous refusal, duplicate-tuple rejection, non-broadening legacy policy, deterministic generation and v1/v2 projection parity. Prove real Responses HTTP/tool follow-up/SSE, per-token isolation, cancellation/errors/usage and preserved Chat behavior through finite external fixtures. Prove the real Codex interactive consumer and exact cleanup. Compile-preserving production-removal controls must go runtime RED, then exact restoration GREEN. Run the normal source, tagged/static/guard/build, paired-smoke and downstream linkage gates. Fixture conformance is not real account entitlement, model execution, a release or live deployment.

## Affected documents and boundary

This accepting change amends ADR-2026-06-06 D1/D2/D3 and ADR-2026-07-24 decision 2, and adds references in `002-provider-base-contract.md`, `006-cross-provider-interactions.md` and `011-local-daemon-fleet.md`. The index/read order changes accompany it. The shared boundary contract is unchanged; no synchronized region is edited. A private corpus carries only a thin canonical pointer. Implementation and adoption remain explicitly pending.
