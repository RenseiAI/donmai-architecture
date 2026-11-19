---
status: Proposed
date: 2026-11-19
boundary: shared
split: sibling-extensions
---

# ADR-2026-11-19 — Subscription accounts: observed accounts, host logins and account policy

**Status:** Proposed
**Date:** 2026-11-19
**Boundary:** shared (OSS-canonical here; `status: Mirrored` stub plus a platform-only companion ADR in `rensei-architecture`)
**Authors:** agent:claude (Opus 5.5), for the product owner

## Context

Coding-agent subscriptions (a ChatGPT plan used by Codex, a Claude plan used by
Claude Code, a gateway plan such as Ollama Cloud, OpenCode or OpenRouter) are
prepaid capacity that lives **on a machine**, as a harness login. Nobody but the
person who signed in can create one, and no provider today lets a hosted control
plane mint or move one. The execution layer already sees parts of this:

- the daemon probes each harness's login and quota (Codex `account/rateLimits/read`
  and `account/rateLimits/updated`, the Claude `get_usage` control request and
  `rate_limit_event`) at most every five minutes and reports one `UsageAccount`
  per harness on the heartbeat: an opaque account id, the plan slug, a limit id,
  the quota windows `{id, kind, usedPercent, resetsAt, windowDurationMins}`,
  reset credits, an `unavailable` reason, and the latest login check;
- a host carries the `host-session:<harness>` capability tag only while that login
  check passes, so placement can require a logged-in host;
- the hosted plane stores the windows per (tenant, host, harness, account,
  limit, window) and treats an exhausted window as non-viable until its reset.

What is missing is a model of the subscription itself. Five gaps:

1. **No account identity that survives a tenant boundary.** The stored account
   reference is keyed per tenant, so one login on one machine that serves three
   tenants appears as three unrelated accounts. A usage guard that must hold for
   every tenant scheduling on the login cannot be computed.
2. **One login per harness per host.** The daemon's quota state holds a single
   account per harness. A host with two Codex homes, or a Codex login and a
   gateway login, cannot report both.
3. **No user policy.** Whether a login may be used at all, how much of it to keep
   unused, and whether it may cross into overage, purchased credits or
   API-billed use are not expressible. The only rule is "exhausted means skip".
4. **The provider and the model are conflated.** "OpenAI" is both the company
   whose model answers and the company that bills the plan. A gateway plan bills
   for many companies' models, and some plans gate individual models behind
   access programs. The two-axis provider model
   (`ADR-2026-06-06-two-axis-provider-model.md`) names the model provider by
   company but has no subscription axis.
5. **No scan contract.** Logins are discovered only as a side effect of the
   quota poller. There is no "show me what this host is logged into" and no
   user-triggered rescan.

The product owner's direction (2026-11-19) sets the requirements: subscriptions
are **observed, never created**; a pool spans hosts logged into different
accounts and a host may hold several; logins are scanned when a host joins a
pool and on demand; every observed login can be enabled, disabled and given a
guard and billing permissions **per host**; policy scopes are deployment →
pool → host; a guard on a login shared by several tenants binds all of them at
**dispatch time only** and may be approximate; and subscriptions are
**user-managed**, not a system-to-node configuration cascade, because the
platform does not manage them.

## Decision

Model a subscription as four things the execution layer can observe and one
thing the user decides: a **subscription provider** and its catalog, an
**observed account**, a **host login**, the login's **usage state**, and the
user's **account policy**. The daemon scans and reports logins; it never reports
secrets. Policy is user-authored at deployment → pool → host, evaluated as a
viability predicate before new work starts, and never applied to work already
running.

### D1 — Subscription provider and model provider are different axes

1. A **subscription provider** is whoever issues and bills a login: the company
   behind a plan (OpenAI ChatGPT, Anthropic Claude) or a **gateway provider**
   (Ollama Cloud, OpenCode, OpenRouter, and their peers) that is
   model-provider-agnostic. A **model provider** is the company whose model
   answers, exactly the MODEL-ENDPOINT company of `ADR-2026-06-06` D1. One
   subscription provider may serve many model providers; one model provider may
   be reachable through many subscription providers.
2. **The catalog** is declared data, one entry per subscription provider:

   | Level | Holds | Example |
   |---|---|---|
   | provider | id, kind (`direct` or `gateway`), the login kinds it issues | `openai-chatgpt`, `direct` |
   | plan | plan slug as the provider reports it, display name, window shapes | `team`: 5-hour and weekly windows |
   | model | (model provider, model id) the plan reaches | (OpenAI, a GPT model) |
   | access program | a per-model entitlement tier the plan may or may not carry | a per-model research tier such as a Blue or Red program |
   | harness compatibility | which harnesses may sign in with this login | ChatGPT tokens: any harness that implements the sign-in; Claude plan: Claude Code only |
   | billing modes | what happens past the included allowance, in order | `quota-window` → `credits` → `overage` → `api-metered` |

3. **Billing modes** are a closed vocabulary:
   - `quota-window` — included, prepaid usage measured as window percentages;
   - `credits` — a purchased or banked balance spent after (or instead of) a window;
   - `overage` — provider-billed usage beyond the plan, charged after the fact;
   - `api-metered` — the same harness falling back to an API key billed per token.

   The first is prepaid; the other three are **billing boundaries** (D7).
4. Catalog rows are matched against what the daemon reports (provider, plan slug,
   window ids); an unmatched plan is still observed and usable, shown as
   `uncatalogued`, with only the windows the daemon reported. The catalog
   describes; it never grants. Harness compatibility is a ceiling checked with
   the two-axis validity rule (`ADR-2026-06-06` D2), never a reason to start a
   harness the host lacks.
5. The OSS layer ships the vocabulary and a minimal catalog for the providers its
   harnesses scan (generated with the capability matrix, `ADR-2026-06-06` D3, as a
   new `subscriptionProviders` section). A hosted deployment may extend it with
   plans, access programs and prices; an extension may add rows and narrow
   compatibility, never widen it.

### D2 — Observed account: one identity everywhere it is seen

1. An **observed account** is one subscription account as the provider knows it:
   (subscription provider, account identity). It is never created by the system;
   it exists because at least one host reported a login to it.
2. **Identity source.** The daemon derives `accountKey`, an opaque, host-
   independent value, from the provider's own stable account identity: the
   account id the provider's login or quota read returns, combined with the user
   id where the provider scopes quota per user inside a shared workspace (team
   plans). It hashes on the host —
   `SHA-256("donmai-account-v1" ‖ provider ‖ accountId ‖ userId?)` — so the wire
   never carries a raw id, and never an email, display name, token or file path.
   The same login on two machines yields the same `accountKey`.
3. A control plane that serves several tenants re-keys `accountKey` with a
   deployment-wide secret (an HMAC) before storage, so the stored identity is
   stable across tenants but cannot be linked to any value outside the
   deployment. That cross-tenant identity is server-internal: no tenant-facing
   read returns it. Tenant-facing surfaces keep a tenant-scoped reference, so no
   tenant learns that another tenant sees the same account (D6.4).
4. A provider that exposes no stable account identity reports
   `identity: "host-scoped"`. Its logins are treated as distinct per host and the
   cross-tenant guard (D6) falls back to per-host evaluation for them.

### D3 — Host login: account × host × harness, several per host

1. A **host login** is one observed account signed in on one host for one
   harness: (`accountKey`, host machine id, harness, login slot). The **login slot**
   is an opaque, host-local discriminator (a hash of the config home the harness
   reads its login from) so a host can report two logins for one harness. A host
   may hold any number of host logins across harnesses and accounts.
2. Each host login reports its **windows** (D1 vocabulary, unchanged from
   today's `UsageWindow`), its plan slug, its **login check** (`ok`, `refused`,
   `unknown`, with the time it ran), and its **billing state**: which billing mode
   the account is in now (`quota-window` while any included window has room; the
   next mode once the provider reports it is spending credits, overage or
   API-metered usage) plus any credit balance the provider exposes.
3. The `host-session:<harness>` capability tag stays: it is set while **at least
   one enabled** host login for that harness passes its login check. Placement
   keeps requiring it; account policy (D4) decides which login and whether.
4. A host login disappears when the host stops reporting it for one scan
   interval after a successful scan (the user logged out); its policy is kept,
   so a re-login restores it.

### D4 — Account policy: user-managed, deployment → pool → host

1. **Fields**, all per host login:

   | Field | Type | Built-in default |
   |---|---|---|
   | `enabled` | boolean | `true` once observed (open question for the owner) |
   | `guardPercent` | 0–100: keep this share of each window unused | `0` (burn to the reset) |
   | `allowCredits` | boolean | `false` |
   | `allowOverage` | boolean | `false` |
   | `allowApiBilledFallback` | boolean | `false` |
   | `warnAtPercent` | list of 0–100 | `[80]` |

2. **Scopes.** Policy may be written at three scopes: **deployment** (a tenant's
   default for every login it sees), **pool** (every login on hosts in the pool),
   and **host** (one host login). For each field the most specific scope that sets
   it wins: host, then pool, then deployment, then the built-in default. This is a
   user's own defaults chain, not a policy-narrowing cascade: there is no system,
   project, workflow or node level, and nothing above the tenant can set or
   override it.
3. **Joining a pool grants scheduling.** Adding a host to a tenant's pool grants
   that tenant scheduling on the host's enabled logins, subject to the tenant's
   policy. A tenant's policy binds only that tenant's dispatches, except the guard,
   which binds every tenant on the login (D6).
4. Policy is configuration, never credentials. Disabling a login does not log it
   out; enabling one cannot log it in.

### D5 — Scan and rescan

1. **Contract.** `scan(host) → HostLoginReport[]`, one entry per host login:

   ```
   HostLoginReport {
     harness, subscriptionProvider, loginSlot,
     accountKey, identity: "account" | "host-scoped",
     plan?, limitId?,
     loginCheck: { state: "ok" | "refused" | "unknown", checkedAt },
     windows: UsageWindow[],
     billingState: { mode, creditsBalance? },
     unavailable?: { reason: "unsupported" | "probeFailed", answered }
   }
   ```

2. **Never reported:** tokens, API keys, cookies, refresh credentials, auth file
   contents or paths, raw account or user ids, email addresses, display names,
   organisation or workspace names. The daemon reads what the harness exposes
   through its documented interfaces only (no undocumented usage endpoints), and a
   scan never runs a model turn.
3. **When it runs.** The quota poller keeps refreshing windows at most every five
   minutes. A **full scan** (login discovery, every harness, every login slot)
   runs when the daemon starts, when a host joins a pool, and on a **user
   rescan**. A rescan is a daemon control operation (`POST /api/daemon/logins/scan`
   on the local control API, and the `donmai` CLI's `logins scan`); a control plane
   requests one over its existing host-mutation channel. A rescan is rate-limited
   per host (one at a time, at most once a minute) and returns the full report.
4. Standalone, `donmai logins` lists the host's logins and their windows from the
   same report.

### D6 — The guard is a shared, dispatch-time gate

1. **Evaluation point.** The guard, `enabled` and exhaustion are **viability**
   predicates in the placement law (`ADR-2026-08-12-placement-composition-law-and-single-fallback-rule.md`,
   stage 3). They are evaluated when work is admitted and again when a host
   claims it. They are never evaluated after the session starts: crossing a guard
   never stops, pauses or preempts running work.
2. **Rule.** A host login is guard-blocked when any of its included windows has
   `usedPercent ≥ 100 − guardPercent` and a reset still ahead. `guardPercent = 0`
   is exhaustion. A blocked login is ineligible until the earliest reset that
   clears every blocking window; the typed reason names the login and that reset.
3. **Across tenants.** Usage belongs to the account, so the usage figure is the
   freshest report for the `accountKey` from any host. The guard for one host
   login is the **strictest** `guardPercent` among the tenants that schedule on it;
   once usage crosses it, no tenant may start new work on that login. `enabled`
   and the billing permissions stay per tenant.
4. **Privacy of the shared gate.** A tenant sees that a login is guard-blocked and
   until when; it never sees which other tenant's guard bound, nor that other
   tenants exist.
5. **Approximate by design.** Windows are up to one poll interval old and several
   tenants may admit against the same reading; overshoot of a few percent is
   accepted. No cross-tenant reservation, lock or token accounting is introduced.
6. **Local enforcement.** The daemon applies the same rule at claim with what it
   knows: its local policy and its own windows. A control plane may push the
   effective host-level policy over the host-mutation channel; the daemon then
   uses the more restrictive of the pushed and local values (the narrow-only shape
   of `ADR-2026-06-06` D5). A claim refused for a guard or exhaustion nacks with the
   typed reason and its reset, and the work is re-placed by the single fallback
   rule.

### D7 — Warnings and billing boundaries

1. **Warnings** fire once per window per reset when usage crosses each
   `warnAtPercent` threshold, and when the guard blocks a login.
2. **Billing boundaries always warn first.** Before a login is used in a billing
   mode past `quota-window` (credits, overage or API-metered), the operator is
   warned, whatever the thresholds say. A dispatch that would start in such a mode
   is refused unless the matching `allow*` field is `true` for every tenant
   scheduling it — the dispatching tenant's own permission, never another
   tenant's.
3. **Detection is the provider's word.** The billing state is what the daemon
   reports (D3.2). Where a provider does not report it, a login whose included
   windows are exhausted is treated as past the boundary, so a missing signal
   fails toward refusal, not toward spend.
4. As with the guard, a boundary crossed during a running session warns and is
   recorded; it does not stop the session.

### D8 — Effect on resolution and on stage routing

1. **Prepaid first among enabled, viable logins.** Where a resolved model may run
   either on a host login or on a keyed mode (`byok`, `metered`), the preference
   stage orders the host-login candidates first, and among them prefers the most
   headroom above the guard. This is a preference (stage 4), never a gate:
   disabled, guard-blocked, exhausted or billing-refused logins have already been
   removed at stage 3, and keyed fallback is the next surviving candidate under the
   single fallback rule.
2. **Stage-routed reviews.** A `review`-role stage
   (`ADR-2026-11-02-stages-roles-and-stage-cards.md`) for a security-class card
   may declare an **ordered target list**: each target a model selection (D7 of
   that ADR) optionally narrowed to a subscription provider or host login. The
   user's order is the declared ordering policy. Resolution takes the first target
   that survives permission and viability; the next target is the fallback; no
   unlisted target is ever used. When no target survives, the stage emits
   `failure` with reason `review_target_unavailable` and the unavailable targets
   with their reasons, instead of degrading to an unlisted model.
3. Every resolution records the host login chosen (or each login rejected, with
   its reason) in the admission receipt, beside the auth mode.

### D9 — Migration from today's quota snapshots

1. Today's `UsageAccount` heartbeat field becomes the `HostLoginReport` list. The
   field stays accepted for one release; a daemon that sends only the old shape
   is read as one host login per harness, slot `default`, identity `host-scoped`.
2. Window ids, kinds, the five-minute poller, the claim-time exhaustion check and
   the `host-session:<harness>` tag are unchanged in meaning.
3. The hosted plane's migration of its stored snapshots, references and the
   viability rule is specified in the platform companion ADR.

## Consequences

### Positive

- A login seen by several tenants is one account with one guard, so a
  shared machine can be trusted not to burn a plan its owner wanted to keep.
- The owner decides per host whether and how far a subscription is used; the
  system no longer invents a global reserve.
- Gateways and access programs fit without special cases: the subscription axis
  is separate from the model axis.
- Billing surprises become refusals with a warning first.

### Negative

- A new daemon report shape, CLI noun and control operation, and a lock-step
  release of the daemon and any control plane that reads it.
- Per-host policy multiplies configuration; the deployment and pool scopes exist
  to keep that manageable.
- The strictest-guard rule lets any tenant on a shared login lower everyone's
  usable share.

### Risks

- **Identity drift.** A provider that changes its account id format splits one
  account into two until both reports age out; the guard then under-counts for up
  to one scan interval. Mitigation: the `donmai-account-v1` prefix versions the
  derivation.
- **Shared-workspace collapse.** A team plan whose quota is per user but whose
  account id is per workspace collapses users into one account if the user id is
  unavailable; the guard then over-blocks. Mitigation: D2.2 includes the user id
  where the provider exposes it; otherwise the login is `host-scoped`.
- **Stale reads overshoot.** Concurrent admissions against one reading can pass a
  guard by roughly one session's usage per tenant. Accepted (D6.5).

## Alternatives considered

- **A system-wide reserve, cascading system → node.** Built as a draft and
  removed: the platform does not own subscriptions, a global number cannot fit
  plans of very different sizes, and an inner level could not loosen it.
- **Hard-stopping sessions at the guard.** Rejected: it destroys work to protect
  a soft budget, and window readings are minutes old.
- **Exact cross-tenant accounting** (reservations or token budgets against each
  window). Rejected for now: providers report percentages, not tokens; the cost is
  a distributed lock for an approximate signal.
- **Keeping the per-tenant account reference as the only identity.** Rejected: it
  makes the shared guard impossible (D2).
- **Hosted subscriptions placeable on any compatible host or sandbox.** Out of
  scope while providers bind logins to a machine; revisit if they allow it.

## Affected documents

Landed in the commit that flips this ADR to `Accepted`:

- `001-layered-execution-model.md` — Layer 3 (Execution): add the host-login
  concept beside the worker, with a pointer here.
- `002-provider-base-contract.md` — the subscription-provider catalog as a
  declared-data section of the capability matrix.
- `011-local-daemon-fleet.md` — the scan contract, the `logins` CLI noun and the
  local control operation; heartbeat `HostLoginReport`.
- `013-orchestrator-and-governor.md` — the claim-time guard and nack reason.
- `ADR-2026-06-06-two-axis-provider-model.md` — amendment note: the subscription
  axis is orthogonal to the model-endpoint axis.
- `ADR-2026-08-12-placement-composition-law-and-single-fallback-rule.md` —
  amendment note: account policy and the guard are stage-3 viability inputs;
  prepaid-first is a stage-4 preference.

## Affected work items

This corpus carries no tracker identifiers. The delivery program is enumerated
with identifiers in the platform corpus's companion ADR. By shape:

- **Execution layer:** the `HostLoginReport` scanner with login slots and the
  account-key derivation; the `logins` CLI noun and local scan operation; the
  claim-time guard and billing-boundary refusal.
- **Hosted plane:** storage and migration, the cross-tenant identity, account
  policy authoring, scan on pool join and rescan, warnings, and resolution.

## Implementation notes

- The quota poller and window mappers already exist; the scanner wraps them per
  login slot rather than replacing them.
- The account-key derivation is golden-vector tested in Go so a control plane
  can verify it receives stable keys.
