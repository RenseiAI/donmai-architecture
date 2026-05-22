---
status: Accepted
date: 2026-05-10
boundary: shared
---

# ADR-2026-05-10 — Provider abstractions are native-rich; never lowest-common-denominator

**Status:** Accepted
**Date:** 2026-05-10
**Boundary:** shared (OSS-canonical; mirrored as a stub in `rensei-architecture` per `BOUNDARY.md` § "Cross-cutting ADR dual-publish")
**Authors:** Mark Kropf (Rensei) + Rensei Agent — synthesized from architectural conversation 2026-05-10 while planning the IssueTrackerProvider abstraction for tracker #2.

## Context

`001-layered-execution-model.md` § "Goal of the platform" commits the architecture to a user-facing promise:

> **using Rensei across LLM providers, sandbox providers, and issue trackers must produce a strictly better result than using any of those providers alone. If we fail at that, we are an integration vendor, not a platform.**

The eight Provider Families (`002`) — `Sandbox · Workarea · AgentRuntime · VCS · IssueTracker · Deployment · AgentRegistry · Kit` — each have concrete OSS impls today and a list of shipping or planned alternates. Onboarding the second impl in any family forces a design choice that reappears every time:

- **Lowest-common-denominator (LCD).** Collapse provider-specific verbs, nodes, options, and UI to a generic shape. New providers slot in by implementing the shared shape; existing providers' surfaces shrink to the intersection. This is the standard pattern in integration-as-a-service vendors (Zapier, n8n, Workato, Make, Pipedream).
- **Native-rich peers.** Keep each provider's full native surface. The platform handles cross-provider plumbing (dispatch, OAuth, webhook normalization, session continuity) through a typed internal contract; the user-visible surface stays provider-shaped. Provider count goes up, surface area stays differentiating.

The forcing question landed during the Wave-14 planning for IssueTrackerProvider tracker #2 (GitHub Issues): the platform already ships 21 Linear-specific workflow nodes (triggers + conditions + actions). The LCD path would collapse them to ~7 generic `tracker.*` nodes; the native-rich path keeps Linear's 21 and adds a peer set for GitHub Issues (`github_issues.task_list.checked`, `github_issues.review.requested`, `github_issues.linked_pr.merged`, etc.). The same question recurs across every other family: do we ship a generic `vcs.merge` verb that loses GitHub's merge-queue affordances and Atomic's patch-theory semantics, or two native-rich verbs? Do we ship a generic `sandbox.acquire` that papers over Vercel-Sandbox-snapshot vs E2B-pause vs Mac-Studio-pool semantics, or expose each provider's distinguishing capabilities directly?

LCD wins on consistency and lowers the cost of a third provider. It loses the user commitment from `001`. Once that commitment is the architecture's stated differentiator, LCD is no longer a tradeoff — it's a category change from "platform" to "integration vendor."

## Decision

Every Provider Family abstraction in this architecture splits cleanly into two surfaces, and the rules below apply uniformly across all eight families today and any family added in the future:

### 1. Internal contract surface — typed, cross-provider, capability-flagged

The platform's internal plumbing — anything that runs whether or not a user opened the workflow editor — is abstracted via a typed contract per family. This includes (per family, non-exhaustive):

| Family | Internal contract surface |
|---|---|
| **Sandbox** | acquire/release lifecycle, capability matrix, capacity scheduling |
| **Workarea** | acquire-deterministic-state / release-with-disposition |
| **AgentRuntime** | Spawn/Resume/Inject/Stop, Event channel normalization, capability matrix |
| **VCS** | clone/commit/push primitives, attestation, identity |
| **IssueTracker** | dispatch hot path, OAuth, webhook normalization, session continuity, activity routing |
| **Deployment** | deploy lifecycle, gate hooks, observability emission |
| **AgentRegistry** | discovery, list/resolve, scope resolution |
| **Kit** | detect/provide/composition algorithm |

This surface MUST work across providers without provider-conditional branches in the consumer. Capability flags (per `002`) communicate what each provider's implementation actually delivers; consumers gate behavior on flags, not provider identity.

### 2. User-visible surface — native-rich per provider

Workflow nodes, workflow verbs, CLI subcommands, UI palettes, templates, and any other surface a user authors against MUST stay native-rich per provider. Each provider exposes its full differentiating capability:

- **Workflow nodes:** Linear's 21 native nodes (incl. `linear.agent_session.*`, `linear.issue.create_sub_issue`, etc.) stay as-is. GitHub Issues ships its own native node set (`github_issues.task_list.*`, `github_issues.review.*`, `github_issues.linked_pr.*`). Jira ships epic-aware nodes. Adding a provider grows the catalog; it never trims the existing ones.
- **CLI:** `af linear *`, `af jira *`, `af github *` are sibling subcommand trees, not a single `af tracker --provider <id>`.
- **Workflow verbs:** `vercel.deploy`, `cloudflare.deploy`, `github.pr.create`, `atomic.patch.commit` stay distinct. Generic wrappers like `deploy.run` or `vcs.merge` are explicitly out.
- **Templates:** A SDLC template for Linear-shaped tenants references Linear-native nodes; a SDLC template for GitHub-Issues-shaped tenants references GitHub-Issues-native nodes. We ship per-provider template variants, not one template with a provider knob.
- **UI:** The workflow editor, CLI help, and provider-specific dashboards filter by which integrations are enabled and which capabilities each declares. Doubling node count per added provider is the correct cost; the editor's palette filtering is what keeps the surface tractable for users.

### 3. Capability flags drive the editor / palette filter

Per `002`'s capability-flags-as-the-abstraction-technique, every provider declares typed capability flags. The user-visible surface (workflow editor palette, CLI command discovery, template defaults) reads enabled-integrations + capability flags and shows only nodes/verbs the active providers actually support. Users on a Linear-only org never see Jira nodes; users on a GitHub-Issues-only org never see Linear's `agent_session` nodes. Capabilities the provider DOESN'T support gracefully disappear from the palette rather than being shown as broken stubs.

### 4. Cross-cutting consequences

- **Workflow runtime gates verbs at compile time** (`016`). The compile-time check verifies the verb's required-capability set is satisfied by the provider declared in the workflow. A workflow that references `linear.agent_session.acknowledge` against a GitHub-Issues-bound subscription fails to publish.
- **Templates are provider-shaped, not provider-parameterized.** `sdlc-loop-linear.yaml`, `sdlc-loop-github.yaml`, `sdlc-loop-jira.yaml` are siblings. Each is hand-curated to use the native-rich nodes of its target tracker.
- **The platform never apologizes for native-rich surfaces.** "Why do I see different nodes than my coworker on Jira?" is the right user experience, not a bug. Documentation and onboarding teach the answer; the architecture doesn't bend to obscure it.

## Consequences

### Positive

- **Honors the user-facing commitment from `001`.** Each provider's differentiating capabilities reach end users; the platform earns the "strictly better result than any of those providers alone" promise.
- **Prevents progressive dilution.** LCD abstractions tend to drift toward the smallest common subset over time as new providers are added. Native-rich peers don't have that gradient.
- **Plugins gain a real reason to exist.** A "Rensei Vercel Plugin" that ships native-rich `vercel.*` verbs is more valuable to a Vercel-using customer than a generic `deployment.run` wrapper. The native-rich discipline is what makes plugin authors' work visible.
- **Architectural clarity for the next reviewer.** "Should this be generic or per-provider?" is decided by the surface taxonomy: internal contract = generic+typed; user-visible = per-provider+native. No case-by-case re-litigation.

### Negative

- **Surface area grows linearly with provider count.** Two trackers ≈ 2× the workflow node count; three sandboxes ≈ 3× the verb count. Documentation, examples, and tests grow with it.
- **Templates require per-provider curation.** A SDLC for Jira can't be a one-line knob change of the Linear SDLC; it needs a Jira author who knows the native affordances.
- **Cross-provider migration is harder for users.** A tenant moving from Linear to GitHub Issues will rewire workflows. We accept this; cross-tracker migrations are rare events for users (and usually accompanied by other org changes that justify the rewire).
- **Editor / palette filtering becomes load-bearing UX.** Without good filtering, users see a long node list and can't tell which apply to them. The architecture creates the requirement; the editor must meet it.

### Risks

- **Near-duplicate verbs become hard to tell apart.** `linear.comment.create` and `github_issues.comment.create` look almost identical; users picking the wrong one silently produces wrong-tracker activity. Mitigation: namespace prefix is mandatory and visible in palette; capability flags drive default selection based on the active integration; workflow runtime errors loudly when a verb's provider is not enabled in the org.
- **Providers may declare capability flags they don't deliver.** Mitigation: `002` already prescribes capability discrepancy detection — runtime verifies that observed behavior matches declared capabilities and quarantines providers that diverge.
- **Plugin authors may copy each other's verbs to reach feature parity rather than expressing native capabilities.** Mitigation: plugin review (registry curation) flags near-duplicate verbs that don't differ in declared capabilities. This is the same risk model as malicious-or-incompetent plugin authors generally; not unique to this ADR.
- **The architecture invites accidental cross-cutting "switch" surfaces.** Tenants may ask for "tracker-agnostic" templates. Saying yes once would re-create LCD. Mitigation: the ADR is the policy; tenant requests for tracker-agnostic templates are answered with per-tracker variants.

## Alternatives considered

- **(a) Lowest-common-denominator workflow nodes / verbs.** Rejected per the `001` commitment. LCD turns the platform into the same integration-vendor category we explicitly aren't.
- **(b) Hybrid: ship generic nodes plus optional native-rich extensions.** Rejected because it creates a moving line that future contributors will keep moving toward (a). Once `tracker.comment.create` exists alongside `linear.comment.create`, every new provider is invited to also implement the generic — and the generic's adoption rises while the native-rich set ages out. Native-rich-only is a stable equilibrium; hybrid isn't.
- **(c) Native-rich nodes but generic templates.** Rejected because the template is the user's first-touch artifact for a workflow. A generic template that references provider-specific nodes via Mustache substitution looks tidy but encodes a hidden provider switch the user can't see — a `001`-Principle-2 violation (workflow shape must be user-visible).
- **(d) Defer the decision until a third provider lands.** Rejected because the decision is a discipline policy, not a per-provider choice. Deferring just means the second provider ships under whichever pattern was more convenient that week, and the third provider then lives with that ad-hoc precedent.

## Affected documents

- **`001-layered-execution-model.md`** — § "Goal of the platform" reaffirmed by this ADR; no edit required. § "The eight plugin families" gains a one-line cross-reference noting that the OSS-shipped impl + SaaS alternates table is the *internal contract* surface; the user-visible surface is per-provider per this ADR.
- **`002-provider-base-contract.md`** — gains a new section "Native-rich UX, typed-internal contract" explaining the two-surface split; the existing capability-flags-as-the-abstraction-technique section gains a forward reference to palette filtering as a downstream consumer.
- **`015-plugin-spec.md`** — verb-namespace enforcement section explicitly notes that verbs are provider-shaped, not generic-shaped. Plugin manifests cannot register verbs with cross-provider names (e.g., `tracker.*`, `vcs.*`, `sandbox.*` are reserved against accidental LCD adoption).
- **`016-workflow-engine.md`** — palette filtering by enabled integrations + provider capability flags is added as a first-class editor concern. Compile-time verb resolution gains the "verb's provider must be enabled" check.
- [`rensei-architecture/006-cross-provider-interactions-platform-extensions.md`](https://github.com/RenseiAI/rensei-architecture/blob/main/006-cross-provider-interactions-platform-extensions.md) — Seam descriptions reaffirm that cross-provider seams operate at the *internal contract* layer, not the user-visible surface.
- `rensei-architecture/009-linear-realignment.md` — updated to reflect the two-surface split: contract-side abstraction yes; node-collapse no.

## Follow-on items

- **Multi-tracker mirror (Jira/Asana)** — IssueTrackerProvider abstraction follows this ADR. Internal contract abstracts dispatch / OAuth / webhook / activity. Workflow nodes stay native-rich per tracker.
- **Linear client → IssueTrackerProvider impl** — refactor scope is internal-contract only; the 21 Linear nodes are not collapsed.
- **(net-new) GitHub Issues IssueTrackerProvider impl** — first validating implementation of the ADR. Ships with its own native-rich workflow node set and its own SDLC template variant.
- **(net-new) Workflow editor palette filtering by enabled integrations + capability flags** — load-bearing UX consequence of this ADR. Belongs in the workflow-engine work cluster.
- **Vercel Integration / DeploymentProvider** — when a second deployment provider ships (Cloudflare, custom CI), Vercel's native verbs stay; the new provider ships its native verbs alongside.
- **Agent registry plugins** — the entry-kind taxonomy from the manifest stays per-source; we don't collapse `local-yaml | git-ref | langchain | a2a` to a single generic.
- **Sandbox / Workarea / VCS / AgentRuntime / Kit second-impl work items** — the same discipline applies whenever the second implementation in any of these families lands. Cross-reference this ADR in those issues' scope.

## Implementation notes

- For the IssueTrackerProvider work in flight: the planning artifact "Plan: Abstract issue tracking cleanly before onboarding tracker #2" treats this ADR as the policy gate. Phase 3 of the plan ("Workflow nodes & templates") is rewritten from "collapse to 7 generic nodes" to "ship the workflow-editor palette filter; Linear's native nodes stay; GitHub Issues ships its own native set."
- Phase 4 of the plan (GitHub Issues end-to-end) ships the second native-rich tracker plus its own `sdlc-loop-github.yaml` template. Bugs and missed gaps in the internal contract surface get exposed there — that's the validating function the second provider serves.
- The native-rich discipline is enforced **at design-review time, not at runtime.** There is no machine-readable rule that prevents a contributor from shipping `tracker.comment.create` as a future verb name; reviewers do. The verb-namespace prefix-reservation in `015` makes "this name is reserved" a first-class check, but the human discipline is the load-bearing layer. Treat ADR adherence as a review checklist item for any cross-provider work.
