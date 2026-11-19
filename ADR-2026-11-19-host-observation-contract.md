---
status: Proposed
date: 2026-11-19
boundary: shared
split: sibling-extensions
---

# ADR-2026-11-19 — Host observation: one contract for what a host reports, with subscription accounts and forge identities as its first kinds

**Status:** Proposed
**Date:** 2026-11-19
**Boundary:** shared. Canonical here. `rensei-architecture` carries a `status: Mirrored` stub and a platform-only companion ADR.
**Authors:** agent:claude (Opus 5.5), for the product owner

## Context

A host carries state that decides whether work placed on it will succeed, and
no one but the host's owner can create that state:

- **Subscription logins.** A harness signed in to a coding-agent plan (a ChatGPT
  plan for Codex, a Claude plan for Claude Code, a gateway plan such as Ollama
  Cloud, OpenCode or OpenRouter) is prepaid capacity bound to the machine.
- **Git and forge identities.** The `user.name`/`user.email` a commit will carry,
  whether a signing key is configured, the `gh`/`glab` login, and whether the
  daemon's own process can actually read that login.

The execution layer sees fragments of the first today:

- the daemon probes each harness's quota at most every five minutes and reports
  one `UsageAccount` per harness on the heartbeat;
- the host carries the `host-session:<harness>` tag only while the login check
  passes.

It sees nothing of the second. Field failures follow from that:

- deploys blocked because the commit author was not a member of the deploy
  team;
- landing stalled because the forge login sat in a keychain the daemon's
  context could not read;
- sessions commit with whatever identity the host happens to have.

The subscription half has five gaps of its own:

- no account identity survives a tenant boundary;
- the daemon reports one login per harness per host;
- no user policy exists, only "exhausted means skip";
- the subscription provider is conflated with the model provider;
- logins are discovered only as a side effect of the quota poller.

The product owner's direction (2026-11-19) sets the requirements:

- state is **observed, never created**;
- hosts are scanned when they join a pool and again on demand;
- each observed item can be enabled, disabled and configured per host;
- policy scopes are deployment → pool → host, and they are user-managed rather
  than a system-to-node configuration cascade;
- a shared limit binds every tenant on a host at **dispatch time only** and may
  be approximate;
- the same observed-and-configured model serves **every** kind of host state.
  Subscription accounts are the first kind and forge identities the second.

## Decision

Define one **host-observation contract**:

- what a daemon may report about a host and what it must never report;
- when it scans;
- how an observed item is enabled, disabled and given policy;
- where in the placement law each kind's policy takes effect.

Each **observed kind** plugs into that contract with a declared schema. This ADR
specifies the contract (Part G), kind 1 **subscription accounts** in full
(Part S), and kind 2 **forge identities** at the contract level (Part F). A
later ADR or the kind's own delivery fills in Part F's details within these
bounds.

---

## Part G — The host-observation contract

### G1 — Observed items and kinds

1. An **observed item** is one fact about a host that the host's owner created
   outside the system. Its shape:

   ```
   ObservedItem {
     kind,                 // a registered kind id
     itemKey,              // stable, opaque; host-independent where the kind allows (G3)
     slot?,                // opaque host-local discriminator when one host holds several
     attributes,           // the kind's closed attribute schema (G2)
     scopes?: string[],    // capability or permission names the item holds
     readiness: { state: "ready" | "degraded" | "unavailable" | "unknown",
                  reasons: ReasonCode[], checkedAt }
   }
   ```

2. A **kind** is a closed registry entry that declares:
   - its attribute schema, with each attribute's **disclosure class** (G2);
   - how its `itemKey` is derived;
   - its readiness checks and reason codes;
   - its policy fields and their built-in defaults (G5);
   - its **effect**: where its policy takes effect in the placement law (G6);
   - whether it has a **shared effect** across tenants (G7).

   New kinds are added by ADR, never by configuration.
3. Kinds registered here are `subscription-login` (Part S) and the forge kinds
   `git-identity`, `forge-login` and `credential-helper` (Part F).

### G2 — What a daemon may report, and what it never reports

1. Every attribute has one disclosure class:

   | Class | Meaning | Example |
   |---|---|---|
   | `public` | a value the host owner already publishes or that names a product | a plan slug, a forge host name, a credential helper's name, a signing-key kind |
   | `identity` | a value that names a person or account, shown only to tenants scheduling on the host | a git author name and email, a forge account login |
   | `hashed` | an identifier that must be correlated but never shown | a subscription account id |
   | `boolean` / `enum` | presence or kind facts derived from something secret | "a signing key is configured", "the token is readable", "the token holds scope `repo`" |

2. **Never reported, for any kind:**
   - tokens, API keys, passwords and cookies;
   - refresh, session or OAuth credentials;
   - private or public key material and key fingerprints;
   - credential file contents and the paths that locate them;
   - raw provider account or user ids;
   - environment values.

   A kind may report that such a thing exists, its kind, and whether it works.
   It may never report the thing itself.
3. **Enforcement is structural.** The daemon encodes reports only through each
   kind's closed schema, so an undeclared field cannot be serialized. Receivers
   drop unknown fields and refuse a report whose `hashed` attribute does not
   match its declared shape. A golden test per kind proves that a fixture holding
   real-looking secrets produces a report without them.
4. A probe uses only the documented, read-only interfaces of the tool it
   inspects. It never runs a model turn, never pushes or fetches, and never
   prints a credential to read it. "Readable" means the tool returned success,
   not that the daemon saw the value.

### G3 — Item identity

1. Where the kind's subject exists independently of the host (a subscription
   account, a forge account), the daemon derives the `itemKey` from the
   provider's stable identifier and hashes it on the host:
   `SHA-256("donmai-<kind>-v1" ‖ fields)`. The same subject on two hosts then
   has the same key.
2. Where the subject is host-local (a git identity in one config, a credential
   helper), the key is a hash of its `identity`-class attributes and its slot.
3. A control plane serving several tenants may re-key `itemKey` with a
   deployment-wide secret before storing it. Any cross-tenant identity is
   server-internal (G7.3).

### G4 — Scan and rescan

1. A **full scan** discovers every item of every kind. It runs:
   - when the daemon starts;
   - when the host joins a pool;
   - on a **user rescan**.
2. Each kind may also declare a refresh cadence. For example, subscription
   windows refresh at most every five minutes.
3. The rescan is a daemon control operation:
   - `POST /api/daemon/observations/scan` with an optional `kinds` filter, on the
     local control API;
   - `donmai host observations [--kind <k>] [--rescan]` in the CLI.

   A control plane requests one over its existing host-mutation channel
   (operation `observations.scan`).
4. A scan returns the complete item list for the kinds it covered. Scans are
   rate-limited per host (one in flight, at most one a minute) and bounded per
   kind by a timeout. A kind that times out reports `readiness: unknown`; it
   does not vanish.
5. **Lifecycle.** An item is `present` while reported. It becomes `gone` after
   one successful full scan of its kind omits it. Policy outlives a gone item,
   so the item comes back configured when it reappears.

### G5 — Enable, disable and policy

1. Every kind has the field `enabled`. A disabled item is never selected for new
   work and contributes nothing to placement. Disabling an item never changes the
   host: it does not log out, delete or edit configuration.
2. A kind declares its other policy fields, each with a built-in default.
3. **Scopes.** Policy is written per tenant at three scopes:
   - **deployment**: the tenant's default for every item of the kind it sees;
   - **pool**: every item on the pool's hosts;
   - **host**: one observed item.

   For each field, the most specific scope that sets it wins (host, then pool,
   then deployment, then the built-in default). Every effective value names the
   scope that bound it. This is the user's own defaults chain. It is not a
   policy-narrowing cascade, and no level above the tenant can set it.
4. Joining a tenant's pool grants that tenant scheduling on the host's enabled
   items, under its own policy. Policy is configuration and never a credential.

### G6 — Where policy takes effect

Each kind declares one or more effects, which map to stages of the placement
law (`ADR-2026-08-12-placement-composition-law-and-single-fallback-rule.md`):

| Effect | Stage | Meaning |
|---|---|---|
| `viability` | 3 | A failing item removes the candidate; a typed reason names the item and when it may recover. |
| `selection` | 6 (bind) | The tenant's policy chooses which item the session uses on that host. The runner applies it per session and never edits host configuration. |
| `preference` | 4 | Orders candidates by an item property; never gates. |
| `warning` | 3, advisory | A known mismatch is reported before dispatch. A tenant may promote a warning class to a refusal; it is never silently skipped. |

Rules for every effect:

- **Admission and claim only.** Every effect is evaluated when work is admitted
  and again when a host claims it, with byte-identical predicates. Nothing is
  evaluated after the session starts: no observation change stops, pauses or
  preempts running work.
- **The daemon enforces locally.** It applies each kind's viability and
  selection rules at claim, using its local policy and its own observations. A
  control plane may push the effective host-level policy over the host-mutation
  channel, and the daemon applies the more restrictive value (narrow-only, as in
  `ADR-2026-06-06-two-axis-provider-model.md` D5). A refusal nacks with the typed
  reason, and the work is re-placed by the single fallback rule.

### G7 — Tenants sharing a host

1. Policy is per tenant. One tenant's choice never changes another tenant's
   dispatches, unless the kind declares a **shared effect**: a property of the
   host's subject that every tenant consumes (a subscription's usage, Part S6).
2. A shared effect states its merge rule (for example, the strictest value
   wins) and is evaluated **approximately**: readings may be one refresh
   interval old, and concurrent tenants may overshoot. There are no
   reservations and no cross-tenant locks.
3. A tenant learns the verdict of a shared effect and when it clears. It never
   learns which other tenant's policy bound it, or that other tenants exist.

### G8 — Standalone behaviour

A single-machine deployment has one tenant and one scope. It works as follows:

- `donmai host observations` lists the items;
- local configuration supplies `enabled` and the policy fields;
- the claim-time rules of G6 apply.

No kind requires a control plane to function (`001` boundary rules 2 and 4).

---

## Part S — Kind 1: subscription accounts (`subscription-login`)

### S1 — Subscription provider and model provider are different axes

1. A **subscription provider** issues and bills a login. It is either a company
   behind a plan (OpenAI ChatGPT, Anthropic Claude) or a **gateway provider**
   (Ollama Cloud, OpenCode, OpenRouter and their peers) that is
   model-provider-agnostic.

   A **model provider** is the company whose model answers: the MODEL-ENDPOINT
   company of `ADR-2026-06-06` D1. One subscription provider may serve many
   model providers.
2. **The catalog** is declared data, one entry per subscription provider:

   | Level | Holds | Example |
   |---|---|---|
   | provider | id, kind (`direct` or `gateway`), login kinds issued | `openai-chatgpt`, `direct` |
   | plan | plan slug as reported, display name, window shapes | `team`: 5-hour and weekly windows |
   | model | (model provider, model id) the plan reaches | (OpenAI, a GPT model) |
   | access program | per-model entitlement tier the plan may carry | a per-model research tier such as a Blue or Red program |
   | harness compatibility | harnesses that may sign in with the login | ChatGPT tokens: any harness implementing the sign-in; Claude plan: Claude Code only |
   | billing modes | what happens past the included allowance, in order | `quota-window` → `credits` → `overage` → `api-metered` |

3. **Billing modes** are a closed vocabulary:

   | Mode | Meaning | Prepaid? |
   |---|---|---|
   | `quota-window` | included usage measured as window percentages | yes |
   | `credits` | a purchased or banked balance | no: billing boundary |
   | `overage` | provider-billed usage beyond the plan | no: billing boundary |
   | `api-metered` | an API key billed per token | no: billing boundary |

   Billing boundaries are governed by S7.
4. Reports are matched to catalog rows by provider, plan slug and window ids. An
   unmatched plan is still observed and usable, and is shown as `uncatalogued`.

   The catalog describes; it never grants. Harness compatibility is a ceiling,
   checked with the two-axis validity rule (`ADR-2026-06-06` D2).
5. The OSS layer ships the vocabulary and a minimal catalog for the providers its
   harnesses scan, generated with the capability matrix (`ADR-2026-06-06` D3) as
   a `subscriptionProviders` section. A deployment may add rows and narrow
   compatibility; it may never widen compatibility.

### S2 — Item identity

1. The subject is an **observed account**: (subscription provider, account
   identity). `itemKey` follows G3.1:
   `SHA-256("donmai-subscription-login-v1" ‖ provider ‖ accountId ‖ userId?)`.
   - `accountId` is the provider's own stable account identifier, from its login
     or quota read.
   - `userId` is added where the provider scopes quota per user inside a shared
     workspace (team plans).
2. A provider that exposes no stable identity reports `identity: host-scoped`.
   Its logins are distinct per host, and S6's shared effect falls back to
   per-host evaluation.

### S3 — Item shape

The **host login** is account × host × harness × slot, and a host may hold any
number of them.

- The slot is a hash of the config home the harness reads its login from.
- `attributes`:
  - harness and subscription provider (`public`);
  - plan and limit id (`public`);
  - windows `{id, kind, usedPercent, resetsAt, windowDurationMins}` (`public`);
  - billing state `{mode, creditsBalance?}` (`enum` and a number);
  - the account key (`hashed`).
- `readiness` is the login check: `ready`, `unavailable` (refused), or `unknown`
  with `checkedAt`.
- The `host-session:<harness>` tag stays. It is set while at least one enabled
  login for the harness is ready.

### S4 — Policy fields

| Field | Type | Built-in default |
|---|---|---|
| `enabled` | boolean | `true` once observed (open question for the owner) |
| `guardPercent` | 0–100: keep this share of each window unused | `0` (burn to the reset) |
| `allowCredits` | boolean | `false` |
| `allowOverage` | boolean | `false` |
| `allowApiBilledFallback` | boolean | `false` |
| `warnAtPercent` | list of 0–100 | `[80]` |

### S5 — Effects

- `viability`: the login is enabled, ready, under its guard (S6) and not past a
  disallowed billing boundary (S7).
- `preference`: S8.1.

### S6 — The guard is a shared effect

1. A login is guard-blocked when any included window has
   `usedPercent ≥ 100 − guardPercent` and a reset still ahead.
   `guardPercent = 0` means exhaustion. A blocked login is ineligible until the
   earliest reset that clears every blocking window, and the typed reason names
   the login and that reset.
2. Usage belongs to the account. The usage figure is therefore the freshest
   report for the account from any host.
3. The effective guard for one login is the **strictest** `guardPercent` among
   the tenants that schedule on it. Once usage crosses it, no tenant may start
   new work on that login.
4. `enabled` and the billing permissions stay per tenant.
5. The guard is approximate by design (G7.2) and evaluated at admission and claim
   only (G6).

### S7 — Warnings and billing boundaries

1. Warnings fire once per window per reset, at each `warnAtPercent` and when the
   guard blocks.
2. Before a login is used past `quota-window`, the operator is always warned. A
   dispatch that would start in such a mode is refused unless the matching
   `allow*` field is true for the dispatching tenant.
3. The billing state is what the provider reports. Where the provider does not
   report it, exhausted included windows count as past the boundary, so a
   missing signal fails toward refusal.
4. A boundary crossed inside a running session warns and is recorded. It does
   not stop the session.

### S8 — Effect on resolution and stage routing

1. **Prepaid first among enabled, viable logins.** Where a model may run either
   on a host login or on a keyed mode (`byok`, `metered`), the preference stage
   orders host-login candidates first. Among them it prefers the most headroom
   above the guard. The keyed mode is the next surviving candidate under the
   single fallback rule.
2. **Stage-routed reviews.** A `review`-role stage
   (`ADR-2026-11-02-stages-roles-and-stage-cards.md`) for a security-class card
   may declare an **ordered target list**. Each target is a model selection (D7
   of that ADR), optionally narrowed to a subscription provider or a login.
   - Resolution takes the first target that survives permission and viability.
   - The next target is the fallback.
   - No unlisted target is used.
   - When none survives, the stage emits `failure` with reason
     `review_target_unavailable` and each target's reason.
3. The admission receipt records the login chosen, and each login rejected with
   its reason.

### S9 — Migration

1. Today's heartbeat `UsageAccount` list becomes `subscription-login` observed
   items. The old field stays accepted for one release, read as one login per
   harness with slot `default` and `identity: host-scoped`.
2. Window ids, kinds, the five-minute poller, the claim-time exhaustion check and
   the `host-session:<harness>` tag keep their meaning.

---

## Part F — Kind 2: forge identities (contract level)

These bounds govern what the forge kinds' delivery may build. Their attribute
details, reason codes and probes are settled by the kind's own delivery. Any
change to the bounds below needs an ADR amendment.

### F1 — Kinds and attributes

| Kind | Item | Attributes (disclosure class) | Readiness |
|---|---|---|---|
| `git-identity` | one effective git author identity in one config scope | `name`, `email` (`identity`); `scope`: `global`, or `repo-override` present (`enum`); `signing`: `none`, `gpg` or `ssh` (`enum`); signing key configured (`boolean`) | `ready` when name and email are set; `degraded` when signing is configured but its program is unavailable |
| `forge-login` | one forge CLI login (`gh`, `glab`, peers) | forge and forge host (`public`); account login (`identity`); token scope names (`scopes`); auth store kind: `keychain`, `file` or `env` (`enum`); readable from the daemon's execution context (`boolean`) | `ready` when the daemon's context can use the login; `unavailable` with `unreadable_in_daemon_context` when the login exists but the daemon cannot use it |
| `credential-helper` | one configured git credential helper | helper name only (`public`) | `ready` when the helper is resolvable |

Never reported, beyond G2.2: tokens, key ids and fingerprints, signing-key
material, remote URLs carrying credentials, and the contents of git or forge
config files.

### F2 — Identity

- `forge-login`: `itemKey` follows G3.1 from (forge host, account login), so one
  forge account on several hosts is one subject.
- `git-identity` and `credential-helper`: host-local keys (G3.2).

Forge kinds declare **no shared effect**. Each tenant chooses independently.

### F3 — Policy fields

| Field | Kind | Effect |
|---|---|---|
| `enabled` | all | G5.1 |
| `commitIdentity` | `git-identity` | `selection`: the identity that authors and commits this tenant's work on this host. Applied per session through the session environment (author and committer variables), never by editing the host's git config. |
| `forgeLogin` | `forge-login` | `selection`: the login this tenant's sessions use on this host |
| `requireSigning` | `git-identity` | `viability` when set: the selected identity must have signing configured and ready |
| `refuseOn` | all | a list of warning classes (F4) the tenant promotes to refusals |

Several tenants on one host may select different identities. That is the point
of per-tenant selection.

### F4 — Pre-dispatch warnings

These are `warning` effects (G6), evaluated for the work's target host and
repository before dispatch:

| Warning class | Raised when |
|---|---|
| `forge_login_unreadable` | the selected forge login is not readable in the daemon's context |
| `forge_scope_insufficient` | the login lacks a scope the target repository needs |
| `signing_required_missing` | signing is required but the selected identity has no ready key |
| `no_commit_identity` | the host has no ready `git-identity` and the tenant selected none |
| `author_not_deployable` | the selected author is not accepted by the target's deploy provider |

`author_not_deployable` needs a membership check against a deploy provider. A
control plane supplies that check through the `DeploymentProvider` family
(`001`, Layer 2). Standalone, the class is reported `unknown`, never `ok`.

---

## Consequences

### Positive

- One model, one scan, one policy UI and one evaluation rule serve every kind of
  host state. A new kind is a schema and an ADR, not a new subsystem.
- Shared subscription logins have one guard. Owners decide per host how far a
  subscription is used, and billing surprises become warned refusals.
- Commit identity becomes a tenant's explicit choice per host. The known
  identity failures (non-member author, unreadable keychain login) surface
  before dispatch, not mid-landing.

### Negative

- New report shape, CLI noun, control operation and host-mutation operation, plus
  a lock-step release of the daemon and any control plane that reads it.
- Per-host policy multiplies configuration. The deployment and pool scopes exist
  to contain that.
- The strictest-guard rule lets any tenant on a shared login lower everyone's
  usable share.

### Risks

- **A schema that admits a secret by accident.** G2.3's closed encoder and
  golden tests are the control. A reviewer must check every new attribute's
  disclosure class.
- **Identity drift.** A provider that changes its id format splits one subject
  until the old reports age out. The versioned key prefix makes the change
  explicit.
- **Shared-workspace collapse.** A per-user quota behind a per-workspace id
  over-blocks unless the user id is available. Otherwise the login is
  `host-scoped`.
- **Stale reads overshoot** a shared guard by roughly one session's usage per
  tenant. This is accepted (G7.2).

## Alternatives considered

- **A subsystem per kind** (subscriptions now, identities later). Rejected: the
  product owner asked for the same observed-and-configured experience, and two
  scan paths and two policy models would drift.
- **A system-wide reserve cascading system → node.** It was built as a draft and
  then removed. The platform does not own subscriptions, and one number cannot
  fit very different plans.
- **Hard-stopping sessions at a guard.** Rejected: it destroys work to protect a
  soft budget read from minutes-old data.
- **Exact cross-tenant accounting.** Rejected for now: providers report
  percentages, and the cost would be a distributed lock for an approximate
  signal.
- **Editing host git config to apply a tenant's identity.** Rejected: one tenant
  would change another's sessions. Selection is per session.
- **Hosted subscriptions placeable on any compatible host or sandbox.** Out of
  scope while providers bind logins to a machine. Revisit if they allow it.

## Affected documents

These edits land in the commit that flips this ADR to `Accepted`:

- `001-layered-execution-model.md`, Layer 3: observed host state beside the
  worker, with a pointer here.
- `002-provider-base-contract.md`: the subscription-provider catalog as a
  declared-data section of the capability matrix.
- `011-local-daemon-fleet.md`: the observation report, the `host observations`
  CLI, the scan operation and the host-mutation operation.
- `013-orchestrator-and-governor.md`: claim-time viability and selection for
  observed kinds, and the nack reasons.
- `ADR-2026-06-06-two-axis-provider-model.md`: an amendment note that the
  subscription axis is orthogonal to the model-endpoint axis.
- `ADR-2026-08-12-placement-composition-law-and-single-fallback-rule.md`: an
  amendment note that observed-kind effects map to stages 3, 4 and 6.

## Affected work items

This corpus carries no tracker identifiers. The delivery program is enumerated
with identifiers in the platform corpus's companion ADR. By shape:

- **Contract:** the observation report and closed per-kind encoder, the scan
  operation and CLI, and claim-time enforcement.
- **Kind 1:** the subscription-login scanner, the catalog, and the guard and
  billing rules.
- **Kind 2:** the forge-identity scanners, per-session identity selection and
  pre-dispatch warnings.

## Implementation notes

- The quota poller and window mappers already exist. The `subscription-login`
  scanner wraps them per slot instead of replacing them.
- Each kind's key derivation and secret-free encoding is golden-vector tested in
  Go, so a control plane can verify it receives stable, clean reports.
