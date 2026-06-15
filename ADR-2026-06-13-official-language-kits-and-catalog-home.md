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
   public-good Sigstore trust root have both landed, so every official kit ships a real
   `kit.toml.sigstore` bundle and installs under `signed-by-allowlist` WITHOUT
   `--allow-unsigned`. The gate only blocks unsigned / untrusted-signer kits (typically
   third-party or locally-built ones).
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
   the embedded public-good Sigstore trust root verifies the chain offline. Official
   kits therefore install under the default `signed-by-allowlist` mode without
   `--allow-unsigned`.

5. **`demand.env` end-to-end wire (follow-up, cross-repo):** PATH-mutating installers
   (Rust/Python/Ruby) propagate env to downstream commands. Not implemented.

### Trust-default change impact on `005-kit-manifest-spec.md`

`005-kit-manifest-spec.md` § "OSS vs SaaS responsibilities" previously listed:

> | Signing verification | ✅ ships permissive | ✅ ships allowlist + attested |

The compiled-in OSS default is now **`signed-by-allowlist`** (not `permissive`), and
the daemon seeds the vendor signing identity into `trust.issuerSet` by default. The
updated row:

> | Signing verification | ✅ ships signed-by-allowlist (vendor-issuer trust root seeded by default; official kits verify out of the box) | ✅ ships populated allowlist + attested |

Operators installing OFFICIAL kits need no override — the seeded vendor issuer set
verifies the shipped `kit.toml.sigstore` bundles. `--allow-unsigned` (audit-logged) or
`permissive` trust mode is only needed for unsigned third-party / locally-built kits.

## Consequences

- OSS users get language coverage out of the box; the closed platform consumes the
  catalog rather than authoring kits.
- The signing CI signs the whole catalog in one pass, and a single parity fixture can
  guard composer drift across the layer.
- The trust gate is usable for official kits today: the vendor trust root is compiled
  in and seeded by default.
- Official kits are **signed** (each ships a `kit.toml.sigstore` bundle) and install
  under the default `signed-by-allowlist` mode with no `--allow-unsigned` and no
  `permissive` opt-out. Those overrides remain only for unsigned third-party kits.

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
  kits ship signed.
- Follow-up: `demand.env` end-to-end wire (cross-repo: `donmai` daemon + `donmai-kits`
  manifest schema).

## Implementation notes

Kit manifests live under `donmai-kits/kits/<family>/<id>/kit.toml`. The daemon's scan
path (`~/.donmai/kits/*.kit.toml` by default) discovers them after installation via
`donmai kit install`. The composition algorithm, detection runtime, and toolchain
provisioner in the OSS execution layer handle them without modification — the manifests
are pure data.
