---
status: Accepted
boundary: shared
split: sibling-extensions
date: 2026-06-15
---

# ADR-2026-06-15 — Turn-result manifest is the deterministic turn outcome

**Status:** Accepted
**Date:** 2026-06-15
**Boundary:** shared
**Authors:** turn-manifest agent (W3)

## Context

When an agent session ends, the orchestration layer needs to know the turn's
outcome — the QA/acceptance verdict, a summary, and the artifacts the turn
produced (the PR it opened, the commit it pushed). Until now that outcome
reached the platform only by SCRAPING the agent's free-form final message for an
inline `WORK_RESULT:<verdict>` marker (and, on the platform side, by re-scanning
durable issue comments for the same marker).

The scrape is fragile:

1. **Weak tool users forget or misplace the marker.** A model that ends with
   prose instead of the marker, or buries `WORK_RESULT:passed` mid-paragraph,
   produces `result=unknown` and stalls the SDLC chain.
2. **Non-final turns leak markers.** A background-poll wakeup (memory inject,
   steering) can re-emit a stale pre-wakeup message whose marker no longer
   reflects the true outcome.
3. **Providers with no terminal message.** Codex's terminal event carries no
   text, so the marker (and the summary) are absent unless the runner falls back
   to the last assistant message — another scrape.

This is the same class of problem the execution layer already solved for
structured completion: the one-shot lane (`agent/oneshot.go`) validates the
model's JSON output against a schema rather than parsing prose. The turn outcome
deserves the same treatment.

## Decision

**The agent writes its turn outcome to a structured file —
`.agent/turn-result.json` — and the runner reads + validates it as the FIRST
tier of the verdict resolution order.** The inline `WORK_RESULT` marker is
retained as a backstop for agents that did not (or could not) write the file.

The manifest is a minimal, versioned contract carrying only the **agent-owned**
half of the session completion contract
(`013-orchestrator-and-governor.md` § "completion contracts"):

```json
{
  "schemaVersion": 1,
  "verdict": "passed | failed | blocked",
  "summary": "<one line>",
  "blockedReason": "<reason, when verdict=blocked>",
  "pullRequestUrl": "<pr url, when one was opened>",
  "commitSha": "<head sha, advisory>"
}
```

`verdict` reuses the existing marker vocabulary (`passed` / `failed` / `blocked`)
so the platform consumes either channel uniformly. Runner-owned signals (cost,
provider session id, failure-mode classification, the authoritative
post-backstop head sha) stay on the terminal result envelope, NOT in the
manifest.

Resolution order in the runner (`runner/loop.go`):

1. **`ParseManifest`** reads `.agent/turn-result.json`, validates it against a
   JSON Schema (the same `santhosh-tekuri/jsonschema/v6` pattern as the one-shot
   lane), and rejects an unrecognised `schemaVersion`. The manifest verdict and
   summary OVERRIDE the scraped marker. A `blocked` verdict feeds the same
   blocked-classification fork the marker scan produces.
2. **Marker scrape** (`scanWorkResult`) — the prior behaviour, now the fallback.
3. **Deterministic backstop** — unchanged, the last resort.

The runner posts the validated manifest VERBATIM on the terminal status wire
(`result/poster.go` gains an additive `manifest` field). The platform applies it
through the issue-tracker session adapter's `applyTurnManifest`, idempotent by
content hash so racing/retried terminal posts apply it at most once.

The prompt templates (`prompt/templates/*.tmpl`) instruct the agent to write the
manifest FIRST and emit the marker as a fallback — a far more reliable
instruction for a weak tool user than "end your final message with exactly one
marker on its own line".

## Consequences

### Positive

- **Deterministic turn outcome.** A structured file the agent wrote is far more
  reliable than a marker scraped from prose — fewer `unknown_result` stalls.
- **Provider-agnostic.** Codex (no terminal message) and any future provider get
  the same structured channel; no dependence on a terminal-message scrape.
- **Single source of truth.** The manifest carries the PR url + commit sha the
  durable CI / merge gates already correlate on — preferred over scraped values.
- **Back-compat both directions.** A new runner against an old platform degrades
  to the scalar fields; an old runner against a new platform posts no manifest
  and the platform falls back to the marker scan. The wire move is purely
  additive.

### Negative

- One more file the agent must write, and one more validation path in the runner
  + one more adapter method on the platform.
- The manifest duplicates a little of what the scalar fields already carry
  (verdict, summary, PR url) — accepted, because the structured object is what
  the platform's idempotent apply consumes.

### Risks

- A malformed agent-written manifest could be silently swallowed. Mitigated:
  `ParseManifest` distinguishes "no file" (benign fallback) from "file present
  but invalid" (logged warn), and both fall through to the marker scrape — never
  worse than today.
- Schema drift between the runner's parse type and the wire carrier. Mitigated:
  the runner's `TurnManifest` is a type ALIAS of the agent-package wire struct
  (`agent.TurnManifest`), so there is one source of truth across parse + wire.

## Alternatives considered

- **Keep scraping the marker only.** Rejected: the fragility above is the
  motivating problem; weak tool users stall chains.
- **Make the manifest authoritative with NO marker fallback.** Rejected for now:
  the marker fallback is the mixed-version safety net (an old runner, or an agent
  that wrote no file, must still transition). The marker is cheap to keep.
- **Carry only the scalar fields, no nested manifest object on the wire.**
  Rejected: the platform's idempotent `applyTurnManifest` wants the structured
  object (content-hash dedup of the whole turn outcome), and the nested object
  documents the contract on the wire.

## Affected documents

- `013-orchestrator-and-governor.md` § "completion contracts" — the agent-owned
  half of the completion contract is now a structured manifest file
  (`.agent/turn-result.json`) read first by the runner, with the `WORK_RESULT`
  marker as the fallback.

See the platform-side extensions in the mirrored stub
`rensei-architecture/ADR-2026-06-15-turn-result-manifest.md` for the
`IssueTrackerSessionAdapter.applyTurnManifest` contract, the status-route +
session-event-bridge wiring, and the SDLC system-card prompt change.

## Implementation notes

- donmai: `runner/manifest.go` (`TurnManifest` alias + `ParseManifest` +
  `applyTurnManifest` fold), `runner/loop.go` (resolution order, step 10·M),
  `result/poster.go` (additive `manifest` wire field), `agent/types.go`
  (`agent.TurnManifest` + `Result.Manifest`), `prompt/templates/*.tmpl`.
- Lock-step: `result/poster.go`'s new `manifest` field is a wire move. The
  `rensei` binary needs a `donmai` go.mod bump to emit manifests; that bump
  lands in the consolidated W3 release, NOT with this change. The default-false
  / additive design means a skewed peer simply omits the manifest and the
  platform falls back to the marker.
