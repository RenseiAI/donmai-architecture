---
status: Accepted
boundary: OSS-only
---

# ADR-2026-06-13-daemon-sessionhandle-enrichment

**Status:** Accepted
**Date:** 2026-06-13
**Boundary:** OSS-only
**Authors:** Platform Parity Program — W1 corpus lane (Claude Sonnet 4.6)
**Amends:** `ADR-2026-05-07-daemon-http-control-api.md` — additive extension to the SessionHandle wire type

## Context

The daemon's `/api/daemon/sessions` and `/api/daemon/sessions/<id>` endpoints
(specified in `ADR-2026-05-07-daemon-http-control-api.md`) returned a `SessionHandle`
that identified a session by id and status but carried no filesystem-location
information. The local fleet-watch TUI (`donmai fleet-watch` / the OSS dashboard,
`011-local-daemon-fleet.md`) renders a per-session table; without a worktree path,
project name, or repository origin on the wire, the table showed only opaque session
IDs and states — not useful at a glance.

Three additive string fields resolve this without breaking existing readers (fields are
nullable; absent-field means "unknown"):

- `worktreePath` — the absolute path of the worktree the session is executing in.
- `projectName` — the human-readable project name (e.g., the repository directory
  basename or a user-supplied label).
- `repository` — the git remote origin URL for the repository (if determinable).

The enrichment is shipped in donmai PR #148 (released v0.40.0) and is strictly additive:
the daemon populates the fields when the information is available at session-start; absent
or unknown values are emitted as empty strings or omitted. Readers MUST NOT fail on
missing fields.

## Decision

Add three optional string fields to `SessionHandle` in the daemon's HTTP control API:

```go
// SessionHandle (GET /api/daemon/sessions and /api/daemon/sessions/<id>)
type SessionHandle struct {
    ID     string `json:"id"`
    Status string `json:"status"`

    // Enrichment fields (additive; may be empty string or absent)
    WorktreePath string `json:"worktreePath,omitempty"` // abs path of working dir
    ProjectName  string `json:"projectName,omitempty"`  // human label
    Repository   string `json:"repository,omitempty"`   // git remote origin URL
}
```

### Back-compat contract

- Existing readers that do not read `worktreePath`, `projectName`, or `repository`
  continue to function without modification.
- The daemon MUST NOT require these fields to be populated in order to create a session
  handle; they are populated best-effort from session-start metadata.
- Readers that consume these fields MUST treat an absent, null, or empty string value
  as "unknown" — they MUST NOT error or crash.
- The fields are never used for identity or routing; they are display-only annotations.

### Population rules

The daemon populates the fields at session-start from information available in the
session-start request or derivable from the working directory:

1. `worktreePath` — resolved from the session's working directory parameter; absolute
   and canonicalized.
2. `projectName` — derived from `filepath.Base(worktreePath)` if no explicit label is
   supplied; falls back to empty string if the path cannot be resolved.
3. `repository` — derived from `git remote get-url origin` in `worktreePath` at
   session-start; empty string if the directory is not a git repo or has no origin.

None of these derivations block session creation. Failures are logged at DEBUG level
and the field is emitted as empty; the session proceeds normally.

### Fleet-watch reader pattern

The local fleet-watch TUI reads `SessionHandle` from `GET /api/daemon/sessions` and
renders the enriched fields in the session table. The expected reader pattern:

```go
for _, s := range handles {
    displayPath := s.WorktreePath
    if displayPath == "" {
        displayPath = "<unknown>"
    }
    displayProject := s.ProjectName
    if displayProject == "" && displayPath != "<unknown>" {
        displayProject = filepath.Base(displayPath)
    }
    // render row: s.ID, s.Status, displayProject, displayPath, s.Repository
}
```

Readers SHOULD NOT attempt to re-derive `projectName` or `repository` from
`worktreePath` at read time — the daemon's values are the authoritative source. A
reader that needs a display label and finds `projectName` empty MAY fall back to
`filepath.Base(worktreePath)` for display, as shown, but MUST NOT write the derived
value back.

## Consequences

### Positive

- Fleet-watch table rows are immediately human-readable without requiring the operator
  to cross-reference a session ID against an external log.
- The enrichment is additive and zero-migration: no daemon-restart, no schema change,
  no protocol version bump.
- The population logic is centralized in the daemon (session-start path), not scattered
  across each consumer.

### Negative

- `projectName` is a derived label (from directory basename), not a user-defined name.
  It may not match the user's mental model of the project. A future extension could
  accept an explicit `projectLabel` in the session-start request.
- `repository` requires a subprocess call (`git remote`) at session-start. On
  non-git worktrees this is a no-op error; on large repos with slow remotes, the call
  is near-instant (reads local config, not the network).

### Risks

- A future breaking change to `SessionHandle` (e.g., changing `id` to a UUID type)
  would require a wire-version bump; this ADR's additive extension does not. New
  breaking changes still require a version gate.

## Alternatives considered

- **Add a dedicated `/api/daemon/sessions/<id>/context` sub-endpoint.** Rejected:
  it splits what is logically one object into two round-trips. The enrichment fields
  are small strings with no security impact; co-locating them with the handle is the
  simpler choice.
- **Client-side derivation (reader calls `git remote` itself).** Rejected: the reader
  (the fleet-watch TUI) may not have access to the worktree (remote reader case) and
  should not shell out to git on behalf of the daemon's local state. Daemon-side
  population is authoritative.
- **Store enrichment in the session database / state file.** Out of scope for this ADR;
  in-memory session state at the daemon is sufficient for the fleet-watch use case.

## Affected documents

- `ADR-2026-05-07-daemon-http-control-api.md` — this ADR extends the `SessionHandle`
  type defined there; the parent ADR does not need to be edited (this ADR is the
  amendment record).
- `011-local-daemon-fleet.md` — the fleet-watch subsection should note that
  `SessionHandle` now carries `worktreePath`, `projectName`, and `repository` for
  display in the session table.

## Affected work items

- donmai PR #148 — implementation; released in v0.40.0.
- TUI host-watch dashboard (donmai PR #148) — the B2 dashboard surface from the
  Platform Parity Program FD-9 inventory (shipped).

## Implementation notes

- Changes are in `donmai/daemon/session.go` (SessionHandle type) and the session-start
  handler; the HTTP client types in `afclient/session_types.go` gain the three new
  fields.
- Fleet-watch TUI (`afview/fleet/`) reads the enriched fields from the list response.
- No test changes beyond adding the new fields to the fixture JSON in the handler unit
  tests — existing tests continue to pass because `omitempty` means the fields are
  optional in both marshal and unmarshal directions.
