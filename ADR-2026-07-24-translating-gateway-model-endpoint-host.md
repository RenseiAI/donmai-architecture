---
status: Proposed
boundary: shared
date: 2026-07-24
---

# ADR-2026-07-24-translating-gateway-model-endpoint-host

**Status:** Proposed
**Date:** 2026-07-24
**Boundary:** shared (OSS-canonical here; `status: Mirrored` stub in `rensei-architecture`)
**Authors:** open-harness strategy run, filed by the coordinator session

## Context

ADR-2026-06-06 D2 rules that only same-protocol
(harness × endpoint-host) cells are valid and names the sanctioned future
extension point verbatim: "Cross-protocol gateways are a future first-class
ModelEndpoint host kind (a translating-gateway host that owns the shim + its
own serving host + cost attribution); until one ships, no cell crosses
protocols." Demand for cross-protocol cells is now concrete (running one
company's models under another company's harness; consuming aggregator
gateways; enterprise federated serving), and third-party proxy tools that fill
this gap today do so by impersonating vendor clients — reusing vendors' own
OAuth client identifiers and generating disguised client fingerprints to
defeat provider enforcement. That approach is disqualifying for this project
regardless of utility: it evades counterparty enforcement systems, has
documented account-ban and re-metering consequences, and cannot pass an
enterprise security review.

Separately, auth for model access is a spectrum with three classes:
Class 0 (static API keys), Class E (enterprise federated auth: request-signing
and short-lived federated credentials on cloud-managed hosts — a compliance
IMPROVEMENT over static keys), and Class S (consumer-subscription OAuth, the
only class with per-provider terms-of-service gating, and the only class the
impersonation tooling targets). Provider posture on Class S is volatile and
competitive: at least one major provider publicly sanctions subscription
passthrough into third-party harnesses, at least two prohibit it, and postures
have reversed within single months. Any hard-coded posture will be wrong soon.

## Decision

Ship a translating-gateway host natively in the OSS daemon, filling the
reserved extension point, with the following contract:

1. **Modeling.** A new `ServingHost` value `gateway`. Company endpoint
   manifests declare `HostDesc` cells with `Host: gateway` and the wire
   protocol the gateway PRESENTS for that company. Cell validity is unchanged
   (D2 intersection rule); cross-protocol pairings become valid only through
   an explicit, hand-authored gateway cell. Models remain named by company;
   the gateway is where they are served from, never a model identity.
2. **Surfaces and translation.** The gateway presents the existing wire
   protocols (OpenAI-chat, Anthropic-messages, Gemini-generate; OpenAI-
   responses to follow) on a loopback listener with per-session bearer
   binding, and translates via one canonical intermediate representation
   (typed messages, tool calls, streaming deltas, canonical finish reasons,
   and normalized reasoning/thinking configuration). No pairwise ad-hoc
   translation.
3. **Backends.** Direct provider APIs (Class 0), enterprise federated hosts
   (Class E), OpenAI-compatible aggregators and self-hosted endpoints, and —
   policy-gated only — Class S subscription passthrough for providers whose
   terms sanction it.
4. **Auth policy is hot-reloadable data, never code.** A per-provider,
   per-class sanction table (versioned, fingerprinted, auditable) governs
   Class S. The shipped OSS default denies Class S except for providers with
   a recorded sanction. Platform-pushed org policy acts as a ceiling that the
   local file may only narrow (the same narrow-only fail-closed posture as
   ADR-2026-06-06 D5). The table is LIVING DATA with a named review cadence:
   provider posture has already reversed multiple times in 2026, so the
   architecture treats every entry as reversible without a deploy.
5. **Structural exclusions.** The gateway never reuses a vendor's own OAuth
   client identifiers, never fabricates or disguises client identity or
   fingerprints, never ships anti-detection options, and never pools
   consumer-subscription accounts (Class S credentials are own-account,
   locally held, and unrepresentable in pooled configuration). These are
   absences of code paths, not policy defaults.
6. **Cost attribution.** The gateway meters every upstream exchange and emits
   cost records keyed by endpoint company + host (primary) and harness
   (sibling), completing the dual-stamp that ADR-2026-06-06 D4 specified.
7. **OSS/platform split** (per ADR-2026-06-14 readiness rules and 001's
   contract): OSS ships the working gateway — surfaces, IR, translators,
   single-credential operation, the rotation/cooldown/failover state machine,
   local cost ledger, policy read-path. Platform-only: multi-credential
   pools over centrally administered credentials, org policy administration
   and the sanction-table UI, hosted cost ingest/dashboards, and any routing
   intelligence that CHOOSES cells (the gateway executes a chosen cell; it
   never chooses).

## Consequences

### Positive

- Every cross-protocol cell becomes legal through one audited chokepoint.
- Harness choice decouples from model economics.
- Enterprise deployments get federated auth as a first-class serving path.
- Posture changes are config flips, not deploys.

### Negative

- The daemon grows a network component (loopback-only) and a translation
  surface that must track three wire dialects.
- The matrix gains cells whose capability is unproven at birth — mitigated by
  the capability-tier gating (companion capability-measurement ADR / eval
  spine).

### Risks

- Translation-fidelity drift — mitigated: golden fixtures per surface ×
  upstream pair, benchmark-tested hot path.
- A sanction-table entry going stale against a provider posture change —
  mitigated: living-data review cadence, audit log of every Class S decision,
  keys-only fallback always present.

## Alternatives considered

- **Integrate or embed the existing third-party proxy tooling.** Rejected:
  its OAuth path is deliberate vendor impersonation with documented
  enforcement consequences; embedding it — even transitively — is an
  enterprise disqualifier and contradicts the auditability posture. Its
  MIT-licensed translation-matrix and rotation patterns are acknowledged as
  prior art; no code is taken.
- **Contracts-only in OSS, implementation platform-side.** Rejected: violates
  001 ("the OSS layer ships a working implementation of every interface —
  never only the type").
- **Model the gateway as a new company.** Rejected: breaks naming-by-company
  (requirement #2 of ADR-2026-06-06); the gateway is a serving host, not a
  model vendor.

## Affected documents

- `ADR-2026-06-06-two-axis-provider-model.md` — D2 note: the reserved host
  kind now exists; D4 dual-stamp completed.
- `002-provider-base-contract.md` — no enum change; model-endpoint family
  unchanged, host vocabulary gains one value.
- `011-local-daemon-fleet.md` / `ADR-2026-05-07-daemon-http-control-api.md` —
  daemon gains `/api/daemon/gateway` status surface.
- Matrix spec — new `binaryPins` and gateway cells sections.

## Affected work items

Tracked under the open-harness strategy program
(`runs/2026-07-21-open-harness-strategy/`); implementation phases are Wave 3
(gateway M1) and Wave 4 (gateway M2) of `12-work-breakdown.md`. No fleet
tracker issue is cited inline per this corpus's brand-neutral discipline.

## Implementation notes

M1 (single key, opencode-first consumer), M2 (cross-protocol + policy engine),
M3 (Class E upstreams), and M4 (gemini surface + sanctioned Class S) are
staged per `runs/2026-07-21-open-harness-strategy/08-design-gateway-host.md`.
Enabling any sanctioned Class S default is a separate founder-owned gate; this
ADR fixes only the mechanism and the deny-by-default seed, not the sanction
table's content.
