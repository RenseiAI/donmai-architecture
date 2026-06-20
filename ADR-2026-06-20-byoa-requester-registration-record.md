---
status: Proposed
boundary: shared
split: sibling-extensions
date: 2026-06-20
---

# ADR-2026-06-20 — Requester registration: the inbound principal record

**Status:** Proposed
**Date:** 2026-06-20
**Boundary:** shared (canonical here; mirrored stub in the platform corpus)
**Authors:** agent:claude (design session)

## Context

`ADR-2026-06-19-requester-provider-inbound-agent-family.md` defines the inbound
`RequesterProvider` family: an external agent authenticates, submits a unit of work
into the engine via an `agent.request` trigger, is an attributable principal, and
expects a result back. That ADR specifies the *family contract* and the
*two-sided handshake* shape — identity flows requester → engine, verification trust
flows engine → requester — but it deliberately leaves the **anchor record** of that
handshake unspecified. It names the obligations ("registers once per org with a
human-readable identity, a cryptographic identity, and a capability declaration …
receives a scoped credential. Every request is attributable to that registered
identity") without naming the *thing* those obligations attach to.

Without a single named record, three concerns scatter:

1. **Attribution** — what stable identity does an inbound `agent.request` stamp into
   the audit trail, distinct from the bearer credential it arrives with?
2. **Authorization** — what bounds *which* projects and *which* workflows a given
   external requester may invoke, independent of the raw credential's scopes?
3. **Posture** — what carries the per-requester governance strictness that the
   platform layer enforces, so a single inbound surface can serve both a permissive
   and a strict deployment without a code fork?

Folding these onto the credential itself is wrong: a credential is a bearer secret
that can be rotated, revoked, and re-minted, whereas the identity, the allowed
surface, and the posture are stable properties of the *requester relationship* and
must outlive any one credential. This ADR names that relationship record.

## Decision

**An inbound requester REGISTERS, once per org, as a scoped principal. The
registration — not the credential — is the attribution and authorization anchor for
every `agent.request` dispatch.** Concretely, the OSS-canonical shape is:

1. **The registration is a first-class, named record**, distinct from and
   longer-lived than any credential. A credential is *bound to* a registration; the
   registration is the durable principal, the credential is a rotatable bearer of it.

2. **A registration carries a scoped principal shape** with these contract-level
   fields:
   - **Actor handle** — a human-meaningful identifier for the external agent, unique
     within its org. It is the stable name the dispatch stamps for attribution; the
     full principal identity is the org-qualified form `external:<org>:<handle>`.
   - **Allowed projects** — the set of projects this requester may dispatch into.
     Unset means org-wide; a set means a whitelist. A dispatch whose target project
     is outside the set is denied before execution.
   - **Allowed workflows** — the set of `agent.request`-triggered workflows this
     requester may invoke, referenced by a republish-stable identifier (a template
     slug, not a mutable workflow id). Unset means any installed inbound workflow.
   - **Posture** — a per-requester governance-strictness selector. The OSS contract
     defines the field and its enum domain (`light` | `strict`); the *behaviour* of
     each posture is platform-only (see the mirrored stub) and out of scope here.
   - **Optional public key** — reserved for the future inbound cryptographic
     handshake of `ADR-2026-06-19` (requester-signs-request verification). Carried on
     the record now so the handshake is a population, not a schema change, later.
   - **Status + lifecycle** — a registration is `active`, `disabled`, or `revoked`,
     and is soft-deletable. Only an `active`, non-deleted registration resolves; a
     credential bound to a disabled/revoked/deleted registration authenticates to
     *nothing dispatchable*.

3. **The credential is bound to the registration at mint time.** When the engine
   mints the requester's scoped credential, the credential records which registration
   it belongs to. This binding is what lets the inbound path resolve, from a bare
   bearer credential, the full principal (handle, allowed projects, allowed workflows,
   posture) without trusting any requester-supplied identity claim.

4. **Resolution is the dispatch-time gate.** On each `agent.request`, the engine
   resolves the registration from the presented credential's binding, then evaluates
   the dispatch against the *registration's* allowed projects and allowed workflows —
   not the credential's coarser scopes. The registration is the narrower, authoritative
   bound. A credential that resolves to no active registration is treated as carrying
   no inbound authorization (fail-closed).

5. **The registration is the attribution anchor.** The resolved principal identity
   `external:<org>:<handle>` is what the dispatch stamps into the audit record, so an
   inbound run is attributable to a *registered relationship*, independent of which
   (rotatable) credential carried it. This is the OSS-contract realization of
   `ADR-2026-06-19`'s "every request is attributable to that registered identity."

6. **OSS owns the record shape; the platform owns its enforcement internals.**
   OSS-canonical: that a registration exists, the principal fields it carries, the
   bind-at-mint relationship, the resolve-at-dispatch gate, and the
   registration-as-attribution-anchor rule. **Platform-only and out of scope here:**
   the storage columns, the mint internals, the resolution query, how posture maps to
   policy, and how the registration's fields populate the policy engine's principal
   attributes. See the mirrored stub in the platform corpus.

## Consequences

### Positive

- A single named record carries identity, allowed surface, and posture, so the three
  inbound concerns stop scattering across the credential, the workflow, and ad-hoc
  policy.
- Decoupling the durable principal (registration) from the rotatable bearer
  (credential) means credential rotation/revocation never disturbs attribution or the
  allowed surface — and revoking a registration instantly de-authorizes every
  credential bound to it.
- The allowed-projects / allowed-workflows whitelist makes inbound authorization a
  property of the *relationship*, narrower than and independent of the credential's
  scopes — the bound an inbound execution surface needs.
- Carrying the public-key field now makes the future signed-request handshake a data
  population rather than a schema migration.

### Negative

- Inbound dispatch gains a mandatory resolution step (credential → registration →
  allowed-surface check) on the hot path. The contract requires it be fail-closed,
  which the implementation must honour even under resolution failure.
- A registration is a new lifecycle object to provision, scope, disable, and revoke —
  onboarding an external requester is now a two-step act (register, then mint), not a
  single credential issue.

### Risks

- If a credential could ever dispatch *without* resolving to an active registration,
  the whole authorization bound is bypassed. The fail-closed rule (no active
  registration ⇒ no inbound authorization) is load-bearing and must not regress.
- Binding by mutable workflow id instead of a republish-stable slug would silently
  drop a requester's authorization on every republish. The contract pins the stable
  identifier for exactly this reason.

## Alternatives considered

- **Put identity, allowed surface, and posture on the credential.** Rejected: a
  credential is a rotatable bearer secret; the identity, allowed surface, and posture
  are stable properties of the requester relationship and must outlive any one
  credential. Rotation or re-mint would otherwise reset attribution and scope.
- **Reuse the project membership / role model for inbound requesters.** Rejected: an
  external agent is not a seat-holding member of the org; it is an attributable
  *external* principal with a narrow, explicitly-whitelisted dispatch surface. Folding
  it into member roles would over-grant and muddy the `external:` attribution.
- **No record; carry the allowed surface inline on each request.** Rejected: a
  self-asserted allowed surface is not an authorization bound at all. The bound must
  be server-side, resolved from a credential the engine itself minted and bound.

## Affected documents

Edits land in the commit that flips this ADR to Accepted:

- `002-provider-base-contract.md` — the `RequesterProvider` identity section gains the
  registration record as the anchor the family's scoped-credential and attribution
  obligations attach to.
- `016-workflow-engine.md` — the `agent.request` trigger note references the
  registration as the dispatch-time authorization + attribution anchor.

No edit here touches a `BOUNDARY-SYNC`-marked region, so no synchronized-section
ceremony is required; on acceptance, paired commits (OSS-side first) per `BOUNDARY.md`.

## Affected work items

To be filed on acceptance (the platform corpus carries the platform-side tracker
references).

## Implementation notes

The registration record is resolved from the credential's binding at the start of an
`agent.request` dispatch, before the workflow's first executable node runs. The
allowed-projects / allowed-workflows check and the principal-attribution stamp both
read the *resolved registration*, not the raw credential. Storage shape, resolution
query, mint internals, and the posture-to-policy mapping are platform-only; see the
mirrored stub in the platform corpus.
