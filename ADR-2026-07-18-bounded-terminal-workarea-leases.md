---
status: Accepted
date: 2026-07-18
boundary: OSS-only
---

# ADR-2026-07-18 — Bounded terminal workarea leases

**Status:** Accepted
**Date:** 2026-07-18
**Boundary:** OSS-only
**Authors:** architecture agent

## Context

A session can reach a terminal result while the result receiver still needs to
verify evidence in the session's workarea. If ordinary session teardown makes
that workarea available for reuse before the terminal exchange is acknowledged,
verification can observe a different filesystem state from the one that
produced the result. The failure is especially subtle when the replacement has
the same repository and revision metadata: the identity looks equivalent while
the exact bytes under review are no longer owned by the terminating session.

A process-local hold is insufficient. Either side of the terminal exchange can
restart after accepting the result but before acknowledgement or release. The
hold must therefore survive a crash, remain exclusive for the whole verification
window, and still have a finite lifetime so abandoned terminal exchanges do not
consume workarea capacity forever.

The lease is also a security boundary. A path supplied by a caller, an
equivalent fresh clone, a fallback worker, or an unsandboxed command would not
prove anything about the exact retained workarea. Delivery acknowledgement and
local authority to release are separate facts, and both must survive restart.

## Decision

The terminal status exchange supports a **bounded terminal workarea lease**.
The workarea-owning runtime persists the lease before terminal teardown can make
the workarea reusable. A successful requested lease is independent of ordinary
preservation policy. Release follows an exact, durably applied semantic
acknowledgement for the durable local execution claim, or bounded expiry and
reaping when settlement never obtains that authority.

### D1 — Exact v1 wire identifiers and fields

These identifiers are immutable and case-sensitive:

- capability: `rensei.verify.run@1`;
- verifier request: `rensei.verify.request.v1`;
- verifier result: `rensei.verify.result.v1`;
- Donmai lease request: `donmai.terminal-workarea-lease-request.v1`;
- Donmai lease descriptor: `donmai.terminal-workarea-lease.v1`; and
- Donmai lease acknowledgement:
  `donmai.terminal-workarea-lease-ack.v1`.

The Donmai v1 lease request has exactly these five fields:

```json
{
  "schemaVersion": "donmai.terminal-workarea-lease-request.v1",
  "settlementBudgetMs": 977000,
  "safetyMarginMs": 60000,
  "leaseDurationMs": 1800000,
  "maxLeaseDurationMs": 7200000
}
```

The privileged-verification profile uses those exact values. The request may
be versioned in a later schema, but v1 is not broadened in place.

The full Donmai descriptor is path-free and has exactly these eight fields:

```json
{
  "schemaVersion": "donmai.terminal-workarea-lease.v1",
  "leaseId": "twl_<32 lowercase hex>",
  "sessionId": "<canonical UUID>",
  "terminalResultId": "tr_<32 lowercase hex>",
  "workareaId": "wa_<32 lowercase hex>",
  "acquiredAt": "<UTC timestamp>",
  "expiresAt": "<UTC timestamp>",
  "settlementBudgetMs": 977000
}
```

The external verifier receives only this four-field projection:

```json
{
  "leaseId": "twl_<32 lowercase hex>",
  "workareaId": "wa_<32 lowercase hex>",
  "terminalResultId": "tr_<32 lowercase hex>",
  "expiresAt": "<UTC timestamp>"
}
```

The full descriptor and the host-local absolute workarea path remain in durable
Donmai state. The absolute path is never present on an external wire and is
never caller-selectable.

The semantic acknowledgement has exactly these eight fields:

```json
{
  "schemaVersion": "donmai.terminal-workarea-lease-ack.v1",
  "acknowledged": true,
  "invocationId": "<canonical UUID>",
  "claimId": "<canonical UUID>",
  "leaseId": "twl_<32 lowercase hex>",
  "sessionId": "<canonical UUID>",
  "terminalResultId": "tr_<32 lowercase hex>",
  "workareaId": "wa_<32 lowercase hex>"
}
```

`sessionId`, `invocationId`, and `claimId` use canonical lowercase hyphenated
UUID text (`8-4-4-4-12` hexadecimal digits). Donmai-generated identities use
exactly `twl_`, `wa_`, or `tr_` followed by 32 lowercase hexadecimal digits.
Malformed, normalized-from-a-different-spelling, mixed-version, or
identity-equivalent-but-byte-different input fails before filesystem access or
command execution.

All v1 decoders reject unknown fields, alternate casing, alternate schema
strings, path-bearing variants, trailing JSON values, duplicate object keys,
and unpaired surrogate escapes. Duplicate-key and surrogate checks occur on the
retained raw JSON before a decoder can normalize them. One complete value is
accepted; a normalized Go value is not evidence that the raw wire was valid.

### D2 — Durable acquisition, state, and preserve policy

The workarea-owning side atomically persists the terminal result, the exact
host-local absolute workarea path, the full descriptor identity, release intent,
and the finite lease policy. The durable lease state machine is only:

```text
active -> release-pending -> released
```

Acknowledgement and expiry are transition reasons and timestamps, not extra
lease states. A restart reconstructs all non-released leases before classifying
any workarea as available. Replaying the same terminal result identity and
byte-equivalent payload is idempotent; the same identity with different payload
or lease invariants is a conflict.

A requested terminal-workarea lease is acquired even when ordinary disposition
is `PreserveWorktreeAlways`. Preservation policy controls ordinary teardown; it
does not suppress the requested descriptor or weaken verification retention.

If requested lease acquisition cannot be durably completed, the runner converts
the terminal outcome to failure, does not post a successful terminal status,
and durably quarantines the exact workarea. Ordinary teardown, archive, reuse,
or return-to-pool is forbidden until the bounded recovery path or an explicit
operator action resolves the quarantine.

### D3 — Exact workarea ownership and sandbox

An active lease is an overlay on the workarea's acquired state. It does not
create a second workarea and does not transfer ownership to a verifier. The
originating session remains the exclusive owner from execution through terminal
verification.

The host resolves the external projection to the exact durable descriptor and
the exact local session leaf before any filesystem access. There is no fresh
clone fallback, cross-host fallback, equivalent-workarea substitution, or
caller-selected path. While the lease is not `released`:

- provider release is deferred or rejected except through acknowledgement or
  reaping;
- the workarea cannot return to an available pool state;
- another session cannot acquire it, including in shared mode; and
- daemon drain, worker exit, and restart recovery retain it as unavailable.

Verification commands run only in a proven sandboxed projection of that exact
retained leaf. The projection excludes ignored files and repository execution
configuration; isolates HOME, XDG, Git configuration, tool caches, and other
mutable host state; disables credential helpers, hooks, SSH/keychain access,
and uncontrolled tool paths; and denies network access and unrelated same-UID
host-file reads. If a supported host cannot prove those controls, the verifier
lane is unavailable and `rensei.verify.run@1` is not advertised.

### D4 — Durable exclusive execution claim

Before verification accesses the workarea or runs a command, the lease stores
one durable exclusive claim binding the exact `invocationId` and `claimId` to
that lease, session, terminal result, and workarea. Repeating the same pair is
idempotent. A different invocation, a different claim, or a payload-different
replay conflicts and cannot execute.

The initial descriptor does not itself claim an invocation. Only this durable
local claim grants execution ownership and, after exact acknowledgement,
release authority. Platform result or dead-letter settlement independently uses
a single-winner durable compare-and-set; it does not replace the local claim.

### D5 — Two durable outboxes and receiver-affine replay

Terminal-status delivery and privileged-result delivery are separate durable
outboxes. They are not two views of one queue:

1. the terminal-status outbox carries the original session-status payload and
   full path-free Donmai descriptor; and
2. the privileged-result outbox is keyed by
   `(invocationId, claimId, leaseId)` and carries the canonical verifier result
   body plus the exact expected response and acknowledgement identity.

Before the first send, each outbox persists byte-stable body bytes, expiry or
deadline, delivery/application state, and a non-secret identity sufficient to
select the original organization and receiver. Neither outbox persists bearer
tokens, registration credentials, or any other secret. Every initial attempt
and replay resolves fresh credentials for that receiver. Restart, credential
rotation, configuration reorder, or another organization's readiness must not
reroute a record.

### D6 — Delivery acknowledgement is not local release authority

A transport `2xx`, connection close, non-null acknowledgement, or generic
receiver receipt is not sufficient. A privileged-result attempt succeeds only
when the response reports success for the exact invocation and every
acknowledgement field matches the local durable descriptor and execution claim,
with `acknowledged: true`.

For a matching local claim, the workarea-owning runtime durably records the
semantic acknowledgement before moving `active -> release-pending`. The local
application surface reports whether that durable transition happened separately
from whether provider release has finished. Failure or mismatch before the
transition retries the identical platform settlement. Once `release-pending` is
durable, platform resettlement stops even if provider release still fails; the
reaper/release worker owns provider retries from that point.

A result rejected before local claim acquisition is different. The receiver may
durably settle a transport-error result and return a delivery acknowledgement,
but no acknowledgement can authorize local release without the matching durable
`(invocationId, claimId)` claim. The privileged-result outbox records the result
as delivered and stops duplicate transport retries, while the lease remains
retained. Expiry and reaping, not the no-local-claim acknowledgement, own cleanup.

If the process restarts before acknowledgement is durably applied, it replays
the same result bytes and retains the same lease. If it restarts after
`release-pending` but before provider release completes, it resumes provider
release without resettling the platform result.

### D7 — Exact settlement and lease timing

The claimed settlement budget is exactly:

```text
900000 ms  maximum verification command/result evidence duration
 47000 ms  bounded result transport, retry, and backoff
 30000 ms  durable acknowledgement settlement margin
---------
977000 ms  settlementBudgetMs
```

The `60000 ms` lease safety margin is separate from the `977000 ms` settlement
budget. Therefore a claim requires **strictly more than `1037000 ms`** remaining;
`1037000 ms` is rejected and `1037001 ms` is the first acceptable value.

The optional pre-claim queue window is another separate `60000 ms`. Enqueue
requires **strictly more than `1097000 ms`** remaining; `1097000 ms` is rejected
and `1097001 ms` is the first acceptable value. Queue time and the lease safety
margin are not folded into `settlementBudgetMs`.

The initial lease is `1800000 ms` and its absolute maximum is `7200000 ms`.
Lease duration must be strictly greater than settlement budget plus safety
margin. Renewal is allowed only for the same session, terminal result, workarea,
and lease identities and never beyond the finite maximum fixed at acquisition.

Evidence time is measured at command exit or deadline cancellation, excludes
kill, pipe, and process-wait cleanup grace, and is capped at `900000 ms` both per
command and in aggregate. Timestamps and `durationMs` use one shared rounding
rule. Expiry is not successful acknowledgement and does not change the terminal
verdict.

### D8 — Bounded reaping and idempotent at-least-once release

The daemon runs a periodic actionable-record reaper with finite interval `I`,
actionable batch size `B`, and provider-attempt timeout `R`. Let `N` be the
number of actionable eligible lease records at the start of the bounded scan,
not an unimplemented provider or pool capacity `C`. Every such record is
considered within at most:

```text
ceil(N / B) * I
```

For a responsive provider, release completes within
`ceil(N / B) * I + R`. A reap attempt first durably records
`release-pending`, then invokes the normal provider release policy.

Provider release callbacks are idempotent and may execute at least once,
including again after a crash between effective teardown and the final durable
save. The guarantee is one final durable/effective disposition with continuous
workarea unavailability, not exactly-once callback invocation. A provider
failure leaves the lease `release-pending`, retains the workarea, retries with
capped backoff and the same finite attempt timeout, and records an
operator-visible last error. Only durable `released` permits pool admission.

### D9 — Per-organization readiness and replay barriers

Readiness is evaluated independently for each organization and receiver. Before
advertising `rensei.verify.run@1` for one organization, that organization's
lifecycle supervisor has initialized and recovered all of the following:

- strict raw-wire decoder and verifier registry;
- durable lease controller and exclusive claim path;
- expired-lease reaper;
- terminal-status outbox receiver resolver and replay loop;
- privileged-result outbox receiver resolver and replay loop;
- fresh typed runtime-credential resolution bound to the normalized receiver
  and organization;
- exact synchronous acknowledgement validation/application; and
- the required sandbox.

Recovery includes loading durable records, rebuilding any actionable index,
starting both replay paths and the reaper, and establishing their cancellation
and join ownership. Initial registration is fail-closed without the capability;
once these barriers are ready, capability addition forces registration
convergence. On readiness loss, the supervisor stops new claims first, then
removes the capability and forces token/registration convergence. A cached
registration may not hide capability or receiver-configuration changes. A
global readiness boolean shared by primary and satellite organizations is
forbidden.

### D10 — Default-off platform activation boundary

Source compatibility, schema deployment, a registered capability, and a ready
worker do not authorize platform activation. Node availability or
recommendation, canonical-template insertion or publication, lease enqueue,
claiming, and verification-to-CI transition remain behind one reversible
activation control that defaults off.

Migration deployment, source deployment, template publication, claiming, CI
transition, and activation are distinct held operations. Activation additionally
requires compatible released artifacts, cross-language and crash/replay tests,
a hermetic released-artifact smoke, and awaited signed lifecycle evidence. This
ADR intentionally assigns no future release number and names no platform
migration identity.

## Consequences

### Positive

- Terminal verification observes the exact workarea that produced the result.
- Exclusive ownership spans execution, verification, durable result settlement,
  semantic acknowledgement, and provider disposition.
- Separate receiver-affine outboxes make ambiguous connection loss and restart
  safe without persisting credentials.
- The local durable claim prevents a delivery receipt from becoming accidental
  release authority.
- Finite timing, actionable reaping, and an idempotent at-least-once provider
  release contract bound abandoned retention without pretending callbacks are
  exactly once.
- Per-organization readiness and sandbox gating prevent partial or cross-tenant
  capability advertisement.

### Negative

- Terminal completion can retain a workarea beyond worker-process exit, reducing
  immediately reusable capacity during slow verification.
- The host must persist a lease state machine, execution claim, terminal-status
  outbox, receiver identity, and release retry state before pool admission.
- The embedding verifier owns another durable outbox plus per-organization
  credential, replay, acknowledgement, and sandbox lifecycle.
- Settlement timing and identifier canonicalization become cross-component
  invariants that cannot be changed independently.

### Risks

- **Budget underestimation.** A lease could expire during legitimate settlement.
  Mitigation: the exact arithmetic, strict one-millisecond boundaries, separate
  safety and queue margins, and finite maximum are shared fixtures.
- **Acknowledgement ambiguity.** A delivery receipt could be mistaken for local
  release authority. Mitigation: exact field matching plus the durable local
  execution claim, with explicit no-local-claim behavior.
- **Receiver confusion after restart.** A replay could target the wrong
  organization. Mitigation: persist a non-secret receiver identity and resolve a
  fresh receiver-bound credential for every attempt.
- **Recovery ordering error.** A restarted daemon could admit a workarea before
  loading its lease. Mitigation: lease/outbox recovery and actionable-index
  reconstruction precede readiness and pool admission.
- **Provider release failure.** A lease could remain unavailable longer than
  intended. Mitigation: finite attempts, capped retry, operator-visible state,
  and no reuse until release is durably confirmed.
- **False sandbox confidence.** Verification could read host or ignored secrets.
  Mitigation: no proven sandbox means no capability advertisement or claim.

## Alternatives considered

- **Release when the worker process exits.** Rejected: process lifetime ends
  before terminal settlement and does not prove acknowledgement.
- **Retain an equivalent replacement or fresh clone.** Rejected: matching
  metadata does not prove identity with the bytes that produced the result.
- **Treat platform delivery as release authority.** Rejected: pre-claim failures
  have no durable local execution owner and therefore no local authority.
- **Use one outbox for both deliveries.** Rejected: the messages, receiver
  semantics, credentials, acknowledgement, and replay completion conditions are
  different.
- **Invoke provider release exactly once.** Rejected: a crash can occur after
  effective teardown but before the final durable save; correctness requires an
  idempotent at-least-once callback.
- **Use an unbounded hold until an operator intervenes.** Rejected: abandoned
  exchanges would permanently consume finite capacity.
- **Keep the hold only in process memory.** Rejected: a restart reintroduces the
  early-reuse race this decision exists to prevent.
- **Treat expiry as acknowledgement.** Rejected: reclamation is a capacity action,
  not evidence that verification or durable settlement succeeded.

## Affected documents

- `003-workarea-provider.md` — adds the lease overlay, exclusive-ownership rule,
  release ordering, expiry formula, and bounded reaper contract.
- `011-local-daemon-fleet.md` — drain and restart recovery retain actively leased
  workareas until acknowledgement or expiry.
- `013-orchestrator-and-governor.md` — terminal completion now includes lease,
  verification, acknowledgement, and release ordering.
- `ADR-2026-06-22-daemon-per-session-cancel-wire.md` — its post-mortem release
  statements are constrained by the newer rule that an active terminal lease
  retains the exact workarea until acknowledgement or expiry; the historical
  ADR remains unchanged.
- `README.md` and `AGENTS.md` — add this ADR to the corpus indexes.

No synchronized boundary region is changed. This is OSS execution-layer
lifecycle behavior; downstream platform activation remains a separate,
default-off extension boundary.

## Affected work items

No tracker identifier is embedded in this OSS ADR. Implementations should link
their own work item to this decision.

## Implementation notes

- Persist leases beside host session and workarea lifecycle state so boot
  recovery can load them before pool admission.
- Key terminal-result replay by `terminalResultId`; use the other descriptor
  fields as invariants, not alternate idempotency keys.
- Persist the absolute workarea path only in host-local state; external
  projections remain exactly path-free.
- Expose state, remaining lifetime, execution-claim identity, delivery state,
  release attempts, and last release error through existing workarea
  observability surfaces.
- Shared fixtures cover exact v1 fields and bytes; canonical IDs; unknown,
  duplicate-key, surrogate, path, and trailing-value rejection; claim and
  enqueue one-millisecond boundaries; no-local-claim delivery; restart at every
  outbox/ack/release boundary; multi-organization receiver replay; requested
  lease plus `PreserveWorktreeAlways`; acquisition-failure quarantine; actionable
  index rebuild; sandbox denial; and repeated idempotent provider release.
