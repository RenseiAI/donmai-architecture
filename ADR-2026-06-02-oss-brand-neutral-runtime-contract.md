---
status: Accepted
boundary: shared
split: synchronized-mirror
---

# ADR-2026-06-02-oss-brand-neutral-runtime-contract

**Status:** Accepted
**Date:** 2026-06-02
**Boundary:** shared (cross-cutting; canonical here, mirrored stub in `rensei-architecture`)
**Authors:** Claude (Opus 4.8) + Mark Kropf

## Context

The 2026-05-25 donmai rebrand de-branded the *surface* layer — directory names, `dmk_*` anon tokens, the `.donmai/` config dir, CSS classes, providerId — but left the **runtime/execution contract** of the OSS `donmai` binary branded with the closed-source "Rensei" identity. An audit on 2026-06-02 (triggered when `donmai-site`'s `guard-b` closed-source-content linter went red on the public docs) found the OSS core still bakes in:

1. **~23 `RENSEI_*` environment variables** read directly via `os.Getenv` in non-test Go, in two classes:
   - *User-facing config* the operator sets and `donmai-site` documents: `RENSEI_API_TOKEN`, `RENSEI_DAEMON_TOKEN`, `RENSEI_ORCHESTRATOR_URL`, `RENSEI_DAEMON_URL`, `RENSEI_PLATFORM_URL`.
   - *Platform→worker runtime contract* the Rensei platform **injects** at dispatch (`platform/src/lib/worker-fleet/provisioner.ts` and dispatch write the same names): `RENSEI_DAEMON_JWT`, `RENSEI_SESSION_ID`, `RENSEI_PROJECT_ID`, `RENSEI_ORG_ID`, `RENSEI_RUNTIME_JWT`, `RENSEI_RSK_TOKEN`, `RENSEI_WORKER_ID`, `RENSEI_REGISTRATION_TOKEN`, `RENSEI_CREDENTIAL_SOCKET`, `RENSEI_REPOS`/`RENSEI_REPOSITORY`, `RENSEI_REF`, `RENSEI_STUB_MODE`, `RENSEI_DRIFT_GATE`, `RENSEI_ARCH_DB`, … — a two-repo contract expressed entirely in the closed brand.
2. **Hardcoded closed-source URLs** in the OSS binary: `platform.rensei.dev` (daemon default orchestrator — `daemon/config.go`, `daemon/setup_wizard.go`), `app.rensei.ai`, `registry.rensei.dev` (kit registry default), **`updates.rensei.dev` (the auto-update CDN — `daemon/auto_update.go`)**, and the `rensei.dev/v1` API-version string.
3. **`~/.rensei/` config paths** still live in `afcli/credentials/cmd_rotate.go` (cli.token, cli-config.yaml) and the daemon.yaml docstring; `internal/statepath/statepath.go` already migrated to `.donmai/` with a one-release `.rensei`→`.donmai` fallback.

This violates the boundary stated in `001-layered-execution-model.md`: **donmai is the shared OSS execution core; Rensei is the closed-source platform + `rensei-tui`. donmai on its own must not reproduce closed-source platform features, nor ship pointers to Rensei infrastructure.** A third party who builds OSS `donmai` today is silently pointed at Rensei's CDN, registry, and platform, and must speak a closed-brand env protocol.

`rensei-tui` (closed) composes donmai via Go imports (`afclient`, `daemon`, `runner`, `afcli`, `installer`, providers) and legitimately uses `RENSEI_*` + `app.rensei.ai` — that is the Rensei product and is *not* a leak. The platform (closed) is the other composition/injection layer.

## Decision

Make the OSS `donmai` core **brand-neutral** at the runtime contract, and push all Rensei identity into the composition layers (`rensei-tui` + the platform):

1. **Library packages take config via Go API, not env reads.** `donmai/daemon`, `donmai/runner`, `donmai/afclient`, `donmai/worker` stop calling `os.Getenv("RENSEI_*")` internally; they accept the same values through their `Config`/`Options` structs. `rensei-tui`, which already composes these packages, reads its own `RENSEI_*` env and threads the values in. This removes brand from OSS *and* keeps `rensei-tui`'s env surface untouched.
2. **The standalone `donmai` binary reads a brand-neutral env namespace** (`DONMAI_*`) for the same config (`cmd/donmai`, `afcli/credentials`). Per the zero-users / hard-delete rule, **`RENSEI_*` names are dropped outright — no fallback aliases** (a fallback would re-entrench the brand in OSS).
3. **No closed-source default endpoints in OSS.** Remove the hardcoded `platform.rensei.dev` / `registry.rensei.dev` / `updates.rensei.dev` / `app.rensei.ai` / `rensei.dev/v1` defaults. The OSS binary requires explicit configuration (flag/env/config-file) for orchestrator, registry, update-CDN, and API-version; it ships with **no** default that points at Rensei infra. `rensei-tui` and the platform supply the Rensei endpoints.
4. **The platform updates its worker-env writer** (`provisioner.ts` + dispatch) to emit the brand-neutral names the cloud `donmai` binary now reads.
5. **`~/.rensei/` paths** in `afcli/credentials` move to `.donmai/` (via the existing `statepath` helper); the one-release `.rensei` read-fallback already in `statepath` covers migration.
6. **Docs + guards.** `donmai-site` documents only the brand-neutral names; the `guard-b` linter stops scanning its own rule-definition script.

The canonical name mapping (closed `RENSEI_*` ↔ neutral) is defined in the wave plan (`runs/2026-06-02-donmai-debrand/`) and mirrored into `001 § "The donmai ↔ Rensei Platform contract"` (synchronized region).

## Consequences

### Positive
- OSS `donmai` is genuinely brand-neutral and self-contained; building it does not phone home to Rensei infra.
- The donmai↔Rensei boundary becomes a real, enforceable contract (config-in, no hidden env coupling); `guard-b` passes honestly rather than via allowlist.
- Config-via-API for the library packages is cleaner and more testable than ambient `os.Getenv`.

### Negative
- Multi-repo, lock-step change: donmai (reads/URLs/paths) + platform (writer) + rensei-tui (mapping) + donmai-site (docs) must land together or the worker runtime contract breaks. Requires a coordinated wave (see wave plan) and a donmai release.
- Hard-dropping `RENSEI_*` (no fallback) means any out-of-tree script setting the old names breaks; acceptable under zero-users.

### Neutral
- `rensei-tui` keeps its `RENSEI_*` env surface and `app.rensei.ai` references — those are in-brand for the closed product and out of scope here.

## Alternatives considered

- **`DONMAI_*` primary with `RENSEI_*` fallback in OSS** — rejected: relabels the leak; the closed brand stays compiled into the OSS binary forever.
- **Rename only the donmai-site docs** — rejected: the binary still reads `RENSEI_*` and defaults to `rensei.dev`, so the public docs would be false.
- **Allowlist the guard** — rejected: hides the exact leak the guard exists to catch.
