---
status: Proposed
date: 2026-11-19
boundary: shared
split: sibling-extensions
---

# ADR-2026-11-19 — Host observation: one contract for what a host reports, with subscription accounts and forge identities as its first kinds

**Status:** Proposed. Revised 2026-11-19 with the product owner's rulings.
**Date:** 2026-11-19
**Boundary:** shared. This file is the canonical ADR. `rensei-architecture` carries a `status: Mirrored` stub and a platform-only companion ADR.
**Authors:** agent:claude (Opus 5.5), for the product owner

## Context

A host carries state that decides whether work placed on it will succeed, and
only the host's owner can create that state:

- **Subscription logins.** A harness signed in to a coding-agent plan is
  prepaid capacity bound to the machine. Examples are a ChatGPT plan for Codex,
  a Claude plan for Claude Code, and a gateway plan such as Ollama Cloud,
  OpenCode or OpenRouter.
- **Git and forge identities.** These cover:
  - the `user.name` and `user.email` a commit will carry;
  - whether a signing key is configured;
  - the `gh`/`glab` login;
  - whether the daemon's own process can actually read that login.

The execution layer sees part of the first. The daemon probes each harness's
quota at most every five minutes and reports one `UsageAccount` per harness on
the heartbeat. The host carries the `host-session:<harness>` tag only while the
login check passes. The execution layer sees none of the second. Three failures
have come from that gap:

- deploys were blocked because the commit author was not a member of the deploy
  team;
- landing stalled because the forge login was in a keychain the daemon could not
  read;
- sessions commit with whatever identity the host happens to have.

For subscriptions there are five more gaps:

- no account identity survives a tenant boundary, so usage cannot be measured
  per account;
- the daemon reports one login per harness per host;
- there is no user policy;
- the subscription provider is conflated with the model provider;
- logins are discovered only as a side effect of the quota poller.

Subscription allowances are also changing shape. Providers are moving from
per-seat windows toward account-level allowances shared across products and
harnesses, measured in tokens, with purchasable credits. Such an allowance is
consumed outside this system as well (for example, through the provider's own
chat product). Its usage can only be observed, never computed.

The product owner's requirements (2026-11-19):

- host state is **observed, never created**;
- onboarding presents what was found as a checklist;
- anything found after onboarding starts disabled;
- a rescan marks new items;
- configuration belongs to **each tenant's own host record**;
- a limit gates only its own tenant's dispatch, at **dispatch time only**,
  measured against the account's shared observed usage, and it may be
  approximate;
- policy defaults inherit from a per-definition system default, while
  enablement is never inherited;
- the same observed-and-configured model serves **every** kind of host state.

## Decision

Define one **host-observation contract**:

- what a daemon may report about its host and what it must never report;
- when it scans;
- how an observed item is enabled, disabled and given policy;
- where each kind's policy takes effect in the placement law.

Each **observed kind** plugs into that contract with a declared schema. This
ADR specifies:

- **Part G:** the contract;
- **Part S:** kind 1, **subscription accounts**, in full;
- **Part F:** kind 2, **forge identities**, at the contract level.

Part F's details are filled in by its own delivery within these bounds.

---

## Part G — The host-observation contract

### G1 — Observed items and kinds

1. An **observed item** is one fact about a host, created by the host's owner
   outside the system:

   ```
   ObservedItem {
     kind,                 // a registered kind id
     itemKey,              // stable, opaque; host-independent where the kind allows (G3)
     slot?,                // opaque host-local discriminator; a host may hold several items of one kind
     definition?,          // catalog key the item instantiates (for example provider + plan), for defaults (G5.3)
     attributes,           // the kind's closed attribute schema (G2)
     scopes?: string[],    // capability or permission names the item holds
     readiness: { state: "ready" | "degraded" | "unavailable" | "unknown",
                  reasons: ReasonCode[], checkedAt }
   }
   ```

2. A **kind** is a closed registry entry. It declares:
   - its attribute schema and each attribute's **disclosure class** (G2);
   - its `itemKey` derivation;
   - its readiness checks and reason codes;
   - its policy fields with their defaults (G5);
   - its **effects** (G6);
   - whether its observations aggregate across hosts (G7).

   Kinds are added by ADR, never by configuration.
3. Registered kinds:
   - `subscription-login` (Part S);
   - `git-identity`, `forge-login` and `credential-helper` (Part F).

### G2 — What a daemon may report, and what it never reports

1. Every attribute has one disclosure class:

   | Class | Meaning | Example |
   |---|---|---|
   | `public` | Product names and values the owner already publishes. | A plan slug, a forge host, a credential helper's name, a signing-key kind. |
   | `identity` | Names a person or an account. Shown only to tenants whose host record holds the item. | A git author name and email, a forge account login. |
   | `hashed` | Must be correlated but never shown. | A subscription account id. |
   | `boolean` / `enum` | A presence or kind fact derived from something secret. | "A signing key is configured", "the token is readable", "program X is enabled". |

2. **Never reported, for any kind:**
   - tokens, API keys, passwords and cookies;
   - refresh, session or OAuth credentials;
   - key material and key fingerprints;
   - credential file contents, and the paths that locate them;
   - raw provider account or user ids;
   - environment values.

   A kind may report that such a thing exists, what kind it is, and whether it
   works. It never reports the thing itself.
3. **Enforcement is structural.**
   - The daemon encodes reports only through each kind's closed schema, so an
     undeclared field cannot be serialized.
   - Receivers drop unknown fields, and refuse a `hashed` attribute of the wrong
     shape.
   - A golden test per kind proves that a fixture holding real-looking secrets
     produces a report without them.
4. A probe uses only the documented, read-only interfaces of the tool it
   inspects. It never runs a model turn, never pushes or fetches, and never
   prints a credential in order to read it. "Readable" means the tool reported
   success, not that the daemon saw the value.

### G3 — Item identity

1. Some subjects exist independently of the host, such as a subscription
   account or a forge account. For these, the daemon derives the `itemKey`
   from the provider's stable identifier and hashes it on the host:
   `SHA-256("donmai-<kind>-v1" ‖ fields)`. The same subject on two hosts gets
   the same key, so its usage can be aggregated (G7).
2. Other subjects are host-local, such as a git identity in one config or a
   credential helper. For these, the key is a hash of the subject's
   `identity`-class attributes and its slot.
3. A control plane that serves several tenants may re-key `itemKey` with a
   deployment-wide secret before storing it. Such a key is server-internal and
   used only to aggregate observations (G7).

### G4 — Scan, onboarding and rescan

1. A **full scan** discovers every item of every kind. It runs:
   - at daemon start;
   - when the host joins a tenant's pool;
   - on a **user rescan**.

   Each kind may also refresh on its own cadence. For example, subscription
   usage refreshes at most every five minutes.
2. **Onboarding.** When a host joins a tenant's pool, that tenant's onboarding
   presents the scan as a **checklist**:
   - one toggle per item;
   - **enable all** and **disable all** actions;
   - each item's attributes and readiness.

   The tenant's choices become the explicit enablement of that host record.
   Onboarding is complete when the tenant submits the checklist.
3. **Discovered after onboarding.** An item that first appears for a host
   record after its onboarding starts **disabled**. This applies whether a
   periodic scan or a rescan finds it.
   - **Auto-enable setting (decided by the product owner, 2026-11-19).**
     A tenant may set "newly discovered items of this kind: leave disabled
     (default) / enable automatically". Only kinds whose `enabled` field has
     no selection effect allow it.
   - **When the setting is on:** the onboarding checklist starts fully
     checked, later discoveries arrive enabled, and each auto-enabled item
     raises a notification naming the host and the item.
   - **Policy is untouched.** An auto-enabled item takes the default policy
     unchanged. For subscription logins (S4) that means every billing
     permission stays off, so only prepaid allowance can be consumed.
   - **Scope.** The forge kinds (Part F) never allow it: a commit identity or
     forge login is never selected automatically.
4. **Rescan** is a daemon control operation:
   - `POST /api/daemon/observations/scan`, with an optional `kinds` filter, on
     the local control API;
   - `donmai host observations [--kind <k>] [--rescan]` in the CLI.

   A control plane requests one over its host-mutation channel (operation
   `observations.scan`). The result is presented the same way as the checklist,
   with **newly discovered items marked** and each item's current toggle shown.
5. Scans are bounded:
   - one scan in flight per host, and at most one a minute;
   - a timeout per kind;
   - a kind that times out reports `readiness: unknown` and does not vanish.
6. **Lifecycle.** An item is `present` while it is reported. It becomes `gone`
   after one successful full scan of its kind omits it. Policy and enablement
   outlive a gone item.

### G5 — Enablement and policy belong to the tenant's host record

1. **Ownership.** Each tenant that adds a host to one of its pools holds its
   own **host record**, and that record owns its observed items' enablement and
   policy. Records and pools never span tenants. One physical host may be
   enabled for one kind or item in one tenant and for a different one in
   another. No tenant sees another tenant's configuration.
2. **Enablement is explicit and never inherited.** Every item on a host record
   has `enabled`, set by the onboarding checklist (G4.2), the post-onboarding
   default (G4.3) or a later toggle.
   - A disabled item is never selected for new work and contributes nothing to
     placement.
   - Disabling never changes the host: it does not log out, delete or edit
     configuration.
3. **Policy fields inherit their defaults.** Each kind declares its other
   policy fields. A field's effective value is the most specific of:
   1. the **host record** value for this item;
   2. the **tenant** default for the kind;
   3. the **system default for the item's definition** (for subscription logins,
      the catalog provider and plan);
   4. the kind's built-in default.

   Every effective value names the level that bound it. This is a defaults
   chain owned by the user and the catalog. It is not a policy-narrowing
   cascade, and no project, workflow or node level exists.
4. Policy is configuration and never a credential.

### G6 — Where policy takes effect

Each kind declares one or more **effects**. Each effect maps to a stage of the
placement law (`ADR-2026-08-12-placement-composition-law-and-single-fallback-rule.md`):

| Effect | Stage | Meaning |
|---|---|---|
| `viability` | 3 | A failing item removes the candidate. A typed reason names the item and when it may recover. |
| `selection` | 6 (bind) | The tenant's policy picks which item the session uses on that host. The runner applies the choice per session and never edits host configuration. |
| `preference` | 4 | Orders candidates by a property of the item. It never gates. |
| `warning` | 3, advisory | Reports a known mismatch before dispatch. A tenant may promote a warning class to a refusal. It is never silently skipped. |

Effects are evaluated when work is admitted, and again when a host claims it,
with byte-identical predicates. They are never evaluated after the session
starts: no observation or policy change stops, pauses or preempts running work.

The daemon applies viability and selection again at claim, using what it
knows. A control plane pushes the claiming tenant's effective host-record
policy over the host-mutation channel. The daemon applies the more restrictive
of the pushed policy and its local policy, in the narrow-only shape of
`ADR-2026-06-06-two-axis-provider-model.md` D5. A refusal nacks with its typed
reason, and the work is re-placed under the single fallback rule.

A push replaces the registration's whole policy. The daemon persists the last
applied push per registration, so a restart never runs ungated:

- **Ever governed.** A registration that has ever received a push is enforced
  from its last-known policy at boot, until a fresh push replaces it.
- **Never governed.** A registration that has never received a push passes
  claims through. This keeps rollout and standalone hosts working.
- **Corrupt or unreadable file.** A persisted file that cannot be read fails
  closed for that registration: every item of the kind is disabled.

The control plane re-pushes the effective policy when a daemon registers or
reconnects, but only for a host record it already governs. An empty push to a
never-governed registration would disable every item. A typed claim refusal
tells the control plane its view has drifted. On `disabled` it re-pushes the
policy. On a usage reason it requests a rescan of that kind.

### G7 — Tenants sharing a physical host

1. **Policy is per tenant, and so are its effects.** One tenant's policy never
   gates another tenant's dispatch.
2. **Observations may be shared.** A kind whose subject is host-independent may
   declare that its usage observations **aggregate across hosts**. For example,
   one subscription account logged in on several hosts has one usage figure.
   Each tenant evaluates **its own** policy against that shared observation.
   The aggregation:
   - is approximate, because readings may be one refresh interval old;
   - uses no reservations and no cross-tenant locks;
   - shows a tenant only the subject's usage, never another tenant's
     configuration, enablement or existence.

### G8 — Standalone behaviour

A single-machine deployment works without a control plane: one tenant, one
host record. `donmai host observations` lists the items, local configuration
supplies enablement and policy, and the claim-time rules of G6 apply. No kind
requires a control plane to function (`001` boundary rules 2 and 4).

---

## Part S — Kind 1: subscription accounts (`subscription-login`)

### S1 — Subscription provider, model provider and the allowance

1. A **subscription provider** issues and bills a login. It is either:
   - a company behind a plan (OpenAI ChatGPT, Anthropic Claude); or
   - a **gateway provider** (Ollama Cloud, OpenCode, OpenRouter and peers) that
     is model-provider-agnostic.

   A **model provider** is the company whose model answers, which is the
   MODEL-ENDPOINT company of `ADR-2026-06-06` D1. One subscription provider may
   serve many model providers.
2. **The catalog** is declared data with one entry per subscription provider:

   | Level | Holds | Example |
   |---|---|---|
   | provider | id, kind (`direct` or `gateway`), and the login kinds it issues | `openai-chatgpt`, `direct` |
   | plan | plan slug as reported, display name, allowance shape, `lowCap` flag, and **policy defaults** (G5.3) | `team`: low-cap, default guard 50% |
   | model | the (model provider, model id) pairs the plan reaches | (OpenAI, a GPT model) |
   | harness compatibility | the harnesses that may sign in with the login | ChatGPT tokens: any harness implementing the sign-in. Claude plan: Claude Code only. |
   | billing modes | what happens past the included allowance, in order | `allowance` → `credits` → `overage` → `api-metered` |

   Access programs are **not** catalog data. They are detected per account
   (S3.3).
3. **The allowance belongs to the account.** It is not tied to a login or a
   harness:
   - An account has one or more **allowances**. Each has an id, a unit
     (`percent` or `tokens`) and windows:
     `{id, kind, used, limit?, resetsAt, windowDurationMins}`.
   - An allowance may be **harness-independent**: shared by every harness and
     product on the account, including consumption outside this system.
   - Usage is always **observed** from the provider's own report, never computed
     from sessions this system ran.
   - A per-seat allowance (one user inside a shared workspace) is an allowance
     keyed by account and user. It stays supported for as long as providers meter
     per seat.
4. **Billing modes** are a closed vocabulary:

   | Mode | Meaning | Prepaid? |
   |---|---|---|
   | `allowance` | included usage, observed as percent or tokens | yes |
   | `credits` | a purchased or banked balance | no: billing boundary |
   | `overage` | provider-billed usage beyond the plan | no: billing boundary |
   | `api-metered` | an API key billed per token | no: billing boundary |

   Billing boundaries are governed by S7.
5. Reports match catalog rows by provider and plan slug. An unmatched plan is
   still observed and usable: it is shown as `uncatalogued` and takes the
   kind's built-in defaults. The catalog describes and supplies defaults. It
   never grants. Harness compatibility is a ceiling, checked with the two-axis
   validity rule (`ADR-2026-06-06` D2).
6. The OSS layer ships the vocabulary and a minimal catalog for the providers
   its harnesses scan. The catalog is generated with the capability matrix
   (`ADR-2026-06-06` D3) as a `subscriptionProviders` section. A deployment may
   add rows, set definition defaults and narrow compatibility. It may never
   widen compatibility.

### S2 — Item identity

1. The subject is an **observed account**: (subscription provider, account
   identity). The `itemKey` is
   `SHA-256("donmai-subscription-login-v1" ‖ provider ‖ accountId ‖ userId?)`,
   where:
   - `accountId` is the provider's stable account identifier;
   - `userId` is added while the provider meters per seat inside a shared
     workspace.
2. A provider that exposes no stable identity reports `identity: host-scoped`.
   Its usage is not aggregated across hosts.

### S3 — Item shape

1. A **host login** is account × host × harness × slot. The slot is a hash of
   the config home the harness reads its login from. A host may hold several
   logins, including several for one harness.
2. Attributes:
   - harness, subscription provider, plan and the `definition` (provider and
     plan): `public`;
   - allowances and windows (S1.3): `public`;
   - billing state `{mode, creditsBalance?}`: an `enum` and a number;
   - the account key: `hashed`.
3. **Access programs.** The scan reports each per-model entitlement program the
   account carries, such as a research tier, as
   `{programId, state: "enabled" | "not-enabled" | "unknown", tier?, models[]}`,
   using `enum` and `public` values only. Programs are detected, never curated
   and never assumed.
4. `readiness` is the login check: `ready`, `unavailable` (refused), or
   `unknown`, with `checkedAt`.
5. The `host-session:<harness>` tag is unchanged: it is set while at least one
   login for the harness is ready. Whether a tenant may use a login is
   enablement and policy (G5, S5), not the tag.

### S4 — Policy fields

| Field | Type | Built-in default | Notes |
|---|---|---|---|
| `guardPercent` | 0–100: keep this share of each window unused | `0` (burn to the reset) | Catalog default `50` for `lowCap` plans |
| `allowCredits` | boolean | `false` | |
| `allowOverage` | boolean | `false` | |
| `allowApiBilledFallback` | boolean | `false` | |
| `warnAtPercent` | list of 0–100 | `[80]` | |

`enabled` is G5.2: explicit, set at onboarding, and disabled when the login is
discovered later.

### S5 — Effects

- **`viability`.** A login is viable when it is:
  - enabled on the tenant's host record;
  - ready;
  - under **the tenant's own** guard against the account's shared observed
    usage (S6);
  - not past a billing boundary that the tenant's policy disallows (S7).
- **`preference`:** S8.1.

### S6 — The guard

1. A login is guard-blocked for a tenant when any included window of any
   allowance the login draws on has `used ≥ (100 − guardPercent)%` of its limit
   and a reset still ahead. `guardPercent = 0` means exhaustion.
2. While blocked, the login is ineligible for that tenant until the earliest
   reset that clears every blocking window. The typed reason names the login and
   that reset.
3. **Usage is the account's shared observation (G7.2).** The usage figure is
   the freshest report for the account from any host, because the allowance is
   physical and per account. It already includes consumption elsewhere,
   including outside this system.
4. **The guard is the tenant's own.** Each tenant's guard gates only that
   tenant's dispatch. Two tenants on one login may use different guards; the one
   with the lower guard simply stops scheduling first.
5. The guard is approximate by design (G7.2) and evaluated at admission and at
   claim only (G6).

### S7 — Warnings and billing boundaries

1. Warnings fire once per window per reset: at each `warnAtPercent`, and when
   the guard blocks.
2. Before a login is used past `allowance`, the operator is always warned. A
   dispatch that would start in such a mode is refused unless the tenant's
   matching `allow*` field is true.
3. The billing state is what the provider reports. When it is not reported,
   exhausted included windows count as past the boundary, so a missing signal
   fails toward refusal.
4. A boundary crossed inside a running session warns and is recorded. It does
   not stop the session.

### S8 — Effect on resolution and stage routing

1. **Prepaid first among enabled, viable logins.** When a model may run either
   on a host login or on a keyed mode (`byok`, `metered`), the preference stage
   orders host-login candidates first. Among them it prefers the most headroom
   above the tenant's guard. The keyed mode is the next surviving candidate
   under the single fallback rule.
2. **Stage-routed targets.** A `review`-role stage
   (`ADR-2026-11-02-stages-roles-and-stage-cards.md`) for a security-class card
   may declare an **ordered target list**.
   - Each target is a model selection (D7 of that ADR), optionally narrowed to a
     subscription provider or a login.
   - A target may **opt in to an access program** (S3.3). That target is then
     viable only on a login whose scan reports the program `enabled` for the
     model.
   - Resolution takes the first target that survives permission and viability.
     The next target is the fallback, and no unlisted target is ever used.
   - **When no target survives, the stage emits `failure`** with reason
     `review_target_unavailable` and each target's reason. The stage's
     `failure` transition decides where the work item goes.
3. The admission receipt records the login chosen, the program used if any, and
   each rejected login with its reason.

### S9 — Migration

1. Today's heartbeat `UsageAccount` list becomes `subscription-login` items.
   - The old field stays accepted for one release.
   - Each old entry is read as one login per harness, slot `default`,
     `identity: host-scoped` when no stable id is present, and one
     percent-unit allowance per `limitId`.
2. Window ids, kinds, the five-minute poller, the claim-time exhaustion check and
   the `host-session:<harness>` tag keep their meaning.
3. **Rollout.** Every login already present when the contract rolls out is
   recorded as **enabled** on its existing host record, and that host record
   counts as onboarded, so nothing stops working. The disabled-by-default rule
   of G4.3 starts to apply only after rollout.
4. No pool-level policy scope exists. The defaults chain is exactly G5.3.

---

## Part F — Kind 2: forge identities (contract level)

These bounds govern what the forge kinds' delivery may build. Their attribute
details, reason codes and probes are settled within the bounds, and anything
beyond them needs an ADR amendment.

### F1 — Kinds and attributes

**`git-identity`.** One effective git author identity in one config scope.

- Attributes and disclosure classes:
  - `name` and `email`: `identity`;
  - `scope` (`global` or `repo-override` present): `enum`;
  - `signing` (`none`, `gpg` or `ssh`): `enum`;
  - signing key configured: `boolean`.
- Readiness: `ready` when the name and email are set. `degraded` when signing is
  configured but its program is unavailable.

**`forge-login`.** One forge CLI login (`gh`, `glab` and peers).

- Attributes and disclosure classes:
  - forge and forge host: `public`;
  - account login: `identity`;
  - token scope names: `scopes`;
  - auth store kind (`keychain`, `file` or `env`): `enum`;
  - readable from the daemon's execution context: `boolean`.
- Readiness: `ready` when the daemon's context can use the login.
  `unavailable` with `unreadable_in_daemon_context` when the login exists but
  the daemon cannot use it.

**`credential-helper`.** One configured git credential helper.

- Attribute: the helper's name only (`public`).
- Readiness: `ready` when the helper is resolvable.

Beyond G2.2, the following are never reported: tokens, key ids and fingerprints,
signing-key material, remote URLs that carry credentials, and the contents of
git or forge config files.

### F2 — Identity

- A `forge-login` key follows G3.1, from (forge host, account login).
- `git-identity` and `credential-helper` keys are host-local (G3.2).
- The forge kinds declare no cross-host aggregation.

### F3 — Policy and effects

All forge-kind policy lives on the tenant's host record (G5.1). Enablement
follows G4.2 and G4.3.

| Field | Kind | Effect |
|---|---|---|
| `commitIdentity` | `git-identity` | `selection`: the identity that authors and commits this tenant's work on this host. It is applied per session through the session environment (author and committer variables), never by editing the host's git config. |
| `forgeLogin` | `forge-login` | `selection`: the login this tenant's sessions use on this host. |
| `requireSigning` | `git-identity` | `viability` when set: the selected identity must have signing configured and ready. |
| `refuseOn` | all forge kinds | The list of warning classes (F4) that the tenant promotes to refusals. It is **empty by default**, so every class stays advisory until the tenant opts in. |

### F4 — Pre-dispatch warnings

These are `warning` effects (G6). They are evaluated for the work's target host
and repository before dispatch:

| Warning class | Raised when |
|---|---|
| `forge_login_unreadable` | the selected forge login is not readable in the daemon's context |
| `forge_scope_insufficient` | the login lacks a scope the target repository needs |
| `signing_required_missing` | signing is required but the selected identity has no ready key |
| `no_commit_identity` | the host has no ready `git-identity`, and the tenant selected none |
| `author_not_deployable` | the selected author is not accepted by the target's deploy provider |

`author_not_deployable` needs a membership check against a deploy provider. A
control plane supplies it through the `DeploymentProvider` family (`001`
Layer 2). In a standalone deployment the class reports `unknown`, never `ok`.

---

## Consequences

### Positive

- One model, one scan and one evaluation rule serve every kind of host state. A
  new kind is a schema plus an ADR.
- Each tenant controls exactly its own use of a shared machine. One tenant can
  enable Codex while another enables only Claude on the same host, and no
  tenant's configuration leaks to or binds another.
- Usage is measured where it really lives, on the account, including use outside
  this system. That keeps the allowance model correct when providers move to
  shared token allowances.
- Commit identity becomes an explicit choice per host record. Known failures
  surface before dispatch, not mid-landing.

### Negative

- A new report shape, CLI noun, control operation and host-mutation operation,
  plus a lock-step release of the daemon and any control plane that reads it.
- Per-host-record policy multiplies configuration. Tenant and definition defaults
  exist to keep that manageable.
- Tenants with different guards on one account compete for one allowance: the
  tenant with the higher guard leaves room that a tenant with a lower guard may
  spend.

### Risks

- **A schema that admits a secret.** The closed encoder and golden tests (G2.3)
  are the control. Every new attribute's disclosure class needs review.
- **Identity drift.** A provider that changes its id format splits one subject
  until old reports age out. The versioned key prefix makes the change
  explicit.
- **Per-seat collapse.** Until a provider's shared allowance arrives, a per-seat
  quota behind a workspace id over-blocks unless the user id is available.
- **Stale reads overshoot** a guard by roughly one session's usage per tenant.
  This is accepted (G7.2).

## Alternatives considered

- **One subsystem per kind.** Rejected. The same experience was asked for, and
  two scan and policy paths would drift apart.
- **The strictest guard across tenants binds everyone.** Superseded by the
  product owner's ruling. Configuration belongs to each tenant's host record,
  and no tenant's choice may gate another's.
- **A system-wide reserve cascading from the system level down to the node
  level.** Built as a draft and removed. The platform does not own
  subscriptions, and a single number cannot fit very different plans. It is
  replaced by per-definition defaults that the user overrides.
- **Inherited enablement.** Rejected. Using a subscription is an explicit choice
  per host record.
- **Curated access programs.** Rejected. Detection per account is accurate and
  needs no curator.
- **Computing allowance usage from sessions this system ran.** Rejected. The
  allowance is consumed elsewhere too, so only the provider's report is true.
- **Hard-stopping sessions at a guard, or exact cross-tenant accounting.**
  Rejected. The first destroys work and the second needs locks, both to serve an
  approximate signal.
- **Editing host git config to apply a tenant's identity.** Rejected. It would
  change other tenants' sessions.
- **Hosted subscriptions placeable on any compatible host or sandbox.** Out of
  scope while providers bind logins to a machine.

## Affected documents

These edits land in the commit that flips this ADR to `Accepted`:

- `001-layered-execution-model.md`, Layer 3: observed host state beside the
  worker.
- `002-provider-base-contract.md`: the subscription-provider catalog as a
  capability-matrix section.
- `011-local-daemon-fleet.md`: the observation report, `host observations`, the
  scan operation and the host-mutation operation.
- `013-orchestrator-and-governor.md`: claim-time viability and selection, and
  the nack reasons.
- `ADR-2026-06-06-two-axis-provider-model.md`: an amendment note that the
  subscription axis is orthogonal to the model-endpoint axis.
- `ADR-2026-08-12-placement-composition-law-and-single-fallback-rule.md`: an
  amendment note that observed-kind effects map to stages 3, 4 and 6.

## Affected work items

This corpus carries no tracker identifiers. The platform corpus's companion ADR
enumerates the delivery program with identifiers. By shape, the work is:

- **The contract:** the report and encoder, the scan operation and CLI, and
  claim-time enforcement.
- **Kind 1:** the login scanner with allowance and program detection, the
  catalog with definition defaults, and the guard and billing rules.
- **Kind 2:** the forge-identity scanners, per-session selection, and
  pre-dispatch warnings.

## Implementation notes

- The quota poller and window mappers already exist. The `subscription-login`
  scanner wraps them per slot.
- Key derivation and secret-free encoding are golden-vector tested in Go for
  each kind.
