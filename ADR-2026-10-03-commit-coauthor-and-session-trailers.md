---
status: Proposed
date: 2026-10-03
boundary: shared
split: sibling-extensions
---

# ADR-2026-10-03 — Commit co-author and session trailers on agent commits

**Status:** Proposed. Architecture only; nothing is built. Acceptance lands
the corpus edits under "Affected documents" in the same commit.
**Date:** 2026-10-03
**Boundary:** shared. OSS-canonical here: two optional session-contract
fields, their intake validation, two commit trailers, the runner-owned hooks
directory that adds them, and the precedence of a host-supplied author
identity. How a hosted control plane decides whose credit a session carries,
and freezes it, lives in the platform corpus's sibling ADR and this ADR's
mirrored stub.
**Authors:** architecture lane, filed by the coordinator session.

## Context

1. **The default author names the session.**
   `ADR-2026-06-15-kit-session-start-context.md` has the runner stamp
   `Donmai Agent (<issueIdentifier>)` and `agent+<sessionId>@donmai.dev` as
   author and committer. The session id in that email is how a commit is
   traced back to its session today.
2. **Hosts replace the author.** `runner/loop.go` `buildSessionEnv` already
   honors a `GIT_AUTHOR_*` / `GIT_COMMITTER_*` identity found in the runner's
   own environment over that default, and `runner/backstop_test.go` tests it.
   A host that authors every commit as one fixed service account does this,
   for example so that a deployment service recognizes the author. No ADR
   records the precedence. Once the author is fixed, nothing in the commit
   names the session.
3. **Human credit needs a trailer.** Git hosts render a
   `Co-Authored-By: Name <email>` trailer as a second contributor. A trailer
   is part of the commit message, and no environment variable adds one. The
   runner has to append it, and it has to receive the name and email.
4. **There are two commit producers.** The runner's backstop commit
   (`runner/backstop.go`), and commits the agent makes itself with
   `git commit` from its shell.
5. **Repositories redirect their hooks.** Many repositories set
   `core.hooksPath` from a package-manager lifecycle script or a setup
   script. After that, a hook placed in `<git-dir>/hooks` never runs. Agents
   commonly run a repository's install step during a session.
6. **Harnesses add their own co-author lines.** Some harnesses append a
   `Co-Authored-By` line naming the model to every commit. Logic that skips
   "when a co-author trailer is present" would drop a human's credit.
7. **A session provenance key exists, but not on the runtime path.**
   `008-version-control-providers.md` lists `X-Donmai-Session-Id` among the
   git provider's provenance trailers, and `landing/vcs/github.go` emits it.
   That package is not wired into the session runtime, so no runtime commit
   carries a session trailer today.
8. **Workareas can hold several repositories.**
   `ADR-2026-08-22-session-owned-multi-repository-workarea.md` makes commits,
   branches and the backstop apply per `mutable` repository.

## Decision

### D1 — The session contract carries an optional commit co-author

- Two optional fields, `CoAuthorName` and `CoAuthorEmail` (JSON
  `coAuthorName`, `coAuthorEmail`, `omitempty`), on the poll work item
  (`daemon/poll.go`), the session detail and session spec
  (`daemon/types.go`), and queued work in the runner. They map wherever the
  MCP bearer maps today (`PollItemToSessionSpec`).
- They are additive. Old runners ignore them and old work sources never send
  them. Mapping tests cover both directions, as for the `codeIntel` block of
  `ADR-2026-07-05-self-referential-stdio-mcp-in-box-capability.md`.
- They travel as a pair. One without the other is dropped.
- The runner never resolves identity. The work source that sets the pair owns
  its truth; the runner checks only its syntax.

### D2 — The runner validates the pair at intake and before use

The runner drops the pair when either value contains CR, LF, NUL, `<` or `>`,
or the substring `Co-Authored-By:` (case-insensitive), or when the email is
not a single address with exactly one `@` and no whitespace. It logs a
warning that names the session and the reason, never the values, and the
session runs with no co-author. The same check runs again before each use.

### D3 — Two trailers

```
Co-Authored-By: <CoAuthorName> <CoAuthorEmail>   (when the pair is present)
Agent-Session: <sessionId>                        (on every session commit)
```

- **`Agent-Session` restores traceability under any author identity.** It is
  present when no co-author is set and whatever identity the host supplied.
- **The key is brand-neutral.** Commit history is permanent. This project's
  provenance keys have been renamed before, and a key that names a product
  outlives the product name.
- **Idempotence is per exact line.** A trailer is appended only when that
  exact line, key and value, is absent. Other `Co-Authored-By` lines stay, so
  a harness's own co-author line and the human's sit side by side. Amend,
  rebase and backstop commits keep exactly one copy.
- **One key for every producer.** The landing path's session trailer moves to
  `Agent-Session` as well, so a session has one provenance key. The other
  `X-Donmai-*` provenance keys and the landing path's agent co-author line are
  unchanged by this ADR.

### D4 — Backstop commits pass the trailers as arguments

The runner passes each trailer as a `--trailer` argument (argv, never through
a shell) on every backstop commit, in every `mutable` repository. The hook of
D5 also runs on a backstop commit; exact-line idempotence keeps one copy.

### D5 — Agent commits go through a runner-owned hooks directory

- **Location.** Per session, the runner writes a hooks directory and a
  trailer data file into the session's runner state directory, outside every
  repository (directory and hooks `0700`, data file `0600`). Nothing in a work
  tree can stage them.
- **Selection.** The session environment selects that directory with
  command-scope git configuration: it appends
  `core.hooksPath=<dir>` through `GIT_CONFIG_COUNT`, `GIT_CONFIG_KEY_<n>` and
  `GIT_CONFIG_VALUE_<n>`, preserving any entries already present. Command
  scope outranks system, global, repository-local and worktree
  configuration, so the selection holds after a repository sets
  `core.hooksPath`, and it covers every repository the session commits in,
  linked worktrees included.
- **Chaining.** The directory holds a dispatcher for every hook name git
  defines. Each dispatcher first runs the repository's own hook of the same
  name, with the same arguments and standard input, and propagates its exit
  status. The repository's hook is found from its own configuration files'
  `core.hooksPath`, else from `git rev-parse --git-path hooks`. Repository
  hooks keep working, and a failing repository hook still blocks its commit.
- **Appending.** `prepare-commit-msg` then appends each line of the data file
  to the message file, exact-line idempotent (D3). It reads the data file
  verbatim and never interpolates its values in a shell.
- **Lifecycle.** The runner writes both at provision, rewrites them from the
  session spec on resume, and removes them at teardown.
- **Minimum git.** Command-scope configuration through the environment needs
  git 2.31 or later. With an older git the runner logs that agent-commit
  trailers are unavailable; backstop commits still carry them.
- **What it cannot cover.** A commit made without `git commit` (plumbing such
  as `git commit-tree`, a commit made through a hosting API) and a commit
  that passes an explicit `-c core.hooksPath=` (which outranks the
  environment) get no trailers from the hook.

### D6 — A host-supplied author identity overrides the default

When the runner's environment carries `GIT_AUTHOR_NAME` and `GIT_AUTHOR_EMAIL`,
they win over the default identity of `ADR-2026-06-15`. `GIT_COMMITTER_NAME`
and `GIT_COMMITTER_EMAIL` fall back to the author values. This is existing
behavior, now recorded. The default identity itself is unchanged. The
trailers of D3 are independent of whichever identity authors the commit.

### D7 — What this ADR does not decide

- **Whose credit a session carries.** A work source decides. A hosted control
  plane records how it resolves and freezes the pair in its own corpus.
- **A local operator source.** A standalone daemon could fill the pair from
  its own configuration. That is a later amendment.
- **Commit signing and the other provenance keys.**

**OSS defaults.** With no pair set, a session's commits carry
`Agent-Session` and nothing else new, and the default author identity is
unchanged. Nothing here needs a control plane, as `001` requires.

## Consequences

### Positive

- A session's owning human can be credited on every commit it makes, without
  the runner knowing where the credit came from.
- Every session commit names its session, whatever identity authored it.
- Repository hooks keep running, including in repositories that redirect
  `core.hooksPath`.
- A harness's own co-author line and the human's coexist.

### Negative

- Every agent commit now passes through a runner-owned dispatcher.
- Every session commit gains one trailer line.
- Agent-commit trailers need git 2.31 or later.

### Risks

- **Hook chaining regressions.** A dispatcher that alters arguments, standard
  input or exit status would break or silently weaken a repository's own
  hooks. Mitigation: fixtures for a repository that sets `core.hooksPath`,
  one that uses `<git-dir>/hooks`, and a failing repository hook.
- **Environment drift.** A tool that clears the environment before calling
  git bypasses the selection. Backstop commits still carry the trailers.
- **Value injection.** A crafted name could try to inject a trailer or a
  header. Mitigation: D2 at intake and before use, argv-only backstop
  trailers, and a hook that never evaluates values.

## Alternatives considered

- **A hook in `<git-dir>/hooks` per clone, skipping when any co-author
  trailer exists.** Rejected: silent once a repository sets `core.hooksPath`
  (Context item 5), and it drops the human's line when a harness adds its own
  (item 6).
- **Setting `core.hooksPath` in each repository's local config.** Rejected: a
  repository's own setup step overwrites it, and it mutates repository state.
- **Wrapping the `git` binary.** Rejected: invasive, and tools that resolve
  git on their own bypass it.
- **`commit.template`.** Rejected: it seeds only editor-composed messages;
  `git commit -m` ignores it.
- **Keep the session id in the author email.** Rejected: it conflicts with a
  host-supplied fixed identity (D6).
- **Keep `X-Donmai-Session-Id`.** Rejected for the runner: a product-named
  key in permanent history, and two keys for one fact.

## Affected documents

Edited in the accepting commit:

- `ADR-2026-06-15-kit-session-start-context.md` — an amendment recording D6
  (host-supplied identity precedence) and the `Agent-Session` trailer.
- `008-version-control-providers.md` — in the git provider's provenance
  trailer block, `Agent-Session` replaces `X-Donmai-Session-Id`.
- `013-orchestrator-and-governor.md` — completion contracts and backstop: the
  backstop's commits carry the D3 trailers in every `mutable` repository.
- `README.md` — index entry (this commit) and status at acceptance.
- `AGENTS.md` — a read-order row for commit identity and trailers, at
  acceptance.

No `BOUNDARY-SYNC` region is touched.

## Affected work items

This corpus carries no tracker identifiers; the delivery work is named by
shape:

- the two contract fields, their mapping and intake validation;
- backstop trailers in every `mutable` repository;
- the runner-owned hooks directory: dispatchers, the data file, the
  environment selection, provision, resume and teardown;
- the landing path's session key moving to `Agent-Session`;
- fixtures: a repository that sets `core.hooksPath`; a commit that already
  carries another co-author line; amend; a failing repository hook; a
  multi-repository workarea; an invalid pair.

## Implementation notes

- **Dispatcher form.** Each hook can be a small file that executes the
  runner binary with a hook subcommand (`os.Executable()`, as in
  `ADR-2026-07-05`), so no shell parses a value. A POSIX shell script that
  only reads the data file is acceptable.
- **Appending.** `git interpret-trailers --in-place --trailer <line> <file>`
  appends a line in trailer position; the exact-line check runs first.
- **Environment.** Read the current `GIT_CONFIG_COUNT`, append the
  `core.hooksPath` pair at index `n`, and set the count to `n + 1`. Never
  overwrite existing pairs.
- **Resume.** The pair comes from the durable session spec, so a resumed
  session rewrites the same data file.
