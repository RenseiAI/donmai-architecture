---
# ADR-2026-05-07-daemon-http-control-api

**Status:** Accepted

**Date:** 2026-05-07

**Authors:** Wave 9 coordinator (Claude Opus 4.7), confirmed by mark@donmai.dev

## Context

The four daemon-targeted operator surfaces — Provider, Kit, Workarea, Routing
— ship today as commands in the closed-source `closed-source-tui` binary
(`cmd/rensei/{provider,kit,workarea,routing}.go`) backed by HTTP clients in
`closed-source-tui/internal/api/{provider,kit,workarea,routing}_*.go` that reference
`/v1/providers`, `/v1/kits`, `/v1/workareas`, and `/v1/routing/*`. Those
endpoints are not implemented anywhere — neither on the SaaS platform nor on
the local `donmai` daemon — so the commands have always returned misleading
errors.

Mapping the four surfaces against `001-layered-execution-model.md`:

| Surface | Layer | Concern |
|---|---|---|
| Provider | Layer 1–3 (Provider Base Contract → Execution) | Per-host Provider Family registry |
| Kit | Layer 4 (Composition) | Locally installed kit manifests |
| Workarea | Layer 3 (Execution → Workarea) | Pool members + on-disk archives |
| Routing | Layer 3 (Execution → cross-provider scheduler) | Effective routing config + per-session explain |

None has a platform-specific concern. Per the boundary discipline in
`001-layered-execution-model.md` § "The OSS↔Platform contract"
and the closed-source TUI's boundary guidance:

> Generic Donmai commands … are implemented in `donmai` and
> imported here via `afcli.RegisterCommands`. **If a generic command is
> missing, contribute it upstream to donmai first**, then it
> automatically appears in the downstream binary.

Today's placement is a pre-existing boundary violation. This ADR records the
canonical shape of the daemon's HTTP control API and the
donmai-resident command surface that consumes it. Wave 9 (planned
in `runs/WAVE9_DAEMON_OSS_BOUNDARY_MIGRATION_PLAN.md`) implements it.

## Decision

The local `donmai` daemon owns an HTTP control API at the canonical namespace
`/api/daemon/*`. The four migrating surfaces' endpoints, types, client
methods, cobra commands, and renderers move from closed-source-tui to public
donmai packages. The rensei binary picks them up automatically via
the existing `afcli.RegisterCommands` seam.

Five sub-decisions:

### D1 — URL namespace: `/api/daemon/*`, not `/v1/*`

The daemon already serves seven `/api/daemon/*` routes (status, stats, pause,
resume, stop, drain, update, capacity, pool/*, sessions, sessions/<id>,
heartbeat, doctor — see `donmai/daemon/server.go:95-114`). The
four new surfaces extend the same namespace:

```
GET    /api/daemon/providers
GET    /api/daemon/providers/<id>

GET    /api/daemon/kits
GET    /api/daemon/kits/<id>
GET    /api/daemon/kits/<id>/verify-signature
POST   /api/daemon/kits/<id>/install
POST   /api/daemon/kits/<id>/enable
POST   /api/daemon/kits/<id>/disable

GET    /api/daemon/kit-sources
POST   /api/daemon/kit-sources/<name>/enable
POST   /api/daemon/kit-sources/<name>/disable

GET    /api/daemon/workareas
GET    /api/daemon/workareas/<id>
POST   /api/daemon/workareas/<archiveID>/restore
GET    /api/daemon/workareas/<archiveIDA>/diff/<archiveIDB>

GET    /api/daemon/routing/config
GET    /api/daemon/routing/explain/<sessionID>
```

The `/v1/*` paths the closed-source-tui clients reference today are retired: they
were aspirational pointers to a SaaS platform contract that never landed and
have no place in a localhost daemon API. All client code paths in the
migrated `afclient` methods MUST hit `/api/daemon/*`.

### D2 — Auth model: localhost-only, no bearer

The daemon binds to `127.0.0.1` exclusively. The `Authorization: Bearer …`
header is silently ignored by the daemon and MUST NOT be sent by the
afclient methods that target it. Sending a platform user-JWT to a localhost
service expands the trust boundary for no gain.

The closed-source-tui fix from commit `10275ba` (host: target the local daemon, not
cfg.APIBaseURL) already encodes this convention by routing the four
commands through a separate `daemonClient` rather than the platform-aware
authenticated client. afcli inherits that separation: `afclient.Client`'s
new daemon-targeted methods take a `daemonBaseURL` (defaulting to
`http://127.0.0.1:7734`) and never attach bearer headers.

### D3 — Public package surface in donmai

Per `donmai/AGENTS.md` §"Package Architecture", public packages
expose what downstream consumers (rensei) compose. Wave 9 lands:

| Concern | Package | New file(s) |
|---|---|---|
| Wire types | `afclient/` | `provider_types.go`, `kit_types.go`, `workarea_types.go`, `routing_types.go` |
| HTTP client methods | `afclient/` | extend `Client` with `ListProviders`, `GetProvider`, `ListKits`, `GetKit`, `InstallKit`, `EnableKit`, `DisableKit`, `VerifyKitSignature`, `ListKitSources`, `EnableKitSource`, `DisableKitSource`, `ListWorkareas`, `GetWorkarea`, `RestoreWorkarea`, `DiffWorkareas`, `GetRoutingConfig`, `ExplainRouting` |
| Cobra commands | `afcli/` | `provider.go`, `kit.go`, `workarea.go`, `routing.go` (plus `_test.go` per file) |
| Renderers | `afview/` (new public package in donmai) | `afview/provider/`, `afview/kit/`, `afview/workarea/`, `afview/routing/` |

**Renderers go in a new public `afview/` package in donmai** —
not `internal/views/`, not `tui-components`. The reasoning:

- `internal/views/` (option a) blocks closed-source-tui from importing the canonical
  renderer; rensei would have to fork its own copy. That violates the
  "soldered-in" principle and re-introduces the drift Wave 9 is fixing.
- `tui-components` (option mid) hosts low-level, surface-agnostic primitives
  (theme, format, widgets). Surface-specific composed renderers
  ("ProviderListView", "KitDetailPanel") are not theme primitives; mixing
  them dilutes the `tui-components` boundary and makes its release cadence
  load-bearing for unrelated changes.
- `afview/` (option b, chosen) sits beside `afclient`/`afcli`/`worker` as a
  peer public package. Renderers depend on `afclient` types and on
  `tui-components` primitives; closed-source-tui imports `afview/` for the
  authoritative composed views; tui-components stays a pure primitive
  layer.

`afview/` follows the same package-naming discipline as the rest of
donmai: lowercase single-word sub-packages
(`afview/provider/`, `afview/kit/`, etc.), exported types
(`afview/provider.ListView`, `afview/kit.DetailModel`).

### D4 — Daemon-side data sources

What's already in-process in the daemon vs what each Track A vertical adds:

| Surface | Existing | Gap |
|---|---|---|
| Providers | `runner.Registry` (in-process AgentRuntime registry: claude/codex/ollama/opencode/gemini/amp/stub) | Surface as HTTP. Other Provider Families (Sandbox, Workarea, VCS, IssueTracker, Deployment, AgentRegistry, Kit) return empty in this wave with `family: agent_runtime` set on each populated entry. The endpoint MUST emit a top-level `partialCoverage: true` flag and a `coveredFamilies: ["agent-runtime"]` array so consumers can render the "other families coming" caveat without sniffing for emptiness. |
| Kits | None | Minimal in-process Kit registry that scans `~/.rensei/kits/*.kit.toml` per `005-kit-manifest-spec.md` § "Registry sources" item 1 ("Local manifests"). Empty if no kits installed. Scan path MAY be overridden by `daemon.yaml` key `kit.scanPaths: [<path>, …]`; default is `["~/.rensei/kits"]`. |
| Workareas | Daemon's pool (warming/ready/acquired/releasing) + archive directory under `~/.rensei/workareas/` | Surface pool + archive listing, per-id inspect, archive restore (recreate a workarea from an archived snapshot), and diff (filesystem-level delta between two archived workareas). Full surface ships this wave per D4a below. |
| Routing | Internal sandbox+workarea routing decisions per session | Surface effective config (provider precedence, capability filters) + per-session explain (which provider+workarea were chosen and why). Read-only this wave. |

### D4a — Workarea full surface

The full Layer-3 Workarea operator surface ships this wave. Endpoint
contracts:

```
GET  /api/daemon/workareas
     → 200 { active: WorkareaSummary[], archived: WorkareaSummary[] }
       active[]   : pool members (state ∈ warming|ready|acquired|releasing)
       archived[] : snapshots on disk (id, sessionId, createdAt, sizeBytes,
                    sourceProvider, capabilities, disposition)

GET  /api/daemon/workareas/<id>
     → 200 { workarea: { kind: "active"|"archived", ...metadata, manifest: {...} } }
     The id form accepts either a live pool member id or an archive id;
     the response disambiguates via the `kind` field.

POST /api/daemon/workareas/<archiveID>/restore
     body  : { reason?: string, intoSessionId?: string }
     → 201 { workarea: { id, kind: "active", state: "ready", ... } }
     Materialises the archive into a new pool member. The new id is
     distinct from the archive id (archives are immutable). Conflicts
     (intoSessionId already in use) → 409. Pool saturation → 503 with
     Retry-After header naming the soonest expected pool slot.

GET  /api/daemon/workareas/<idA>/diff/<idB>
     → 200 { diff: { entries: [...] } }              when entries ≤ threshold
     → 200 application/x-ndjson                       when entries > threshold
       entries[] : { path, status, sizeA?, sizeB?, modeA?, modeB?, hashA?, hashB? }
       status    : "added" | "removed" | "modified"
     Both ids MUST resolve to archives (diffing live members is out of
     scope — they mutate during the diff and produce torn reads). Diff
     scope: filesystem tree under the workarea root, excluding the
     well-known `.rensei/` daemon-private subtree. Hashes are SHA-256
     over file contents; missing for directories. Symlinks compared by
     target string. Diff output MUST be deterministic across runs (sort
     entries by path).
```

The streaming threshold is configurable via `daemon.yaml` key
`workarea.diffStreamingThreshold` (default `1000`). At or below the
threshold, the response is a single JSON envelope with `Content-Type:
application/json`; above the threshold, the response is NDJSON
(`Content-Type: application/x-ndjson`) with one `entry` JSON object per
line and a final `{"summary": {...}}` line carrying counts. Both shapes
emit the same per-entry structure; consumers MUST handle both via
`Content-Type` discrimination.

### D5 — Architecture corpus updates (this wave)

Coordinator updates these files in the same commit set as this ADR, before
dispatching Track A sub-agents:

- `011-local-daemon-fleet.md` — adds a new `## HTTP Control API` section
  enumerating all `/api/daemon/*` endpoints (the existing seven plus the
  new four families) and documenting the localhost-only auth model from
  D2.
- `005-kit-manifest-spec.md` — adds a "Daemon kit registry" subsection
  describing the scan path (`~/.rensei/kits/*.kit.toml`, configurable via
  `daemon.yaml`) and the `/api/daemon/kits*` endpoint contract.
- `004-sandbox-capability-matrix.md` — adds a forward reference to
  `/api/daemon/routing/explain/<sessionID>` as the operator-facing surface
  for the cross-provider scheduler's per-session decisions.

### D6 — Kit install source wire shape

<!-- boundary: OSS-only -->
<!-- Wave 12 amendment (2026-05-07). Anchors KitInstallSource +
     trustOverride: "allowed-this-once" wire shape consumed by
     POST /api/daemon/kits/<id>/install. Audit reference:
     runs/WAVE12_PHASE2_AUDIT.md § 1.3, § 2.2, Q-audit-1. -->

The kit install endpoint accepts an optional `source` block selecting
where the daemon should fetch the kit from at install time, plus an
optional `trustOverride` field that bypasses the configured trust gate
for a single request:

```jsonc
// POST /api/daemon/kits/<id>/install
{
  "version": "1.2.3",                              // optional pin
  "source": {
    "kind": "git" | "tessl" | "agentskills",      // Wave 12 ships "git" only
    "url": "https://github.com/rensei/kit-foo",
    "ref": "v1.2.3",                              // optional; default HEAD
    "manifestPath": "kits/foo.kit.toml"           // optional; default = scan
  },
  "trustOverride": "allowed-this-once"            // optional; see below
}
```

`source.kind` follows the federation order from
`005-kit-manifest-spec.md` § "Registry sources". Wave 12 wires only
`"git"`; `"tessl"` and `"agentskills"` return 501 with an
`ErrKitSourceFederationUnimplemented` body. The federation list returned
by `/api/daemon/kit-sources` continues to surface the descriptors so
operators see the full federation order.

`trustOverride: "allowed-this-once"` bypasses the trust gate for a
single install when the configured trust mode (`signed-by-allowlist` or
`attested`) would otherwise reject an unsigned or
signed-but-unverified kit. The override is **single-shot** — not
persisted, not honored on subsequent re-installs. Each override is
**audit-logged** via `slog.Info` with structured fields `kitId`,
`signerId` (best-effort; populated from the verifier output or the
manifest's `authorIdentity` when unsigned), `actor` (from
`daemon.yaml: trust.actor`, falling back to `uid:<os.Getuid()>` per
the Q-audit-2 resolution), and `at` (RFC3339 UTC timestamp). The
override semantic mirrors the `trustOverride` field from
`002-provider-base-contract.md` § "Signing and trust".

Trust-gate response when the gate rejects WITHOUT a trustOverride:

```jsonc
// 403 Forbidden
{
  "error": "kit install: trust gate rejected (signed-by-allowlist requires verified signature)",
  "kitId": "<id>",
  "trust": "signed-unverified"
}
```

### Open questions resolved

This ADR resolves the four open questions from the Wave 9 plan:

| Q | Resolution |
|---|---|
| Q1 — renderer placement (a) `internal/views/` vs (b) public `afview/` | **(b)** — public `afview/` package in donmai. See D3. |
| Q2 — `tui-components` vs new `afview/` | **`afview/`**. tui-components stays primitives; afview hosts composed surface-specific renderers. See D3 reasoning. |
| Q3 — kit registry scan path | **`~/.rensei/kits/*.kit.toml`** (default), configurable via `daemon.yaml` key `kit.scanPaths`. See D4. |
| Q4 — diff streaming threshold | **Default 1000 entries** before switching to NDJSON, configurable via `daemon.yaml` key `workarea.diffStreamingThreshold`. See D4a. |

## Consequences

### Positive

- One canonical home for OSS-execution-layer operator commands. The two
  binaries no longer fork on Provider/Kit/Workarea/Routing.
- The rensei binary's command surface for these four areas comes for free
  via `afcli.RegisterCommands` — no closed-source-tui-resident copy of types,
  commands, or renderers.
- The daemon's HTTP API lives at one canonical namespace
  (`/api/daemon/*`), matching the pre-existing seven endpoints. Operators
  and integration writers learn one URL prefix.
- Wave-9 architecture-first discipline: the contract is locked before
  parallel sub-agent code lands, so each vertical compiles against a
  stable target.

### Negative

- Two repos must move in lockstep this wave: donmai ships the
  surface; closed-source-tui simultaneously bumps its dep and deletes its old
  copies. A botched bump leaves closed-source-tui unable to build. Mitigation:
  Track B is sequential after Track A is green; closed-source-tui's CI must run
  full `go test -race ./...` before the dep bump merges.
- The `afview/` package is new and joins `afclient`/`afcli`/`worker` as a
  fourth public donmai package. Each new public package is a
  small permanent maintenance commitment (godoc, semver discipline). We
  judge the boundary clarity worth the cost.
- The Provider HTTP endpoint's `partialCoverage: true` flag is a
  permanent honesty marker until the other 7 Provider Families gain
  registries. UI must render the caveat correctly forever, not "until
  parity ships." (See `partialCoverage` doc string in `provider_types.go`
  for the wire-level contract.)

### Risks

- The Workarea diff implementation must be deterministic and streaming
  for large archives. Off-by-one on the streaming threshold or
  non-deterministic walk order will cause flaky integration tests
  downstream. Mitigation: A3's tests pin both the cutoff and the walk
  order via fixtures.
- Restore of a corrupted archive must fail clearly (400 with reason)
  rather than half-materialising a broken pool member. Mitigation: A3
  tests cover the corrupted-archive path explicitly.
- Renderer churn: lifting renderers from `closed-source-tui/internal/views/` to
  `donmai/afview/` may surface previously-internal interface
  shapes (model state, msg types) that the current renderer code relied
  on. Mitigation: Track A sub-agents do the lift surface-by-surface and
  flag any tui-components changes back through coordinator review before
  cross-repo writes.

## Alternatives considered

### Alternative 1 — Implement on the SaaS platform instead

Reject. Provider/Kit/Workarea/Routing introspection is OSS-execution-layer
plumbing (`001-layered-execution-model.md` § "The OSS execution layer never
ships an interface whose only working implementation lives downstream in
the SaaS product."). Putting the canonical surface on the SaaS platform
would leave OSS-only users without a working command and force the daemon
to phone home for state it owns.

### Alternative 2 — Keep `/v1/*` namespace

Reject. The daemon already commits to `/api/daemon/*` for its existing
seven routes. Splitting the daemon's HTTP API across two namespaces
(`/api/daemon/*` for lifecycle, `/v1/*` for inspection) confuses
integration writers and bloats the routing table for no benefit. The
`/v1/*` path was never attested anywhere; deprecating it costs nothing.

### Alternative 3 — Renderers in `internal/views/` (option a)

Reject. Rejected on the boundary clarity grounds in D3: an internal
package forces closed-source-tui to fork its own renderers, re-introducing the
exact drift this wave fixes.

### Alternative 4 — Renderers in `tui-components`

Reject. tui-components is correctly scoped to surface-agnostic primitives
(theme, format, widgets). Composed surface-specific renderers
("ProviderListView") have a different release cadence than primitive
widgets. Mixing the two would force tui-components into lockstep releases
with afclient changes; that's a worse boundary than the new `afview/`
package.

### Alternative 5 — Daemon delegates to the platform for Routing

Considered for the Routing surface specifically, since Thompson-Sampling
state could plausibly be owned by a SaaS service. Rejected because the
local daemon is the entity that *makes* per-session routing decisions —
the explain endpoint must source from the daemon's in-process trace
buffer to be useful at all. The SaaS dashboard remains a valid second
consumer of the same data; nothing in this ADR precludes that.

## Affected documents

- `001-layered-execution-model.md` — § "The OSS execution layer never
  ships an interface whose only working implementation lives downstream
  in the SaaS product." This ADR is a concrete instance of the rule.
- `004-sandbox-capability-matrix.md` — adds forward reference to
  `/api/daemon/routing/explain/<sessionID>` per D5.
- `005-kit-manifest-spec.md` — adds "Daemon kit registry" subsection per
  D5.
- `011-local-daemon-fleet.md` — adds `## HTTP Control API` section per
  D5.

## Affected work items

- Wave 9 plan: `runs/WAVE9_DAEMON_OSS_BOUNDARY_MIGRATION_PLAN.md`.
- Tracks Track A (4 sub-agents in donmai), Track B (closed-source-tui
  cleanup), Track C (rensei-smokes coverage). Phase numbering and
  dispatch order are owned by the coordinator session.
- Future wave: per-Provider-Family registries (Sandbox, Workarea, VCS,
  IssueTracker, Deployment, AgentRegistry, Kit). Tracked as the lifting of
  `partialCoverage: true` from the `/api/daemon/providers` response. No
  Linear ticket assigned yet; will be opened when a sub-agent or
  customer demand crosses the threshold.

## Implementation notes

- donmai sub-agents extend `daemon/server.go:register` (one new
  `mux.HandleFunc` per route) and add per-surface handler files
  (`daemon/handle_provider.go`, `daemon/handle_kit.go`,
  `daemon/handle_workarea.go`, `daemon/handle_routing.go`).
- afclient methods extend the existing `DaemonClient` struct in
  `afclient/daemon_client.go` — the standalone daemon-targeted client
  that already serves the seven lifecycle routes. Each new surface lands
  in its own file (`provider_client.go`, `kit_client.go`,
  `workarea_client.go`, `routing_client.go`) following the same
  `c.get(...)` / `c.post(...)` private helper pattern. No bearer auth on
  these calls; `DaemonClient` does not attach an `Authorization` header.
- Renderers in `afview/<surface>/` accept the corresponding `afclient`
  type and emit a `tea.Model` plus a plain-text fallback for `--plain`
  output mode. The fallback is what `rensei-smokes` integration tests
  pin against; the Bubble Tea model is what TTY users see.
- Tests live at three layers: handler-level unit tests in
  `daemon/handle_*_test.go`, client-level httptest integration tests in
  `afclient/<surface>_client_test.go`, command-level tests in
  `afcli/<surface>_test.go`. Each Track A sub-agent ships all three for
  their surface.
- The streaming-NDJSON workarea diff path is the only non-trivial
  HTTP-protocol piece. A3 sub-agent should implement it as a generator
  that emits one entry at a time and switches Content-Type at the
  threshold; tests should pin both branches.
