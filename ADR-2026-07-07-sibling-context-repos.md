---
status: Accepted
boundary: OSS-only
---

# ADR-2026-07-07-sibling-context-repos

**Status:** Accepted
**Date:** 2026-07-07
**Boundary:** OSS-only
**Authors:** agent (org agent-docs convention program, 2026-07-07)

## Context

Every repo's `AGENTS.md` now contracts that the governing architecture corpus is
readable at `../<corpus>` (sibling of the working repo), and routes agents to
corpus playbooks (`agents/PROTOCOL.md`) before contract-touching work. Runner
workspaces, however, are provisioned as single-repo clones
(`runtime/worktree.Manager.Provision`): cloud sandboxes boot bare, so a
dispatched agent that needs the corpus must burn turns cloning it manually —
or, worse, skip the read.

The daemon's poll payload already carries a per-session `env` map on each work
item, which downstream control planes populate at dispatch. That gives us a
brand-neutral, zero-wire-change carrier for a workspace-shape hint.

## Decision

The runner honors a `DONMAI_SIBLING_REPOS` environment variable on the work
item (`work[].env`; process env as fallback for standalone runs):

- Value: comma-separated entries, each `<git-url>` or `<git-url>#<ref>`.
- For each entry the runner shallow-clones (`git clone --depth 1`, plus
  `--branch <ref>` when given) into a directory **sibling to the session
  worktree**, named from the URL basename with any `.git` suffix stripped.
- An existing sibling with a `.git` dir is freshened best-effort
  (`git -C <dir> pull --ff-only --quiet`); freshen failure keeps the stale copy.
- Provisioning is guarded by a per-target-directory mutex (concurrent sessions
  may share a parent directory) and rejects unsafe names (empty, path
  separators, `.`/`..`, or a collision with the session worktree itself).
- **Sibling failures are never fatal to the session** — the runner logs a
  warning and proceeds; agents fall back to cloning per their `AGENTS.md`.

Sibling repos are read-only context. Nothing in the runner writes to them, and
completion contracts do not consider them.

## Consequences

### Positive

- Dispatched agents find the corpus exactly where every `AGENTS.md` says it is,
  in both hosted sandboxes and local daemons, without extra credentials logic
  in the agent loop (the URL may carry whatever auth the dispatcher embeds).
- Zero wire-protocol change: the mechanism rides the existing `env` map, so old
  daemons ignore it and old control planes simply never set it.
- Generic: any repo set can be materialized (docs corpora, shared fixtures),
  not only architecture corpora.

### Negative

- Shallow clones show truncated history; agents verifying doc freshness via
  deep `git log` must fetch more depth themselves.
- A stale-but-present sibling (failed freshen) is silently older than origin;
  the warning appears only in runner logs.
- The env value is a comma-separated string, so repo URLs containing commas are
  unsupported (accepted; git URLs do not contain commas in practice).

Amends `013-orchestrator-and-governor.md` (§ Sibling context repos).

## Amended 2026-08-22 — the destination moves under the session root

`ADR-2026-08-22-session-owned-multi-repository-workarea.md` (Accepted
architecture; implementation and migration pending) changes **where a sibling
lands and who owns it**, and nothing else about this ADR.

What changes, once that ADR's D2 ships:

- The destination is a per-session `context` leaf at
  `<workareaRoot>/<name>` — inside the session-owned directory — instead of a
  directory beside the session worktree in a shared parent.
- The per-target-directory mutex above becomes unnecessary. It exists because
  "concurrent sessions may share a parent directory"; under a per-session leaf
  namespace there is no shared target to serialise on. It also only ever covered
  provisioning, never concurrent *use* of the shared copy — the defect that
  motivated the move.
- The "collision with the session worktree itself" rejection is subsumed by that
  ADR's D5 leaf-name rules (validation, reserved names, and duplicate-leaf
  refusal naming both entries rather than auto-renaming).
- Cleanup, disk accounting, archive, and restart adoption reach the clone for
  the first time, because it is now inside the object those authorities bind
  (D7). A context clone can no longer outlive the session that created it, and is
  charged to exactly one session.

What is preserved verbatim:

- **The wire.** `DONMAI_SIBLING_REPOS`, its comma-separated `<git-url>[#ref]`
  grammar, and the `work[].env` carrier with process-env fallback are unchanged.
- **The `../<name>` promise.** A context leaf sits beside the selected
  repository's leaf under the same root, so the relative path from the harness
  working directory is `../<name>` exactly as before. No repo's `AGENTS.md`
  changes.
- **Read-only by default, never fatal, freshen best-effort.** A `context`
  repository defaults to `read-only` authority, freshen failure keeps the stale
  copy, and sibling failure never fails the session.
- **The old placement stays correct until D2 ships.** A runner without the new
  provisioner honours this ADR as written above; that is current behaviour and
  this text describes it truthfully.

Pre-existing clones already sitting in a shared parent are **not** adopted,
charged, or deleted by that ADR — deleting one could delete another live
session's context. They are reported as an unowned-legacy condition and
reclaimed by explicit operator action (D9.4).
