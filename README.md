# Donmai Architecture

Canonical OSS architecture corpus for the **Donmai execution layer** — the `donmai` binary, the local daemon (`donmai daemon`), the runner, the eight Provider Families, the Kit composition framework, and the workflow engine that underlies them.

This corpus is the single source of truth for cross-repo architectural decisions affecting the OSS execution layer. Where any project's documentation conflicts with what's written here, this wins.

## What lives here vs. its sibling

This repository is the **OSS-public canonical corpus**. Its sibling, [`rensei-architecture`](https://github.com/RenseiAI/rensei-architecture), is the **Rensei-Platform-extensions corpus** — it carries the platform-only docs (Linear realignment against the Rensei team's backlog, PM agent definitions tied to that backlog, the SaaS dashboard parity discipline, multi-tenant control-plane decisions) and the platform-side `<doc>-platform-extensions.md` deltas that extend shared docs in this repo.

The boundary discipline — verbatim from `001-layered-execution-model.md` § "The donmai ↔ Rensei Platform contract":

> 1. The OSS layer defines all interfaces in this corpus.
> 2. The OSS layer ships a working implementation of every interface — never *only* the type.
> 3. The SaaS control plane extends with alternate implementations and centralized administration (registries, signing, policy enforcement, multi-tenant management, the SaaS dashboard, the routing-intelligence panel).
> 4. The OSS layer never depends on the SaaS plane to function. Removing the platform leaves a usable single-machine product.
> 5. The boundary between them is a small set of pluggable function callbacks (`setAgentLauncher`-shaped), not subprocess or RPC. The platform composes the OSS layer as a library; both ship as one binary to end users.

That discipline — particularly point (4), "removing the platform leaves a usable single-machine product" — is what determines which docs live in this corpus and which extend the contract from `rensei-architecture`. See `BOUNDARY.md` for the convention this repo uses to keep the split honest going forward.

## Status

**Wave 10 Phase 3 migration complete.** OSS-only and shared-with-OSS-substance docs have migrated from `rensei-architecture` here. Phase 4 (cross-reference rewrite) follows; expect some inline markdown links to currently use bare filename forms that Phase 4 promotes to absolute repo URLs or sibling-repo paths.

## Index

### Canonical

- **`001-layered-execution-model.md`** — Layered model, terminology, the eight Provider Families, the OSS↔platform boundary, capability-flag abstraction. Read first. This doc carries a **synchronized** "donmai ↔ Rensei Platform contract" section that is mirrored verbatim in `rensei-architecture/001`; see `BOUNDARY.md`.

### Reference docs (per layer)

- **`002-provider-base-contract.md`** — Unified `Provider` interface that all eight plugin families extend. Manifest, capability struct, AgentRuntime v2 enrichments.
- **`003-workarea-provider.md`** — Deterministic filesystem state. `acquire`/`release` lifecycle, snapshot semantics, local pool implementation.
- **`004-sandbox-capability-matrix.md`** — Capability flags and regime-fit table for Sandbox providers (Local, Vercel, E2B, Modal, Daytona, Docker, K8s). Cross-provider scheduler.
- **`005-kit-manifest-spec.md`** — Buildpacks-shaped contribution framework. `detect`/`provide` lifecycle, manifest schema, daemon kit registry.
- **`006-cross-provider-interactions.md`** — How layers cooperate at the seams. Workarea↔Memory cursor, Kit toolchain → Sandbox image, A2A as transport flavor (OSS-substance seams; Seam 4 cost-emission and Seam 6 audit-chain extensions live in `rensei-architecture`).
- **`007-intelligence-services.md`** — Memory + Code Intelligence + Architectural Intelligence interfaces and single-tenant reference impls. Multi-tenant federation lives in `rensei-architecture`.
- **`008-version-control-providers.md`** — `VersionControlProvider` interface admitting git hosts, Atomic, S3, and non-code substrates.

### Distribution & runtime

- **`011-local-daemon-fleet.md`** — Operator manual for the local daemon mode of the `donmai` binary. Install paths (macOS launchd, Linux systemd, Docker), first-run wizard, config knobs, drain semantics, recovery, observability, HTTP control API. Multi-machine fleet aggregation lives in `rensei-architecture`.
- **`013-orchestrator-and-governor.md`** — Orchestrator, governor, worker, AgentRuntime dispatch, completion contracts, macOS signing & notarization rule. Topology view + Donmai merge-queue specifics live in `rensei-architecture`.
- **`014-tui-operator-surfaces.md`** — TUI display primitives, capability-chip pattern, theme + accessibility, primitive registry. Live capacity contract + dual-surface discipline live in `rensei-architecture`.
- **`015-plugin-spec.md`** — Plugin manifest, single-artifact distribution, atomic auth, verb registry, namespacing, lifecycle, versioning.
- **`016-workflow-engine.md`** — Workflow grammar, node taxonomy, compile contract, durable execution, locus-of-definition rule, inter-node piping.

### ADRs

- **`ADR-template.md`** — Template for new architectural decisions. Copy when proposing changes. Mirrored to `rensei-architecture` via stub.
- **`ADR-2026-04-27-plugin-and-workflow-architecture.md`** — Plugin / Provider Family / Workflow taxonomy + AgentRuntime as 8th family. Cross-cutting; mirrored as stub in `rensei-architecture`.
- **`ADR-2026-04-28-sandbox-capabilities-in-types.md`** — TypeScript file-layout in `packages/core/src/providers/`.
- **`ADR-2026-04-28-workflow-piping-uses-nodes.md`** — `{{ nodes.*.output.* }}` workflow grammar.
- **`ADR-2026-04-29-long-running-runtime-substrate.md`** — `@donmai/server` substrate. Platform schema mirror + JWT trust anchor extensions live in `rensei-architecture`.
- **`ADR-2026-05-03-locus-of-workflow-definition.md`** — Workflow-grammar discipline. Cross-cutting; mirrored as stub in `rensei-architecture`.
- **`ADR-2026-05-06-tui-noun-consolidation.md`** — `host` / `fleet` / `capacity` consolidation. User-auth retrofit + Live capacity addendum extensions live in `rensei-architecture`.
- **`ADR-2026-05-07-daemon-http-control-api.md`** — Local daemon's `/api/daemon/*` HTTP control API. Wave 9 ADR — canonical example of "OSS daemon owns its own surface."
- **`ADR-2026-05-10-native-rich-providers.md`** — Provider abstractions split into typed-internal contract + native-rich user-visible surface; never lowest-common-denominator. Cross-cutting; mirrored as stub in `rensei-architecture`.
- **`ADR-2026-05-12-cli-linear-proxy.md`** — CLI Linear proxy via platform login session; `rensei linear` command routes through platform OAuth on behalf of the agent. Cross-cutting; mirrored as stub in `rensei-architecture`.
- **`ADR-2026-05-12-cross-process-hook-bus-bridge.md`** — Cross-process Layer 6 hook bus bridge for daemon-driven sessions; enables hook events to propagate from worker children back to the daemon host. Cross-cutting; mirrored as stub in `rensei-architecture`.
- **`ADR-2026-06-01-code-survival-pool-execution.md`** — Code-survival batch execution in the worker pool: ephemeral-clone posture, atomic claim, concurrent fan-out, soft reachability weight. Cross-cutting; platform extensions in `rensei-architecture`.
- **`ADR-2026-06-02-interactive-agent-run-mode.md`** — Interactive (non-headless) agent run mode; in-pool streaming sessions with token output and all auth modes. Cross-cutting; mirrored as stub in `rensei-architecture`.
- **`ADR-2026-06-02-oss-brand-neutral-runtime-contract.md`** — Removes the closed-source brand from the OSS donmai runtime (env names, default URLs, state paths); pushes all closed-brand identity into the composition layer. Cross-cutting; mirrored as stub in `rensei-architecture`.
- **`ADR-2026-06-03-batch-work-type-category.md`** — Formalizes `batch` as a first-class work-type category in the execution model, amending `001` §Layer 3 and `013`; covers KG extraction and code-survival as examples. Cross-cutting; the platform delta (the KG-extraction batch lane) lives as a sibling ADR in `rensei-architecture`.
- **`ADR-2026-06-03-injectable-state-dir.md`** — Makes daemon host-state dir (state + log paths) injectable by the embedding binary via a `donmai/runtime/statehome` seam; OSS default stays `donmai`, closed composing binary sets its own brand. Cross-cutting; mirrored as stub in `rensei-architecture`.
- **`ADR-2026-06-06-two-axis-provider-model.md`** — Two-axis provider model: engine (which agent runtime) × transport (how it's driven) with a manifest-first AgentRuntime contract. Cross-cutting; mirrored as stub in `rensei-architecture`.
- **`ADR-2026-06-07-intelligence-implementation-is-platform.md`** — Intelligence (Memory / Code Intelligence / Architectural Intelligence) implementation is platform-only; OSS ships execution + contracts + kit extension points, no reference implementations. Cross-cutting; mirrored as stub in `rensei-architecture`.
- **`ADR-2026-06-08-arch-intel-go-native-af-arch-deprecation.md`** — Retires the legacy arch-intel TS CLI/package; Layer-1 drift gate goes Go-native in OSS execution, Layer-2 learned baseline stays platform-owned. Cross-cutting; mirrored as stub in `rensei-architecture`.
- **`ADR-2026-06-10-durable-ci-wait.md`** — The develop→verify CI wait is orchestration-owned and durable (signal gate correlated on `Result.CommitSHA`); agent sessions never wait for remote CI or park on in-process timers. Amends `013` § Completion contracts. Cross-cutting; mirrored as stub in `rensei-architecture`.
- **`ADR-2026-06-19-requester-provider-inbound-agent-family.md`** — The inbound `RequesterProvider` family: an external agent authenticates, submits a unit of work via an `agent.request` trigger, is an attributable principal, and expects a `{ result, receipt? }` back. The inbound dual of A2A. Cross-cutting; mirrored as stub in `rensei-architecture`.
- **`ADR-2026-06-20-byoa-requester-registration-record.md`** — Requester registration: the inbound principal record. An inbound requester registers once per org as a scoped principal (handle, allowed projects/workflows, posture); a credential binds to it at mint; resolution is the dispatch-time authorization + attribution anchor. Cross-cutting; mirrored as stub in `rensei-architecture`.
- **`ADR-2026-06-21-mcp-adapter-archetype.md`** — MCP adapter archetype: the OSS-canonical shape of an MCP facade over the inbound dispatch primitive — a fixed `dispatch` / `get_receipt` / `list_workflows` tool surface mapping one-to-one onto inbound operations, fail-closed, same governance gates as the native `agent.request` entry; a transport flavor, not a side-door. Cross-cutting; mirrored as stub in `rensei-architecture`.
- **`ADR-2026-06-21-webhook-callback-delivery.md`** — Webhook push-back contract: the egress delivery mode of `requester.respond` — an HMAC-SHA256-signed (`X-Agent-Signature`), timestamp-bound, one-time-secret, at-least-once-retried, idempotent, posture-gated POST of the `{ result, receipt? }` envelope to a registered callback URL. Cross-cutting; mirrored as stub in `rensei-architecture`.
- **`ADR-2026-06-22-linear-backlog-grooming-verbs.md`** — OSS `donmai linear` backlog-grooming verb set: `list-backlog-issues --parents-only --statuses --team` (with `parentID` in the issue payload), `list-sub-issues`, `add-relation --type blocks`, `list-labels`/`apply-label`, `update-issue --status/--priority/--estimate`, and env-default scope (`DONMAI_LINEAR_PROJECT`/`DONMAI_LINEAR_TEAM`). Captures the parent-in-target-status-then-cascade dimensionality contract. OSS-only.
- **`ADR-2026-06-22-daemon-per-session-cancel-wire.md`** — Daemon per-session cancel-wire: `WorkerSpawner.StopSession` + localhost-only `POST /api/daemon/sessions/:id/stop` + a fast in-band stop via the lock-refresh `stop` field + a distinct `FailureOperatorCancelled` mode (never re-dispatched) + an idle/no-progress watchdog (`FailureNoProgress`) and the deferred-exit-trigger multi-root exclusion. Amends `011`. OSS-only.
- **`ADR-2026-06-28-per-llm-call-observability-span-contract.md`** — Frozen six-kind camelCase JSON span union and current OpenTelemetry GenAI projection. Types shipped in v0.49.3; the correlated processor/poster is shipped but unreleased at `c07354bb` and posts raw compatibility arrays rather than OTLP export envelopes. Cross-cutting; mirrored as a thin stub with platform ingest/store extensions in `rensei-architecture`.
- **`ADR-2026-07-04-code-intel-index-schema-v2-go-authoritative.md`** — Code-intel index schema v2: Go owns `.donmai/code-index/index.json` (TS byte-compat deliberately dropped; the top-level `version` field gates loads — any mismatch forces a clean full rebuild); `FileIndex` gains `contentHash`/`simHash`/`imports`/`exports`, enabling real PageRank over the persisted import graph, real content-hash dedup, Go-native hybrid search (Voyage + Cohere, env-key opt-in, BM25 fallback), and real Merkle-diff incremental indexing. Explicitly restates that Code Intelligence is exempt from the `ADR-2026-06-07` retraction and continued; the `DONMAI_CODE_BIN` exec-shim is deprecation-warned and removed when `donmai-libraries` is archived. Amends `007`. OSS-only.
- **`ADR-2026-07-05-self-referential-stdio-mcp-in-box-capability.md`** — Self-referential stdio MCP server as the in-box capability delivery pattern: capabilities that must touch the sandbox working tree (code-intel is the archetype and first instance) ship as compiled-in stdio MCP servers (hidden `donmai mcp code-intel`; server `af-code-intelligence`, six `af_code_*` tools) spawned by the runner via `os.Executable()` with an **explicit `--root`** (never cwd inheritance — no target guarantees the runner cwd), activated by typed QueuedWork blocks (`codeIntel` first) with the runner authoring the server entry (defaults-win; never shadowed by platform-sent cards). THE reusable pattern for `af_linear` and future in-box capabilities (the `runner/loop.go` F.5 seam). Version-coupling rule: the platform must not stamp a block until the reading runner version is deployed; old runners ignore unknown fields. Amends `007`. Cross-cutting; platform stub + sibling extension land with the W3 platform-activation lane.
- **`ADR-2026-07-10-deterministic-kit-packages-and-command-composition.md`** — Kit package and catalog integrity contract: signed canonical inventory binds every payload path/digest/size/mode; complete packages stage, verify, and activate atomically with rollback; generic commands retain owner-qualified identity and ambiguous aliases fail instead of last-wins; signed catalog snapshots pin exact package digests; legacy manifest trust remains explicitly weaker. Amends `005`. OSS-only canonical; implementation pending.
- **`ADR-2026-07-12-interactive-pty-session-host.md`** — Interactive PTY session host: the OSS execution-layer contract for platform-managed interactive terminal sessions — spawn-under-PTY (generalizing the `agy` path), a seq-numbered ring buffer, verbatim resize application, a live stdin sink, a host-side headless-VT snapshot authority (D3), a `sessionClass` reaper-exemption stamp (named cross-repo dependency), the brand-neutral framing library (normative spec `protocol/interactive-attach-v1.md`), and a generic dial-out-only attach client (`ATTACH_URL` + bearer, mirroring `DONMAI_DAEMON_URL`). Carries the synchronized outbound-stream mandate (a third persistent outbound loop; inbound listeners remain forbidden) that amends the 2026-06-22 pull-model decision. Amends `001`/`011`. Cross-cutting; mirrored stub + relay/control-plane/quotas/iOS extensions in `rensei-architecture`.
- **`ADR-2026-07-12-kit-catalog-expansion.md`** — Lifts the deterministic-package catalog-expansion hold: an authorized new kit enters `EXPECTED_KIT_IDENTITIES` through an explicit **first-publication-pending** path (manifest + payload only, no trust artifacts), is payload/identity-verified without a not-yet-minted descriptor, and graduates to published only when the main-only signer mints and verifies its complete package on merge (the maintainer merge is the authorization). Preserves every published-subset invariant, adds a demotion-hole guard (descriptor-without-legacy-signature is an error), keeps descriptor determinism and allowlist fail-closed, and admits no unsigned install. Records the mobile-lane rule (`default/swift` = single Swift foundation; any future `mobile`/`ios` kit = `order="framework"` on a disjoint detect). Amends `ADR-2026-07-10` (§6 L1, §7) and `005`. OSS-only.
- **`ADR-2026-07-18-bounded-terminal-workarea-leases.md`** — **Accepted architecture; implementation, release, migration, and activation pending.** Provider-neutral terminal lease, Donmai-owned sole-origin claim clock with exact replay, durable downstream claim-acknowledgement receipt before command/result, acknowledgement/expiry release paths, separate acquisition quarantine, receiver-affine outbox, exact package/composition/artifact gates, and bounded idempotent provider release. Ownership ends only at durable `released`. Shared; the coordinated mirrored stub and consumer protocol/sandbox/activation extension are accepted architecture, not shipped availability. Amends `003`, `011`, and `013`.

### Agents (archetypes)

- **`agents/pm/backlog-writer.yaml`** — PM-archetype: refine/groom/author modes, no-sub-issue rule, haiku-executable scope discipline. Rensei-team tool allowlists live in `rensei-architecture/agents/pm/backlog-writer-rensei.yaml` via `extends:`.
- **`agents/pm/outcome-auditor.yaml`** — same pattern.
- **`agents/pm/improvement-loop.yaml`** — same pattern.
- **`agents/pm/operational-scanner-sentry.yaml`** — Sentry-source archetype; same pattern.
- **`agents/migration/migration-coordinator.yaml`** — Migration archetype: AgentDefinition + Task tool + WORK_RESULT marker. Rensei-team-specific binary-distribution gate + tool allowlists live in `rensei-architecture/agents/migration/migration-coordinator-rensei.yaml` via `extends:`.

### Convention

- **`BOUNDARY.md`** — How this corpus stays OSS-canonical: the three verdicts (`OSS-only` / `platform-only` / `shared`), split mechanism for shared docs, dual-publish-stub pattern for cross-cutting ADRs, frontmatter `boundary:` field, synchronized-section CI hook plan, `extends:` composition pattern for agents YAMLs.

## Reading order for new contributors

Humans and fleet agents alike should consume in this order:

1. **`001-layered-execution-model.md`** — Layered model, terminology, the eight Provider Families, the OSS↔platform boundary, capability-flag abstraction. Read first.
2. **`002-provider-base-contract.md`** — Without the base contract, the rest looks like a list of unrelated provider types.
3. **`015-plugin-spec.md`** — Plugin manifest, single-artifact distribution, atomic auth, verb registry.
4. **`016-workflow-engine.md`** — Workflow grammar, node taxonomy, durable execution.
5. The reference doc for whichever layer you are working on: `003` (workarea), `004` (sandbox), `005` (kit), `007` (intelligence), `008` (VCS).
6. **`013-orchestrator-and-governor.md`** — The runtime that embeds the workflow engine.
7. **`011-local-daemon-fleet.md`** — Operator manual for the local daemon mode of the `donmai` binary.
8. **`014-tui-operator-surfaces.md`** — TUI display primitives, capability-chip pattern, theme + accessibility.
9. **`006-cross-provider-interactions.md`** — The seams; where most subtle bugs live.

For full read-order detail (including ADR ordering and agent archetypes), see `AGENTS.md`. Skip [`009-linear-realignment.md`](https://github.com/RenseiAI/rensei-architecture/blob/main/009-linear-realignment.md) and [`012-product-management-agents.md`](https://github.com/RenseiAI/rensei-architecture/blob/main/012-product-management-agents.md) when consuming only this OSS corpus — both are platform-only and live in `rensei-architecture`.

## How this corpus changes

This repo follows permissive-direct-to-main norms. Both humans and fleet agents may commit directly. The git history is the audit log.

**Substantive architectural changes follow the ADR pattern**: copy `ADR-template.md` to a new dated file (named `ADR-YYYY-MM-DD-<slug>.md`), commit the proposal, and update the affected reference docs in the same commit. The canonical doc (`001`) is updated only when an ADR has shifted the layered model itself. New ADRs declare a `boundary:` field in their frontmatter — see `BOUNDARY.md`.

**Non-substantive edits** (typos, clarifications, examples, broken-link fixes) commit directly without ceremony.

## Conventions

- Doc numbering is stable. Don't renumber without an ADR. New docs append (`010-`, `017-`, etc.).
- Diagrams use Mermaid embedded in markdown. Avoid external image assets.
- Code samples are TypeScript or Go depending on subject; concrete code lives in source repos (`donmai`, `donmai-libraries`, future Kit repos), not here.
- "Kit" is a placeholder name pending brand decision; do not search/replace until the rename ADR lands.

<!-- ADR-INDEX:START (generated by scripts/gen-adr-index.sh) -->
## Complete ADR index (generated)

Every tracked `ADR-*.md` in this corpus, generated from frontmatter by
`scripts/gen-adr-index.sh`. This is the machine-maintained companion to the
curated reading-order index above; it exists so the README↔disk index never
drifts (`adr-status-lint.sh` warns when it does). Regenerate after adding or
renaming an ADR.

| ADR | Status | Boundary | Title |
|---|---|---|---|
| [`ADR-2026-04-27-plugin-and-workflow-architecture.md`](ADR-2026-04-27-plugin-and-workflow-architecture.md) | Accepted | shared | Plugin Distribution Model and Workflow Engine as First-Class Architecture |
| [`ADR-2026-04-28-sandbox-capabilities-in-types.md`](ADR-2026-04-28-sandbox-capabilities-in-types.md) | Accepted | — | — |
| [`ADR-2026-04-28-workflow-piping-uses-nodes.md`](ADR-2026-04-28-workflow-piping-uses-nodes.md) | Accepted | — | — |
| [`ADR-2026-04-29-long-running-runtime-substrate.md`](ADR-2026-04-29-long-running-runtime-substrate.md) | Accepted | shared | — |
| [`ADR-2026-05-03-locus-of-workflow-definition.md`](ADR-2026-05-03-locus-of-workflow-definition.md) | Accepted | shared | — |
| [`ADR-2026-05-06-tui-noun-consolidation.md`](ADR-2026-05-06-tui-noun-consolidation.md) | Accepted | shared | — |
| [`ADR-2026-05-07-daemon-http-control-api.md`](ADR-2026-05-07-daemon-http-control-api.md) | Accepted | — | — |
| [`ADR-2026-05-10-native-rich-providers.md`](ADR-2026-05-10-native-rich-providers.md) | Accepted | shared | Provider abstractions are native-rich; never lowest-common-denominator |
| [`ADR-2026-05-12-cli-linear-proxy.md`](ADR-2026-05-12-cli-linear-proxy.md) | Accepted | shared | CLI Linear proxy via platform login session |
| [`ADR-2026-05-12-cross-process-hook-bus-bridge.md`](ADR-2026-05-12-cross-process-hook-bus-bridge.md) | Accepted | shared | Cross-process Layer 6 hook bus bridge for daemon-driven sessions |
| [`ADR-2026-06-01-code-survival-pool-execution.md`](ADR-2026-06-01-code-survival-pool-execution.md) | Accepted | shared | — |
| [`ADR-2026-06-02-interactive-agent-run-mode.md`](ADR-2026-06-02-interactive-agent-run-mode.md) | Accepted | shared | Interactive (non-headless) agent run mode |
| [`ADR-2026-06-02-oss-brand-neutral-runtime-contract.md`](ADR-2026-06-02-oss-brand-neutral-runtime-contract.md) | Accepted | shared | — |
| [`ADR-2026-06-03-batch-work-type-category.md`](ADR-2026-06-03-batch-work-type-category.md) | Accepted | shared | — |
| [`ADR-2026-06-03-injectable-state-dir.md`](ADR-2026-06-03-injectable-state-dir.md) | Accepted | shared | — |
| [`ADR-2026-06-06-two-axis-provider-model.md`](ADR-2026-06-06-two-axis-provider-model.md) | Accepted | shared | — |
| [`ADR-2026-06-07-intelligence-implementation-is-platform.md`](ADR-2026-06-07-intelligence-implementation-is-platform.md) | Accepted | shared | Intelligence implementation is platform-only; OSS ships execution + contracts |
| [`ADR-2026-06-08-arch-intel-go-native-af-arch-deprecation.md`](ADR-2026-06-08-arch-intel-go-native-af-arch-deprecation.md) | Accepted | shared | The af-arch CLI is deprecated; Layer-1 drift gate goes Go-native (execution); Layer-2 stays platform |
| [`ADR-2026-06-10-durable-ci-wait.md`](ADR-2026-06-10-durable-ci-wait.md) | Accepted | shared | Durable CI wait: the develop→verify hop suspends at the orchestration layer, not in the agent session |
| [`ADR-2026-06-13-daemon-sessionhandle-enrichment.md`](ADR-2026-06-13-daemon-sessionhandle-enrichment.md) | Accepted | OSS-only | — |
| [`ADR-2026-06-13-official-language-kits-and-catalog-home.md`](ADR-2026-06-13-official-language-kits-and-catalog-home.md) | Accepted | OSS-only | — |
| [`ADR-2026-06-14-model-host-awareness.md`](ADR-2026-06-14-model-host-awareness.md) | Accepted | shared | — |
| [`ADR-2026-06-14-provider-base-contract-go-native.md`](ADR-2026-06-14-provider-base-contract-go-native.md) | Accepted | OSS-only | — |
| [`ADR-2026-06-14-sdk-axis-readiness-and-freeze-sequencing.md`](ADR-2026-06-14-sdk-axis-readiness-and-freeze-sequencing.md) | Accepted | shared | — |
| [`ADR-2026-06-15-deterministic-merge-landing.md`](ADR-2026-06-15-deterministic-merge-landing.md) | Accepted | shared | Deterministic merge landing is orchestration-owned |
| [`ADR-2026-06-15-kit-session-start-context.md`](ADR-2026-06-15-kit-session-start-context.md) | Accepted | shared | — |
| [`ADR-2026-06-15-turn-result-manifest.md`](ADR-2026-06-15-turn-result-manifest.md) | Accepted | shared | Turn-result manifest is the deterministic turn outcome |
| [`ADR-2026-06-19-requester-provider-inbound-agent-family.md`](ADR-2026-06-19-requester-provider-inbound-agent-family.md) | Accepted | shared | RequesterProvider: the inbound agent-request family |
| [`ADR-2026-06-20-byoa-requester-registration-record.md`](ADR-2026-06-20-byoa-requester-registration-record.md) | Accepted | shared | Requester registration: the inbound principal record |
| [`ADR-2026-06-21-byoa-workflow-authoring-verbs.md`](ADR-2026-06-21-byoa-workflow-authoring-verbs.md) | Proposed | shared | BYOA workflow-authoring verbs: the `workflow:author` capability |
| [`ADR-2026-06-21-mcp-adapter-archetype.md`](ADR-2026-06-21-mcp-adapter-archetype.md) | Proposed | shared | MCP adapter archetype: a facade over the inbound dispatch primitive |
| [`ADR-2026-06-21-webhook-callback-delivery.md`](ADR-2026-06-21-webhook-callback-delivery.md) | Proposed | shared | Webhook callback delivery: the push-back contract |
| [`ADR-2026-06-22-daemon-per-session-cancel-wire.md`](ADR-2026-06-22-daemon-per-session-cancel-wire.md) | Accepted | OSS-only | Daemon per-session cancel-wire and progress watchdogs |
| [`ADR-2026-06-22-linear-backlog-grooming-verbs.md`](ADR-2026-06-22-linear-backlog-grooming-verbs.md) | Accepted | OSS-only | OSS Linear CLI verb contract for backlog grooming |
| [`ADR-2026-06-28-per-llm-call-observability-span-contract.md`](ADR-2026-06-28-per-llm-call-observability-span-contract.md) | Accepted | shared | Per-LLM-call observability span contract |
| [`ADR-2026-07-04-code-intel-index-schema-v2-go-authoritative.md`](ADR-2026-07-04-code-intel-index-schema-v2-go-authoritative.md) | Accepted | OSS-only | code-intel index schema v2: Go authoritative; TS byte-compat dropped; exec-shim decommission plan |
| [`ADR-2026-07-05-self-referential-stdio-mcp-in-box-capability.md`](ADR-2026-07-05-self-referential-stdio-mcp-in-box-capability.md) | Accepted | shared | Self-referential stdio MCP server as the in-box capability delivery pattern |
| [`ADR-2026-07-07-sibling-context-repos.md`](ADR-2026-07-07-sibling-context-repos.md) | Accepted | OSS-only | — |
| [`ADR-2026-07-10-deterministic-kit-packages-and-command-composition.md`](ADR-2026-07-10-deterministic-kit-packages-and-command-composition.md) | Accepted | OSS-only | — |
| [`ADR-2026-07-12-interactive-pty-session-host.md`](ADR-2026-07-12-interactive-pty-session-host.md) | Accepted | shared | — |
| [`ADR-2026-07-12-kit-catalog-expansion.md`](ADR-2026-07-12-kit-catalog-expansion.md) | Proposed | OSS-only | — |
| [`ADR-2026-07-18-bounded-terminal-workarea-leases.md`](ADR-2026-07-18-bounded-terminal-workarea-leases.md) | Accepted | shared | Bounded terminal workarea leases |
| [`ADR-template.md`](ADR-template.md) | Template | shared | Required frontmatter for every new ADR. |
<!-- ADR-INDEX:END -->
