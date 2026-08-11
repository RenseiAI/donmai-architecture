---
status: Proposed
date: 2026-08-11
boundary: shared
split: inline-addenda
---

# ADR-2026-08-11 — Dispatch-wire endpoint BaseURL

**Status:** Proposed
**Date:** 2026-08-11
**Boundary:** shared (OSS-canonical here; `status: Mirrored` stub in `rensei-architecture/ADR-2026-08-11-dispatch-wire-endpoint-baseurl.md`)
**Authors:** agent:claude (dispatch-wire packet)

## Context

`ADR-2026-06-06-two-axis-provider-model.md` D1 already defines the binding
currency that crosses into `Spec.Endpoint`: `EndpointBinding = (company,
model, baseURL, protocol, host, auth, …)`. The Go type
(`agent.EndpointBinding`) has carried `BaseURL` since that ADR landed.

The daemon's wire mirror of that currency — `daemon.SessionEndpointBinding`,
which crosses the local daemon's poll/detail HTTP boundary so `donmai agent
run` can rebuild a runnable `agent.EndpointBinding` from the session detail it
fetches — has never carried it. Every other axis (`company`, `model`,
`protocol`, `host`, the execution-cell identity fields) is mirrored field for
field; `baseURL` was a deliberate omission at the time, not an oversight, but
nothing records why, and the gap is no longer theoretical.

`ADR-2026-07-24-translating-gateway-model-endpoint-host.md` establishes that
an aggregator reached directly, same protocol, is the sanctioned
`Host: direct` + external `BaseURL` shape — no new `ServingHost`, no
translation claim. A harness whose binding IS how it resolves its endpoint
(rather than reading ambient environment variables the way today's shipped
paths do) needs that `BaseURL` to survive the exact hop this wire mirror
serves. Two producers now want to write one: a platform-side resolver
stamping a binding for an endpoint-driven harness onto a dispatch payload, and
a standalone `donmai agent run` invocation pointing such a harness at any
OpenAI-compatible endpoint directly (no platform involved) — both cross this
same wire, and both currently lose the value the moment it reaches the
daemon's session detail.

Today's only producer able to place an arbitrary base URL onto
`ResolvedProfile.Endpoint` is the worker-local translating-gateway binder,
which is loopback-only by construction (`ADR-2026-07-24` D1) and therefore
cannot represent an external aggregator's base URL at all. Nothing upstream of
that binder can express "drive this harness against this external base URL"
today, purely because the wire it would travel drops the field.

## Decision

1. `daemon.SessionEndpointBinding` gains `BaseURL string
   \`json:"baseUrl,omitempty"\``, mirroring `agent.EndpointBinding.BaseURL`,
   mapped through the wire→runtime conversion the daemon's HTTP-fetched
   session detail feeds. Additive and `omitempty`: absent on every dispatch
   that predates it, which round-trips byte-identically to today's behavior
   in both directions (an older producer omitting the key; a newer consumer
   reading an older payload sees a correctly-empty value rather than a
   spurious key).
2. Fail-closed validation applies at the exact seam where a dispatched binding
   enters the runner path — the wire→runtime conversion, before the value is
   trusted for a spawn. When present, `BaseURL` MUST be an absolute `http(s)`
   URL with a host and no userinfo; a non-loopback host MUST use `https`.
   Malformed input is rejected with a typed error there, in the same family as
   the harness-admission typed-denial shape (a fixed code + field name, no raw
   value echoed back) — never silently stripped or silently accepted. A
   dispatch that would have carried a bad URL now fails loudly at the seam
   that would have used it, instead of spawning with a URL nobody validated.
3. Credentials never ride the binding. `agent.EndpointBinding.Env` stays
   `json:"-"`; this ADR does not change that, and the new field carries no
   credential material — only the endpoint identity.
4. The existing loopback-only constraint a harness's own endpoint-application
   step enforces for a `Host: gateway` binding is unchanged and unrelated: it
   governs the OSS translating-gateway host specifically (per
   `ADR-2026-07-24`) and stays exactly as narrow as that ADR left it. The
   fail-closed check in point 2 runs earlier, at the wire boundary, for every
   `BaseURL` regardless of `Host` — it is a shape check on the value crossing
   the wire, not a replacement for any harness's own per-host routing rule.
5. `Host: direct` with an external `BaseURL` is the sanctioned shape for
   "same-protocol aggregator reached directly," per `ADR-2026-07-24` D1. This
   ADR does not introduce a new `ServingHost` or a new protocol-translation
   claim; it only lets the wire actually carry the value that shape requires.

## Consequences

### Positive

- Closes a gap between the binding currency `ADR-2026-06-06` already defined
  and what the daemon's own wire mirror could carry — the mirror now matches
  its source type on every field, not all-but-one.
- Unblocks any endpoint-driven harness (one that resolves its serving
  endpoint from the binding rather than from ambient environment) from being
  driven at an external base URL through a platform-resolved dispatch. Before
  this change, only the loopback-only worker-local gateway binder could place
  a base URL on the resolved profile at all.
- The fail-closed shape check is a pure addition at a seam that previously
  had no shape check on this field, because the field could not exist on the
  wire. No prior behavior narrows: a `BaseURL`-less dispatch is unaffected by
  construction.
- The same validation covers both producers named in Context — a
  platform-resolved dispatch and a standalone `donmai agent run` invocation —
  because both cross the identical wire→runtime seam.

### Negative

- One more field for every future wire-mirror struct change to remember to
  keep in lockstep with `agent.EndpointBinding`; the two types now diverge by
  zero fields where they diverged by one before, but nothing enforces that
  parity mechanically today.
- The validation is deliberately conservative (`https` required off loopback)
  even for endpoints an operator might trust over plain `http` in a private
  network. That tradeoff favors fail-closed default safety over
  configurability; revisiting it is a future ADR, not a config knob added
  quietly here.

### Risks

- A future producer could still choose to route credential-adjacent material
  through `BaseURL` query parameters or path segments, which this ADR's
  shape check does not and cannot detect — the `Env` / `json:"-"` boundary
  remains the actual credential guarantee, not URL shape validation.
- If a harness's own endpoint-application step and this wire-boundary check
  ever drift in what they each consider "loopback," a value could pass one
  and fail the other. They are independent by design (point 4) but should be
  kept behaviorally consistent for "what counts as loopback" even though they
  serve different scopes.

## Alternatives considered

- **Silently drop `BaseURL` at the wire boundary instead of validating it.**
  Rejected: this is exactly the shape of bug this corpus's fail-closed
  discipline exists to prevent — a caller believing a binding was honored
  when a boundary silently narrowed it. The wire either carries the value
  faithfully or the dispatch fails loudly; there is no third option.
- **Validate only inside each harness's own endpoint-application step,
  skip a wire-boundary check.** Rejected as the sole gate: a harness-local
  check only fires for harnesses that implement one, and only after the
  binding has already been trusted across process/module boundaries (the
  daemon → `donmai agent run` hop, and whatever constructs the `SessionSpec`
  in between). A malformed value should fail at the seam nearest where it
  entered untrusted, not wait for whichever harness happens to consume it.
  Per-harness checks (e.g. the loopback-only rule for `Host: gateway`) remain
  additionally in force for their narrower, host-specific concerns.
- **Extend `ServingHost` with a new translating-gateway-adjacent value for
  "external aggregator, direct."** Rejected: `ADR-2026-07-24` D1 already
  settled this — `Host: direct` plus an external `BaseURL` is the correct
  shape for a same-protocol aggregator reached directly, and this ADR is
  purely what lets that shape's `BaseURL` survive the wire. Adding a host
  value here would relitigate a settled decision for no benefit.

## Affected documents

None of the numbered reference docs require correction: the binding
currency, including `baseURL`, is already accurately described in
`ADR-2026-06-06-two-axis-provider-model.md` D1, and no doc claims the daemon
wire mirror carries every axis of that currency (the gap this ADR closes was
never asserted closed anywhere in the corpus). This ADR records the decision
to close it and is itself the reference for the wire-level detail.

## Affected work items

None cited here by design — this OSS-canonical ADR carries no tracker IDs.
Platform-side work items tracking the resolver/producer half of this contract
are recorded in the `rensei-architecture` mirror stub.

## Implementation notes

- Wire type: the daemon's session-detail endpoint-binding mirror gains the
  additive field, mapped through the same function that already bridges every
  other axis from the daemon's wire shape into the runner-consumable binding
  type.
- The fail-closed shape check lives beside the binding type it validates, as
  a plain function taking the raw string and returning a typed error (or
  `nil`); the wire→runtime bridge calls it before trusting the value, and
  returns the error rather than proceeding on a malformed input.
- Test coverage: wire-level JSON round-trip (value present; value absent —
  `omitempty` byte-identical to a pre-this-ADR payload); the validation
  function's accept/reject table (loopback `http` accepted, non-loopback
  `http` rejected, non-loopback `https` accepted, malformed/relative/userinfo
  rejected); and an integration-level test at the wire→runtime seam proving a
  well-formed value propagates, a malformed one is rejected rather than
  silently dropped, and an absent value is unchanged from prior behavior.
