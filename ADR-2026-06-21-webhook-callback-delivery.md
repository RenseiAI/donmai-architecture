---
status: Proposed
boundary: shared
split: sibling-extensions
date: 2026-06-21
---

# ADR-2026-06-21 — Webhook callback delivery: the push-back contract

**Status:** Proposed
**Date:** 2026-06-21
**Boundary:** shared (canonical here; mirrored stub in the platform corpus)
**Authors:** agent:claude (design session)

## Context

`ADR-2026-06-19-requester-provider-inbound-agent-family.md` defines the inbound
`RequesterProvider` family and its response envelope `{ result, receipt? }`
(`RequesterResponse` in `002-provider-base-contract.md`). The family contract serves
two delivery modes: a synchronous response for fast work, and poll/stream for
long-running work (the inbound dispatch returns immediately with a tracking handle; the
requester later redeems it). Both modes are **requester-pull**: the external agent comes
back to fetch the result.

A pull-only contract does not serve terminal-less and event-driven clients. An external
agent that fired a long-running `agent.request` and then went idle — a chat front-end
between turns, a serverless function that has already returned, an orchestrator that does
not hold a connection open — cannot poll. For these, the engine must be able to **push**
the completed envelope back to a requester-registered callback URL when the work
finishes. This is the egress dual of the inbound dispatch: the inbound direction
authenticates the requester *to* the engine; the push-back must authenticate the engine
*to* the requester, so the requester can trust that a callback POST genuinely came from
the engine and was not forged or replayed.

The family already names a delivery-action node (`requester.respond`, per
`ADR-2026-06-19`'s 2026-06-20 amendment) — the terminal node that hands the response
envelope back. The push-back is that node's egress mode. What is unspecified is the
**wire contract**: how a callback POST is signed, how a requester verifies it, how
retries and duplicate deliveries are made safe, and what governs whether egress is
allowed at all. This ADR pins that contract — and nothing about its implementation,
which is platform-side.

## Decision

**The engine MAY push a completed inbound response envelope to a requester-registered
callback URL. The OSS-canonical CONTRACT for that push-back is an HMAC-signed,
idempotent, retried POST, gated by deployment posture. Implementation is platform-only.**
Concretely, the contract is:

1. **The payload is the inbound response envelope.** A callback POST body is the same
   `{ result, receipt? }` envelope the synchronous/pull modes return (`002`), plus the
   tracking handle of the originating dispatch so the requester can correlate it to the
   request it fired. No new result shape; push-back is a third *delivery mode* of the one
   envelope, not a new payload.

2. **Every callback is signed with HMAC-SHA256 over the raw body, carried in
   `X-Agent-Signature`.** The signature header is **`X-Agent-Signature`** (brand-neutral),
   whose value is the lowercase-hex HMAC-SHA256 of the *exact raw request body bytes*,
   keyed by the per-requester callback signing secret. The requester verifies by
   recomputing the HMAC over the bytes it received and comparing in constant time. The
   header name and the HMAC-SHA256-hex-over-raw-body scheme are the OSS contract; a
   requester library reads `X-Agent-Signature` and verifies, exactly as it would any
   webhook signature.

3. **Replay and timestamp binding.** The signed material binds a timestamp so a captured
   callback cannot be replayed indefinitely. The contract carries the delivery timestamp
   in an `X-Agent-Timestamp` header and includes it in the signed input (the HMAC is
   computed over the timestamp concatenated with the raw body, in a fixed canonical
   form). A requester rejects callbacks whose timestamp is outside an acceptance window.
   This is the standard webhook anti-replay binding, named here so adapters do not invent
   divergent schemes.

4. **The callback signing secret is a one-time secret, issued at registration, rotatable.**
   The per-requester callback secret is shown **once** at issue time (registration or a
   subsequent rotate), stored by the engine only in a form sufficient to recompute the
   HMAC, and never returned again. Rotation issues a new one-time secret; the contract
   permits an overlap window during which either the old or the new secret verifies, so a
   requester can rotate without dropping in-flight callbacks. The secret is a property of
   the requester registration (`ADR-2026-06-20`), distinct from the inbound dispatch
   credential — the inbound bearer authenticates requester→engine; the callback secret
   authenticates engine→requester.

5. **Idempotency: every callback carries a stable delivery id; redelivery is the same
   id.** Each callback POST carries an `X-Agent-Delivery-Id` — a stable identifier for
   *this completed dispatch's result*, identical across every retry of the same delivery.
   A requester treats the delivery id as an idempotency key: a second arrival with a
   delivery id it has already accepted is a duplicate and is acknowledged without
   re-processing. The engine guarantees that retries of one logical delivery share one
   delivery id; distinct results never collide on a delivery id.

6. **Retry with bounded backoff; non-2xx is retryable, the contract is at-least-once.**
   A callback is delivered successfully when the requester responds `2xx`. A non-2xx or a
   transport failure is retried with bounded exponential backoff up to a finite ceiling,
   after which the delivery is marked failed and the result remains available via pull
   (`get_receipt` / poll). Because retries can produce duplicates, delivery is
   **at-least-once**, which is why idempotency (point 5) is mandatory rather than
   optional. The engine never blocks a dispatch's completion on callback success — the
   pull path is always the durable fallback.

7. **Egress is posture-gated.** Whether the engine performs callback egress at all, and
   to which destinations, is governed by the deployment **posture** carried on the
   requester registration (`ADR-2026-06-20`'s posture field; OSS defines the field and
   enum, the platform defines behavior). A permissive posture permits callback egress to
   registered URLs; a strict posture MAY forbid outbound callbacks entirely (pull-only),
   or constrain destinations (allowlist, no private-range targets). The contract requires
   that egress is a *gated* capability, never an unconditional one — an inbound surface
   that can be made to POST anywhere is an SSRF and exfiltration vector, so the gate is
   load-bearing.

8. **OSS owns the wire contract; the platform owns delivery.** OSS-canonical: the
   push-back as a delivery mode of `requester.respond`, the `X-Agent-Signature`
   HMAC-SHA256-over-raw-body scheme, the timestamp/replay binding, the one-time rotatable
   callback secret, the delivery-id idempotency key, the at-least-once retry-with-backoff
   semantics, and the posture-gated-egress rule. **Platform-only and out of scope here:**
   the delivery worker, the secret storage and rotation internals, the retry/backoff
   schedule and dead-letter handling, the egress allowlist enforcement, how posture maps
   to the egress decision, and the callback-URL registration UX. See the mirrored stub in
   the platform corpus.

## Consequences

### Positive

- Terminal-less and event-driven external agents are first-class: they fire an
  `agent.request` and receive the completed envelope by push, with no held connection and
  no polling loop.
- The signed, replay-bound, idempotent, retried contract is the standard webhook shape,
  so a requester can reuse any off-the-shelf webhook-verification library — it reads
  `X-Agent-Signature`, checks the timestamp, dedupes on the delivery id.
- Push-back is a *mode* of the existing `requester.respond` node over the existing
  envelope, so no new result type, trigger, or family is introduced — the egress surface
  is small and auditable.
- Posture-gating makes egress a deployment policy decision, so the same engine serves a
  permissive SaaS and a strict on-prem (pull-only) deployment without a code fork.

### Negative

- Push-back adds an outbound egress surface the engine did not previously have for the
  inbound family, with its own failure modes (timeouts, partial delivery, secret
  rotation). The pull path remains the durable fallback, but the egress path is genuinely
  new operational surface.
- At-least-once delivery pushes a real obligation onto requesters: they MUST dedupe on
  the delivery id. A requester that ignores idempotency will double-process on retry. The
  contract makes the obligation explicit, but it is an obligation.

### Risks

- An outbound callback to an arbitrary URL is an SSRF / exfiltration vector. The
  posture-gated-egress rule (point 7) is the mitigation and is load-bearing; a deployment
  that permitted unconstrained callback egress would expose the engine's network position.
  The contract must never invite egress that bypasses the posture gate.
- A weak or reused callback secret lets an attacker forge callbacks to a requester. The
  one-time-secret-with-rotation rule and the HMAC-over-raw-body-with-timestamp binding
  are the mitigations; a requester that verifies the signature and the timestamp window
  is protected even if a callback is intercepted.
- Idempotency-key collisions (two distinct results sharing a delivery id) would cause a
  requester to silently drop a real result as a duplicate. The contract requires distinct
  results never collide on a delivery id; the implementation must derive the id from the
  dispatch identity, not a coarser key.

## Alternatives considered

- **Pull-only; no push-back.** Rejected: it strands terminal-less and event-driven
  requesters, which are a primary BYOA audience (chat front-ends between turns, serverless
  callers). Pull remains the fallback, but push-back is the contract that serves the idle
  requester.
- **Sign callbacks with the requester's inbound dispatch credential (or its public key).**
  Rejected: the inbound credential authenticates requester→engine; reusing it for
  engine→requester conflates the two directions and couples callback verification to a
  rotatable dispatch bearer. A distinct, one-time callback secret keeps the two
  directions independent — rotating the dispatch credential never disturbs callback
  verification, and vice versa.
- **Best-effort, fire-and-forget delivery (no retry, no idempotency).** Rejected: an
  unretried callback drops the result on any transient requester outage, and an unkeyed
  delivery cannot be safely retried. At-least-once with an idempotency key is the minimum
  that is both reliable and safe.
- **Unconditional egress (no posture gate).** Rejected: it makes the inbound surface an
  unconditional outbound POST primitive — an SSRF and exfiltration vector. Egress must be
  a gated capability keyed on deployment posture.

## Affected documents

Edits land in the commit that flips this ADR to Accepted:

- `002-provider-base-contract.md` — the `RequesterProvider` inbound contract section
  gains push-back as the egress delivery mode of the response envelope, with the
  `X-Agent-Signature` HMAC scheme and the posture-gated-egress note.
- `006-cross-provider-interactions.md` — cross-reference: outbound callback egress is the
  push-back dual of the inbound dispatch, governed by the requester registration's posture.
- `016-workflow-engine.md` — the `requester.respond` delivery-action node note records
  push-back as a delivery mode (signed, idempotent, retried, posture-gated) in addition
  to the synchronous/pull return.

No edit here touches a `BOUNDARY-SYNC`-marked region, so no synchronized-section
ceremony is required; on acceptance, paired commits (OSS-side first) per `BOUNDARY.md`.

## Affected work items

To be filed on acceptance (the platform corpus carries the platform-side tracker
references).

## Implementation notes

Push-back is the egress mode of the `requester.respond` delivery-action node: on dispatch
completion, the engine signs the `{ result, receipt? }` envelope with HMAC-SHA256 over the
raw body (keyed by the registration's one-time callback secret), stamps `X-Agent-Signature`,
`X-Agent-Timestamp`, and a stable `X-Agent-Delivery-Id`, and POSTs to the registered
callback URL — but only when the registration's posture permits egress to that
destination. Non-2xx responses retry with bounded backoff (at-least-once; the requester
dedupes on the delivery id); on exhaustion the result remains pull-redeemable. The delivery
worker, secret storage/rotation, backoff schedule, dead-letter handling, egress allowlist,
and the posture→egress mapping are platform-only; see the mirrored stub in the platform
corpus.
