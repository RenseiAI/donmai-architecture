---
status: Proposed
boundary: OSS-only
---

# ADR-2026-07-12-kit-catalog-expansion

**Status:** Proposed
**Date:** 2026-07-12
**Boundary:** OSS-only
**Authors:** Kit-catalog-expansion execution lane
**Amends:** `ADR-2026-07-10-deterministic-kit-packages-and-command-composition.md`
(the catalog-expansion hold in §6 Phase L1 and §7)

## Context

`ADR-2026-07-10` closed the four package/composition contract gaps and, until
publisher/consumer/release conformance evidence is green, held the official
catalog at its activated size. The `donmai-kits` publisher implemented that hold
literally and airtight: `EXPECTED_KIT_IDENTITIES` in `scripts/package_kits.py`
pins the exact directory→kit-id set, `discover_kit_dirs` hard-fails on any extra
or missing directory, and the pre-sign `ci-check` routes a kit with changed
payload through `check_signing_candidate`, which requires the kit to **already
carry a signed descriptor pair** (`kit.package.json` + `.sigstore`).

That publisher recognises exactly three states — legacy-only bootstrap,
signing-pending (a payload change to an *already-published* kit), and published.
None of them models a **first publication**. A brand-new kit cannot carry a
pre-existing signed descriptor, so `ci-check` fails on the merge push *before*
`sign.yml` ever reaches its signing step. The activated size was reached by a
one-time package-v1 activation, not by incremental addition, so there is no
path to admit an authorized new kit at all — not even by a maintainer merge.

A concrete need now exists: the `default/swift` foundation kit is validated and
conformant (schema, skills, deterministic descriptor, boundary-clean) but cannot
enter the catalog. More generally, the execution layer will keep gaining
official language and framework kits, and each will hit the same wall. The hold
was correct as a *gate on contract readiness*; it was never meant to make the
authorized set permanently immutable. The published subset now satisfies the
package contract, so the gate can admit new members through an explicit,
reviewed, still-fully-verified procedure — provided the addition never weakens
any invariant the deterministic-package contract established.

This ADR defines that procedure. It does not relax any verification applied to
the published subset, and it does not create any unsigned install path.

## Decision

The authorized kit set (`EXPECTED_KIT_IDENTITIES`) may grow through an explicit
**first-publication-pending** path, never as an ordinary kit PR and never
silently. A new authorized kit enters as a fourth publisher state, is validated
for payload/identity closure without requiring a not-yet-minted descriptor, and
graduates to `published` only when the main-only signer mints and verifies its
complete signed package. The maintainer merge to `main` is the authorization
act; `sign.yml` first-signs on that push and no earlier.

This admits `default/swift` as the single Swift **foundation** kit and is the
reusable procedure for every future official kit.

The following sections are normative.

### 1. The first-publication-pending state

A kit is **first-publication-pending** iff it is authorized (present in
`EXPECTED_KIT_IDENTITIES` and matching its pinned kit-id on disk) **and** it has
no `kit.toml.sigstore` on disk — it has never been signed. During that window it
carries **only** its `kit.toml` manifest plus payload files. It carries none of
the three trust artifacts: no legacy manifest signature (`kit.toml.sigstore`),
no package descriptor (`kit.package.json`), and no descriptor signature
(`kit.package.json.sigstore`).

The publisher validates a pending kit's manifest identity, payload/path closure,
portable modes, and Unicode-portable collision keys — exactly the checks a
published kit's payload receives — but does **not** require a descriptor to
exist. In this state the publisher reports a deterministic in-memory closure
digest for traceability only; it is not a published package digest.

On a merge to `main`, `sign.yml` mints all three artifacts in order — it
first-signs the missing legacy bundle, generates the canonical descriptor once
the legacy bundle is stable (the descriptor inventories the legacy bundle), then
signs and verifies the descriptor — and the kit **graduates** to `published`.
From that commit forward it is indistinguishable from any other published kit
and is held to the full published verification on every subsequent check.

### 2. Authorization — who admits a kit, and how

Admission requires all of the following, in one reviewed change plus the merge:

1. **This ADR** (or a successor) lifts the expansion hold and defines the
   procedure. Lifting the hold is not a licence to add kits casually; each
   addition is still a reviewed change.
2. **The same reviewed change** adds the kit id to `EXPECTED_KIT_IDENTITIES` and
   to the `sign.yml` manifest, descriptor, and immutable-tree verification
   arrays, and lands the kit as first-publication-pending (manifest + payload
   only). The kit's content passes every content gate (`validate_kits.py`, skill
   conformance, boundary-clean) and its deterministic descriptor is proven
   locally.
3. **The maintainer merge to `main` is the authorization act.** `sign.yml`
   issues the allowlisted keyless identity only on a `main` push; a pull request
   or any other event is verify-only. There is therefore no way to sign a kit
   without the maintainer's merge, and no way for an ordinary contributor PR to
   admit a kit. The merge *is* the signature of authority.

An unauthorized directory — one not in `EXPECTED_KIT_IDENTITIES` — still
fail-closes `discover_kit_dirs`; an authorized id whose on-disk manifest id
disagrees with its pin still fail-closes. Expansion changes *which* ids are
authorized; it does not change that only authorized ids may exist.

### 3. Security invariants (preserved and added)

Expansion holds every invariant `ADR-2026-07-10` established:

1. **The published subset stays fully verified.** Descriptors, both bundle
   classes, subject digests, portable modes, and RFC 8785 canonical bytes are
   validated for every published kit exactly as before. A pending kit is
   *excluded* from that subset, never a *weakening* of it: it contributes no
   descriptor, so no published verification is skipped or softened.
2. **Descriptor and catalog determinism are unchanged.** Descriptors remain
   byte-reproducible RFC 8785 canonical JSON over the exact payload inventory;
   catalog snapshots consume only the published subset and pin exact digests. A
   pending kit never appears in a catalog snapshot until it graduates.
3. **Allowlist fail-closed is unchanged.** `discover_kit_dirs` still rejects any
   directory outside the authorized set and any id/pin mismatch. Expansion edits
   the allowlist inside the reviewed change; it does not remove the allowlist.
4. **No unsigned install.** The consumer daemon's default `signed-by-allowlist`
   trust still fails closed on an unsigned kit. A first-publication-pending kit
   is not installable until `sign.yml` signs it on merge. `--allow-unsigned` and
   `permissive` mode are never a path to admitting a kit into the trusted set;
   they remain audit-logged operator overrides, not an expansion mechanism.

Expansion adds one new invariant:

5. **Demotion-hole guard.** A pending kit MUST carry **zero** of
   `{kit.toml.sigstore, kit.package.json, kit.package.json.sigstore}`. A kit that
   carries a descriptor or descriptor signature but no legacy signature is an
   **error**, not a pending kit. Without this guard, deleting a published kit's
   legacy signature would silently reclassify it as "pending" and let its payload
   be swapped under a stale descriptor. The guard makes the only way into the
   pending state a genuine never-signed kit.

The pre-sign guards `ADR-2026-07-10` relied on continue to apply to a pending
kit unchanged: the version-bump check, the historical-identity-reuse check
(a new kit's id/version must not reuse any identity reachable from history), and
the generated-artifact immutability check (human PRs may not edit descriptors or
detached bundles — only the main-only signer may).

### 4. Mobile-lane composition rule (P10-WS6)

`default/swift` is the **single Swift foundation kit**: `order = "foundation"`,
detecting `Package.swift`. On the Linux execution lane it builds and tests
pure-Swift logic modules only; app targets that import Apple UI/persistence
frameworks are a separate host-pool lane and are out of scope for the foundation
kit's generic build/test aliases, which stay package-manager-level so a
logic-only package still composes.

Any future `mobile`/`ios` kit MUST compose as `order = "framework"` on a
**disjoint** detect file — never a second foundation. The one-foundation-per-repo
rule (`ErrKitFoundationConflict`) makes two foundations matching the same repo a
hard error; a framework kit layers on top of the Swift foundation rather than
competing with it. A framework kit that wants a generic alias the foundation
already owns takes it only through the owner-qualified composition and delegation
rules in `ADR-2026-07-10` §4, not by scan order.

### 5. The machinery change

The change is confined to the OSS `donmai-kits` publisher and its gates:

- `EXPECTED_KIT_IDENTITIES` gains the new id (`default/swift`).
- `discover_kit_dirs` reports the frozen-set violation count-agnostically
  ("authorized kit set"), so the message stays truthful as the set grows.
- `first_publication_pending(root, kit_dirs)` classifies never-signed kits and
  enforces the §3(5) demotion-hole guard.
- `build_descriptor(..., require_legacy_signature=False)` validates a
  first-publication payload/identity closure without the not-yet-minted legacy
  bundle, and asserts the legacy bundle is genuinely absent from the inventory.
- `check_catalog`, `check_signing_candidate`, and
  `build_catalog_snapshot_candidate` split the discovered kits into a published
  subset (fully verified, snapshot-eligible) and a pending subset (payload/
  identity validated, zero artifacts, snapshot-excluded).
- `sign.yml`'s manifest, descriptor, and immutable-tree verification arrays list
  the authorized set. Its legacy-sign step already first-signs a missing bundle
  and its descriptor-sign step already treats an absent `HEAD:` descriptor as
  needing signature, so a new kit graduates through the existing signing loops.

The publisher- and consumer-side conformance evidence `ADR-2026-07-10` §7
requires is unchanged; expansion does not claim any evidence it has not earned.
It only removes the accidental impossibility of ever adding an authorized kit
once that evidence is green for the published subset.

## Consequences

### Positive

- The authorized catalog can grow through a reviewed, fully-verified path
  instead of a one-time activation. Every future official kit reuses it.
- A new kit is verified for the same payload/identity closure as a published
  kit before it can be merged; the signer mints its trust artifacts atomically.
- The demotion-hole guard closes a swap-under-stale-descriptor path that the
  original frozen set never had to consider.

### Negative

- The publisher gains a fourth state and a per-kit published/pending split,
  increasing its logic surface (mitigated by tests covering both graduation and
  the demotion-hole rejection).
- A pending kit is briefly present in the tree without a descriptor; the state
  is only self-consistent because the demotion-hole guard forbids the ambiguous
  descriptor-without-signature shape.

### Risks

- A future edit could reintroduce a count assumption (e.g. a hardcoded array in
  `sign.yml`) that silently excludes a new kit. Mitigation: the arrays and the
  allowlist are asserted against each other by the integrity tests and the
  signer's own guards fail closed on any mismatch.
- Admitting kits too readily would grow executable supply. Mitigation:
  authorization still requires a reviewed change plus a maintainer merge; the
  hold is lifted as a *procedure*, not as an open door.

## Alternatives considered

### Keep the set permanently frozen; ship new kits out of band

Rejected. The hold was a readiness gate, not a decision that the catalog is
finished. Out-of-band distribution would fork the trust spine the deterministic
package contract exists to centralize.

### Let the signer create the descriptor for any extra directory it finds

Rejected. Signing an unreviewed directory turns directory presence into
authorization and defeats the allowlist. Authorization must be an explicit
allowlist edit plus a maintainer merge, not a side effect of discovery.

### Bootstrap a new kit by hand-placing a descriptor and signature

Rejected. Hand-placed trust artifacts are exactly what `ADR-2026-07-10` and the
`donmai-kits` hard stops forbid. The first-publication path carries no artifacts
until the main-only signer mints them, which is why the demotion-hole guard can
be absolute.

## Affected documents

On acceptance, update in the same commit:

- `ADR-2026-07-10-deterministic-kit-packages-and-command-composition.md` — note
  in §6 Phase L1 and §7 that the catalog may admit an authorized new kit through
  the first-publication-pending procedure defined here, once the published
  subset's conformance evidence is green.
- `005-kit-manifest-spec.md` — record the authorized-set expansion procedure and
  the first-publication-pending state alongside the daemon kit-registry section.

## Affected work items

- `donmai-kits`: the machinery change above (landed as the reviewed change that
  admits `default/swift`) and its integrity tests.
- Future official kits (language and framework) reuse this procedure; a
  `mobile`/`ios` framework kit follows §4.

## Implementation notes

The machinery lands in `donmai-kits` as the same reviewed change that admits
`default/swift`. The maintainer merge to `main` triggers `sign.yml` to
first-sign the kit; the cloud-install smoke then exercises the verified consumer
path against the newly-signed catalog, never an unsigned override.
