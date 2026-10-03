---
status: Accepted
date: 2026-09-27
boundary: shared
split: inline-addenda
---

# ADR-2026-09-27 — Execution security levels: six ordered dimensions, tighten-only composition, attested enforcement

**Status:** Accepted (product-owner rulings, 2026-09-27; no proposal round)
**Date:** 2026-09-27
**Boundary:** shared (OSS-canonical here: the vocabulary, the composition law,
placement attestation, rendering, the receipt fields and the refusal codes. The
concrete scope storage, the operator surfaces that edit it, and the hosted
policy engine's alignment live in the platform corpus's companion ADR.)
**Authors:** architecture lane, filed by the coordinator session

## Context

The execution layer has no shared answer to "how much may this session do?"
Each harness adapter, each dispatch path and each placement answers it
separately, and the answers disagree. The as-is, stated by shape:

1. **Every headless dispatch is stamped fully autonomous**, and the runner maps
   that stamp to full sandbox access for the harness. Nothing between the intent
   and the harness asks whether that level was wanted.
2. **One harness always runs with its permission prompts skipped**, whatever
   the stamp says.
3. **A local host run reads the operator's home, including credential files,
   with open network egress.** The harness runs as the operator's user with no
   containment.
4. **Interactive runs are weaker than headless runs.** The interactive path
   applies fewer tool restrictions than the headless path does.
5. **One harness's command allow-list is a text-prefix match** on the raw
   command string, so an allowed prefix admits anything chained after it.
6. **Host daemons always advertise a sandbox capability**, whether or not any
   sandbox exists.
7. **`004` declares `egressDefault: allow-all` and
   `repositoryAuthorityEnforcement: none` for every provider.** That table is
   honest, and it is the whole of the corpus's statement about containment.

The corpus also contradicts itself. `ADR-2026-08-06` D3 says **broad bypass
flags are not an adaptation strategy**, but scopes the denial to autonomous
spawn. `ADR-2026-07-24` checklist row 3 bans a blanket bypass only
`when a deny-preserving mode exists` — which licenses bypass for exactly the
harnesses least able to contain a session. Two readings, one permissive.

The precedents needed to fix this already exist and are reused, not re-derived:

- `ADR-2026-08-12-placement-composition-law-and-single-fallback-rule.md` D1.1 —
  permission is fail-closed, an unreadable or erroring value denies, deny is
  monotone downward, allow-merge is intersection.
- `ADR-2026-06-06-two-axis-provider-model.md` D5 — `effective = platformAllowed ∩
  machineAllowed`: a narrower authority may only subtract.
- `ADR-2026-08-22-session-owned-multi-repository-workarea.md` D6 — enforcement
  is **attested by the executor**, never inferred from configuration, and a
  candidate that cannot attest is a typed stage-2 viability exclusion.
- `001` § "Security as defense in depth" — each layer enforces locally; the OSS
  layer ships secure mechanisms, the control plane adds central administration.

The names *posture*, *profile* and *baseline* are already taken in these corpora
(preference posture, burst posture, policy postures, capacity and model
profiles, the disallowed-tools baseline). This decision uses none of them.

## Decision

The control plane owns the contract: the dimensions and their ordered levels,
tighten-only resolution across scopes, and verification. The runner renders the
effective levels into each harness's native configuration and reports the level
it achieved per dimension. A control plane that provisions a sandbox renders the
levels into the provider's configuration and attests them. Secrets are released
only when every report meets the effective levels. A harness, provider or
placement that cannot meet a required level is **refused, never silently
weakened**.

### D1 — Vocabulary: `executionSecurity`, six dimensions, six ladders

The object is **`executionSecurity`**. Each dimension is an ordered ladder;
index 0 is the weakest, and each level permits a subset of what the level below
it permits.

| Dimension | Ladder (index 0 → strongest) |
|---|---|
| `toolApproval` | `bypass` < `deny-list` < `allow-list` < `human-approval-for-writes` |
| `fileRead` | `host` < `home-minus-secrets` < `workarea` |
| `fileWrite` | `host` < `workarea` |
| `network` | `open` < `logged` < `allow-list` < `none` |
| `credentials` | `ambient-host-login` < `injected-only` < `short-lived-scoped` |
| `isolation` | `host-user` < `os-sandbox` < `container` < `microvm` |

Level meanings (normative):

- **`toolApproval`** — the ladder measures enforcement strength; the always-on
  deny baseline (D6) is rendered at every level. `bypass`: no approval prompts;
  the deny entries are rendered best-effort through whatever channel the harness
  has, unattested, and the report says so. `deny-list`: the same deny entries,
  plus any authored ones, enforced on parsed invocations and proven by a
  negative fixture. `allow-list`: only calls the effective allow entries match
  run, and the deny entries still apply. `human-approval-for-writes`: the allow
  list applies, and every call that writes, executes or reaches the network
  waits for a human approval; with no approver attached the call is refused,
  never auto-approved. A text-prefix match on a raw command string satisfies
  neither list level, because chaining defeats it.
- **`fileRead`** — `host`: anything the executing OS user can read in the
  execution context. `home-minus-secrets`: as `host`, minus a declared secret set
  (credential stores, key material, harness logins, environment files outside the
  workarea). `workarea`: the session's workarea plus the read-only runtime and
  toolchain paths the executor declares.
- **`fileWrite`** — `host`: anything the OS user can write. `workarea`: the
  session's workarea plus executor-owned temporary and state paths.
- **`network`** — `open`: unrestricted, unrecorded egress. `logged`: unrestricted
  egress, every destination recorded as session evidence. `allow-list`: egress
  only to the effective allowed destinations, enforced below the harness.
  `none`: no egress beyond the resolved model endpoint and the execution layer's
  own control channel, both mediated by the executor.
- **`credentials`** — governs repository, tool and service credentials.
  `ambient-host-login`: the harness may use any login present on the host.
  `injected-only`: the harness sees only credentials the execution layer
  injected for this session, and ambient stores are unreachable to it — which
  needs `fileRead` at `home-minus-secrets` or stronger, or an isolation boundary
  that excludes them. A separate config home alone does not meet it while
  `fileRead` is `host`, and its negative probe attempts an ambient-login read.
  `short-lived-scoped`: injected only, each credential short-lived and scoped to
  the session's declared resources. **The model-endpoint credential is brokered
  separately:** from `injected-only` up it arrives only by execution-layer
  injection, and `short-lived-scoped` exempts it explicitly (as `network: none`
  exempts the model endpoint) unless the endpoint is served through a
  translating gateway (`ADR-2026-07-24-translating-gateway-model-endpoint-host.md`),
  which holds the key and hands the harness a session-scoped token.
- **`isolation`** — `host-user`: the host OS user, uncontained. `os-sandbox`: an
  OS sandbox the harness cannot widen. `container`: a container boundary.
  `microvm`: a hardware-virtualized boundary.

```ts
interface ExecutionSecurityLevels {
  toolApproval: 'bypass' | 'deny-list' | 'allow-list' | 'human-approval-for-writes'
  fileRead: 'host' | 'home-minus-secrets' | 'workarea'
  fileWrite: 'host' | 'workarea'
  network: 'open' | 'logged' | 'allow-list' | 'none'
  credentials: 'ambient-host-login' | 'injected-only' | 'short-lived-scoped'
  isolation: 'host-user' | 'os-sandbox' | 'container' | 'microvm'
}
type ExecutionSecurityDimension = keyof ExecutionSecurityLevels

// What one scope stores: an optional minimum per dimension. Absent = inherit.
type ExecutionSecurityMinimums = Partial<ExecutionSecurityLevels>

// What the control plane stamps on the intent and the session at admission.
interface EffectiveExecutionSecurity {
  levels: ExecutionSecurityLevels
  sources: Record<ExecutionSecurityDimension, string> // opaque ref of the scope that set each level
  rulesetRevision: string
  resolvedAt: string
  digest: string
}
```

The ladders are closed. An unknown dimension or level is a malformed value and
denies (D2).

### D2 — Composition: strongest wins, tighten-only, fail closed

The scope chain is **the control plane's scope chain, outermost first**, ending
at the session. For a child session the parent session is a scope in the chain,
so a child is never weaker than its parent.

1. **The outermost scope holds a value for every dimension.** Every narrower
   scope may store an optional minimum per dimension; absent means inherit.
2. **The effective level is the strongest level across the chain**, per
   dimension. Strongest-wins is `ADR-2026-08-12` D1.1's intersection read on an
   ordered ladder: each level permits a subset of the level below it, so
   intersecting what every scope allows is taking the strongest level any scope
   requires. Rule 7 keeps that true for list contents.
3. **Weakening is refused at write time.** Saving a level weaker than the
   inherited one is refused with `execution_security_weakening_refused`, naming
   the inherited level and its source scope. A later tightening at a wider scope
   needs no repair: the narrower value becomes redundant, never effective.
4. **Fail closed, and the control plane never defaults its own data.** An absent
   outermost value is `execution_security_unconfigured`, naming the dimension
   and the scope. An unreadable, malformed or erroring value at any scope, more
   than one outermost value, or a session with no stamp at claim or secret
   release is `execution_security_unresolvable` and denies — the D1.1 law,
   including its stale-but-bounded snapshot rather than fail-open against a
   missing one. The execution layer carries **no compiled-in default level**.
5. **One answer for every session mode.** Autonomous, human-controlled and
   interactive sessions resolve the same effective levels from the same chain.
   A human at the keyboard is an approver for the approvals a level requests,
   never a reason to lower a level.
6. **No in-band override.** No request field, session mode, role, flag or
   operator action lowers the effective level for one session. Lowering is an
   edit at the scope that set the level, which applies to new admissions beneath
   it; a running session's stamp can only tighten (rule 8).
   Break-glass work happens outside the control plane.
7. **List contents are configuration, composed monotonically.** The entries
   behind the `toolApproval` and `network` list levels are authored only at the
   workflow scope — on the dispatching step, or on the agent card that step
   dispatches, which composes at the same workflow scope — never on the
   outermost value, an organization or a project. An organization-wide allow list
   is therefore not expressible, by choice. Within the workflow scope and down to
   the session, allow entries only shrink (intersection) and deny entries only
   grow (union), always including the D6 deny baseline; a stronger level never
   drops a weaker scope's entries. With no authored allow entries, a
   `toolApproval` list level admits no tool call, and `network: allow-list`
   admits only the model endpoint and control channel that `none` admits.
8. **The stamp is fixed at admission.** A tightening applies to new admissions;
   a resume or restart re-resolves and may only tighten the stamp. Claim and
   secret release check the session's own stamp, whose revision and resolution
   time let a surface show that the current chain is stricter than a running
   session's.

**Single-machine deployments.** The daemon is its own control plane and its
configuration is the outermost scope. The installer seeds it visibly, as a
hosted seed migration would; the resolver has no fallback. A daemon upgraded
from a release without levels detects the upgrade by its configuration schema
version — never by a missing key — writes index 0 on every dimension to its
configuration, visibly, and logs that it did. A key deleted after that upgrade
fails closed. A daemon registered to a control
plane never treats its local configuration as the outermost scope: its local
values are placement-owned and tighten-only (the `ADR-2026-06-06` D5 rule that a
machine may only subtract).

### D3 — Placement attestation and viability exclusion

1. **Two proofs, at two times.** Before placement, an executor or provider
   adapter attests per dimension the strongest level it can enforce
   (`executionSecurityEnforcement` in `004`), proven by a negative probe on its
   exact version — an attempted read, write, connection or credential use
   observed to be refused. Viability reads only that attestation. After
   placement, the per-session records of D4 prove what this session got; secret
   release reads only those. Pool configuration, prompt instructions and
   same-user permission changes prove nothing (the `ADR-2026-08-22` D6 rule 7
   reasoning, generalized). A declared but unproven value is a ceiling, not a
   level, and an absent attestation is exactly index 0. **A control plane counts
   an attestation toward viability only once it can verify that attestation's
   per-session record at secret release**; until then the placement counts as
   index 0 on that dimension, so tightening it is refused rather than trusted.
2. **Achievable level = the strongest enforcing layer.** For a candidate
   (placement × harness adapter version), the achievable level per dimension is
   the strongest of the placement's attested level and the level the harness's
   adaptation profile can render on that placement.
3. **Viability excludes.** A candidate whose achievable level is below the
   effective level on any dimension is excluded at stage 2 with
   `execution_security_unmet` and stable rule id `execution-security.<dimension>`.
   `ADR-2026-08-12` D1.2's loud, typed ∅ applies unchanged. A pin never bends
   it; ranking never trades it; claim time re-runs the same predicate.
4. **Placement-owned configuration may only be stricter.** A pool's own
   setting for a dimension (an egress policy, for example) may tighten beyond
   the effective level and never loosen below it.
5. **No false capability claims.** A host must not advertise a sandbox
   capability it does not have. A generic sandbox tag is not a level and is
   never read as one.

### D4 — Two rendering targets, two records

**The runner** turns the effective levels into the exact harness/version's
native configuration as `ADR-2026-08-06` adaptation-plan entries, through the
existing channel and delivery vocabularies (`tool_permission`, `config_file`,
`config_home`, `environment_binding`, `injected_boundary`, `host_adapter`); no
channel or delivery strategy is added. **The level is decided by proof, not by
which flag is used.** A no-prompt mode whose deny rules hold, proven by the
exact version's negative fixture, may render `deny-list`. A flag that disables
policy enforcement itself, not just prompts, is rendered only at `bypass`, and
at `bypass` the runner prefers a no-prompt mode that keeps deny rules. A grant
of full filesystem or network access is rendered only where every dimension it
opens is at index 0.

**A control plane that provisions a sandbox** renders the levels into the
provider's own configuration before the runner starts: egress policy from
`network`, the injected credential set and its form from `credentials`, the
runner's user and in-box write scope from `fileRead`/`fileWrite`, and the
isolation class the provider actually delivers. It records what it achieved in
a provisioning record of the same shape.

Illustrative, non-exhaustive mapping by harness family (the exact
harness/version adaptation manifest is authoritative):

| Harness family | `toolApproval` | `fileRead` / `fileWrite` / `network` |
|---|---|---|
| Native permission grammar (a permission mode plus allow/deny rules) | `bypass`: no-prompt mode plus the deny baseline as deny rules, best-effort; `deny-list`: the same rules proven by fixture, under the no-prompt mode only if the fixture proves they hold there; allow rules for `allow-list`; ask rules routed to the approval adapter at the top level | the harness's own sandbox settings where the pinned version has them; otherwise the placement |
| Native OS sandbox plus approval policy | "never ask" at `bypass` with exec-policy deny rules best-effort; exec-policy rules for the list levels | full-access sandbox only when `fileRead` and `fileWrite` are `host` and `network` is `open`; workspace-write sandbox for `fileWrite: workarea`; sandbox network off for `none` |
| Extension API, no native policy | the handshake-verified injected boundary (checklist rows 3–4), carrying the deny baseline at every level | executor OS sandbox or placement only |
| Declared harness on a shared driver | only what the driver renders | driver or placement |

> **Forward note, 2026-10-03.** The executor OS sandbox that the "Extension
> API, no native policy" row defers to is specified by
> `ADR-2026-10-03-executor-os-confinement.md`. The executor confines the
> harness process at its own spawn in both session modes, attests
> `fileWrite: workarea` and `isolation: os-sandbox` per harness (never
> host-wide), reports `executor_os_sandbox` in the receipt, and refuses a
> requested confinement it cannot apply with `execution_security_unrenderable`
> plus a closed reason. No refusal code is added to D5.

For every family, `credentials` above index 0 needs the ambient stores
unreadable (D1), not only a separate config home.

Where no channel can meet a required level, the adaptation plan is denied with
`execution_security_unrenderable`; the provisioning control plane refuses the
same way.

```ts
type EnforcingLayer =
  | 'harness_native'      // the harness's own permission grammar or sandbox
  | 'injected_boundary'   // a handshake-verified injected policy boundary
  | 'executor_os_sandbox' // an OS sandbox the executor applies around the harness
  | 'provider_sandbox'    // the provisioned sandbox's own configuration
  | 'egress_proxy'        // an executor-owned egress proxy
  | 'credential_broker'   // execution-layer credential injection

interface ExecutionSecurityDimensionReport {
  required: string        // informational echo only; never compared
  achievedLevel: string
  enforcingLayers: EnforcingLayer[] // empty only when achievedLevel is index 0
  evidenceDigest?: string
}
// The dimensions that carry an always-on deny set (D6) report how it held.
interface DenyBaselineDimensionReport extends ExecutionSecurityDimensionReport {
  denyBaseline: 'enforced' | 'best_effort' | 'unavailable'
}
interface ExecutionSecurityReport {
  toolApproval: DenyBaselineDimensionReport // the tool deny baseline
  network: DenyBaselineDimensionReport      // the always-on egress denies (cloud metadata)
  fileRead: ExecutionSecurityDimensionReport
  fileWrite: ExecutionSecurityDimensionReport
  credentials: ExecutionSecurityDimensionReport
  isolation: ExecutionSecurityDimensionReport
}

// Added to AppliedAdaptationReceipt (ADR-2026-08-06 D4):
//   executionSecurity: ExecutionSecurityReport
//   provisioningRecordId?: string
interface ExecutionSecurityProvisioningRecord {
  recordId: string
  admissionReceiptId: string
  providerRef: string
  // The dimensions provisioning renders; network (with denyBaseline) is required.
  report: Pick<ExecutionSecurityReport, 'network' | 'credentials' | 'fileRead' | 'fileWrite' | 'isolation'>
  recordedAt: string
}
```

A `toolApproval` report above `bypass` requires `denyBaseline: 'enforced'`;
otherwise the achieved level is `bypass`. A `network` report at `allow-list` or
above requires `denyBaseline: 'enforced'`. The verifier reads each
`denyBaseline` from **the record that owns that layer**: `network` from the
provisioning record when the control plane provisioned the context, and from
the runner's receipt otherwise; `toolApproval` always from the runner's
receipt.

**Secrets wait for the records.**

- **"Meets" is computed against the control plane's own stamp.** Each reported
  `achievedLevel` is compared with the session's stamped level; the `required`
  a report echoes is never compared.
- **Each record meets what its layers own, and together they meet every stamped
  level.** The runner's receipt references the provisioning record and counts
  its layers, but the verifier takes `provider_sandbox` and `credential_broker`
  claims from the provisioning record the control plane wrote itself, never from
  the runner's copy.
- **Refusals, each with zero secret delivery and zero spawn:** a session with no
  stamp is `execution_security_unresolvable`; a context the control plane
  provisioned with no valid provisioning record is
  `execution_security_receipt_unmet` at any level; a report below the stamp is
  `execution_security_receipt_unmet`. A report is never repaired by inference
  from process state.

**Compatibility: only peer data defaults to index 0.** Only data a peer supplies
is read as index 0 when absent: a runner receipt with no `executionSecurity`
report, or no receipt at all, achieves exactly index 0 — which meets an index-0
stamp and nothing above it. The control plane never reads its own data (the
stamp, its provisioning records) as index 0. A runner that receives a work item
with no levels section renders index 0 only while its control plane has not
advertised that it always stamps; after that handshake a missing section is
`execution_security_unresolvable` and the run is refused.

### D5 — Refusal codes

The six codes form the closed `ExecutionSecurityRefusalCode` enum; each surface
carries the subset shown.

| Code | Carried by | Meaning |
|---|---|---|
| `execution_security_unconfigured` | resolution refusal | The outermost scope has no value for a dimension |
| `execution_security_unresolvable` | resolution, claim or secret-release refusal | A value is unreadable, malformed or erroring; more than one outermost value; or a session has no stamp |
| `execution_security_weakening_refused` | scope-write refusal | A stored minimum below the inherited level; carries the inherited level and its source scope |
| `execution_security_unmet` | stage-2 exclusion reason (the closed reason enum of the `ADR-2026-08-13` addendum) | The candidate cannot enforce the effective level; rule id `execution-security.<dimension>` |
| `execution_security_unrenderable` | `AdaptationDenialCode`; provisioning refusal | The exact harness/version or provider has no channel for a required level |
| `execution_security_receipt_unmet` | secret-release refusal | A report below the stamp, or a required provisioning record missing or malformed |

Codes are typed on both sides of the wire. Human-readable detail is
display-only; no consumer branches on it (`ADR-2026-08-13` addendum rule).

### D6 — What stays always-on

Existing always-on protections are not levels, and no level disables them. They
are the "nearly" in a nearly wide-open default:

- **The control plane's tool deny baseline** — credential-surface denies (key and
  cloud-credential directories, environment files outside the workarea,
  environment dumps, metadata fetches), the role's tool-surface denies, and the
  tool block lists the control plane stamps. Rendered in every session mode and
  at every level: best-effort at `bypass`, enforced and proven from `deny-list`
  up (D1).
- **The agent-environment variable blocklists and runner-only environment
  names.**
- **The cloud-metadata egress denial, where the placement can enforce it.** Where
  it cannot, the record that owns the network layer says so in
  `network.denyBaseline`, and the gap stays visible.
- **The trust-boundary rules** of
  `ADR-2026-08-12-pi-extension-delivery-seam-and-capability-pack-boundary.md`.

## Consequences

### Positive

- One vocabulary and one law for containment across harnesses, placements,
  providers and session modes; every effective level has a named source scope.
- The D3/row-3 contradiction is resolved: bypass legality is a function of a
  visible level, never of a harness's missing grammar or a session's mode.
- Any scope can tighten and see the effect; nothing below can undo it.
- The weakest system value keeps today's behavior running while every stronger
  level becomes available the moment a placement can attest it.

### Negative

- Every adaptation manifest gains a per-dimension rendering declaration, and
  every placement that claims a level above index 0 needs a negative probe.
- Tightening any scope can empty the candidate set. That is loud by design, and
  it is an outage for the affected work until a capable placement exists.
- `human-approval-for-writes` stalls autonomous work unless an approver is
  attached. That is the level's meaning, not a defect.

### Risks

- **Rendering drift across harness versions.** A pin bump can change a native
  knob's meaning. Mitigated by checklist rows 2, 9 and 10: levels are fixtures
  on the exact pinned version.
- **Fail-closed outermost value as a work-stoppage risk.** Mitigated as `D1.1`
  mitigates policy: a stale-but-bounded snapshot with exposed age, never a
  compiled-in fallback.
- **Over-trusting a provider's product claim.** Mitigated by attestation: a
  provider's native control is a ceiling, not a level, until a record proves it.

## Alternatives considered

- **Per-mode policy (interactive looser than autonomous).** Rejected by ruling:
  humans and agents act on the same risk interfaces.
- **Harness or host self-declares its level.** Rejected: advertised capability
  is how a daemon came to claim a sandbox it lacks. Levels are attested.
- **An override path with elevated approval.** Rejected: an in-band override is
  a bypass with paperwork. Break-glass happens outside the control plane.
- **One sandbox on/off switch.** Rejected: the dimensions are independent, and
  harnesses and placements enforce different subsets of them.
- **A code default for the outermost value.** Rejected by ruling: defaults live
  in authored, visible configuration; absence fails closed.
- **Degrade to the best available level.** Rejected: a silent downgrade is the
  bug class the placement law exists to delete.

## Affected documents

Every edit below lands in this ADR's accepting commit.

- `004-sandbox-capability-matrix.md` — `executionSecurityEnforcement` added to
  the capability struct; six rows added to the per-provider table with honest
  current values (declared isolation classes marked unproven); routing step 1 gains the execution-security bullet; daemon-mode
  declarations gain the no-false-sandbox rule; the OSS/SaaS table gains two rows.
- `ADR-2026-08-06-harness-adaptation-plan-and-receipt.md` — amendment notes on
  D3 (the bypass rule applies to every session mode and is keyed to the
  `toolApproval` level) and D4 (receipt field, provisioning record, denial code,
  secret-release condition).
- `ADR-2026-07-24-harness-addition-v2-checklist.md` — row 3 amended and its
  retired qualifier quoted; amendment section resolving the contradiction and
  extending rows 9 and 10.
- `ADR-2026-08-12-placement-composition-law-and-single-fallback-rule.md` —
  addendum: executionSecurity levels join the viability tuple.
- `001-layered-execution-model.md` — § "Security as defense in depth" pointer.
  No `BOUNDARY-SYNC` region is touched.
- `scripts/retired-claim-lint.sh` — rule `BYPASS_ABSENT_DENY_MODE` for the
  retired row-3 qualifier.
- `README.md`, `AGENTS.md` — index and read-order entries.

## Affected work items

This corpus carries no tracker identifiers; the delivery program is named by
shape and enumerated in the platform corpus's companion ADR.

- **Control plane:** scope storage and effective resolution with source scope;
  the outermost value edited on an operator surface; workflow and session
  tightening; stamping the effective levels on every dispatch path; sandbox
  provisioning that renders and records levels; secret release gated on the
  records.
- **This corpus's repositories:** the runner renders levels per harness and
  placement, reports achieved levels with enforcing layers, and refuses what it
  cannot meet; host registration stops advertising a sandbox it lacks;
  adaptation manifests declare per-dimension rendering; per-level negative
  fixtures and smokes.

## Implementation notes

- **One predicate, three evaluation points.** Resolve time, claim time and
  secret release read the same effective levels and the same comparison. A
  second re-derivation is the defect this law exists to prevent.
- **Index 0 is legal and explicit.** A deployment that wants today's behavior
  writes the weakest levels as authored values and sees them displayed with
  their source. It does not get them by omission.
