---
status: Proposed
date: 2026-07-18
boundary: shared
split: sibling-extensions
---

# ADR-2026-07-18 — Bounded terminal workarea leases

**Status:** Proposed — implementation pending and unreleased
**Date:** 2026-07-18
**Boundary:** shared (OSS-canonical lease contract here; downstream platform stub and sibling extension required before acceptance)
**Authors:** architecture agent

## Context

A session can reach a terminal result while a result consumer still needs to
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

The provider-neutral lease, claim, acknowledgement application, terminal-status
outbox, recovery, quarantine, timing, and provider-release rules belong to the
Donmai execution layer. A particular consumer's capability and verifier schema
names, multi-tenant credentials, settlement store, activation controls, and
sandbox implementation do not. Those details require a downstream platform
extension under the shared-ADR mechanism in `BOUNDARY.md`.

## Decision

This ADR proposes a **bounded terminal workarea lease**. The workarea-owning
runtime persists the lease before terminal teardown can make the workarea
reusable. A requested lease is independent of ordinary preservation policy.
Durable ownership ends only at durable `released`: exact acknowledgement and
expiry are separate reasons that may make provider release eligible, but neither
reason itself releases the workarea.

This is a target contract, not a shipped claim. No released Donmai artifact is
asserted to implement it, and no downstream privileged consumer may advertise or
activate a capability solely because this proposal exists. The ADR remains
`Proposed` until the OSS contract, its fixtures, the required quarantine
authority, and the downstream extension are implemented and verified.

### D1 — Exact Donmai-owned v1 schemas

Donmai owns these immutable, case-sensitive schema identifiers:

- lease request: `donmai.terminal-workarea-lease-request.v1`;
- lease descriptor: `donmai.terminal-workarea-lease.v1`;
- local execution claim: `donmai.terminal-workarea-lease-claim.v1`;
- semantic acknowledgement: `donmai.terminal-workarea-lease-ack.v1`;
- local acknowledgement outcome:
  `donmai.terminal-workarea-lease-ack-outcome.v1`;
- terminal-status outbox record: `donmai.terminal-status-outbox.v1`; and
- acquisition quarantine record:
  `donmai.terminal-workarea-quarantine.v1`.

Every exact v1 JSON schema in this ADR has a closed field set. Decoders reject
unknown fields, alternate casing, alternate schema strings, trailing JSON
values, duplicate object keys, and unpaired surrogate escapes. Duplicate-key
and surrogate checks occur on retained raw JSON before a decoder can normalize
the value. String identities are compared byte-for-byte after JSON decoding;
there is no Unicode normalization or case folding. Identity-bearing fields are
ASCII-only. Timestamps use exactly UTC RFC 3339 with millisecond precision
(`YYYY-MM-DDTHH:MM:SS.mmmZ`). SHA-256 values are 64 lowercase hexadecimal
digits. Base64 uses canonical padded RFC 4648 encoding. Fields shown as `null`
are required fields with an explicit null value, not optional omissions.

The lease request has exactly these five fields and, for this proposed profile,
these exact values:

```json
{
  "schemaVersion": "donmai.terminal-workarea-lease-request.v1",
  "settlementBudgetMs": 977000,
  "safetyMarginMs": 60000,
  "leaseDurationMs": 1800000,
  "maxLeaseDurationMs": 7200000
}
```

The full path-free descriptor has exactly these eight fields:

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

An external consumer receives only this exact four-field embedded projection:

```json
{
  "leaseId": "twl_<32 lowercase hex>",
  "workareaId": "wa_<32 lowercase hex>",
  "terminalResultId": "tr_<32 lowercase hex>",
  "expiresAt": "<UTC timestamp>"
}
```

The full descriptor and host-local absolute workarea path remain in durable
Donmai state. The path is never present on an external wire and is never
caller-selectable.

The durable local execution claim has exactly these eight fields:

```json
{
  "schemaVersion": "donmai.terminal-workarea-lease-claim.v1",
  "invocationId": "<canonical UUID>",
  "claimId": "<canonical UUID>",
  "leaseId": "twl_<32 lowercase hex>",
  "sessionId": "<canonical UUID>",
  "terminalResultId": "tr_<32 lowercase hex>",
  "workareaId": "wa_<32 lowercase hex>",
  "claimedAt": "<UTC timestamp>"
}
```

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

Applying that acknowledgement produces and durably stores this exact seven-field
local outcome before the caller receives it:

```json
{
  "schemaVersion": "donmai.terminal-workarea-lease-ack-outcome.v1",
  "outcome": "applied|already-applied|rejected",
  "reason": null,
  "leaseId": "twl_<32 lowercase hex>",
  "terminalResultId": "tr_<32 lowercase hex>",
  "leaseState": "active|release-pending|released",
  "providerReleaseComplete": false
}
```

`reason` is `null` for `applied` and `already-applied`; for `rejected` it is
exactly one of `claim-missing`, `identity-mismatch`, or `state-conflict`.
`providerReleaseComplete` is true if and only if `leaseState` is `released`.
`applied` means the exact acknowledgement and the transition to
`release-pending` committed in one durable transaction. `already-applied` is
returned only for a byte-equivalent acknowledgement that was previously
applied. A conflicting replay is `rejected`.

`sessionId`, `invocationId`, and `claimId` use canonical lowercase hyphenated
UUID text (`8-4-4-4-12` hexadecimal digits). Donmai-generated identities use
exactly `twl_`, `wa_`, `tr_`, `rcv_`, or `twq_` followed by 32 lowercase
hexadecimal digits. Malformed or differently spelled identities fail before
filesystem access or command execution.

Donmai MUST publish byte fixtures for every schema above, including invalid raw
JSON fixtures for duplicate keys, unpaired surrogates, unknown fields, trailing
values, noncanonical identifiers, timestamps, digests, and base64. Any other
language implementation of a Donmai-owned schema MUST consume the same fixtures.
A consumer-owned verifier request, verifier result, or response envelope is not
a Donmai schema and is deliberately not named or partially defined here; D9
assigns that exact-wire work to the downstream extension.

### D2 — Durable ownership, acquisition, and preserve policy

The workarea-owning side durably binds the terminal result, exact host-local
absolute workarea path, full descriptor, requested release disposition, finite
lease policy, local claim if present, acknowledgement outcome if present,
release reason, provider-attempt history, and last error. The physical storage
layout is implementation-private; this ADR creates no additional public JSON
record beyond the exact schemas in D1, D3, and D6.

The durable lease state machine is only:

```text
active -> release-pending -> released
```

Acknowledgement and expiry are reasons and timestamps, not lease states. A
restart reconstructs every `active` and `release-pending` lease before
classifying any workarea as available. The originating session remains the
exclusive owner until `released` is durably committed. Replaying the same
terminal result identity and byte-equivalent payload is idempotent; the same
identity with different payload or lease invariants is a conflict.

A requested terminal-workarea lease is acquired even when ordinary disposition
is `PreserveWorktreeAlways`. Preservation policy controls ordinary teardown; it
does not suppress the requested descriptor, the lease, or the release state
machine.

### D3 — Separate acquisition-failure quarantine authority

Lease-acquisition failure is guarded by a restart-safe quarantine authority that
is separate from the lease store. The reference shape is an independently
opened and fsynced filesystem journal under the daemon state root. A valid
quarantine record has exactly these twelve fields:

```json
{
  "schemaVersion": "donmai.terminal-workarea-quarantine.v1",
  "quarantineId": "twq_<32 lowercase hex>",
  "workareaId": "wa_<32 lowercase hex>",
  "sessionId": "<canonical UUID>",
  "terminalResultId": "tr_<32 lowercase hex>",
  "workareaPath": "<host-local absolute path>",
  "pathSha256": "<64 lowercase hex>",
  "reason": "lease-acquisition-failed",
  "state": "guarded|quarantined|cleanup-pending",
  "createdAt": "<UTC timestamp>",
  "updatedAt": "<UTC timestamp>",
  "lastError": null
}
```

`pathSha256` is the SHA-256 of the exact UTF-8 path bytes and detects catalog
mismatch; it is not an external identity or a substitute for the stored path.
`lastError` is null or a UTF-8 diagnostic string and never participates in
identity. The quarantine record is host-local and is never sent externally.

The ordering is normative:

1. Before lease acquisition or ordinary terminal teardown, Donmai MUST create
   and fsync a `guarded` record in the quarantine authority.
2. It MAY then commit the lease in the separate lease store.
3. After it has re-read and verified the durable lease and associated it with the
   pool member, it MAY remove the guard. A crash before removal is safe: boot
   reconciliation finds both records and clears the redundant guard only after
   proving the lease still excludes the workarea.
4. If lease persistence fails, the guard remains exclusion authority and is
   promoted to `quarantined` when possible. The terminal outcome becomes failure,
   no successful terminal status is posted, and ordinary release, archive,
   return-to-pool, reuse, or a second lease attempt is forbidden.
5. Boot recovery MUST load quarantine records before lease recovery and before
   pool discovery. `guarded`, `quarantined`, and `cleanup-pending` all exclude the
   workarea. Any non-ready or orphan pool member that cannot be reconciled to a
   clean terminal record is treated as quarantined, never inferred available.

If the quarantine authority cannot be opened, read, written, renamed, or fsynced,
the affected provider root MUST remain unready: no new acquisition, ordinary
release, pool admission, or privileged consumer advertisement is permitted.
An in-process acquisition that cannot write its guard fails before success and
places the provider root in that fail-closed condition. Recovery requires the
authority to be restored and a full reconciliation of lease, quarantine,
session, and pool catalogs; availability must never be inferred from the absence
of a record after an I/O failure.

A finite quarantine cleanup scheduler considers every eligible quarantine under
the D8 batch/concurrency bound. Automatic cleanup may only request provider
`destroy`; it transitions to `cleanup-pending` first and removes the record only
after durable provider/catalog confirmation that the old workarea no longer
exists. An authorized operator may retain the quarantine for inspection or
retry destruction. The same workarea ID is never returned to the pool; reuse
requires successful destruction and a newly acquired workarea with a new ID.
Provider failure keeps the record unavailable and operator-visible.

This authority and its crash fixtures are a pre-activation requirement. Until
implemented, lease acquisition failure MUST be treated as unsupported and no
consumer capability depending on terminal leases may be advertised.

### D4 — Exact workarea ownership; sandbox is a consumer extension

A non-released lease is an overlay on the workarea's acquired state. It does not
create a second workarea and does not transfer ownership to a verifier. The host
resolves the external projection to the exact durable descriptor and exact local
session leaf before any filesystem access. There is no fresh-clone fallback,
cross-host fallback, equivalent-workarea substitution, or caller-selected path.
While the lease is not `released`:

- provider release is allowed only through the acknowledgement or expiry/reaping
  paths in D5 and D8;
- the workarea cannot return to an available pool state;
- another session cannot acquire or join it, including in shared mode; and
- daemon drain, worker exit, restart recovery, and consumer failure retain it as
  unavailable.

This ADR does not define a sandbox projection, snapshot manifest, writable
overlay, environment policy, network policy, or host-filesystem confinement.
Those controls belong to the consumer that executes privileged verification.
A consumer MAY advertise such a privileged capability only after its separately
specified sandbox contract is implemented and tested on the advertised host.
The Donmai lease alone never proves sandbox readiness.

### D5 — Exclusive local claim and two release paths

Before a consumer accesses the workarea or runs a command, Donmai MUST durably
store the exact D1 execution claim, binding one `invocationId` and `claimId` to
the lease, session, terminal result, and workarea. Repeating the byte-equivalent
claim is idempotent. Any different invocation, claim, identity, or payload
conflicts and cannot execute. The descriptor alone grants no execution or
release authority.

Acknowledgement and expiry/reaping are separate paths:

**Acknowledgement path**

1. The consumer returns the exact D1 semantic acknowledgement.
2. Donmai compares every field against the durable descriptor and local claim.
   A transport success, connection close, non-null body, or generic receipt is
   insufficient.
3. Donmai atomically persists the acknowledgement outcome and moves
   `active -> release-pending` before returning `outcome: applied`.
4. The release worker invokes the provider's normal release disposition. On
   success it persists `released`; on failure it retains `release-pending` and
   retries under D8.

**Expiry/reaping path**

1. Reaching `expiresAt` only makes an `active` record eligible for the reaper. It
   does not acknowledge, release, change the terminal verdict, or permit reuse.
2. The reaper durably records expiry as the release reason and moves
   `active -> release-pending`.
3. It invokes the same provider release path. Only durable `released` ends
   ownership and permits subsequent pool admission.

An acknowledgement without the matching local claim is `rejected` with
`claim-missing`; it cannot authorize release. Expiry owns eventual cleanup in
that case. A restart before acknowledgement application replays the same
terminal-status bytes and retains `active`. A restart after `release-pending`
resumes provider release without asking the consumer to settle again.

### D6 — Provider-neutral terminal-status outbox and receiver affinity

Donmai owns one durable terminal-status outbox. A downstream consumer may own a
separate result outbox, but that is not a second Donmai queue and must be defined
in the downstream extension.

A Donmai receiver key is an opaque generated identity with exact form
`rcv_<32 lowercase hex>`. It is assigned when receiver configuration is created,
not derived from a URL, display name, organization, array position, or Unicode
text. Normalization consists only of strict validation against that lowercase
ASCII form; case folding, Unicode normalization, trimming, and URL
canonicalization are forbidden. Configuration reordering or endpoint rotation
must preserve the key.

The terminal-status outbox record has exactly these twelve fields:

```json
{
  "schemaVersion": "donmai.terminal-status-outbox.v1",
  "terminalResultId": "tr_<32 lowercase hex>",
  "receiverKey": "rcv_<32 lowercase hex>",
  "bodyBase64": "<canonical padded base64>",
  "bodySha256": "<64 lowercase hex>",
  "deadlineAt": "<UTC timestamp>",
  "deliveryState": "pending|attempting|delivered|dead-letter",
  "applicationState": "pending|applied|not-authoritative|rejected",
  "attemptCount": 0,
  "nextAttemptAt": "<UTC timestamp>",
  "lastAttemptAt": null,
  "lastError": null
}
```

`attemptCount` is a non-negative integer. `lastAttemptAt` is null until the first
attempt and otherwise an exact timestamp. `lastError` is null or a UTF-8
diagnostic that is not used for identity. `bodySha256` covers the decoded
`bodyBase64` bytes. Those bytes are immutable after the first durable save.

`deliveryState` tracks transport only. `attempting` is durably recorded before a
send and is recovered to `pending` after an interrupted process. `delivered`
means the configured receiver accepted the bytes; `dead-letter` means the finite
deadline or retry policy ended transport attempts. Neither state grants local
release authority. `applicationState` tracks the D1 local acknowledgement
outcome: `applied` only after durable `applied` or `already-applied`,
`not-authoritative` for a delivered response without a matching claim, and
`rejected` for a semantic conflict. None of `pending`, `not-authoritative`, or
`rejected` permits acknowledgement-path release.

Every send and replay resolves `receiverKey` through a provider-neutral resolver
that returns the receiver's current endpoint and, if required, fresh ephemeral
authorization. The outbox persists neither endpoint-derived routing aliases nor
secrets. A missing key or resolver failure retries the same record and may
ultimately dead-letter it; it MUST NOT fall back to another receiver. Delivery is
at least once, and byte-equivalent replay is required after restart or ambiguous
connection loss.

### D7 — Exact settlement and lease timing

The proposed settlement budget is exactly:

```text
900000 ms  maximum consumer command/result evidence duration
 47000 ms  bounded result transport, retry, and backoff
 30000 ms  durable acknowledgement settlement margin
---------
977000 ms  settlementBudgetMs
```

The `60000 ms` lease safety margin is separate from the `977000 ms` settlement
budget. A local execution claim therefore requires **strictly more than
`1037000 ms`** remaining: `1037000 ms` is rejected and `1037001 ms` is the first
acceptable value.

An optional pre-claim queue window is another separate `60000 ms`. Enqueue
requires **strictly more than `1097000 ms`** remaining: `1097000 ms` is rejected
and `1097001 ms` is the first acceptable value. Queue time and the lease safety
margin are not folded into `settlementBudgetMs`.

The initial lease is `1800000 ms` and its absolute maximum is `7200000 ms`.
Lease duration MUST be strictly greater than settlement budget plus safety
margin. Renewal is allowed only for the same session, terminal result, workarea,
and lease identities and never beyond the finite maximum fixed at acquisition.

Consumer evidence time is measured at command exit or deadline cancellation,
excludes kill, pipe, and process-wait cleanup grace, and is capped at `900000 ms`
both per command and in aggregate. Exact rounding and timestamp projection must
be fixed in the consumer-owned schema fixtures required by D9. Expiry is not a
successful acknowledgement and does not change the terminal verdict.

### D8 — Provable bounded reaping and at-least-once provider release

The release/quarantine scheduler is a declared fixed-delay batch scheduler with:

- `N`: actionable records captured at the start of one bounded scan;
- `B`: maximum records admitted to one batch, with `B >= 1`;
- `K`: maximum concurrent provider attempts within a batch, with
  `1 <= K <= B`;
- `I`: maximum delay before the first batch and between completion of one batch
  and admission of the next, with `I > 0`; and
- `R`: hard timeout for one provider attempt, with `R > 0`.

Batches do not overlap. Within a batch the scheduler runs at most `K` provider
attempts concurrently, starts the next attempt round immediately when the prior
round completes or times out, and admits the next batch no later than `I` after
the prior batch completes. Each snapshot record receives at most one provider
attempt in that bounded scan; a failed attempt is scheduled in a later scan only
after its capped backoff. Records becoming actionable after the scan snapshot
belong to the next scan and do not increase `N` retroactively.

Let:

```text
M = ceil(N / B)       batches in the snapshot
Q = ceil(B / K)       maximum provider-attempt rounds per batch
```

Every record in the snapshot MUST be considered, and every successful responsive
provider attempt MUST complete, within the conservative bound:

```text
M * (I + Q * R)
```

The formula deliberately includes provider-attempt duration for every possible
round in every batch. Implementations MAY provide a tighter measured bound, but
MUST NOT claim a smaller normative bound without adopting and documenting a
scheduler that proves it. A provider that fails or times out is still considered
within the bound; successful reclamation cannot be bounded when the provider
never succeeds.

Before invoking provider release, the scheduler MUST durably record
`release-pending`. Every durable `release-pending` record MUST cause at least one
`WorkareaProvider.release(workarea, mode)` attempt. That callback MUST be
idempotent for repeated calls with the same `Workarea.id` and equivalent
`ReleaseMode`, and Donmai MAY invoke it more than once, including after a crash
between effective teardown and the final durable save. A different disposition
for an already pending lease is a conflict, not a second policy choice.

Provider failure leaves the lease or quarantine `release-pending`/
`cleanup-pending`, retains the workarea, retries with capped backoff and the same
finite attempt timeout, and records an operator-visible last error. The guarantee
is one final durable/effective disposition with continuous unavailability, not
exactly-once callback invocation. Only durable `released`, or durable quarantine
destruction plus catalog removal, permits later capacity admission.

### D9 — Required downstream extension; exact consumer protocol deferred

Because this ADR is `shared`, the platform corpus must carry the thin mirrored
stub prescribed by `BOUNDARY.md` plus a sibling platform-extension ADR. Both are
pre-acceptance dependencies and are not created or made normative by this OSS
file.

The downstream extension MUST define, without changing the Donmai schemas above:

- its capability identifier and exact consumer-owned verifier request, verifier
  result, and response-envelope schemas;
- closed field sets, optional/null rules, canonical byte projection, content and
  evidence digest semantics, timestamp rounding, Unicode rejection, and shared
  cross-language fixtures for those schemas;
- its separate durable result outbox, receiver mapping, delivery/application
  states, replay, credential freshness, and authorization rules;
- any multi-tenant ownership, platform compare-and-set settlement, lifecycle
  convergence, and readiness supervision;
- the complete sandbox contract and supported-host proof required before the
  privileged capability may be advertised; and
- all migration, template, node, claim-routing, workflow/CI activation, rollback,
  and lifecycle-evidence gates.

No consumer capability, schema name, credential scope, migration identity,
template identity, workflow node, or activation state is defined by this ADR.
Until the downstream extension is accepted, implemented, fixture-compatible, and
default-off activation is deliberately enabled, the downstream feature remains
unavailable.

## Consequences

### Positive

- Provider-neutral Donmai ownership remains exact through durable provider
  disposition rather than ending at transport receipt, acknowledgement, or
  expiry.
- The acknowledgement and expiry/reaping paths are explicit and share one
  idempotent at-least-once provider-release mechanism.
- A separate pre-lease quarantine guard closes the acquisition-failure restart
  gap without pretending the failed lease store can quarantine itself.
- Exact Donmai schemas, receiver-key normalization, outbox states, local claim,
  and local acknowledgement outcome can be fixture-tested independently of a
  particular consumer.
- The reaping theorem accounts for provider-attempt duration and declared
  concurrency rather than using an unavailable capacity variable.
- The OSS/platform split leaves consumer schemas, credentials, sandbox controls,
  and activation in the corpus that owns them.

### Negative

- Terminal completion can retain a workarea beyond worker-process exit, reducing
  immediately reusable capacity during slow settlement.
- The host must operate two durable authorities—the lease/outbox store and the
  independent quarantine journal—and recover both before pool admission.
- Providers must tolerate repeated equivalent release callbacks.
- This proposal cannot be accepted or activated from one repository alone; it
  requires cross-language fixtures, runtime implementation, and the downstream
  extension.

### Risks

- **Budget underestimation.** A lease could expire during legitimate settlement.
  Mitigation: exact arithmetic, strict one-millisecond boundaries, separate
  safety and queue margins, and a finite maximum are shared fixtures.
- **Acknowledgement ambiguity.** A delivery receipt could be mistaken for local
  release authority. Mitigation: exact field matching, a durable local claim,
  and a separate local acknowledgement outcome.
- **Quarantine-store failure.** Missing persistence could otherwise permit reuse
  after restart. Mitigation: guard-before-lease ordering, boot-time exclusion,
  fail-closed provider readiness, and no inference from record absence after I/O
  failure.
- **Provider release failure.** A workarea could remain unavailable longer than
  intended. Mitigation: finite attempts, capped retry, operator-visible state,
  and no reuse until the durable terminal disposition.
- **False sandbox confidence.** A consumer could advertise verification without
  confinement. Mitigation: this ADR makes no sandbox claim and requires the
  downstream extension and implementation proof before advertisement.

## Alternatives considered

- **Release when the worker process exits.** Rejected: process lifetime ends
  before terminal settlement and does not prove acknowledgement.
- **Retain an equivalent replacement or fresh clone.** Rejected: matching
  metadata does not prove identity with the bytes that produced the result.
- **Treat transport delivery as release authority.** Rejected: delivery has no
  durable local execution owner and therefore no local release authority.
- **Let the failed lease store also record quarantine.** Rejected: the authority
  whose write failed cannot prove restart-safe exclusion.
- **Invoke provider release exactly once.** Rejected: a crash can occur after
  effective teardown but before the final durable save; correctness requires an
  idempotent callback that may run more than once.
- **Use an unbounded hold until an operator intervenes.** Rejected: abandoned
  exchanges would permanently consume finite capacity.
- **Specify one downstream verifier and sandbox in this ADR.** Rejected: those
  contracts are consumer-specific and would violate the OSS/platform boundary.

## Affected documents

- `003-workarea-provider.md` — proposed lease overlay, ownership through durable
  `released`, claim/release paths, separate safety margin, actionable `N`, and
  idempotent repeated provider release.
- `011-local-daemon-fleet.md` — proposed drain, crash recovery, quarantine-first
  boot ordering, release-pending retention, and bounded scheduler operations.
- `013-orchestrator-and-governor.md` — proposed terminal completion ordering with
  local claim, separate acknowledgement and expiry/reaping paths, and durable
  provider disposition.
- `ADR-2026-06-22-daemon-per-session-cancel-wire.md` — its historical post-mortem
  release statements remain unchanged but would be constrained by this proposal:
  a non-released terminal lease retains the exact workarea.
- `006-cross-provider-interactions.md` — intentionally unchanged. This proposal
  introduces no new provider-family seam beyond the WorkareaProvider lifecycle;
  a particular verifier seam belongs in the downstream extension.
- `015-plugin-spec.md` — intentionally unchanged. This proposal defines no plugin
  capability or verb identifier.
- `016-workflow-engine.md` — intentionally unchanged. This proposal defines no
  workflow node, template, or CI transition.
- `README.md` and `AGENTS.md` — index this ADR honestly as Proposed, shared,
  implementation-pending, and unreleased.
- [`rensei-architecture/ADR-2026-07-18-bounded-terminal-workarea-leases.md`](https://github.com/RenseiAI/rensei-architecture/blob/main/ADR-2026-07-18-bounded-terminal-workarea-leases.md)
  — a thin `Mirrored` stub is required downstream before acceptance.
- [`rensei-architecture/ADR-2026-07-18-bounded-terminal-workarea-leases-platform-extensions.md`](https://github.com/RenseiAI/rensei-architecture/blob/main/ADR-2026-07-18-bounded-terminal-workarea-leases-platform-extensions.md)
  — the consumer protocol, authorization, sandbox, and activation extension is
  required downstream before acceptance.

No synchronized `BOUNDARY-SYNC` region is changed.

## Affected work items

No tracker identifier is embedded in this OSS ADR. Implementations should link
their own work item to this proposal.

## Implementation and acceptance gates

This proposal is implementation-pending and unreleased. Before it may become
`Accepted`:

1. Donmai must implement the exact schemas, raw-wire validation, claim,
   acknowledgement outcome, outbox, receiver resolver, lease state machine,
   quarantine authority, recovery ordering, timing boundaries, and scheduler.
2. The local and every supported WorkareaProvider release path must pass repeated
   equivalent release fixtures and preserve continuous unavailability through
   crash points.
3. Shared fixtures must cover exact bytes; canonical IDs and timestamps; unknown,
   duplicate-key, surrogate, path, and trailing-value rejection; claim/enqueue
   one-millisecond boundaries; no-local-claim acknowledgement; receiver-key
   rotation and missing resolution; restart at every outbox/ack/release boundary;
   `PreserveWorktreeAlways`; guard-before-lease failure; unavailable quarantine
   persistence; quarantine cleanup; actionable-index rebuild; and repeated
   provider release.
4. The downstream mirrored stub and platform-extension ADR must exist, be
   accepted, and supply their own cross-language consumer fixtures and sandbox
   proof.
5. Released-artifact tests—not branch-local or snapshot-only evidence—must prove
   the combined contract before any privileged capability is advertised or any
   activation control is enabled.
