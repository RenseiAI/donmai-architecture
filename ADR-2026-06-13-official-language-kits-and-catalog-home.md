---
status: Accepted
boundary: OSS-only
---

# ADR-2026-06-13-official-language-kits-and-catalog-home

**Status:** Accepted
**Date:** 2026-06-13
**Boundary:** OSS-only
**Authors:** Platform Parity Program — W1 corpus lane (Claude Sonnet 4.6)
**Mirrors:** `donmai-kits/docs/adr/ADR-0001-official-language-kits.md` (canonical decision; this entry is the donmai-architecture corpus mirror for discoverability)

## Context

The kit machinery — manifest schema, declarative detection, the `foundation → framework
→ project` composition algorithm, toolchain provisioner, and Sigstore trust gate — is
built and shipped in the OSS execution layer (`005-kit-manifest-spec.md`). What was
missing was **content**: only a single TypeScript/Next.js kit existed, and it was
duplicated with drift between the OSS catalog and a manifest string embedded in the
closed platform.

Two cross-cutting facts drive this decision:

1. **The default trust mode is now `signed-by-allowlist`, and the vendor trust root is
   compiled in.** A security change flipped the compiled-in default from `permissive`.
   The daemon does NOT ship an empty allowlist — `applyDefaults` (and the equivalent
   `kitRegistryOrEmpty` path) seed `trust.issuerSet` with `defaultVendorIssuerSet()`,
   the official donmai-kits signing identity. The signing CI and the embedded
   public-good Sigstore trust root have both landed, so every official kit manifest
   ships a real `kit.toml.sigstore` bundle and passes the legacy manifest
   `signed-by-allowlist` gate WITHOUT `--allow-unsigned`. That gate blocks unsigned /
   untrusted-signer manifests (typically third-party or locally-built ones); it does
   not verify a complete package.
2. **Kits are execution-layer content.** A kit is a declarative detection + toolchain +
   commands + skills contract with no server side and no platform dependency. Per the
   OSS boundary rule, default kits are OSS-owned.

## Decision

The full decision lives in the canonical ADR at
`donmai-kits/docs/adr/ADR-0001-official-language-kits.md` (the `donmai-kits` repo).
Summary:

1. **One OSS monorepo for official kits: `donmai-kits`.** A dedicated, brand-neutral
   OSS repo holds the catalog. Kits are language-agnostic TOML + content data files
   consumed by the Go execution layer via the daemon scan path or git install — not TS
   library code.

2. **Seven foundation/framework kits authored** (manifests-only, no machinery changes):

   | Kit | Order | Toolchain |
   |---|---|---|
   | `default/typescript` | foundation | node 22 |
   | `default/ts-nextjs` | framework | node 22 (pnpm) |
   | `default/go` | foundation | go 1.23 |
   | `default/rust` | foundation | rust stable |
   | `default/java` | foundation | temurin 17 |
   | `default/python` | foundation | python 3.12 + uv |
   | `default/ruby` | foundation | ruby 3.3 (rbenv) |

3. **TypeScript kit split** into `default/typescript` foundation (any TS/Node project)
   and `default/ts-nextjs` framework (Next.js-specific). The closed platform SHOULD
   consume this OSS catalog rather than embedding its own TS kit string.

4. **Signing CI + vendor trust root — LANDED.** Keyless Sigstore signing runs in
   `donmai-kits/.github/workflows/sign.yml` (GitHub Actions OIDC → Fulcio, logged in
   the public-good Rekor transparency log), emitting a protobuf-format
   `kit.toml.sigstore` bundle per kit (`--new-bundle-format`). The daemon's compiled-in
   `defaultVendorIssuerSet()` pins that workflow's exact Fulcio SAN + OIDC issuer, and
   the embedded public-good Sigstore trust root verifies the chain offline. The raw
   manifest therefore passes the default `signed-by-allowlist` trust gate without
   `--allow-unsigned`.

   **2026-07-10 scope clarification:** this bundle signs only `kit.toml`. It does not
   bind, install, or verify referenced skills, prompt fragments, hooks, executables,
   modes, or other payload files. “Verified” in this historical decision therefore
   means `legacy-manifest-verified`, not verified package installation. The complete
   package, transactional install, deterministic catalog, and command-ownership
   contract is accepted in
   `ADR-2026-07-10-deterministic-kit-packages-and-command-composition.md`; its runtime
   and publisher implementation remains pending.

5. **`demand.env` end-to-end wire (follow-up, cross-repo):** PATH-mutating installers
   (Rust/Python/Ruby) propagate env to downstream commands. Not implemented.

### Trust-default change impact on `005-kit-manifest-spec.md`

`005-kit-manifest-spec.md` § "OSS vs SaaS responsibilities" previously listed:

> | Signing verification | ✅ ships permissive | ✅ ships allowlist + attested |

The compiled-in OSS default is now **`signed-by-allowlist`** (not `permissive`), and
the daemon seeds the vendor signing identity into `trust.issuerSet` by default. At
that decision point, the row described the manifest trust gate as:

> | Manifest signature verification | ✅ ships signed-by-allowlist (vendor-issuer trust root seeded by default; official manifest bytes verify out of the box) | ✅ ships populated allowlist + attested |

The seeded vendor issuer set verifies the shipped manifest-only
`kit.toml.sigstore` bundles without an override. That fact does not establish a
complete package install. `--allow-unsigned` (audit-logged) or `permissive`
trust mode remains relevant only to the legacy manifest gate and cannot promote
legacy material to `package-verified`.

## Consequences

- OSS users get language coverage out of the box; the closed platform consumes the
  catalog rather than authoring kits.
- The signing CI signs every catalog manifest in one pass, and a single parity
  fixture can guard composer drift across the layer.
- The legacy manifest trust gate is usable for official manifests today: the vendor
  trust root is compiled in and seeded by default.
- Official kit **manifests** are signed (each ships a `kit.toml.sigstore` bundle).
  Referenced payload and atomic package installation remain pending under the
  2026-07-10 package-contract ADR.

## Affected documents

- `005-kit-manifest-spec.md` — § "OSS vs SaaS responsibilities" updated to reflect
  `signed-by-allowlist` as the OSS default (not `permissive`). Also § "Daemon kit
  registry" — scan path now resolves via the `statehome` seam (`~/.donmai/kits/`
  by default for OSS; `~/.rensei/kits/` for the closed binary) rather than
  hardcoded paths.

## Affected work items

- `donmai-kits` PR / release: official language kit scaffold (7 kits, `donmai-kits`
  repo).
- Done: keyless Sigstore signing CI (`donmai-kits/.github/workflows/sign.yml`) +
  compiled-in vendor trust root (`defaultVendorIssuerSet()` in the daemon) — official
  kit manifests ship signed.
- Follow-up: `demand.env` end-to-end wire (cross-repo: `donmai` daemon + `donmai-kits`
  manifest schema).

## Implementation notes

Kit manifests live under `donmai-kits/kits/<family>/<id>/kit.toml`. The legacy
daemon scan path (`~/.donmai/kits/*.kit.toml` by default) can discover flat
manifests after `donmai kit install`, and the existing detection/toolchain paths
can consume the manifest fields. That is legacy manifest-only behavior, not
complete package support. Signed payload closure, typed package paths, atomic
installation, and the authority-aware composer/manifest revision remain pending
under `ADR-2026-07-10-deterministic-kit-packages-and-command-composition.md`.
