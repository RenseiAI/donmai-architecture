---
status: Accepted
date: 2026-06-14
boundary: shared
split: sibling-extensions
---

# ADR-2026-06-14-model-host-awareness

**Status:** Accepted
**Date:** 2026-06-14
**Accepted:** 2026-06-14 (lands with the affected `ADR-2026-06-06` reference + a queued matrix/gen follow-up).
**Boundary:** shared (OSS-canonical here; `status: Mirrored` stub in `rensei-architecture/ADR-2026-06-14-model-host-awareness.md` carrying the platform delta). `ADR-2026-06-06-two-axis-provider-model.md` already establishes the `host` axis at the cell level; this ADR makes the **model representation** carry a host list. No `BOUNDARY-SYNC` region is touched, so no byte-identical synchronized section and no paired-PR sync — just the canonical/mirror dual-publish.
**Authors:** catalog/host workstream (Opus 4.8)

## Context

`ADR-2026-06-06-two-axis-provider-model.md` decomposed the LLM layer into a HARNESS axis (the agent-loop driver) and a MODEL-ENDPOINT axis (named by company). It established that the **serving host** — `direct` (the vendor's first-party API), `bedrock`, `vertex`, `azure`, an `oauth-cli` subscription surface, or `local` — is a first-class fact: a MODEL-ENDPOINT manifest declares a list of `HostDesc` cells, one per `(serving-host × protocol × authModes × …)` tuple, and that is "where Bedrock/Vertex/direct/OAuth-CLI differ for the *same* company."

But there is a gap between that cell-level host axis and how a **model identity** is represented downstream. A model — say Anthropic's Sonnet — is the SAME model whether it is answered by the vendor's direct API, by Bedrock, or by Vertex. The catalog/representation layers, however, still collapse the host into a single opaque runtime identifier: a model row knows its harness and its modelId, but not the SET of inference hosts that can serve it. That collapse has two costs:

1. **"Same model, many hosts" is inexpressible at the representation layer.** A consumer that wants to show an operator "this model is reachable via direct, Bedrock, and Vertex" — or that wants the future scheduler to choose a host per workload — has no list to read. The host fact lives only inside the matrix's per-cell rows, not on the model.
2. **A host-first-class re-vocabularization becomes a contract break, not a data migration.** The roadmap re-keys the model catalog onto `harness × host` (the natural completion of the two-axis model). If model representations have no host field today, that re-vocab must add a column AND rewire every reader at once. If the model carries a `hosts[]` list now — defaulting empty / host-unaware — the re-vocab is a backfill.

This ADR addresses the representation layer only. It does not change binding/validity (still owned by `ADR-2026-06-06` D2), the matrix SoT (D3), or per-machine narrowing (D5).

## Decision

**A model identity's representation carries a `hosts` list: the set of inference hosts that can serve that model.** Three parts:

1. **`hosts` is a list of inference-host ids**, drawn from the same `host` vocabulary the matrix already uses (`direct | bedrock | vertex | azure | oauth-cli | local`). The vocabulary is **open** (free-form strings), not a closed enum, so a new host the matrix adds is a config-only change — mirroring how harness ids stay open. An empty list means **host-unaware**: "served via the default host for this harness," which is the behavior-neutral default for every representation that predates this ADR.

2. **The host axis is orthogonal to harness and modelId.** A model is `(harness, modelId, hosts[])`. The same `modelId` under the same harness can appear once with the union of its hosts; the same model under two harnesses is two rows whose `hosts[]` may overlap. Consumers that want a deduped "one row per model identity, with its distinct hosts" view group by `modelId` and union the lists — host topology is a property of the identity, not of any single representation row.

3. **The OSS matrix/gen will emit a `Models[]` list whose entries carry `hosts[]`, derived from the matrix `HostDesc` cells.** Today the host fact is per-cell (`harnessEndpointCells[]`); the generator already knows, for each `(company, model)`, the set of hosts across its valid cells. Emitting that as a model-level `hosts[]` on a `Models[]` section of the generated matrix is the OSS half of this decision. **It is QUEUED as a follow-up workstream — NOT implemented in this ADR's commit** — so the generator change ships under the matrix-gen owner with its own parity-gate update, rather than racing the representation-layer adoption. Until it ships, the host lists are hand-curated by the consuming layer (see the mirrored platform stub).

## Consequences

### Positive

- **The host-first-class catalog re-vocab becomes a data migration.** Adding `hosts[]` now, defaulting empty, means the later `harness × host` re-keying is a backfill of an existing field, not a new contract every reader must learn at once.
- **"Same model, many hosts" becomes a first-class, displayable fact** at the representation layer, not something a consumer must reassemble from the matrix's per-cell rows.
- **Open vocabulary keeps host additions cheap** — a new serving host (e.g. a future translating-gateway host kind from `ADR-2026-06-06` D2) is a new string, no schema change.
- **Behavior-neutral by construction.** Empty `hosts[]` = host-unaware = today's behavior. Nothing on the dispatch/binding hot path reads the field yet; it is a representation enrichment ahead of the re-vocab.

### Negative

- **Two host representations coexist until the re-vocab lands**: the matrix's per-cell `host` (binding-authoritative) and the model-level `hosts[]` (representation/display). They must be kept consistent by the matrix/gen emission (the queued follow-up) rather than hand-curation, or they drift.
- **Hand-curated host lists are a stopgap** and can be wrong/stale until the generator owns them.

### Risks

- **Drift between curated `hosts[]` and the matrix cells** before the generator emits `Models[]`. Mitigation: the consuming layer curates conservatively from documented availability and treats the matrix as the binding-time source of truth; the generator follow-up replaces curation with derivation.
- **Over-reading the field too early.** Mitigation: this ADR scopes `hosts[]` to representation/display only; the hot-path binding stays on the matrix cell until the re-vocab ADR explicitly moves it.

## Alternatives considered

- **Do nothing; keep host only in the matrix cells.** Rejected: makes the host-first-class re-vocab a contract break instead of a data migration, and leaves "same model, many hosts" inexpressible at the representation layer — the two costs in Context.
- **A closed host enum.** Rejected: the matrix already treats host as an extensible axis (a future translating-gateway host is named in `ADR-2026-06-06` D2). A closed enum would force a schema change per new host, contradicting the "one new row" design goal.
- **An object array `hosts: [{ host, … }]` instead of `string[]`.** Rejected for now as premature: the per-host attributes (protocol, authModes, costModel) already live, binding-authoritatively, on the matrix `HostDesc` cells. Duplicating them onto the model representation would create a second source of truth for the same facts. A `string[]` list of host ids is the minimal forward-compatible shape; if a per-host representation attribute is ever genuinely needed at the model layer, that is its own ADR.
- **Emit `Models[]` in the matrix/gen in the same commit.** Rejected for sequencing: the generator change belongs to the matrix-gen owner with its own parity-gate update; coupling it to the representation-layer adoption would couple two owners' release cadences for no benefit. Queued as an explicit follow-up.

## Affected documents

- `ADR-2026-06-06-two-axis-provider-model.md` — D1/D2 (the MODEL-ENDPOINT `HostDesc` cells and the `host` axis). This ADR extends the host axis from the cell level up to the model representation; it does not contradict any D1–D7 decision. No edit to `002-provider-base-contract.md` (the base contract is unchanged — `hosts[]` is a representation field, not a new manifest verb).

Queued OSS follow-up (NOT in this commit): matrix/gen emits a `Models[]` section whose entries carry `hosts[]` derived from `harnessEndpointCells[]`, with the parity gate extended to assert each model's `hosts[]` is the union of its valid cells' `host` values.
