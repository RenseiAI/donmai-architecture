---
status: Accepted
date: 2026-08-03
boundary: OSS-only
---

# ADR-2026-08-03 — Daemon host-status signal completion (outbound status + inbound claim gating + `pool.deleted`)

**Status:** Accepted
**Date:** 2026-08-03
**Boundary:** OSS-only
**Authors:** mark, agent:claude

## Context

The daemon and its orchestrator already had two host-status signals defined in
their wire types, but neither one actually did anything:

1. **Outbound: the daemon computed a lifecycle status and dropped it before the
   wire.** `HeartbeatPayload.Status` (`daemon/types.go:248-251`) is populated
   every beat from `h.opts.GetStatus()` (`daemon/heartbeat.go:285` on `main`),
   but the struct that is actually marshalled onto
   `POST /api/workers/<id>/heartbeat`, `heartbeatRequestBody`
   (`daemon/heartbeat.go:428-440` on `main`), has no `Status` field at all. An
   orchestrator has no way to learn a host is `draining` from the heartbeat
   request, no matter how compliant it is on its own end.
2. **Inbound: the daemon received a host-status signal and never consulted
   it.** The heartbeat response's `hostStatus` (`HostStatusDetail`,
   `daemon/heartbeat.go:466-473`) is stored via the `OnHostStatus` callback
   (`daemon/daemon.go:869-872`) and exposed only through `Daemon.HostStatus()`
   (`daemon/daemon.go:505-529`) for CLI display (`donmai daemon stats`). No
   caller anywhere in the poll/claim path (`daemon/poll.go`,
   `runner/loop.go`) ever read it — a host told `pool_deleted` or
   `pool_draining` kept claiming new work exactly as before.
3. **`pool.deleted` was in the mutation catalogue but unhandled.**
   `applyOneMutation`'s switch (`daemon/mutation_apply.go:92-109` on `main`)
   has cases for `project.enable/disable/add/remove` and
   `modelAccess.set/clear`; anything else — including `pool.deleted` — falls to
   `default:`, which returns `fmt.Errorf("unsupported mutation op %q (upgrade
   daemon?)", m.Op)` and ACKs the mutation as failed, forever, on every
   redelivery.

None of this requires a control plane to fix: both structs, the poll loop, and
the mutation dispatcher are entirely daemon-local. This is squarely an OSS
wire-contract and daemon-behavior gap, independent of which orchestrator the
daemon talks to.

## Decision

The daemon now completes both directions of the host-status signal and
handles `pool.deleted`:

- **Outbound.** `heartbeatRequestBody` gains `Status string
  \`json:"status,omitempty"\`` and the beat construction populates it from
  `payload.Status`. `omitempty` is load-bearing: a daemon with nothing
  meaningful to report sends no key, so an orchestrator can read "absent" as
  "no signal" rather than disambiguating an empty string.
- **Inbound claim gating.** `HostStatusDetail` gains
  `SuspendsClaiming() bool`, which returns true only for the `pool_*` family
  of statuses (`pool_deleted`, `pool_draining`, `pool_disabled`, and — once an
  orchestrator sends it — `pool_paused`); an absent status, `"ok"`, and
  unrecognized values (including `unauthorized`, which has its own
  re-register rail) do not suspend claiming, so a newer orchestrator can never
  take a working daemon offline with a status string the daemon does not
  recognize. `PollService` gains a `ClaimSuspended func() (bool, string)`
  callback, consulted once per poll tick immediately before the poll request
  — skipping the request is the only way to decline work without a
  claim-then-NACK round trip. In-flight sessions, the spawner, and the
  heartbeat loop are untouched; the very next tick re-evaluates, so recovery
  after the signal clears is automatic with no separate "resume" op.
- **`pool.deleted` handling.** `applyOneMutation` now special-cases
  `pool.deleted` before the config lock is taken (it touches no daemon
  config): it records the host status locally (so claiming suspends
  immediately rather than waiting for the next beat to say the same thing),
  logs the orchestrator-supplied candidate pool ids for the operator, and ACKs
  applied. It deliberately does **not** re-bind to another pool itself — the
  registration wire carries no pool id, so re-binding is an orchestrator-side
  action; inventing a client-side rebind flow the orchestrator does not
  implement would be exactly the half-working-client pattern this corpus
  forbids (`BOUNDARY.md`).

## Consequences

### Positive

- Drain semantics (`011-local-daemon-fleet.md` § "Drain semantics") become
  actually observable by an orchestrator for the first time — the daemon side
  of that claim was previously unfulfillable regardless of orchestrator
  correctness.
- A `pool_deleted`/`pool_draining`/`pool_disabled` (and future `pool_paused`)
  signal now actually stops a daemon from claiming new work, closing a gap
  where these states were exposed for CLI display only.
- `pool.deleted` no longer fails every redelivery attempt against a current
  daemon build; the mutation resolves cleanly.

### Negative

- The daemon still cannot rebind itself to a `candidatePoolId` after
  `pool.deleted` — an operator or the orchestrator must re-register the host
  against a new pool. This is a deliberate scope limit (see Decision), not an
  oversight, but it means `pool.deleted` alone does not fully self-heal a
  fleet.
- `ClaimSuspended` is consulted only in the poll loop; a session already
  claimed before the signal arrived runs to completion untouched. This is
  correct per the existing drain-semantics contract (drain never kills
  in-flight work) but means a `pool_deleted` host can still finish work for
  up to one session's duration after the signal lands.

### Risks

- **Unrecognized-status fail-open is deliberate but has a flip side.**
  Because only the known `pool_*` family suspends claiming, a future
  orchestrator-side status value that *should* suspend claiming but is typo'd
  or shipped before the daemon recognizes it will silently fail open (daemon
  keeps claiming). This trades availability for compatibility; revisit if a
  status value ever needs to be "suspend by default, allow-list what doesn't."

## Alternatives considered

**A. Have the orchestrator enqueue a `session.kill`-style directive instead of
a passive status flag.** Rejected — claim suspension is a *don't accept new
work* signal, not a *stop what's running* signal; conflating the two would
either kill sessions the drain contract says must finish, or require a second
signal anyway.

**B. Poll-loop reads `HostStatus()` directly instead of a dedicated
`ClaimSuspended` callback.** Rejected — coupling the poll loop to the exact
shape of `HostStatusDetail` makes every future status addition a poll-loop
change. The callback indirection lets `daemon.go` own the mapping from status
string to suspend/allow, one place, with `SuspendsClaiming()` as the single
source of truth pollable from tests without a running daemon.

## Affected documents

- `011-local-daemon-fleet.md` — § "Drain semantics" step 1 overclaimed that
  updating the registered status is sufficient for an orchestrator to route
  around the host; corrected in this commit to note the heartbeat-wire
  dependency this ADR closes.
- `013-orchestrator-and-governor.md` — § "The worker" documents a *different*
  `RegisterRequest.Status` struct (`donmai/worker/types.go`) than the one this
  ADR touches (`donmai/daemon/types.go` `HeartbeatPayload` /
  `heartbeatRequestBody`); added a footnote distinguishing the two
  daemon-heartbeat implementations so future readers don't conflate them the
  way the outbound wire gap this ADR fixes went unnoticed.

## Affected work items

- W1 capacity consolidation, lane **W1-E** (daemon-side host-status
  completion) — the orchestrator-side counterpart lives in the platform repo
  (out of scope for this corpus) and is tracked as `platform-only` doc content
  in `rensei-architecture`.

## Implementation notes

This lands as a single commit, `eb38cb0` ("feat(daemon): honour host status in
the claim path and handle pool.deleted"), on branch
`worktree-w1e-hoststatus-honour`. **As of this ADR's date the branch carries an
open, unmerged pull request (#249) — it is not yet on `main` and has not
shipped in a released `donmai` binary.** The architectural decision is
accepted and the implementation exists; do not cite this ADR as evidence that
a downloadable `donmai` build sends `heartbeatRequestBody.Status` or handles
`pool.deleted` until the PR merges and a release ships. Key symbols for
reviewers: `HostStatusDetail.SuspendsClaiming()` (`daemon/heartbeat.go:513` on
the branch), `PollService.ClaimSuspended` (`daemon/poll.go:399`,
consulted at `daemon/poll.go:575-578`), `applyOneMutation`'s `pool.deleted`
branch (`daemon/mutation_apply.go:89`).
