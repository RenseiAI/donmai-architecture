---
status: Accepted
boundary: shared
split: sibling-extensions
---

# ADR-2026-06-20-externally-delivered-nodes

**Date:** 2026-06-20 (canonical half authored 2026-08-04)
**Related:**
- [015-plugin-spec.md](015-plugin-spec.md) — the verb registry this ADR extends with the `node` block
- [016-workflow-model.md](016-workflow-model.md) — how verb kinds compose into workflow nodes
- [ADR-2026-05-03-locus-of-workflow-definition.md](ADR-2026-05-03-locus-of-workflow-definition.md) — the locus rule a delivered node must satisfy
- [ADR-2026-05-10-native-rich-providers.md](ADR-2026-05-10-native-rich-providers.md) — the provider-shaped-not-family-shaped discipline the reserved-prefix check enforces

## Context

A workflow node is compiled-in source: a generator walks the node directory tree,
emits a manifest, and a registry ingests it into a frozen in-memory array built at
module init. The palette resolver reads only that array, and the executor resolves
an action through the same compiled path.

That makes every new node a code change plus a redeploy. It also means a plugin
that already declares a workflow verb has no way to surface that verb as a visible,
editable canvas node — the verb is invokable but invisible, which contradicts the
locus rule in `ADR-2026-05-03`: a verb with node-surfacing metadata **is** a node.

The question this ADR answers is how an external, signed, versioned source can
deliver a node without handing that source the ability to run arbitrary code in the
host.

## Decision

Deliver a workflow node from an external, signed, versioned source by **extending
the plugin manifest to carry the verb→executable binding plus node-surfacing
metadata**, and by adding a **datastore-backed delivered-node source** that the
palette and executor read alongside the compiled manifest. **Execution stays
in-host; refresh is bounded to the _declarative_ surface.**

### 1. Extend the plugin manifest

Most of what a delivered node needs is already in `015`: `implementedBy`,
`inputSchema` / `outputSchema`, `kind`, `sideEffectClass`, `idempotencyKey`, and
`eventSubscription` are all specified there today. Two changes:

- **Inline the schemas.** `inputSchema` / `outputSchema` may be carried inline as
  JSON Schema 7 rather than only as a path, so a registry blob is self-contained
  and refreshable without fetching the tarball.
- **Add a `node` block** — the palette/frontend metadata: `category`,
  `displayName`, `providerId`, `ports`, `configSchema`, `lifecycleTag`,
  `deprecated`, and `requiredProviders`. **This block is the only genuinely new
  schema in this ADR**; see `015-plugin-spec.md` § "Node-surfacing metadata".

`providers` re-allows entries whose `class` is null — the executable resolves
in-host this phase. Manifest validation gains two checks beyond namespace and
reserved-prefix enforcement: `implementedBy` must reference a declared
`providers.*.id`, and `node.requiredProviders ⊇ [node.providerId]` for
provider-bound nodes.

One source of truth follows: the in-host verb declarations derive from the
manifest, ending the duplication between a hand-maintained verb table and the
manifest that already describes the same verbs.

### 2. A delivered-node source read alongside the compiled manifest

A `delivered_nodes` relation holds one row per (installation scope,
verb-with-a-`node`-block). Each row carries a projected node payload — the
discovered-node shape **minus the executable closure** — plus the plugin id (the
load-bearing handshake that lets the resolver delivery-gate the node), provider id,
category, plugin version, source-mount id, trust tier, and a `lastSeenAt` stale
sentinel.

The palette resolver unions `[...compiled, ...delivered]` **before** its existing
filters. The executor falls back to a delivered-verb lookup on a compiled-registry
miss. **The compiled path does not change** — it remains the executable-bearing
source of truth for in-repo nodes.

### 3. Install and refresh through a reconciler

Two relations mirror the existing agent-registry mount model: a **source mount**
(scope, `sourceClass ∈ {registry, git, local-path}`, config, trust tier,
reconcile TTL) and a **reconcile-event log** with the same shape as the
agent-registry reconcile events.

Reconciliation re-materializes `delivered_nodes` from the source manifest on three
triggers: manual refresh, TTL, and signed webhook. Verbs removed by a new manifest
version drop via the `lastSeenAt`-null sentinel. The reconciler **never throws** —
errors are caught and recorded — and materialization is an idempotent upsert keyed
on `UNIQUE(scope, scopeOwnerId, verbId)`. The trust-policy check runs **before**
materialization.

### 4. Execution stays in-host, and that is the security boundary

`implementedBy` resolves through a **static, in-host registry** mapping a family id
to a vetted in-host executable. **An unknown family id fails closed at
materialize** — the error is recorded and the node never surfaces.

This is the load-bearing property of the whole design: refresh can add or change
verb ids, node metadata, schemas, config panels, and gating, but it **cannot
introduce new executable behavior**. A brand-new provider family still requires an
in-host code change and a redeploy. An external source that is compromised can
therefore mislabel and reshape nodes, but cannot execute anything the host has not
already vetted.

The `invoke(verbId, input, ctx)` contract is the **seam** for two deferred paths —
sandboxed external execution, and a local daemon-proxy path. Both land as a new
implementation of that interface rather than a re-architecture. Credentials resolve
by kind exactly as they do for compiled provider nodes.

### 5. Per-tenant access through an allowlist plus scoped mounts

A per-tenant allowlist (`trustMode`, `allowedSigners`, plugin allow/block lists),
evaluated before materialization, is the access gate. A tenant pinned to
`signed-by-allowlist` materializes only nodes from versions signed by an accepted
signer; a blocked plugin id never materializes regardless of trust mode. A
`system`-scope source is visible to all tenants **subject to each tenant's
allowlist**; a tenant-scope source is private to that tenant. The default trust
posture mirrors the official-kits posture: `signed-by-allowlist` with the
distributor's signing identity seeded.

Enablement reuses the three-field model (`is_official` / auto-publish / sticky
status) at the **node** grain: materialization is the fan-out, a per-tenant node
state record carries `enabled | disabled` plus a reason and an `experimental` tag,
and the operator toggle is **sticky across re-reconciles**. The seed at
materialization time is the manifest's `lifecycleTag`, defaulting to `enabled` when
the manifest omits it.

## Consequences

### Positive

- A node ships without a host code change or redeploy, while the host keeps a hard
  veto over what can execute.
- The verb registry becomes one source of truth; the hand-maintained verb table
  that duplicated manifest content goes away.
- A verb with a `node` block is a visible canvas node, satisfying the locus rule
  instead of contradicting it.
- The reconciler, mount, and event shapes mirror the agent-registry model
  step-for-step, so there is one mount-and-reconcile pattern to learn, not two.

### Negative

- Two node sources exist. Every consumer of the node set must read the union, and a
  consumer that reads only the compiled array is silently incomplete.
- A delivered node's behavior is pinned to a plugin version, so a source that
  reshapes a verb between versions can change a node under a live workflow.
- Manifest validation is now load-bearing for security, not just ergonomics.

### Risks

- **Stale delivery.** A source that stops responding leaves rows whose `lastSeenAt`
  ages without dropping them. The sentinel bounds this, but a long TTL widens the
  window in which a withdrawn node stays on the palette.
- **Fail-closed depends on registry completeness.** An unknown family id failing
  closed is only protective if the in-host registry is the complete set of vetted
  executables. A registry entry added carelessly is the way this design leaks.
- **Trust-check ordering.** Trust policy must run before materialization. Reordering
  it — or adding a second materialization path that skips it — reintroduces the
  hole this ADR closes.

## Alternatives considered

- **Sandboxed external execution now.** Rejected for this phase: it needs its own
  isolation boundary and per-verb resource limits, and it is not required to deliver
  a *node*. The `invoke` seam keeps it available without committing to it.
- **Out-of-process executable loader.** The manifest can carry a class reference,
  but no loader runs it this phase. It is the on-ramp to the sandbox path.
- **Deliver nodes as compiled code via a plugin build step.** Rejected: it puts
  arbitrary publisher code back in the host process, which is the exact property
  this design exists to avoid.

## Explicitly deferred

- Sandboxed external execution backed by a microVM.
- The out-of-process executable loader.
- In-canvas per-verb version pinning — delivered nodes pin implicitly via the
  stored plugin version.
- Collapsing the remaining hand-maintained verb table into a manifest-derived
  artifact; it touches a live plugin path.
- New executable provider families remain an in-host code change plus redeploy.

## Boundary

`shared`, `split: sibling-extensions`.

This file is the canonical, brand-neutral half: the manifest extension, the
`node` block, the reconciler and mount shapes, the fail-closed execution rule, and
the trust posture — everything that is a property of the plugin spec itself.

The platform-side sibling records the extensions that are specific to the
multi-tenant deployment: concrete table and route names, the admin surface, the
per-org enablement records, and the seeded signing identity. It carries
`status: Mirrored` with a `canonical:` pointer at this file.

## Affected documents

- `015-plugin-spec.md` — amended by this ADR: inline schemas, and the new
  "Node-surfacing metadata" section specifying the `node` block plus the two added
  validation rules.
