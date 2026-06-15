---
status: Accepted
date: 2026-06-14
boundary: OSS-only
---

# ADR-2026-06-14-provider-base-contract-go-native

**Status:** Accepted
**Date:** 2026-06-14
**Accepted:** 2026-06-14 (lands with the affected `002` edit in this commit).
**Boundary:** OSS-only (the base contract is OSS-execution-layer plumbing with a working OSS-shipped implementation; no part requires the SaaS control plane). `002` has no `BOUNDARY-SYNC` region and no `rensei-architecture` mirror, so this is a clean OSS-only edit — no paired PR, no boundary-sync check.
**Authors:** SDK foundation workstream (Opus 4.8)

## Context

`002-provider-base-contract.md` defines the unified base contract every plugin family extends — discovery (manifest), capability declaration, scope resolution, signing/trust, and the `activate`/`deactivate`/`health` lifecycle — in **TypeScript** (`Provider<F>`, `ProviderManifest<F>`, `ProviderCapabilities<F>`, `ProviderScope`, `ProviderSignature`). That is the contract a third-party provider SDK builds on.

The execution layer, however, has migrated to Go. The two LLM-layer families that the two-axis decomposition (`ADR-2026-06-06`) declared READY — the **harness** family (`agent.HarnessProvider` + `HarnessManifest`) and the **model-endpoint** family (`agent.ModelEndpointProvider` + `ModelEndpointManifest`) — already ship as Go types in `donmai/agent/`. But they share **no Go-native base**: each manifest independently declares a `Family` field, and there is no Go realization of the `002` generic `Provider<F>`, the `ProviderScope` / `ProviderSignature` shapes, the 9-value `ProviderFamily` enum, or the `activate`/`deactivate`/`health` lifecycle. A third-party Go provider SDK therefore has nothing to build on — it would have to reverse-engineer the base shape from the two axis manifests.

This is contract-FREEZING work: the SDK base contract is the thing every future provider family compiles against, so its Go shape must be landed deliberately, grounded in `002`, and made ADDITIVE so the closed-source TUI consumer's embed (`afcli.RegisterCommands`) keeps compiling against `donmai` unchanged.

## Decision

Land the Go-native realization of the `002` base provider contract in the `donmai/agent` package (`agent/base.go`), additive, and make the two freezing axes formally extend it at the manifest level. Six concrete pieces, mapping 1:1 onto `002`:

1. **`ProviderFamily` (the 9-value roster).** `ProviderFamily` is a type alias of the existing `agent.Family` (so the two never diverge; `FamilyHarness == "agent-runtime"` byte-identical to `002`). The four peer families `002` names but that `wire.go` had not yet declared (`workarea`, `deployment`, `agent-registry`, `kit`) are added as reserved discriminants, completing the 9-family enum. `KnownProviderFamilies()` and `IsKnownProviderFamily()` make the roster queryable.

2. **`ProviderManifest[F]` (generic base manifest).** A Go generic parameterized by the family-typed capabilities struct `F`. It embeds `ProviderBase` — the family-agnostic discovery + trust header (`apiVersion`, `family`, `id`, `version`, `name`, origin metadata, `scope`, `signature`, `stability`, tooling hints) — and carries `CapabilitiesDeclared F` (the up-front, pre-load capability declaration). A new SDK-authored family targets `ProviderManifest[F]` directly.

3. **`ProviderScope` + `ScopeSelector`.** The four-level scope (`project | org | tenant | global`, most-specific wins) with the conjunctive-across / disjunctive-within selector. `ScopeSpecificity()` ranks for the "most-specific wins" rule; `ValidateScope()` enforces `002`'s rule 4 (a non-global level must carry a non-empty selector) and returns the new `ErrInvalidScope` sentinel.

4. **`ProviderSignature` + `ProviderHealth`.** The signing/trust descriptor (`signer`, `publicKey`, `algorithm`, `signatureValue`, `manifestHash`, `attestedAt`, optional `attestations`) and the `ready | degraded | unhealthy` health verdict, with `HealthReadyVerdict()` as the stub-by-default for providers with no liveness signal. Signature lands as the SHAPE only — a manifest may carry a `nil` signature today (the OSS permissive default; signing is deferred for the two-axis manifests per `ADR-2026-06-06`).

5. **`BaseProvider` lifecycle interface + `NoopLifecycle` helper.** `BaseProvider` extends `BaseManifest` with idempotent `Activate`/`Deactivate` and an optional `Health`. `NoopLifecycle` is an embeddable zero-value helper giving a new provider the base lifecycle for free (idempotent no-ops + always-ready Health).

6. **Both axes formally extend the base, additively.** `HarnessManifest` and `ModelEndpointManifest` each gain a computed `Base()` method projecting onto `ProviderBase`, so both satisfy the new `BaseManifest` interface (compile-time asserted) WITHOUT a field-layout or wire change. The base LIFECYCLE is bridged — not bolted onto the existing interfaces — via `BaseProviderFromHarness` (mapping the legacy `Provider.Shutdown` onto the base `Deactivate`) and `BaseProviderFromEndpoint`. Widening `HarnessProvider` or `ModelEndpointProvider` with the base methods would break every existing implementor, so the extension is realized through the manifest projection + the bridge adapters.

Per `002` Decision 3 ("Stay on `v1`"), the contract is enriched **in place**: every manifest's `apiVersion` is `rensei.dev/v1`; there is no `v2` bump and no migration guide.

A load-bearing parity gate (`matrix/base_parity_test.go`, run `GOWORK=off`) asserts that **every shipped manifest across both freezing axes embeds the base contract** and projects a well-formed header (correct `apiVersion`, a known 9-family discriminant, a valid scope, a known stability tier), and that the bridge adapters expose an idempotent lifecycle. A future axis manifest that forgets the base projection fails this gate.

## Consequences

### Positive

- **The third-party provider SDK has a Go base to build on.** `ProviderManifest[F]` + `BaseProvider` + `NoopLifecycle` are the surface a new Go-native family targets; it inherits discovery, scope, signing, and lifecycle for free.
- **The two freezing axes are unified under one base** without any wire or read-site change — proven by the compile-time `BaseManifest` assertions and the parity gate.
- **Additive and back-compatible.** The closed-source TUI consumer's embed compiles unchanged (it consumes only existing `agent` symbols — `AuthBYOK`/`AuthMetered`/`AuthShared` and `runner/access`); no embed-surface symbol changed signature.
- **The 9-family roster is queryable in Go**, closing the gap where `wire.go` declared only five of the nine `002` families.

### Negative

- **A second source for the family-agnostic header.** `HarnessManifest.Base()` and `ModelEndpointManifest.Base()` are projections, not the storage of record — a manifest's header lives in its own fields and is re-projected on each `Base()` call. We accept the small projection layer in exchange for zero wire churn; the parity gate keeps the projection honest.
- **Lifecycle is bridged, not native, for the existing axes.** The harness/endpoint providers do not implement `BaseProvider` directly; the host administers them through `BaseProviderFromHarness`/`BaseProviderFromEndpoint`. A future cosmetic phase could make a harness implement `BaseProvider` natively once the legacy `Provider.Shutdown` name retires.

### Risks

- **Projection drift.** A manifest could project a `Base()` that disagrees with its own fields. Mitigated by the parity gate asserting every shipped manifest's projected header is well-formed and family-correct.
- **Signature is shape-only today.** Manifests carry `nil` signatures (permissive default). Until the `ADR-2026-06-06` signing phase lands, the trust verification path is not exercised end-to-end; the shape is frozen so the later phase drops in without a contract change.

## Alternatives considered

- **Widen `HarnessProvider` / `ModelEndpointProvider` with `Activate`/`Deactivate`/`Health` directly.** Rejected: it breaks every existing harness and endpoint implementor (none have those methods) and would force a lock-step churn across `provider/harness/*` and `provider/endpoint/*` — the opposite of the additive constraint. The bridge adapters achieve the same "families extend the base lifecycle" guarantee additively.
- **A non-generic `interface{}`-keyed base manifest.** Rejected: it loses the family-typed capability declaration `002` is built on (the scheduler reasons about typed capability flags). Go generics (`ProviderManifest[F]`) preserve the `Provider<F>` shape `002` specifies.
- **A standalone `sdk` package separate from `agent`.** Rejected for this wave: the two freezing axes and their `Family` vocabulary already live in `agent`; placing the base there keeps the contract co-located with the families that extend it and avoids an import cycle (`agent` is the lowest layer). A dedicated SDK-facade package can re-export from `agent` later without moving the contract.

## Affected documents

- `002-provider-base-contract.md` — § "The base interface" gains a short **Go-native realization** note: the base contract is now landed Go-native in `donmai/agent` (`ProviderManifest[F]`, `ProviderScope`, `ProviderSignature`, `ProviderHealth`, `BaseProvider`, the 9-family `ProviderFamily` roster), the two freezing axes extend it via a `Base()` manifest projection + lifecycle bridge, and `apiVersion` stays `rensei.dev/v1`. Landed in the same commit as this ADR's `Accepted` flip.

This ADR does NOT amend a `BOUNDARY-SYNC` synchronized section, so no paired PR or `check-boundary-sync.sh` run is required for it.

## Affected work items

Platform program W2 workstream `w2-sdk-base-contract` (B1). The freeze-sequencing decision (which axes are READY vs deferred) is the companion `ADR-2026-06-14-sdk-axis-readiness-and-freeze-sequencing.md`.

## Implementation notes

- Base contract: `donmai/agent/base.go`. Axis `Base()` projections: `agent/harness.go`, `agent/endpoint.go`. New sentinel: `agent/errors.go::ErrInvalidScope`.
- Parity gate: `donmai/matrix/base_parity_test.go` (`GOWORK=off go test -race ./matrix/...`). Base-type unit tests: `donmai/agent/base_test.go`.
- The contract is enriched in place on `rensei.dev/v1` (no `v2`) per `002` Decision 3.
