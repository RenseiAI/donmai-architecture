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
