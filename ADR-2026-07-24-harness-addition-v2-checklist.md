---
status: Accepted
boundary: shared
date: 2026-07-24
---

# ADR-2026-07-24-harness-addition-v2-checklist

**Status:** Accepted (founder decision 2026-07-24, runs/2026-07-21-open-harness-strategy)
**Date:** 2026-07-24
**Boundary:** shared (the checklist binds OSS harness authors and the
platform enablement steps that follow each OSS landing; `status: Mirrored`
stub in `rensei-architecture`)
**Authors:** open-harness strategy run, filed by the coordinator session

## Context

ADR-2026-06-06 made adding a harness "a manifest row, not a rewrite." Two
native additions executed under that contract surfaced requirements the
contract does not state: third-party harnesses ship multiple releases per
day (an unpinned binary makes every smoke non-reproducible and every cell
claim unstable); harnesses differ radically in shipped policy surface (one
arrives with a rich permission model to project onto, another ships none and
the trust boundary must be injected); and a shipped adapter violated the
exactly-one-terminal-event contract in a way only a conformance test catches.

## Decision

Amend the harness-addition procedure: a new harness (or a harness binary pin
bump) is DONE only when every row below holds.

| # | Requirement | Enforced by |
|---|---|---|
| 1 | **Binary pin.** The harness binary version is pinned in matrix metadata (`binaryPins`: min/pinned/verified-against). Construction fails below min; above verified-against runs but labels the session. | matrix parity gate + provider probe test |
| 2 | **Pin-bump protocol.** Bumping a pin re-runs the full harness smoke lane against the new pin in CI before merge. A red lane blocks the bump. | smokes CI |
| 3 | **Policy injection.** The adapter enforces the resolved policy (allowed/disallowed tool patterns, permission default, MCP whitelist) via the harness's native config where one exists, and via an injected, handshake-verified boundary where none exists. Autonomous sessions never use a blanket permission bypass when a deny-preserving mode exists. | permission-denial smoke (mandatory) |
| 4 | **Fail-closed trust boundary.** Where the boundary is injected, the session must fail to start if the boundary is not verifiably active, and must abort if boundary integrity is lost mid-session. | fail-closed + bypass-monitor smokes |
| 5 | **Endpoint pin.** The adapter reads `Spec.Endpoint`, honors `Endpoint.Model` over `Spec.Model`, hard-blocks provider fallback outside the resolved cell, and fails loudly on a company/host it cannot route. | provider-lockout smoke |
| 6 | **Event-contract conformance.** Exactly one Init event, complete (never per-token) assistant texts, exactly one terminal event, then channel close — asserted by a reusable conformance test every adapter runs. | shared conformance test in the agent package |
| 7 | **Smoke set.** spawn, prompt, event-stream shape, permission-denial, teardown (plus injection/steer, resume/replay, and env-hygiene where the caps claim them) against the pinned binary, platform-free. | smokes repo lane per harness |
| 8 | **Tier entry.** New cells enter at `untested` and are non-routable as cascade defaults until `smoke-validated`; capability claims follow the measurement ladder, never the manifest. | router tier gate (platform) |

## Consequences

### Positive

- Reproducible cells.
- Uniform trust posture across permission-rich and permission-less harnesses.
- A conformance test that catches the terminal-event bug class once for all
  adapters.

### Negative

- Adding a harness is more than a manifest row again — deliberately; the row
  was always the ARCHITECTURAL cost, and this table is the OPERATIONAL cost
  that keeps cells honest.

### Risks

- Pin lag versus fast-moving upstreams — accepted; the ladder
  (min / pinned / verified-against) lets operators run ahead with a label.

## Alternatives considered

- **Fold this table into ADR-2026-06-06 as a silent doc edit rather than a
  new ADR.** Rejected as the primary path: the table is itself a decision
  record (new mandatory gates, not a clarification), so it is filed as its
  own ADR; ADR-2026-06-06 §Affected documents is amended in the same commit
  to cross-reference it. Either shape carries identical checklist content,
  so a future maintainer that prefers the amendment-only form loses nothing
  by treating this ADR's decision record as the amendment's changelog entry.

## Affected documents

- `ADR-2026-06-06-two-axis-provider-model.md` — D3/D7 operational amendment;
  add a cross-reference from its harness-addition guidance to this ADR.
- Matrix spec — `binaryPins` section.
- Smokes repo charter — per-harness lanes.
- Capability-tier ADR / eval-spine design — row 8 dependency.

## Affected work items

Tracked under the open-harness strategy program
(`runs/2026-07-21-open-harness-strategy/`); rows 1/2/6 are Wave 0 of
`12-work-breakdown.md` (partially landed — see that file's W0 status note),
the remaining rows land with each harness's own wave. No fleet tracker issue
is cited inline per this corpus's brand-neutral discipline.

## Implementation notes

The opencode and pi harness additions are the two native additions that
motivated this amendment; their wave-by-wave application of the checklist is
tracked in `runs/2026-07-21-open-harness-strategy/12-work-breakdown.md`
(Waves 0, 2a, 2b). Detailed implementation belongs in the `donmai` and
`donmai-smokes` repos, not here.
