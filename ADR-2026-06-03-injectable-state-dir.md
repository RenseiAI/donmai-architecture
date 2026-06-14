---
status: Accepted
boundary: shared
split: sibling-extensions
---

# ADR-2026-06-03-injectable-state-dir

**Status:** Accepted
**Date:** 2026-06-03
**Boundary:** shared (cross-cutting; canonical here, mirrored stub in `rensei-architecture`)
**Authors:** Claude (Opus 4.8) + Mark Kropf

## Context

[`ADR-2026-06-02-oss-brand-neutral-runtime-contract.md`](ADR-2026-06-02-oss-brand-neutral-runtime-contract.md) de-branded the OSS `donmai` runtime contract and, as part of that, consolidated on-disk state to `~/.donmai/` (Decision 5: `internal/statepath/statepath.go` resolves `~/.donmai/<file>`; the original one-release `.rensei`→`.donmai` read-fallback has since been removed upstream). That correctly removed the closed brand from the **OSS** binary's default.

But the state dir is **hardcoded**, and `internal/statepath` is module-private. The closed-source composing binary (`rensei-tui`) embeds donmai's `daemon` / `runner` / `installer` packages as Go imports; those packages call `internal/statepath` internally. The composing binary therefore **cannot** override the directory — Go's `internal/` rule blocks the import, and there is no config seam. The result is an **inverse brand leak**: a user who installs the *closed* product sees and depends on an *OSS-branded* `~/.donmai/` directory (`daemon.jwt`, `daemon.yaml`, `worktrees/`).

The same shape exists in the log path. `installer/launchd` hardcodes the daemon log directory to `~/Library/Logs/rensei/` for **every** embedder — so the *OSS standalone* `donmai` binary logs to a **Rensei-branded** directory, the mirror-image leak.

Two concrete symptoms observed 2026-06-03:

1. The closed binary's own CLI strings are internally inconsistent: `cmd/rensei/daemon_run.go`, `worker.go`, and `observability.go` advertise `~/.rensei/daemon.{yaml,jwt,log}` in flag defaults and help text, while the files actually land in `~/.donmai/` (resolved through the embedded `statepath`). This split-brain is what produced the `rensei host logs` "no such file `~/.rensei/daemon.log`" bug (fixed separately by pointing the logs command at the launchd log path).
2. State and logs are not separable per-embedder: there is no way to have OSS `donmai` use `~/.donmai` + `~/Library/Logs/donmai` while the closed `rensei` uses `~/.rensei` + `~/Library/Logs/rensei`.

This violates the boundary in `001-layered-execution-model.md` in both directions: the OSS core should be brand-neutral *and self-contained*, and the closed product's identity (including its on-disk footprint) belongs in the composition layer — not leaked out of, nor into, the OSS core.

## Decision

Make the OSS host-state footprint **injectable by the embedding binary**, with a brand-neutral OSS default. Concretely:

1. **Introduce a single exported host-identity seam** in a *non-`internal`* donmai package (e.g. `donmai/runtime/statehome`) that owns the on-disk identity and derives both paths from one brand token:
   - `StateDir(suffix string) string` → `~/.<brand>/<suffix>` (replaces the hardcoded `~/.donmai` in `internal/statepath`, which delegates to this seam).
   - `LogDir() string` → `~/Library/Logs/<brand>/` (replaces the hardcoded `rensei` in `installer/launchd`).
   - Default brand = **`donmai`**. The seam is set **once at process init** by the embedder — config-via-API, not ambient `os.Getenv` inside library code, consistent with `ADR-2026-06-02` §1.
2. **The standalone `donmai` binary keeps the brand-neutral default** (`donmai`) and MAY accept an explicit override via its own `DONMAI_*` namespace (e.g. `DONMAI_STATE_HOME`), read only in `cmd/donmai`, never in library packages — consistent with `ADR-2026-06-02` §2.
3. **The closed composing binary sets its own brand** at startup (`statehome` set to `rensei`), so all embedded-daemon state lands in `~/.rensei/` and logs in `~/Library/Logs/rensei/`. The launchd service label is already correctly per-brand (`dev.donmai.daemon` vs `dev.rensei.daemon`) and is out of scope here.
4. **Migration.** The closed binary ships a one-time, idempotent migration on first run of the seam-aware version: if its brand dir lacks live state but the consolidated `~/.donmai/` has it, move `daemon.jwt` / `daemon.yaml` / `worktrees/` into the brand dir; reconcile any pre-2026-06-02 stale files already sitting in the brand dir. (The original OSS `.rensei`→`.donmai` read-fallback from `ADR-2026-06-02` has already been removed upstream — no consolidation-window fallback remains.)
5. **The closed binary's stale path strings** (`~/.rensei/...` in flag help / comments that currently mismatch the real `~/.donmai` location) are corrected to resolve through the same seam, eliminating the split-brain.

Net end state — clean separation both directions:

| Binary | State dir | Log dir | Service label |
| --- | --- | --- | --- |
| OSS `donmai` (standalone) | `~/.donmai/` | `~/Library/Logs/donmai/` | `dev.donmai.daemon` |
| closed `rensei` (composing) | `~/.rensei/` | `~/Library/Logs/rensei/` | `dev.rensei.daemon` |

## Consequences

### Positive
- OSS `donmai` is brand-neutral *and* self-contained on disk (no Rensei-branded log dir); the closed product's footprint is wholly in the composition layer. The boundary becomes enforceable in both directions.
- Removes the closed binary's `~/.rensei` (help) vs `~/.donmai` (actual) split-brain — the class of bug that produced the `host logs` failure.
- One seam drives state + log dirs consistently; future host-footprint additions inherit brand-awareness for free.

### Negative
- Lock-step multi-repo change: donmai (seam + `internal/statepath` + `installer/launchd` delegate to it) and rensei-tui (set brand + migration + string fixes) must land together, and rensei-tui must adopt the donmai version that introduces the seam.
- A one-time on-disk migration in the closed binary (state files relocate `~/.donmai` → `~/.rensei`). Must be idempotent and crash-safe; a botched migration could orphan a `daemon.jwt` and force a re-register.

### Risks
- If the seam is set *after* any embedded code has already resolved a path, state splits across two dirs for one process. Mitigation: the embedder MUST set the brand before constructing the daemon/runner (assert/log if resolved-before-set).
- Reverses part of `ADR-2026-06-02`'s consolidation for the closed binary; reviewers must confirm this is a refinement (composition-layer identity), not a regression (re-branding the OSS core). The OSS default stays `donmai` — that invariant is the test.

## Alternatives considered

- **Leave it: closed `rensei` keeps using `~/.donmai`.** Rejected: ships an OSS-branded dir to users of the closed product; the inverse log leak (OSS → `~/Library/Logs/rensei`) also stays. The boundary stays violated both ways.
- **Read a `DONMAI_STATE_HOME` env var inside `internal/statepath` itself.** Rejected: re-introduces ambient `os.Getenv` into a *library* package, the exact anti-pattern `ADR-2026-06-02` §1 removed. Env reads belong in the binary entrypoints, not library internals.
- **Promote `internal/statepath` to public and have rensei-tui call a setter.** Acceptable, and effectively what (1) is — but framed as a dedicated `statehome` seam that also owns `LogDir()`, so state + logs share one brand token rather than two parallel setters.
- **Thread a `StateDir` field through every `daemon`/`runner` `Config`.** Rejected as the primary mechanism: far more invasive (dozens of call sites), and host-footprint identity is genuinely process-global, not per-Config. A single init-time seam matches the actual scope.

## Affected documents

- `011-local-daemon-fleet.md` — daemon on-disk state location (state dir + log dir now embedder-injected, OSS default `donmai`).
- `ADR-2026-06-02-oss-brand-neutral-runtime-contract.md` — Decision 5 refined: the `~/.donmai` consolidation becomes the OSS *default* of an injectable seam rather than a hardcode; this ADR is the follow-on, not a reversal.
- Platform-side delta (rensei sets brand `rensei` + migration) lives in the `rensei-architecture` mirrored stub (this ADR's `boundary: shared`).

## Affected work items

- donmai issue: *"Make daemon host-state directory injectable (brand-neutral default)"* — the OSS seam (`statehome`, `internal/statepath` + `installer/launchd` delegation, `cmd/donmai` `DONMAI_STATE_HOME`). Brand-neutral.
- rensei-tui issue: *"Route daemon state/logs to `~/.rensei` via the donmai statehome seam + migrate from `~/.donmai`"* — set brand, one-time migration, fix stale `~/.rensei` help strings, smoke.

## Implementation notes

Land order: donmai seam first (new minor), then rensei-tui bumps to it and sets the brand + migration. The OSS `internal/statepath.Resolve` and `installer/launchd` LogDir/LogPath/ErrorLogPath become thin delegations to `statehome`, so existing callers are untouched. Keep the `statehome` default `donmai` so OSS standalone behavior is unchanged except the (intended) log-dir de-leak to `~/Library/Logs/donmai`. Detailed implementation belongs in the two issues, not here.
