---
status: Accepted
boundary: shared
date: 2026-06-07
---

# ADR-2026-06-07 — Intelligence implementation is platform-only; OSS ships execution + contracts

**Status:** Accepted · **Boundary:** shared (canonical here; mirrored stub in `rensei-architecture`)

## Context

`007-intelligence-services.md` commits the OSS layer to ship a **single-tenant reference implementation** of Memory, Code Intelligence, and Architectural Intelligence (sqlite + local vectors / local LLM). That commitment has carried a `scheduled` (unshipped) status since 2026-05-07.

A 2026-06-07 boundary review (driven by the rensei-docs feature-completeness audit, `runs/2026-06-07-rensei-docs-feature-completeness/`) established the actual OSS surface and the actual consumers of the intelligence libraries:

- **The OSS surface is execution + a thin fleet dashboard, with no intelligence server.** `donmai` (the OSS Go binary) is the execution/runner layer — it carries **zero** arch-intel / KG / memory code. The one OSS server-side piece, `@donmai/dashboard`, is a fleet/routing monitor over the local daemon's HTTP API: it has no datastore and does not depend on, or surface, any intelligence library.
- **The Go binaries cannot consume the TS intelligence libraries.** `@donmai/architectural-intelligence`, `@donmai/code-intelligence`, and the `core` orchestrator are TypeScript; `donmai`/`rensei-tui` are Go. There is no path by which the OSS binary uses them.
- **The only live consumers of the intelligence libraries are the closed platform and the legacy Node CLI.** The Node CLI (`@donmai/cli`) is being retired in favor of the Go TUIs (see `README` "Migrating from the legacy Node CLI"). That removes the sole OSS-standalone consumer. What remains is the closed Rensei platform (multi-tenant Postgres) and the Rensei-operated dashboard deployment.
- **Platform-only code already leaks into the OSS packages.** `@donmai/architectural-intelligence`'s `postgres-impl` carries a multi-tenant RLS adapter (`SET LOCAL rensei.current_org_id` + `current_setting(...)::uuid`) that only the closed platform uses — and which never worked against the platform's `text` tenant ids (see `ADR-2026-06-07-graph-id-type-text` in `rensei-architecture`). The closed platform reaches *into* an OSS package for a platform concern.

Net: the OSS single-tenant intelligence story has no implementation, no Go-reachable delivery path, and (once the Node CLI retires) no standalone consumer. Intelligence is, in practice, a platform feature.

## Decision

1. **Intelligence implementation is platform-only.** The OSS layer no longer commits to ship reference implementations of Memory / Code Intelligence / Architectural Intelligence. Storage, extraction, synthesis, recall, and the multi-tenant tenant model are owned by the closed platform.
2. **OSS retains the intelligence *contracts* and *kit extension points*.** The interfaces in `007` (`MemoryQuery`/`MemoryWrite`, `ArchitecturalIntelligence`, Code Intelligence API) stay OSS-canonical so kits and agents target a stable interface, and generic AST / extractor extension points stay in core per `005`. OSS owns the contract; the platform owns the implementation.
3. **The OSS surface is: execution (`donmai` Go) + the fleet dashboard + the contracts.** No server-dependent intelligence client lives in `donmai`. (The Go TUIs already enforce this — platform-dependent commands live only in `rensei-tui`.)
4. **Platform-coupled code is removed from the OSS packages.** Once the platform migrates off it, the `postgres-impl` + `rensei.current_org_id` RLS in `@donmai/architectural-intelligence` is dropped. The package reduces to its contract (+ the optional `sqlite-impl` reference) or is retired alongside the Node CLI.
5. **A genuine OSS standalone intelligence, if ever wanted, must be built Go-native** (the TS libraries cannot serve the Go binary). That is explicitly out of scope here and would be its own ADR.

## Consequences

- **`007` (this corpus)** is amended: the OSS reference-impl commitment for Memory and Architectural Intelligence is retracted; OSS scope = contracts + kit extension points. The "scheduled" reference-impl rows become "platform-owned."
- **`007-platform-extensions` (rensei-architecture)** is amended: the platform owns the *full* intelligence implementation, not merely a multi-tenant extension of an OSS store.
- **Platform migration:** `arch/query.ts` + the `arch-nightly-synthesis` job move off `PostgresArchitecturalIntelligence` onto platform-owned queries on the platform's own graph store (`PgGraphStore`, already `text`-correct). The `@donmai/architectural-intelligence` import is dropped from the platform. (The SDK's Postgres reads never functioned for real tenants, so there is no behavior regression.)
- **donmai-libraries:** `@donmai/architectural-intelligence` sheds `postgres-impl` + the RLS adapter; kept as contract (+ sqlite reference) or retired with the Node CLI.
- This supersedes the OSS reference-impl portions of `007` § Memory and § Architectural Intelligence ("Implementation status" annotations).

## Boundary

`shared`. The decision retracts an OSS-canonical commitment (so it is canonical here) and reassigns the implementation to the platform (so `rensei-architecture` carries a `Mirrored` stub + the platform-side `007` edit). Neither edit touches a `BOUNDARY-SYNC`-marked region, so no synchronized-section ceremony is required — paired commits, OSS-side first.
