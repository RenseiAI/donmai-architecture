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

- **`toolApproval`** — `bypass`: tools run without approval or policy checks.
  `deny-list`: every call runs except those an enforced deny list matches.
  `allow-list`: only calls an enforced allow list matches run. `human-approval-for-writes`:
  the allow list applies, and every call that writes, executes or reaches the
  network waits for a human approval; with no approver attached the call is
  refused, never auto-approved. **List levels match parsed invocations** (tool
  identity plus parsed arguments). A text-prefix match on a raw command string
  satisfies neither list level, because chaining defeats it.
- **`fileRead`** — `host`: anything the executing OS user can read in the
  execution context. `home-minus-secrets`: as `host`, minus a declared secret set
  (credential stores, key material, harness logins, environment files outside the
  workarea). `workarea`: the session's workarea plus the read-only runtime and
  toolchain paths the executor declares.
- **`fileWrite`** — `host`: anything the OS user can write. `workarea`: the
  session's workarea plus executor-owned temporary and state paths.
- **`network`** — `open`: unrestricted, unrecorded egress. `logged`: unrestricted
  egress, every destination recorded as session evidence. `allow-list`: egress
  only to declared destinations, enforced below the harness. `none`: no egress
  beyond the resolved model endpoint and the execution layer's own control
  channel, both mediated by the executor.
- **`credentials`** — `ambient-host-login`: the harness may use any login present
  on the host. `injected-only`: the harness sees only credentials the execution
  layer injected for this session; ambient logins are unreachable.
  `short-lived-scoped`: injected only, and each credential is short-lived and
  scoped to the session's declared resources.
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

// What the control plane stamps on the intent and the session.
interface EffectiveExecutionSecurity {
  levels: ExecutionSecurityLevels
  sources: Record<ExecutionSecurityDimension, string> // opaque ref of the scope that set each level
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
   requires.
3. **Weakening is refused at write time.** Saving a level weaker than the
   inherited one is refused with `execution_security_weakening_refused`, naming
   the inherited level and its source scope. A later tightening at a wider scope
   needs no repair: the narrower value becomes redundant, never effective.
4. **Fail closed.** An absent outermost value is
   `execution_security_unconfigured`, and the error names the dimension and the
   scope. An unreadable, malformed or erroring value at any scope is
   `execution_security_unresolvable` and denies — the D1.1 law, including its
   stale-but-bounded snapshot rather than fail-open against a missing one. The
   execution layer carries **no compiled-in default level**.
5. **One answer for every session mode.** Autonomous, human-controlled and
   interactive sessions resolve the same effective levels from the same chain.
   A human at the keyboard is an approver for the approvals a level requests,
   never a reason to lower a level.
6. **No in-band override.** No request field, session mode, role, flag or
   operator action lowers the effective level for one session. Lowering is an
   edit at the scope that set the level, which applies to everything beneath it.
   Break-glass work happens outside the control plane.

In a single-machine deployment the daemon is its own control plane and its
configuration is the outermost scope: the value is authored and readable data,
written explicitly at install, never a constant in the binary.

### D3 — Placement attestation and viability exclusion

1. **Placements attest; they do not advertise.** Each execution host and
   substrate provider declares, per dimension, the strongest level it can
   enforce (`executionSecurityEnforcement` in `004`). A level counts only when
   the executor, or the control plane that provisioned the context, proves it
   with a negative probe on the exact version — an attempted read, write,
   connection or credential use observed to be refused. Pool configuration,
   prompt instructions and same-user permission changes prove nothing (the
   `ADR-2026-08-22` D6 rule 7 reasoning, generalized). An absent declaration is
   exactly index 0 on every dimension.
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
channel or delivery strategy is added. A harness's broad bypass flag is rendered
only where the effective `toolApproval` level is `bypass`, and a full-filesystem
or full-network grant only where that dimension's effective level is index 0.

**A control plane that provisions a sandbox** renders the levels into the
provider's own configuration before the runner starts: egress policy from
`network`, the injected credential set and its form from `credentials`, the
runner's user and in-box write scope from `fileRead`/`fileWrite`, and the
isolation class the provider actually delivers. It records what it achieved in
a provisioning record of the same shape.

Illustrative, non-exhaustive mapping by harness family (the exact
harness/version adaptation manifest is authoritative):

| Harness family | `toolApproval` | `fileRead` / `fileWrite` / `network` | `credentials` |
|---|---|---|---|
| Native permission grammar (a permission mode plus allow/deny rules) | skip-permissions mode only at `bypass`; deny/allow rules under a non-bypass mode for the list levels; ask rules routed to the approval adapter at the top level | the harness's own sandbox settings where the pinned version has them; otherwise the placement | isolated config home; injected environment only |
| Native OS sandbox plus approval policy | "never ask" only at `bypass`; exec-policy rules for the list levels | full-access sandbox only at `host`; workspace-write sandbox for `fileWrite: workarea`; sandbox network off for `none` | isolated home directory |
| Extension API, no native policy | the handshake-verified injected boundary (checklist rows 3–4) | executor OS sandbox or placement only | isolated state directory |
| Declared harness on a shared driver | only what the driver renders | driver or placement | driver |

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
  required: string        // the effective level
  achievedLevel: string
  enforcingLayers: EnforcingLayer[] // empty only when achievedLevel is index 0
  evidenceDigest?: string
}
type ExecutionSecurityReport = Record<ExecutionSecurityDimension, ExecutionSecurityDimensionReport>

// Added to AppliedAdaptationReceipt (ADR-2026-08-06 D4):
//   executionSecurity: ExecutionSecurityReport
//   provisioningRecordId?: string
interface ExecutionSecurityProvisioningRecord {
  recordId: string
  admissionReceiptId: string
  providerRef: string
  report: ExecutionSecurityReport  // provider_sandbox and credential_broker layers only
  recordedAt: string
}
```

**Secrets wait for the records.** Each record must meet the levels assigned to
the layers it controls, and together they must meet every effective level. The
runner's receipt is the combined view: it references the provisioning record
and counts its layers. A missing, malformed or short record is
`execution_security_receipt_unmet`: zero secret delivery, zero spawn. A report
is never repaired by inference from process state.

**Compatibility is additive.** On the wire, an absent levels section is exactly
index 0 on every dimension, and an absent report achieves exactly index 0.
Index 0 is met by construction, so a legacy peer stays viable only where every
effective level is the weakest. A control plane whose effective levels are
above index 0 never emits a work item without the section.

### D5 — Refusal codes

| Code | Raised at | Meaning |
|---|---|---|
| `execution_security_unconfigured` | resolution | The outermost scope has no value for a dimension |
| `execution_security_unresolvable` | resolution | A scope's value is unreadable, malformed or erroring |
| `execution_security_weakening_refused` | scope write | A stored minimum below the inherited level; carries the inherited level and its source scope |
| `execution_security_unmet` | stage 2 exclusion reason | The candidate cannot enforce the effective level; rule id `execution-security.<dimension>` |
| `execution_security_unrenderable` | adaptation or provisioning | The exact harness/version or provider has no channel for a required level |
| `execution_security_receipt_unmet` | secret release | A record is missing, malformed, or reports an achieved level below the effective level |

Codes are closed and typed on both sides of the wire. Human-readable detail is
display-only; no consumer branches on it (`ADR-2026-08-13` addendum rule).

### D6 — What stays always-on

Existing always-on protections are not levels and no level disables them: the
agent-environment credential blocklists, runner-only environment names, the
cloud-metadata egress denials, and the trust-boundary rules of
`ADR-2026-08-12-pi-extension-delivery-seam-and-capability-pack-boundary.md`.
They remain defense in depth beneath the ladder, including at index 0.

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
  current values; routing step 1 gains the execution-security bullet; daemon-mode
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
