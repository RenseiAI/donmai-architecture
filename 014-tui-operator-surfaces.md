# 014 — TUI Operator Surfaces

**Status:** Reference (initial draft)
**Last updated:** 2026-05-06
**Boundary:** shared (OSS-canonical; platform extensions live at `rensei-architecture/014-tui-operator-surfaces-platform-extensions.md`)
**Related:** `001-layered-execution-model.md`, `002-provider-base-contract.md`, `004-sandbox-capability-matrix.md`, `011-local-daemon-fleet.md`, `013-orchestrator-and-governor.md`, `ADR-2026-05-06-tui-noun-consolidation.md`.

## Noun model

Per `ADR-2026-05-06-tui-noun-consolidation.md`, the TUI's top-level nouns map to three concept layers:

| Top-level | Concept layer | Owns |
|---|---|---|
| `host` | This machine | Daemon lifecycle (install / status / doctor / drain / update), capacity envelope, local workarea pool, installed providers |
| `fleet` | Other machines + per-project routing | Remote daemon visibility, `fleet route set` for execution-route policy on a project |
| `capacity` | Org-wide capacity config | Org execution providers and pool definitions the routing policy chooses from |

The previous top-levels (`worker`, `machine`, `execution`, `workarea`, top-level `provider`, `route`, `routing`) ship as **hidden deprecated aliases** that print a one-line deprecation notice and forward to the new command. Aliases are removed after one release.

This means TUI primitives in this doc render under their owning top-level: `WorkerRow` and `WorkareaPoolPanel` are surfaced inside `host`; `FleetGrid` and `MachinePivot` are surfaced inside `fleet`; capacity-shaped panels (provider lists, pool config) live under `capacity`. The widgets are unchanged — only the command-tree under which they render moved.

Both binaries (`donmai` and the platform binary) speak the noun model — `donmai host install` is the OSS-binary form; the platform binary's `host install` is the platform form. Composition lives at the cobra-command-factory layer (`afcli.RegisterCommands`), so the noun model is shared across binaries.

## Why this exists

Surfaced during the `tui-components` exploration: the architecture corpus is contract-shaped, but every capability flag, plugin manifest, and workflow event ultimately needs to render to an operator. Without a corpus-level "operator surface" contract, three different TUI consumers (`donmai`, the closed-source TUI client, future SaaS dashboard) reinvent the same display primitives independently, each with subtly different vocabulary. We've already seen drift — `tui-components/theme/worktype.go` hardcodes a closed switch of work types while the architecture treats work types as an extensible registry.

This doc is the contract between the architecture corpus and the TUI consumers. It defines the canonical display vocabulary for architectural concepts: capability flags as chips, scope as pills, attestation as fingerprint chips, audit chains as composed rows.

The dual-surface discipline (every SaaS panel ships a TUI counterpart) is a platform commitment; see the platform-extensions doc for that obligation and its enforcement rules.

## Capability flag → typed chip is the killer pattern

Throughout the corpus, capability flags are typed enums (`'wall-clock' | 'active-cpu' | 'invocation' | 'fixed'`). The TUI corollary is **one chip primitive that renders any typed flag with consistent visual grammar**:

```
┌───────────────────────────────┐
│ ◷ active-cpu                  │   ← chip
│   Billed for active CPU only  │   ← humanLabel from 002
└───────────────────────────────┘
```

The chip widget consumes a `(value, label)` pair. The label comes from the capability's `humanLabel` registry in `002`. This means rendering a SandboxProvider's billing model in `donmai`'s local fleet view, in the closed-source TUI client's multi-machine dashboard, and in the SaaS dashboard's routing intelligence panel **always uses the same chip + same label** — drift is impossible because the source of truth is the architecture corpus, not the TUI code.

The chip widget is generic over the flag's enum type. A toolchain chip (`java=17`) is the same shape as a transport-model chip (`dial-in`). Same generic primitive, different inputs.

## Required primitives

The `tui-components` library v0.2.0 ships these primitives. Each is generic over the architecture concept it renders.

### Provider Base Contract (`002`)

| Primitive | Renders | Used in |
|---|---|---|
| `CapabilityChip` | Typed flag + human label | Every provider view, every capability matrix |
| `ScopePill` | `project | org | tenant | global` indicator | Provider lists, plugin installs, workflow scope |
| `AttestationChip` | Signed/unsigned/verified state with key fingerprint truncation | Plugin install confirmation, audit chain entries, VCS provenance |
| `ProviderHealthDot` | Ready / degraded / unhealthy | Provider lists, machine status |

### Plugin (`015`)

| Primitive | Renders |
|---|---|
| `PluginCard` | Plugin metadata + capability summary + install state |
| `VerbBadge` | `<plugin>.<verb>` chip with side-effect class indicator |
| `PluginCapabilitySummary` | Compact list of declared providers + verb count |

### Sandbox + Workarea (`003`, `004`)

| Primitive | Renders |
|---|---|
| `SandboxCapacityGauge` | Concurrent / max with utilization bar; degenerates to "unlimited" for `maxConcurrent: null` |
| `RegionList` | Compact region chip list with truncation overflow |
| `TransportModelIndicator` | dial-in / dial-out / either with tooltip |
| `WorkareaPoolPanel` | Warm / cold / in-use slots per (repo, toolchain) key |
| `ToolchainChip` | `java=17`, `node=20.x` — kit demand or workarea state |

### Worker + Fleet + AgentRuntime (`013`)

| Primitive | Renders |
|---|---|
| `WorkerRow` | Single worker with status, region, load, billing model |
| `FleetGrid` | Grid of WorkerRows grouped by machine / daemon |
| `MachinePivot` | Multi-machine breakdown (relevant when SaaS aggregates daemons) |
| `AgentRuntimeIndicator` | Which runtime (claude/codex/etc.) drove a session |
| `SubAgentNode` | Compact sub-agent rendering for the operator-surface views |

### Kit (`005`)

| Primitive | Renders |
|---|---|
| `KitDetectResult` | List of kits matched, ordering, conflicts |
| `KitContributionDiff` | What this kit added to the session (commands, MCP, prompt fragments) |

### VCS (`008`)

| Primitive | Renders |
|---|---|
| `MergeStrategyBadge` | three-way / patch-theory / crdt / last-write-wins / cell-merge |
| `ConflictGranularityChip` | line / token / object / cell / none |
| `MergeResultRow` | clean / auto-resolved (with N resolutions) / conflict |

### Layer 6 (Policy, Security, Observability)

| Primitive | Renders |
|---|---|
| `AuditEntry` | Signed event row with attestation + timestamp |
| `AuditChain` | Composed AuditEntry list with chain integrity indicator |
| `PolicyDecisionBanner` | allowed / blocked / needs-approval with override actor + reason |
| `CostPanel` | Per-session / per-issue / per-tenant breakdown with trend; tap `idleCostModel` and `billingModel` per `006` Seam 4 |

### Format helpers

| Helper | Renders |
|---|---|
| `format.CapacityRatio` | "5 / 8" or "5 / ∞" |
| `format.AttestationFingerprint` | "ed25519:abc1234…d4f2" |
| `format.RegionList` | "iad1, +3 more" with hover |
| `format.ToolchainSpec` | Multi-toolchain rendering ("java=17, node=20") |
| `format.HumanLabel<T>` | Generic typed-flag → human-readable string lookup |

## Theme swappability

The legacy `tui-components/theme/palette.go` has hardcoded `var BgPrimary color.Color = …` style declarations. To support theme variants (default, dark, high-contrast) and downstream extensions (multi-tenant brand themes on the platform side), this must move to a swappable `Theme` struct.

```go
type Theme struct {
    BgPrimary    color.Color
    BgSurface    color.Color
    Accent       color.Color
    StatusReady  color.Color
    StatusActive color.Color
    StatusError  color.Color
    Header       Style
    TableHeader  Style
    // ... etc
}

func DefaultTheme() Theme { /* current palette */ }
func DarkTheme() Theme    { /* explicit dark variant */ }
func HighContrastTheme() Theme

// Widgets accept a Theme via option:
spinner := widget.NewSpinner(widget.WithTheme(t))
```

This is a v0.2.0 breaking change for `tui-components` (every widget today reads `theme.Accent` directly). Worth landing in one coordinated push rather than gradually. OSS users get default + dark + high-contrast; platform tenants extend with brand themes (see platform-extensions doc).

## Accessibility

Status already pairs color with Unicode symbol (`tui-components/theme/status.go` has `(label, color, symbol, animate)` tuples). The architecture commitment:

1. **Honor `NO_COLOR` env var** — when set, force symbol-first rendering through `StatusStyle.Symbol` with no color.
2. **Explicit a11y mode** — `DONMAI_A11Y=true` env var or `--a11y` flag forces high-contrast theme + symbol-first rendering + verbose-label-only-no-icon variants.
3. **Document non-color signaling** — every status/work-type/activity primitive's documentation states the non-color disambiguator (Unicode symbol).
4. **Screen-reader-friendly labels** — every primitive declares an `accessibleLabel: string` field that screen readers can consume.

For regulated environments (banking, defense), a11y mode may be a tenant-policy default. The architecture admits this; the policy layer enforces it.

## Open registries (status, work type, activity)

The legacy `tui-components/theme/` hardcodes closed switch statements for status, work type, and activity. The architecture introduces new lifecycle states (workarea acquire/release, sandbox warming, kit-applying); switches don't extend.

The fix: **register-style API**. Plugins and architecture docs add new states by registering them with the theme:

```go
// Plugin registration
themeRegistry.RegisterStatus(StatusEntry{
    Kind:    "workarea-warming",
    Label:   "Warming pool",
    Symbol:  "↻",
    Color:   theme.StatusInfo,
    Animate: true,
})
```

Generic states ship in `tui-components` core; domain-specific states ship via plugins/kits. The `theme.GetStatusStyle(kind)` lookup queries the registry; unknown states get a fallback rendering with a "?" symbol and a registration-warning emit.

Same shape for work types and activity types. Closes the drift described in the `tui-components` exploration ("`theme/worktype.go` hardcodes work types in the OSS shared lib, but the architecture treats work-type as orchestrator-internal").

## OSS vs SaaS responsibilities

| Concern | OSS | SaaS |
|---|---|---|
| `tui-components` library (Go, Charm v2) | ✅ owns | consumes |
| Capability primitives + chip widget | ✅ ships | consumes |
| Theme system + swap mechanism | ✅ ships | extends with tenant brand themes |
| Default + dark + high-contrast themes | ✅ ships | inherits |
| `donmai` (OSS binary surface) | ✅ ships | consumed via `afcli.RegisterCommands` |
| Architecture-concept registries (status, worktype, activity) | ✅ ships generic | extends domain-specific |

The OSS layer ships a complete TUI for the local-daemon flow (per `011`). The platform extensions doc carries the SaaS-distinct surfaces — multi-tenant brand theme administration, the Live capacity contract, the dual-surface discipline obligation, the routing-intelligence/audit-chain TUI counterparts.

## Open questions

1. **React ↔ TUI primitive parity.** Should the SaaS dashboard's React components share a name and shape with `tui-components`' Go widgets (e.g., `<CapabilityChip />` and `widget.NewCapabilityChip()`)? Default: yes — coupled API surfaces with separate implementations. Two-way prop-shape parity catches drift at code review.
2. **Theme manifest format.** Tenants will want to author themes in YAML/JSON (not Go code). Schema and registration mechanism live in a future ADR.
3. **Animation discipline.** Bubble Tea v2 has rich animation support. Some indicators benefit from animation (warming, in-flight); some shouldn't (terminal status). Worth a per-primitive declared "animate?" attribute.
4. **Capability chip color discipline.** A `'wall-clock'` billing chip and a `'metered'` idle-cost-model chip may need distinct colors to disambiguate at a glance. Theme registry encodes this.

These ship as defaults-and-document in v0.2.0; ADRs lock as we get user feedback.
