---
status: Proposed
date: 2026-08-07
boundary: shared
split: inline-addenda
---

# ADR-2026-08-07 — Onboarding is the only moment a user is required to act

**Status:** Proposed
**Date:** 2026-08-07
**Boundary:** shared
**Authors:** mark, agent:claude

## Context

### The statement this ADR encodes

> Once a user onboards their machine and installs the host service, all actions
> happening via mobile, terminal, or web occur on the host and "just work".
> After that pairing and authentication, all refreshing, adding/removing of
> org/project scopes and everything else should be transparent to the user.
> Ideally that setup is one time, and the platform handles the rest.

Read strictly: **onboarding is the only moment a user should have to act.**
Everything after it — token refresh, credential plumbing, scope changes, host
re-registration, version drift, reconnection, machine re-identification — is the
system's job, and must be invisible and self-healing.

The statement is a product principle. It has never been an architectural
invariant, and nothing enforces it. This ADR proposes making it one.

### What prompted it

A three-stage audit ran on 2026-08-06/07 across the OSS daemon, the composing
CLI binary, the closed control plane, the attach relay, and the mobile client,
covering onboarding-and-pairing, steady-state-and-refresh, and
scope-changes-and-clients. Every claimed defect then went through an adversarial
verification pass whose job was to falsify it: find the reconciler the auditor
missed, the branch that is unreachable in normal operation, the stale comment
describing behavior a later fix already closed.

Roughly half the claims did not survive. That matters for how this ADR reads —
the evidence below is what remains after someone tried hard to knock it down,
and several of the knockdowns were instructive in their own right (below,
§ "What already works").

Two properties of the surviving set are what motivate a principle rather than a
list of bug fixes:

1. **Not one confirmed defect required a human decision.** In every case the
   information needed to resolve the state was already held by the platform, by
   the host's own registration, or by a token the host was already carrying. The
   user was being asked to re-supply something the machine already knew, or to
   perform a mechanical step on the machine's behalf.
2. **The confirmed defects are five shapes, not eighteen bugs.** They share four
   or five underlying mechanisms. Fixed independently, they would produce
   partial lanes — which is exactly how one of the shapes came to exist.

### The five shapes

**Shape 1 — State frozen at process start.** Registration claims (including the
claimed project-id set), the served-scope set, the project→org routing map,
per-scope allowlists, and per-scope credential contexts are all captured once
when the daemon process starts and never renegotiated. The OSS daemon builds its
registration options once in `Start` (`daemon/daemon.go:709-722`) and reuses that
captured struct even on the reactive re-register path
(`daemon/runtime_token.go`); the composing binary enumerates its additional
served orgs once at boot. The consequence is structural: **every scope change is
a process-restart event by construction.** Because the restart is a hard service
kick, the product's answer to "I added a project" is currently "lose all your
running work on that machine."

Not all of it is frozen, which is what makes the diagnosis crisp rather than
sweeping: the primary config file *does* hot-reload through a file watcher
(`daemon/yaml_watcher.go`, wired at `daemon/daemon.go:986`), and the reload path
pushes the new project set into the live spawner. The mechanism exists. It is
applied to one file, one lane, and one field.

**Shape 2 — Half-built control channels.** The wire already carries what is
needed, and one side does not use it.

- The heartbeat's pending-mutation rail applies `project.enable/disable/add/remove`
  to a running daemon, persists the config, refreshes the spawner, and ACKs —
  all implemented in OSS (`daemon/mutation_apply.go`). The CLI never calls it;
  it writes files locally and prints a restart instruction instead.
- The control plane's own web surface *does* call it — and that path is also
  incomplete, because no mutation-ACK path updates the control plane's admission
  mirror, and the heartbeat request body carries no enabled-scope-id field at all
  (`daemon/heartbeat.go:428-451`; the reported allowlist digest covers only
  `(projectID, repository)` pairs, `daemon/allowlist_report.go`). The mirror that
  gates dispatch can therefore only be moved by re-registration. So the click
  changes the host and not the router; the CLI changes the router and not the
  running host.
- On the secondary-scope lane the same channel silently swallows work: the
  handler wired there applies only `session.kill` and `continue`s past every
  other op **without** recording it as applied or as failed
  (`daemon/mutation_apply.go:122-137`). The control plane has already stamped the
  mutation delivered, and redelivery is gated on undelivered, so the user's
  action is dropped once and never retried, with no error anywhere.

**Shape 3 — Machine state derived from human session state.** The daemon's
primary-scope credential plumbing reads the interactive CLI's *currently active
org* pointer. When that scalar is absent — which is the default outcome of the
documented user-authentication onboarding path, because a user-kind auth context
is deliberately scope-neutral — the entire spawn-time credential rail is disabled
for the process lifetime and every platform-keyed session aborts fail-closed.

This was confirmed live on the founder's machine, not merely in code: two of
three served scopes had no credential plumbing, warning hourly, while the *same
process* was successfully polling both of those scopes on a different lane using
a scope id it derived from host-pinned state a few hundred lines away in the same
file. The remedy printed into the log named a command that does not exist in the
binary.

**Shape 4 — Success asserted from bookkeeping, not post-conditions.** The
onboarding wizard's most common path — pairing a project that already has a
repository bound, i.e. every machine after the first and every teammate after the
first — mints no worker token and writes no host allowlist, then prints
"You're ready." The daemon it installed comes up in an unregistered stub mode,
reports itself ready over its own local control API, and never claims work.
Nothing self-heals it, because the control plane cannot push to a host it has
never seen. Separately, an empty allowlist is read by the control plane as
"serves nothing" rather than "unrestricted", so dispatch refuses silently; and
the onboarding journal records steps *skipped because their post-condition was
already satisfied* as not-completed, so a fully working install is dropped back
into the wizard on every bare invocation.

**Shape 5 — Failure reported where the process is, not where the user is.** A
secondary-scope registration failure logs a warning and continues; that scope is
inert for the process lifetime with no control-plane-visible signal and no retry.
A terminated attach leg is never re-dialed: the runner records a warning, nils the
channel, and keeps supervising the local terminal, so the session stays alive,
holds a capacity slot, keeps accruing wall-clock, and is permanently unreachable
from web and mobile (`runner/interactive_loop.go:276`). The relay's kill endpoint
answers success whenever the *room* exists, even when no host leg received the
frame. And the client branches on the close code *before* consulting the relay's
own `retryable` flag (`attachclient/inbound.go:121`), so a stale-epoch close that
the relay deliberately marks retryable — its documented way of saying "the prior
leg has not been collapsed yet, come back" — becomes a permanent disconnect. The
only confirmed recovery the founder found was a manual daemon restart.

### What already works, and should not be re-fixed

The verification pass was as useful for what it defended as for what it
confirmed. Recording it here so implementers copy rather than reinvent:

- The primary scope's proactive token refresher and its credential fan-out to
  both the heartbeat and poll loops (`daemon/daemon.go:809-975`) are correct and
  invisible. The secondary-scope path is a hand-rolled subset of it; the fix is
  to route through the same wiring, not to write a second one.
- The config file watcher's hot reload is exactly the mechanism the restart
  instructions are missing. It needs to watch a directory rather than one
  basename, and merge per-scope rather than replace globally — a caveat worth
  stating, because the current replace-shaped reload evicts secondary scopes'
  projects from the shared spawner.
- The workerId-preserving token refresh endpoint is live; an OSS comment claiming
  it 404s is stale.
- The attach client's reconnect loop, equal-jitter backoff, transport downgrade
  and upgrade-back are solid. The gap is only in which close codes are treated as
  terminal.
- The secondary-scope credential registry's add-only lazy construction with a
  file watcher is a genuinely self-healing design and is the model the primary
  path should copy.
- A convergence reconciler already exists on the control-plane side whose own
  header documents this exact bug class ("bindings added after registration took
  effect only after a token wipe and daemon restart"). It runs every beat and
  faithfully propagates a stale set, because the input it reads is the thing that
  never moves.

Nearly every fix this ADR implies is "apply an existing mechanism to a lane that
does not have it."

### One correction the audit itself earned

One machine was observed carrying two different frozen machine identities,
derived from `os.Hostname()` (`daemon/config.go:642`) at config-creation time and
persisted independently per config file. Verification showed this is not
service-affecting today: the ids live under different scopes, the host row is
keyed on (scope, machine), identity is a bootstrap key rather than a steady-state
one, and stale rows are reaped on a timer. It is recorded here anyway, because the
rule it violates (D1) is cheap to hold and expensive to retrofit — the latent loss
is operator pool pins and operator delete tombstones, which are keyed on the
derived id and silently revert when it changes.

## Decision

**Onboarding is the only moment a user is required to act.** Adopt this as an
architectural invariant on both sides of the boundary, with two normative halves:
what "transparent" means operationally, and where legitimate user action begins.
Both halves are binding. The first without the second reads as "automate
everything", which is wrong and unsafe.

### What "transparent" means operationally

**D1 — Identity is minted once, opaquely, and referenced rather than copied.**
A host's durable identity is established at onboarding, is opaque, and lives in
exactly one record that every per-scope configuration *references*. It is never
derived from mutable environment state — hostname, network configuration,
DHCP-assigned names — and never re-derived per file or per scope. Rotation is an
explicit platform-initiated operation, never a side effect of the environment
changing. Any identity-keyed operator state (pins, tombstones, bindings) survives
an identity change or the identity is not durable.

**D2 — Machine state never depends on interactive human session state.**
A background service's scope, credential scope, and routing identity derive from
host-pinned state or from the platform. They never read a mutable "currently
active" pointer that an interactive shell can move. A human changing scope in a
terminal must not be able to arm or disarm a daemon.

**D3 — Scope changes are runtime operations, not process-lifecycle events.**
Adding or removing a scope on a host takes effect on the running host with no
process restart, no re-pairing, and no re-authentication. Anything captured at
process start that can legitimately change during the process lifetime is a
defect — registration claims, served-scope sets, routing maps, allowlists, and
credential contexts are all runtime-mutable. *Corollary:* no user-facing
instruction is ever "restart the service"; and any restart the platform performs
on the user's behalf drains first, because a scope change must never cost
in-flight work.

**D4 — State the platform can compute, the platform computes.**
No user-facing remediation hint may name an action whose inputs the platform
already holds — in its own records, in the host's registration, in a token the
host already carries, or in state the platform itself wrote. Every remediation
string is an admission that a self-heal is missing; it is a work item, not a UX
affordance. A hint naming a command that does not exist is a gate failure, not a
typo: the remediation surface should be test-asserted against the registered
command set.

**D5 — Everything that can fail transiently retries and converges.**
No one-way failure latches. No boot-time one-shots for conditions that resolve
later. No frozen snapshots of mutable state. Every credential, registration,
refresh, and transport rail retries under bounded backoff and reports its state.
Fail-closed remains the correct posture where a wrong answer would cross a tenant
boundary — but fail-closed must be paired with a signal: the claim is NACKed back
to the queue and the host reports that it cannot serve, rather than the session
dying silently or looping.

**D6 — Success is asserted from post-conditions, never from bookkeeping.**
A setup step, a mutation ACK, or a control response reports success only when the
end state it claims is verified: the credential exists and authenticates, the
scope is present in the admission mirror, the frame reached a live peer. "The room
exists" is not "the kill was delivered." "The step ran" is not "the step's
post-condition holds." Correspondingly, a step skipped *because its post-condition
already holds* is complete, and readiness is derived from live state rather than
from a persisted journal.

**D7 — Conditions surface where the user is.**
No failure state may be observable only in a local log file. Anything that makes a
host unable to serve — a failed scope registration, an unresolvable allowlist
entry, a dead credential socket, an abandoned attach leg — rides the existing
host-status signal to the control plane and appears in every client. Symmetrically,
conditions clear when they clear: a flag that records the worst moment a session
ever had is not a health signal.

**D8 — One server-side operation per user intent; clients are peers.**
Each state-changing intent is expressed once, server-side ("this host serves this
scope", "stop this session"), and every client calls that one operation. Clients
carry no machine-facing concepts. A capability reachable from only one client is
not shipped, and physical presence at a machine is never a requirement for
anything except installing the host service.

**D9 — Desired state converges in both directions.**
A local write reaches the control plane's admission mirror; a control-plane write
reaches the host and is ACKed as applied or as failed. A control channel used by
only one of the two writers is a half-built feature and must be finished or
removed. An op a lane cannot apply is a **failure**, never a silent drop.

### The boundary of legitimate user action

This is the half that keeps the principle honest. Note first what the evidence
says about its width: **of the confirmed defects, zero fell inside this
boundary.** Every one was mechanism. The boundary is narrow, and in practice
almost nothing that currently interrupts a user belongs inside it. It exists so
that the few genuine cases are protected — and so that "the user must act" becomes
a claim that has to be argued rather than assumed.

Legitimate user action is limited to:

- **L1 — Identity assertion.** The user proving who they are to the identity
  provider. Not delegable. The platform must not hold a reusable credential that
  lets it re-assert a human identity without the human.
- **L2 — Consent to enroll a machine or a scope in a tenant.** Binding a physical
  machine to an organization, or granting a host authority over a project, is a
  trust decision whose blast radius exceeds the actor; the platform may not
  self-grant it. Note precisely what this does *not* license: once consent is
  given, **executing** it — minting keys, writing configuration, registering,
  re-registering, widening a credential when the consented scope widens — is
  entirely mechanism and belongs to D1–D9.
- **L3 — Secrets only the user holds.** A third-party API key, a personal access
  token the platform cannot mint, a passphrase. Ask once, store it, never ask
  again — and never ask for a secret the platform could mint itself.
- **L4 — Device- and OS-level consent the platform cannot grant.** Credential-store
  unlock, administrative elevation for a system-scope service, operating-system
  permission grants, biometric prompts. This is the OS's boundary, not ours. Where
  it is avoidable by design — e.g. writing an encrypted-file secret alongside a
  keychain entry so headless and remote invocations work — avoiding the prompt is
  preferred to asking for it.
- **L5 — Irreversible or externally-consequential actions.** Destroying data,
  revoking a credential others depend on, terminating another user's work,
  changing billing or plan, anything with legal or financial consequence. These
  take an explicit human confirmation even when the platform is certain.

Apply three tests before classifying an interruption as legitimate:

1. **The information test.** Does the platform already hold the answer — in its
   records, in the host's registration, in a token the host carries, or in state
   it wrote itself? If yes, it is mechanism, and asking is a defect. Every
   confirmed case failed this test: the scope id, the project→scope ownership, the
   widened key's scope, the canonical project id, and the served-scope set were all
   already known.
2. **The decision test.** Is the user being asked to *decide*, or to *execute*?
   "Which project should this host serve?" is a decision. "Run this command, then
   restart that service" is execution. Execution is never legitimate.
3. **The default test.** Is there a correct default the platform could pick with a
   cheap reversal? If yes, pick it and make the reversal one action. A decision
   with an obvious default and a cheap undo is not worth an interruption.

Even a legitimate ask obeys delivery rules:

- **Once.** Asked at onboarding, stored, never re-asked. Re-asking is a defect even
  for L1–L5.
- **In whatever client the user is already in.** Never "go to the machine."
- **As a prompt, not as an error.** Never surfaced only in a log line, a stderr
  write, or a warning nobody is watching.
- **With the platform doing everything around it.** The ask is the decision alone;
  every step before and after belongs to the platform.

## Consequences

### Positive

- A single, falsifiable test for a whole class of design questions: *does this
  require the user to act after onboarding, and does the reason survive the three
  tests?* Reviewers get a rule instead of a taste argument.
- The five shapes become named, greppable defect classes. "Boot-frozen state",
  "half-built control channel", "bookkeeping success", and "log-only failure" are
  now review vocabulary rather than one-off findings.
- Most of the implied work is unification, not new subsystems: one credential
  path instead of a primary and a secondary, one scope-change operation instead of
  a CLI lane and a web lane, one host-condition rail instead of three status
  commands and a log file.
- Client parity stops being a per-feature negotiation. D8 makes "reachable only
  from a terminal on the machine" a defect on sight.
- The boundary section gives the platform explicit permission to act — including
  to mint and widen its own credentials on a consented scope change — which is
  the specific authority several of the confirmed defects lacked.

### Negative

- Runtime-mutable state is harder to reason about than boot-frozen state.
  Concurrency and ordering bugs move from "impossible because frozen" to
  "possible, and must be tested." Every unfrozen map needs a lock and a test.
- Self-healing hides real faults. A rail that retries forever can mask a permanent
  misconfiguration. D7 is what keeps D5 honest, and the two must land together or
  the result is a quieter system that is just as broken.
- More authority moves server-side. Minting a widened credential on a consented
  scope change, or coalescing host records, puts security-relevant decisions in
  the control plane. That is the right place for them, but it raises the bar on
  the control plane's own authorization checks.
- Deleting remediation hints removes an escape hatch. Ordering matters: land the
  heal, then delete the hint — not the reverse.

### Risks

- **Contract churn across the boundary.** Making registration claims renegotiable
  and reporting the enabled-scope set on the beat touches the registration and
  heartbeat contracts on both sides, and the OSS daemon and the composing binary
  ship lock-step. A partial rollout in which the host reports a field the control
  plane ignores (or the reverse) *is* the failure shape this ADR indicts.
  Sequence: add the field, have the control plane consume it, then remove the
  restart.
- **Credential rotation ordering.** Today, widening a scope mints a new credential
  and revokes the superseded one while a live process still holds it, so *not*
  restarting is worse than restarting. Any implementation must either defer the
  revoke until the new credential is observed in use, or push the new credential
  to the running process. The revoke-then-hope ordering must not survive the fix.
- **The silent-drop class returning under a new name.** If D9 is implemented as
  "apply what you can", the swallowed-mutation failure reappears with a different
  op. Unknown ops must fail loudly and be redeliverable.
- **Health-signal noise.** D7 pushes more conditions onto the beat. Without the
  clearing and supersession discipline in D7's second half, the operator surface
  degrades into noise — which is precisely how a sticky triage flag came to
  report the worst moment a session ever had.
- **Scope creep of "transparent".** D1–D9 are about state the platform owns. They
  are not a licence to act on the user's behalf in the L1–L5 set; a reviewer
  citing D4 to skip a consent step has misread the ADR.

## Alternatives considered

1. **Document the manual steps better.** Rejected. The confirmed defects are not
   discoverability failures. Several already print an accurate remediation and the
   user still loses in-flight work; one prints a command that does not exist; one
   is unreachable from any client except a terminal on the machine itself. Better
   copy does not let a mobile user add a scope to a host.
2. **Make the restart cheap instead of unnecessary** — have the CLI perform a
   drain-aware restart itself after a scope change. Rejected as the destination,
   accepted as an interim mitigation. It removes the instruction and the loss of
   in-flight work, but preserves the boot-frozen architecture that produced the
   entire class, and does nothing for the web and mobile clients, which cannot
   restart anything.
3. **Treat each defect on its own merits; skip the principle.** Rejected. The
   survivors cluster into five shapes over four or five mechanisms; fixing them
   independently yields N partial lanes. That is demonstrably how the half-built
   control channel in Shape 2 came to exist — two lanes built by different efforts,
   each complete on its own side, joined by nobody.
4. **A weaker principle: "no user action after onboarding, except scope changes."**
   Rejected. The founding statement names scope changes explicitly, and it is the
   wrong carve-out on the merits: scope change is the most common post-onboarding
   event and the one where multi-client parity matters most.
5. **Automate everything; no boundary section.** Rejected. Without the boundary,
   the principle licenses the platform to self-grant tenant access, re-assert human
   identity, and take irreversible actions unattended. The boundary is narrow, and
   load-bearing precisely because it is narrow.
6. **Enforce the principle only in the closed platform.** Rejected. Three of the
   five shapes have their mechanism in the OSS execution layer — frozen
   registration options, the file watcher's single-file scope, the mutation lane
   that drops unknown ops. A principle applied on one side of the boundary would be
   unenforceable on the side that owns the state.

## Affected documents

Listed for the accepting commit; **not edited by this proposal.**

- `011-local-daemon-fleet.md`
  - § "First-run setup" — the wizard's `[1/5] Machine identity` step shows a
    hostname-shaped auto-generated id. D1 requires an opaque durable identity
    minted once into one record and referenced by every per-scope config.
  - § "Config file walkthrough" — D3 makes "which keys are hot-reloadable" part of
    the contract rather than commentary; today only the primary config's project
    list reloads, and the reload replaces rather than merges.
  - § "Drain semantics" / § "Recovery from crash" — D3's corollary: a
    platform-initiated restart drains, and a scope change never costs in-flight
    work.
- `013-orchestrator-and-governor.md`
  - § "Worker registration (the dial-out flow)" — D3 and D9: registration claims
    must be renegotiable at runtime, and the host's enabled-scope set must be
    reported on the beat, not only at register time.
  - § "Completion contracts and backstop" — D5: a fail-closed pre-spawn NACKs
    rather than aborting, and an abandoned attach leg terminates or signals rather
    than holding capacity indefinitely.
  - § "OSS vs SaaS responsibilities" — D8's one-operation rule.
- `014-tui-operator-surfaces.md`
  - § "Open registries (status, work type, activity)" — D7: host-health conditions
    are registry entries surfaced in every client.
  - § "OSS vs SaaS responsibilities" — D6: readiness derived from live state.
- `ADR-2026-08-03-daemon-host-status-signal-completion.md` — extended, not
  superseded. D7 makes host-level self-diagnosed conditions first-class on the
  signal that ADR completed.
- `ADR-2026-07-12-interactive-pty-session-host.md` — D5 and D6 applied to attach: a
  retryable close code is retried, a terminal one is re-minted and re-dialed under
  a bounded budget, and exhausting the budget emits a signal rather than leaving an
  unreachable session holding capacity.
- `ADR-2026-06-03-injectable-state-dir.md` — D1's host-identity record is a
  state-dir-resident artifact; that seam is where it lands.

No `BOUNDARY-SYNC` region is amended.

## Affected work items

Tracked platform-side. The prioritized gap list derived from this ADR — and the
mapping of each item to D1–D9 — lives in the mirrored stub in the platform
corpus, because the individual issue identifiers are tracker-internal.

## Implementation notes

Sequencing constraints only; scope belongs in the tracker.

- **Report before you unfreeze.** The enabled-scope set must ride the heartbeat and
  be consumed by the control plane's admission mirror *before* any client stops
  restarting after a scope change. Doing it in the other order produces a host that
  serves a scope the router will not send to — a silent, invisible failure that is
  worse than the current loud one.
- **Fix the credential-rotation ordering before removing the restart.** As long as
  widening a scope revokes the credential the live process is holding, the restart
  is load-bearing and removing it makes the host go dark on its next refresh.
- **Land D7 with D5, never after.** Retry without reporting converts a visible
  failure into an invisible one.
- **Prefer unification to addition.** In four of the five shapes, the correct fix is
  to route a second lane through the mechanism the first lane already uses —
  the shared refresher and credential fan-out, the file watcher, the mutation
  applier, the reconnect loop — rather than to write a parallel one. The parallel
  implementations are how the asymmetries arose.
- **Watch the directory, merge per scope.** The existing reload replaces the
  spawner's project configuration wholesale; applied to a multi-scope host it
  evicts other scopes' projects. Any watcher expansion must merge per scope, or it
  trades a frozen-state bug for a destructive one.
- **Test the remediation surface.** D4 is enforceable cheaply: assert that every
  user-facing remediation string resolves to a registered command. That gate would
  have caught one confirmed defect outright.
