---
status: Accepted
date: 2026-06-14
boundary: shared
split: synchronized-mirror
---

# ADR-2026-06-14-sdk-axis-readiness-and-freeze-sequencing

**Status:** Accepted
**Date:** 2026-06-14
**Accepted:** 2026-06-14
**Boundary:** shared (OSS-canonical here; `status: Mirrored` stub in `rensei-architecture/ADR-2026-06-14-sdk-axis-readiness-and-freeze-sequencing.md`)
**Authors:** SDK foundation workstream (Opus 4.8)

## Context

Before opening a SaaS preview and shipping a **third-party provider SDK**, the platform needs a deliberate decision about WHICH provider-family axes are ready to **freeze** (their contract becomes the thing third parties build against, and breaking it then costs a deprecation cycle) versus which stay **deferred** behind their own per-axis ADRs. Freezing an axis whose contract is still moving — or whose OSS-shipped implementation doesn't exist — would strand third-party authors against a contract that changes under them, violating `001`'s "the OSS layer never ships an interface whose only working implementation lives downstream" commitment.

The base contract itself is now Go-native (`ADR-2026-06-14-provider-base-contract-go-native`, OSS-only), so the question is purely: against that frozen base, which family axes does the SDK expose first?

The two-axis decomposition (`ADR-2026-06-06`) already established the LLM layer's two families (harness + model-endpoint), their Go manifests, the capability-matrix codegen, and the parity gate. The platform program plan committed to building the 4-axis loader with **harness + model-endpoint** first-class now and **sandbox + issue-tracker** made self-serve via the loader bridge, with **vcs + kit** explicitly deferred behind per-axis ADRs. This ADR records the readiness verdict per axis and the freeze sequencing so the SDK exposes axes in dependency order.

## Decision

Adopt a four-tier readiness verdict per provider-family axis and a freeze sequence that exposes axes in that order. An axis is **READY to freeze** only when (a) its contract is landed against the Go-native base, (b) it has at least one working OSS-shipped implementation, and (c) a parity gate proves shipped implementations honor the contract.

### Readiness verdict (2026-06-14)

| Axis (family) | Verdict | Why |
|---|---|---|
| **harness** (`agent-runtime`) | **READY — freeze now** | Go manifest (`HarnessManifest` + Drive surface), 8 OSS-shipped implementations, capability-matrix codegen + parity gate (`ADR-2026-06-06`), and now a `Base()` projection onto the Go-native base (`ADR-2026-06-14-provider-base-contract-go-native`). The base-parity gate asserts every harness manifest embeds the base. |
| **model-endpoint** | **READY — freeze now** | Go manifest (`ModelEndpointManifest`: hosts × auth × cost × protocol + models), 5 OSS-shipped company endpoints, the same matrix codegen + cell-validity parity, and a `Base()` projection onto the base. The thin 9th family's sole verb (`Resolve`) is stable. |
| **sandbox** | **NEXT — loader-bridge self-serve (W3), freeze after**  | A working OSS-shipped local implementation exists, but the registry is a hardcoded array, not manifest-driven `register()`. Freeze AFTER the W3 loader bridge converts it to manifest-based discovery against the base. |
| **issue-tracker** | **NEXT — loader-bridge self-serve (W3), freeze after** | Same shape as sandbox: working Linear OSS impl, hardcoded-array registry. Convert to `register()` + per-provider `Manifest()` in W3 (sequenced single-lane on `issue-tracker/registry.ts`), then freeze. |
| **vcs** | **DEFERRED — per-axis ADR (post-preview)** | The landing-serializer / `GitHubVCSProvider` work is W4+ and the contract surface (merge-queue, conflict graph) is still being harvested Go-native. Freezing now would freeze a moving contract. Own ADR before SDK exposure. |
| **kit** | **DEFERRED — per-axis ADR (post-preview)** | Three contribution mechanisms under a placeholder brand; the Kit brand-rename and node-id true-namespacing (B6) must settle first. Own ADR before SDK exposure. |
| **workarea / deployment / agent-registry** | **DEFERRED — reserved discriminants only** | Named in the 9-family roster for completeness; no SDK exposure this wave. |

### Freeze sequencing

1. **Now (W2):** freeze the **base contract** (Go-native) + the **harness** and **model-endpoint** axes. These are the SDK's first-class surfaces. The base-parity gate is the freeze proof.
2. **W3:** convert **sandbox** and **issue-tracker** registries to manifest-driven `register()` against the frozen base (the `015` loader bridge), then freeze them as the next two self-serve axes.
3. **Post-preview:** **vcs** and **kit** each land their own per-axis ADR that freezes their contract against the base; only then does the SDK expose them.

The base contract is frozen FIRST and independently — every axis freeze is "freeze axis X against the already-frozen base," never a renegotiation of the base.

## Consequences

### Positive

- **Third-party authors get a stable first surface (harness + model-endpoint) immediately**, with two more (sandbox + issue-tracker) on a short, defined runway.
- **No axis is frozen against a moving contract or a missing OSS implementation** — the readiness criteria (contract landed + OSS impl + parity gate) gate every freeze.
- **The deferral of vcs + kit is explicit and ADR-tracked**, so a later author knows exactly what blocks their SDK exposure.

### Negative

- **Two axes (sandbox, issue-tracker) are advertised as "next" but not yet frozen**, so an early SDK author targeting them must accept a short window of contract motion until W3 lands. Communicated via the readiness table.

### Risks

- **An axis declared READY later proves to need a contract change.** Mitigated by Decision 3 of `002` (pre-production-users, the contract enriches in place on `v1`); a genuine break before GA still costs only a regenerate, not a deprecation cycle.
- **Scope creep into freezing a deferred axis.** Mitigated by requiring a per-axis ADR (vcs, kit) before any SDK exposure.

## Alternatives considered

- **Freeze all four loader axes (harness, model-endpoint, sandbox, issue-tracker) at once.** Rejected: sandbox + issue-tracker registries are still hardcoded arrays, not manifest-driven; freezing them before the W3 loader bridge would freeze a contract their implementations don't yet honor through `register()`.
- **Defer the freeze entirely until all axes are ready.** Rejected: it blocks the third-party SDK on the slowest axis (kit, which needs a brand-rename first). Sequencing per readiness ships value incrementally without freezing anything premature.
- **Freeze vcs now to look complete.** Rejected: vcs has no stable Go contract yet (landing serializer is W4+); freezing it would strand authors against a moving surface — exactly the `001` anti-pattern.

## Affected documents

- `002-provider-base-contract.md` — no contract change from THIS ADR; the readiness/sequencing table is recorded here and referenced from the Go-native base ADR. (The Go-native realization note in `002` is landed by `ADR-2026-06-14-provider-base-contract-go-native`.)

This ADR does NOT amend a `BOUNDARY-SYNC` synchronized section. It is `shared` because the freeze sequence binds both the OSS execution layer (which ships the axis implementations) and the platform (which exposes the SDK and the hosted registry tiers); per `BOUNDARY.md` § "Cross-cutting ADR dual-publish" the canonical lives here and a `status: Mirrored` stub lives in `rensei-architecture`.

## Affected work items

Platform program W2 workstream `w2-sdk-base-contract` (B1, the freeze-sequencing half). W3 sandbox/issue-tracker loader-bridge work (B2/B3) consumes the "NEXT" verdicts; W4+ vcs and post-preview kit consume the "DEFERRED" verdicts.

## Implementation notes

- The base contract this ADR sequences against is `donmai/agent/base.go` (`ADR-2026-06-14-provider-base-contract-go-native`).
- The harness + model-endpoint freeze proof is `donmai/matrix/base_parity_test.go` plus the existing `matrix/parity_test.go` cell-validity gate.
- The W3 loader bridge (`015` `{id,class}→register()`) is the mechanism that moves sandbox + issue-tracker from "NEXT" to "frozen."
