# ADR-2026-04-28-sandbox-capabilities-in-types

**Status:** Accepted

**Date:** 2026-04-28

**Authors:** Mark Kropf + post-foundation audit (continuation of session db959ae0)

## Context

During the 2026-04-27 foundation migration, the Provider base contract work declared a minimal `SandboxProviderCapabilities` interface in `packages/core/src/providers/base.ts` to bootstrap the provider hierarchy. The SandboxProvider capability matrix work then needed the full 18-field struct described in `004-sandbox-capability-matrix.md` — `transportModel`, `supportsFsSnapshot`, `supportsPauseResume`, `idleCostModel`, `billingModel`, `regions`, `os`, `arch`, etc.

Rather than expand the base.ts declaration in place, the full struct was added to `packages/core/src/providers/types.ts`. This produced a type-collision because both files exported `SandboxProviderCapabilities` with different shapes. Hot-fix #101 (commit 1247b7ea) resolved the collision by removing the `base.ts` re-export.

The pattern this established — **rich capability structs live in `types.ts`, not `base.ts`** — is silently in conflict with corpus 002's framing where `Provider<F>`'s capability surface is defined alongside the base contract.

## Decision

Capability structs that extend beyond the bootstrap minimum live in `packages/core/src/providers/types.ts`. The `base.ts` file holds only the `Provider<F>` shape and the names of the capability families; the rich struct definitions are owned by `types.ts` and are the canonical source of truth.

**For future capability extensions** (e.g., VCS caps expansion), use module augmentation against `types.ts` rather than redeclaration in `base.ts`. The pattern is documented inline near the `SandboxProviderCapabilities` declaration.

## Consequences

### Positive

- One file to look at when expanding any capability family.
- No risk of base.ts and types.ts drifting out of sync.
- Module augmentation is the TypeScript-canonical extension mechanism — using it teaches downstream plugin authors the right pattern.

### Negative

- Corpus 002's framing now has an indirection: "the base.ts contract" is conceptually right, but the capability struct lives elsewhere. Readers landing on 002 first will need to follow a pointer.
- A reader coming from corpus 002 → code may be momentarily confused which file owns what. Mitigate via cross-reference in 002.

### Risks

- Future contracts that extend frozen base.ts types might re-encounter the same collision if authors forget the pattern. Mitigation: encode in a project linter rule (e.g., "no `export interface .*Capabilities` in base.ts").

## Alternatives considered

- **Expand `base.ts` in place** — rejected because base.ts is supposed to be the bootstrap minimum; expanding it makes the bootstrap path bloated and complicates plugin author onboarding ("which file do I edit?").
- **Single file containing both** — rejected because `base.ts` legitimately is a smaller surface that plugin authors implement; bundling the rich capability struct violates the purpose of a minimal base.

## Affected documents

- `002-provider-base-contract.md` — §Capabilities, add a one-line pointer: "Rich capability structs live in code at `packages/core/src/providers/types.ts`; this section describes the contract, not the file layout."
- `004-sandbox-capability-matrix.md` — §Implementation, note that the canonical struct location is `types.ts` not `base.ts`.

## Implementation notes

- Linter rule (future): `no-export-interface-capabilities-in-base` — warn when `export interface .*Capabilities` appears in `packages/core/src/providers/base.ts`.
- Module augmentation example for cycle 2 work:

```ts
// In types.ts:
declare module './base' {
  interface VersionControlProviderCapabilities {
    mergeModel: 'three-way' | 'patch-theoretic';
    // ...
  }
}
```
