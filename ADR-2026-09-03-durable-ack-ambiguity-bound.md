---
status: Accepted
date: 2026-09-03
boundary: shared
split: synchronized-mirror
---

# ADR-2026-09-03 — Durable-acknowledgement ambiguity bound (rule 8)

**Status:** Accepted
**Date:** 2026-09-03
**Boundary:** shared (the ambiguous-state ruling, the durable-acknowledgement
ambiguity bound, and the `durable_ack_timeout` reason are OSS-canonical here;
a composing control plane's own durable-receipt latency, retry policy, and
operational response to slow acknowledgement remain a platform extension)
**Authors:** session-continuity design lane

## Context

`ADR-2026-08-17-session-shim-adoption.md` core contract rule 8's *Amendment
2026-09-02 — carrier-fault re-adoption precedes quarantine* draws a line
between a shim whose controller **socket** failed and one whose controller
stream ended "for a carrier fault (the daemon lost its durable carrier, not
the shim's socket)." Only the first case is a candidate for the
`socket_unreachable` quarantine reason; the second re-adopts through the D4
pipeline first. That line assumed the two cases are cleanly distinguishable
at the moment the daemon has to decide. They are not, for one specific
overlap this amendment did not name: a shim can hold a **connected**
controller socket while the daemon's durable acknowledgement of that shim's
events from the control plane is still outstanding — the socket answers, the
durable post-condition has not landed. That overlap is neither "the shim's
socket failed" nor "re-adoption has resolved"; it is a third state the 2026-
09-02 amendment had no name for.

`ADR-2026-08-30-recovery-semantics-for-stateful-links.md` D2 already settles
the general question this specific overlap is an instance of. D2 classifies
"a transport-level acknowledgement without the durable post-condition" as
`ambiguous` by construction — one of eight observations "always `ambiguous`
by themselves" — and states the consequence class for `ambiguous` evidence
in the same section: "it may not... emit a terminal session outcome." A
connected controller socket is exactly a transport-level acknowledgement (the
carrier answered); an outstanding durable receipt from the control plane is
exactly the missing durable post-condition. D2 already forbids treating this
overlap as anything but ambiguous. What was missing from rule 8 was binding
that general rule to this specific daemon-observable condition, naming the
distinct degrade reason so it is never confused with an actually-failed
socket, and giving the ambiguity a bound so "preserve; recheck and retry"
(D2's prescribed handling for ambiguous evidence) cannot become "wait
forever."

**Field basis.** A healthy session on a consumer daemon was quarantined and
terminalized after roughly 30 seconds of slow durable receipts from the
control plane, while every control-plane call the daemon made during that
window still answered `200`. The daemon's socket was never at fault — the
shim's controller connection was live throughout — and the control plane was
never at fault either — it had not refused anything, it was merely slow to
durably acknowledge. Nothing observed in that 30 seconds was evidence of
loss. The daemon terminalized a healthy session because rule 8 as amended
2026-09-02 had no state for "connected socket, outstanding durable
acknowledgement" other than the two it already named, and the closest-fitting
existing path (quarantine, then eventual reap) does not require the durable
post-condition before acting.

## Decision

A shim whose controller socket is connected but whose durable
acknowledgements from the control plane are outstanding is in an
**ambiguous** state, never a lost one. Concretely:

- **The daemon holds the event-backlog stall open** while a durable
  acknowledgement for that shim's events is outstanding, rather than treating
  the stall as evidence the shim or its carrier is gone. This is D2's
  `ambiguous` handling applied to this specific condition: the daemon may
  narrow behavior for safety (stop new delivery, hold the lineage in place)
  but the observation alone authorizes no terminal disposition.
- The hold is bounded by a **durable-acknowledgement ambiguity bound** equal
  to the **lineage-live readoption window** (default 10 minutes — the same
  window rule 8's *Amendment 2026-09-03 — re-adoption window bounded by
  observed liveness* already defines and bounds). This reuses an existing,
  already-reviewed bound rather than introducing a second unrelated timeout
  the core contract would have to keep synchronized with the first.
- **Reaching the bound degrades through a distinct reason,
  `durable_ack_timeout`**, never `socket_unreachable`. On this path the
  daemon **re-adopts before withdrawing**: exhaustion of the
  durable-acknowledgement ambiguity bound is handled exactly like exhaustion
  of the lineage-live re-adoption window it shares its bound with — it does
  not quarantine directly, it re-enters the ordinary re-adoption pipeline
  first, and only an outcome from that pipeline (success, or the window's own
  unconditional-withdraw disposition per
  `ADR-2026-09-03-readoption-exhaustion-withdraws.md`) settles the lineage.
  A durable-acknowledgement timeout is evidence the control plane is slow,
  not evidence the socket failed; it must not shortcut past the re-adoption
  check that would otherwise catch a shim that is, in fact, still live and
  reachable.
- **`socket_unreachable` is reserved** for a controller socket that actually
  failed (connection reset, dial failure, timeout on the transport itself) or
  a control plane that **explicitly refused** the acknowledgement (a decoded
  denial, not silence). A slow-but-live control plane and a slow-but-live
  socket are never folded into this reason.
- **The stranding reconciler never terminalizes on the reason alone.** Both
  `socket_unreachable` and `durable_ack_timeout` are quarantine reasons a
  reconciler may observe; neither one, by itself, is proof of death. The
  reconciler's terminalization discipline is unchanged by this ADR — it still
  requires the terminal evidence rule 10 already demands (an ordinary
  terminal receipt or a durable shim terminal tombstone), and a reason string
  naming *why* a lineage was quarantined is diagnostic metadata, never a
  substitute for that proof. This closes the same class of gap
  `ADR-2026-09-03-readoption-exhaustion-withdraws.md` closed for window
  exhaustion: no quarantine reason may become an implicit terminal signal by
  virtue of a reconciler treating the reason string as dispositive.

This is the general invariant D2 already states, restated at the point rule 8
needed it: **a transport-level acknowledgement without the durable
post-condition is always ambiguous and never emits a terminal outcome.** See
`ADR-2026-08-30-recovery-semantics-for-stateful-links.md` D2 (the general
rule) and `ADR-2026-08-17-session-shim-adoption.md` rule 8's *Amendment
2026-09-02 — carrier-fault re-adoption precedes quarantine* (the specific
carrier-fault/re-adoption seam this ADR closes the remaining gap in).

## Consequences

### Positive

- A healthy session with a live controller socket can no longer be
  terminalized by control-plane acknowledgement latency alone. The field
  incident this ADR is written from — a healthy session quarantined and
  terminalized after ~30 s of slow receipts with every control-plane call
  answering `200` — is exactly the class this closes.
- Reusing the lineage-live readoption window as the ambiguity bound means the
  core contract carries one configurable duration for "how long do we wait on
  an alive-but-unproven shim," not two that could drift apart.
- `durable_ack_timeout` gives operators and reconcilers a reason that is
  honest about what was actually observed (slow acknowledgement, not a dead
  socket), which keeps `socket_unreachable`'s meaning precise and keeps
  post-incident diagnosis from mis-attributing a control-plane latency spike
  to a transport failure.

### Negative

- The daemon now tracks one more bounded timer per lineage with an
  outstanding durable acknowledgement, alongside the lineage-live re-adoption
  timer it already tracks. Implementations that share the same clock and
  window value (as this ADR directs) keep this to one additional field, not
  one additional subsystem.
- A control plane that is durably slow but never actually fails now holds a
  lineage open for up to the full ambiguity bound before re-adoption even
  begins, rather than failing fast. This is deliberate — D2 already forbids
  the fast-fail alternative for ambiguous evidence — but it does mean a
  genuinely stuck control plane is slower to surface as a problem than a
  cleanly failed one.

### Risks

- **A composing control plane that never durably acknowledges anything**
  turns every session into a bound-length wait before re-adoption, on every
  lineage, continuously. This ADR does not fix a control plane that cannot
  keep up; it only ensures the daemon does not mistake "durably slow" for
  "gone" while waiting to find out.
- **The shared bound is a double-edged reuse.** Because the
  durable-acknowledgement ambiguity bound and the lineage-live re-adoption
  window are the same duration by this decision, a future change to one
  without considering the other could silently change both. Implementations
  MUST treat the two as one configured value, not two values that happen to
  default identically today.

## Alternatives considered

- **Fold this into `socket_unreachable` and let the existing re-adoption
  amendment absorb it.** Rejected: the 2026-09-02 amendment's re-adoption
  path exists for a shim whose *socket* is unreachable; a shim with a live,
  connected socket and merely a slow durable acknowledgement is a different
  observation and conflating the two reasons would make `socket_unreachable`
  lie about what was actually seen — exactly the confusion the field incident
  traces back to.
- **Introduce a separate, independently configured durable-acknowledgement
  timeout.** Rejected: this is a second duration the core contract would need
  to keep synchronized with the lineage-live readoption window by
  convention, with no correctness reason for the two to differ — both bound
  "how long do we tolerate an alive-but-unproven lineage before re-adoption
  decides." Reusing the existing window removes a synchronization burden for
  no loss of expressiveness.
- **Terminalize on `durable_ack_timeout` directly instead of re-adopting
  first.** Rejected: this is the defect being fixed, given a new name. A
  durable-acknowledgement timeout says nothing about whether the shim is
  still reachable; skipping the re-adoption check that would answer that
  question is exactly how a healthy, reachable session gets terminalized on
  latency alone.
- **Let the stranding reconciler treat `durable_ack_timeout` as sufficient
  terminal evidence on its own, since it is a distinct and presumably
  meaningful reason.** Rejected: a reason string describes why a lineage was
  quarantined, not what has since become true of it. Treating any reason
  string as terminal proof reopens the same class of gap
  `ADR-2026-09-03-readoption-exhaustion-withdraws.md` already closed for
  window exhaustion, for a reason that did not exist when that ADR shipped.

## Affected documents

- `ADR-2026-08-17-session-shim-adoption.md` — one sentence added to core
  contract rule 8's *Amendment 2026-09-02 — carrier-fault re-adoption
  precedes quarantine* paragraph, naming the durable-acknowledgement
  ambiguity bound and the `durable_ack_timeout` reason. **This edit lands
  inside the `adr-2026-08-17-session-shim-core-contract` synchronized
  region** and ships via paired PRs to both corpora per `BOUNDARY.md` §
  "Simultaneous-PR rule for synchronized sections"; `scripts/check-boundary-
  sync.sh` passes before either PR merges.
- `006-cross-provider-interactions.md` — checked for a §D14 naming this
  behaviour without a deadline; no such section exists in this corpus's
  numbering (`006` is organized by Seam, not by lettered/numbered `D`
  subsections), so no edit lands there. If a future doc introduces an
  equivalent un-bounded description of this behaviour, it must cite this
  ADR's bound rather than restate the behaviour without one.

## Affected work items

None cited in this corpus — tracker issue references belong in the platform
mirror per `BOUNDARY.md`.

## Implementation notes

Implemented in the OSS execution layer (`donmai`, PR #546): the daemon holds
the event-backlog stall open for a lineage with a connected controller socket
and an outstanding durable acknowledgement, bounded by the lineage-live
re-adoption window, and degrades through `durable_ack_timeout` into the
ordinary re-adoption pipeline on exhaustion rather than quarantining directly
as `socket_unreachable`. Architecture only for the composing control plane's
own durable-receipt latency and retry behavior, consistent with D14/D15's
overall split: the OSS-shipped self-hosted journal and any composing external
carrier both observe the same ambiguity discipline this ADR states; a
control plane's choice of how quickly it durably acknowledges is out of
scope here.
