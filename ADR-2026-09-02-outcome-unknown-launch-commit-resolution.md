---
status: Accepted
date: 2026-09-02
boundary: shared
split: inline-addenda
---

# ADR-2026-09-02 — Resolving an outcome-unknown launch adoption-batch commit

**Status:** Accepted
**Date:** 2026-09-02
**Boundary:** shared (the redrive/release/discharge sequence and the
`OnSpawnAborted` contract for embedders are OSS-canonical here; the composing
control plane's reaper-refusal-while-obligation-unresolved rule and the closed
embedder's abort wiring live in the platform mirror)
**Authors:** session-continuity design lane

## Context

`ADR-2026-08-17-session-shim-adoption.md` requires a starting daemon to commit
one complete adoption batch per served scope before advertising readiness (D4
rule 12), and its *Amended 2026-09-01* addendum gives that commit a content
digest and two typed answers — an already-advanced revision, or a refusal
naming already-recorded lineages. Both the rule and its amendment describe the
batch commit a **restarting** daemon issues while adopting shims it did not
just create.

A **newly launched** shim's own adoption-batch commit is a different call,
issued at the opposite end of a session's life: by the time a launch reaches
it, the daemon has already durably recorded that lineage's per-session
adoption, independent of any batch, and the control plane refuses every later
batch that omits a lineage it holds live. When this commit's answer is lost —
a transport timeout, a client deadline expiring around an in-flight request, or
any other shape the daemon cannot distinguish from "the control plane received
and processed it" — the daemon meets the same OUTCOME-UNKNOWN class the
2026-09-01 amendment names, but with no rollback available: no prior committed
projection ever held this brand-new lineage, and the shim's harness is not yet
stopped.

Before this decision, the daemon treated the ambiguity as an ordinary refusal:
it armed the same asynchronous reconciliation pass used for the restart case,
closed the controller, and returned a launch failure. Measured live, on an
installed host, three things were then true at once:

- the launching lineage was recorded in **no** projection this daemon could
  compose a batch from — including every later reconciliation republish, the
  one mechanism that could have resolved the ambiguity, because a complete
  batch that omits a lineage the control plane holds live is refused;
- the harness **kept running** — closing the controller does not stop the
  shim, so the daemon's own "aborted" report was false for as long as the
  shim's own orphan clock had left to run; and
- the session's recovery obligation was **never discharged**, so the row could
  not terminalize.

A launch failure that leaves a live, unreachable harness running under a
report that says otherwise is a correctness defect, not a resilience gap.

## Decision

When a launched shim's adoption-batch commit answers OUTCOME-UNKNOWN, the
daemon drives that ambiguity to a definite outcome **inside the launch**,
synchronously, before returning — it never hands an un-adopted live harness to
an asynchronous pass while reporting the spawn aborted.

1. **Redrive exactly once, on a fresh detached callback budget.** The daemon
   re-composes the complete current projection and re-issues the batch commit
   once, on one budget detached from the caller's own (which may be the very
   budget that just expired). This is not a bare retry of the lost request:
   the redrive re-reads the control plane's expected revision through the
   ordinary prepare path, so a control plane that already committed answers
   with its own advance, which the daemon recognizes and adopts without a
   second commit — nothing is guessed. Three outcomes:
   - **Committed** (a nil error, or a recognized advance that is this
     daemon's own prior commit): the ambiguity resolves as success and the
     caller continues the normal adoption.
   - **Decoded refusal**: the control plane answers with a definite "not
     committed." The daemon releases (step 2).
   - **Still ambiguous**: the one redrive does not resolve inside its bound.
     The daemon releases (step 2) — a launch that cannot prove it was adopted
     must not be reported as adopted.

2. **On release, first make the failure a true statement about the host.**
   Before returning the error the spawner turns into an aborted-spawn report,
   the daemon:
   - records and publishes the launching lineage **quarantined**, in a
     complete snapshot, before returning — an unpublished quarantine change
     disagrees with every later beat, and omitting the lineage outright is not
     an option, because the control plane already holds it live from the
     launch's own per-session adoption;
   - asks the harness to **stop** through the shim's ordinary generation-
     fenced Controller-Stop verb — closing the controller alone does not stop
     it, and the failure is not honest while an un-adopted harness keeps
     running.

3. **Consume whatever terminal proof the stop produces off the accept
   goroutine, bounded, and joined by the daemon's own shutdown WaitGroup.**
   Waiting for the shim to terminate, reap its harness group, and publish a
   tombstone must not hold the lock every sibling launch, the poll loop, and
   the recovery-heartbeat acknowledgement block on. A detached, bounded
   goroutine polls for the tombstone through the daemon's ordinary quarantine-
   tombstone reconciliation, reports it through the terminal-evidence callback
   (the recovery-obligation discharge), and republishes the projection on its
   own fresh budget with its own checked error — a discarded republish error
   here previously produced a host whose beat disagreed with its own last
   committed batch and drained silently. If the discharge does not land inside
   the bound, the lineage stays exactly where the synchronous step already put
   it — quarantined, capacity-consuming, and correct — and the daemon arms its
   ordinary bounded reconciliation pass rather than leaving an un-retriggered
   wedge.

4. **The `OnSpawnAborted` contract for embedders is now explicit.** At the
   point a launch's error crosses into an aborted-spawn report, exactly the
   following is guaranteed true, and no more:
   - the session was **not adopted**;
   - the lineage has been **published in a complete snapshot** and is never
     silently omitted from one;
   - the harness **has been asked to stop**;
   - **terminal evidence was reported** if its tombstone landed inside the
     bound; and
   - the process is **not guaranteed reaped** when no proof landed inside the
     bound — an embedder must not read "spawn aborted" as "no process is
     running."

No step manufactures proof. A tombstone this daemon did not observe is never
fabricated to close the loop early, and the redrive never resends a guessed
revision — every attempt re-reads the expected revision from the control plane
rather than trusting its own prior guess. Fence expiry is unaffected: it still
never releases a claim, and this decision adds no new release path.

## Consequences

### Positive

- A launch failure is now always a true statement: there is no path in which
  the daemon reports a spawn aborted while a live, un-adopted harness keeps
  running unreachable.
- The lineage becomes recoverable through the daemon's own existing
  machinery (bounded reconciliation, quarantine-tombstone consumption)
  instead of becoming permanently uncomposable — the specific defect measured
  in production.
- Embedders gain an explicit, load-bearing `OnSpawnAborted` contract instead
  of one they had to infer from source.

### Negative

- A launch that hits this path pays up to one extra prepare/commit round trip
  (the redrive) plus a quarantine publish and a discharge republish before
  returning — bounded, but real added latency on an already-failing launch.
- The accept goroutine and the daemon's publication lock are held for the
  redrive's one callback-timeout budget; a burst of simultaneous ambiguous
  launches serializes behind it like every other publication.

### Risks

- This decision is necessary but not sufficient on its own: if the composing
  control plane's reaper does not also refuse to release or reap while this
  lineage's recovery obligation is unresolved, the OSS-side quarantine-and-
  discharge sequence can be raced. See the platform mirror for that half of
  the contract.
- The bounded discharge runs off the launch's own return path; an operator
  reading only the synchronous failure might miss that a background discharge
  is still in flight. The diagnostic surface (the quarantine detail string,
  and the reconciliation re-arm count from the 2026-09-01 amendment) is the
  intended place to observe it.

## Alternatives considered

- **Hand the ambiguity entirely to the existing asynchronous reconciliation
  pass, unchanged.** Rejected: this is exactly the behavior that produced the
  measured defect — a batch that omits a live lineage is refused, including by
  reconciliation itself, so the one mechanism that could have resolved the
  ambiguity could never see the lineage that needed it.
- **Retry inside the resilient commit loop's own backoff instead of a
  separate redrive.** Rejected: that loop retries definite refusals with a
  specific decoded reason; resending from inside it on an ambiguous outcome
  would resend the same expected revision that just lost — a guess. A redrive
  that re-composes the projection and re-reads the expected revision is a
  different, safe operation and must stay visibly distinct from the loop that
  refuses to guess.
- **Wait for the stop's terminal proof synchronously, before returning the
  launch error.** Rejected: measured at roughly a minute at production
  defaults, this would block every sibling launch, the worker poll loop, and
  the recovery-heartbeat acknowledgement behind one launch's teardown. The
  quarantine-and-publish step alone already makes the host's published state
  conservative and correct; the discharge only improves it further, and can do
  so from anywhere.
- **Fabricate a tombstone, or infer termination from the stop request
  alone.** Rejected outright: no proof in this subsystem may be manufactured.
  A claim release depends on a genuine group-reaped tombstone, and asserting
  one without observing it would forge exactly the evidence
  `ADR-2026-08-17`'s fence design exists to require honestly.

## Affected documents

- `ADR-2026-08-17-session-shim-adoption.md` — gains a short cross-reference in
  its post-acceptance amendments area pointing at this ADR for the
  launched-shim (as opposed to restart-adoption) OUTCOME-UNKNOWN batch-commit
  case. This edit lands outside the `adr-2026-08-17-session-shim-core-contract`
  synchronized region and does not change it.

## Affected work items

None cited in this corpus — tracker issue references belong in the platform
mirror per `BOUNDARY.md`.

## Implementation notes

Shipped in the OSS execution layer (`donmai`) as
`redriveAmbiguousLaunchSessionShimBatchCommit`,
`releaseAmbiguousLaunchSessionShim`, `recordAmbiguousLaunchBatchQuarantine`,
`startAmbiguousLaunchSessionShimDischarge`, and
`republishAfterAmbiguousLaunchDischarge` in `daemon/session_shim_spawn.go`,
with pinned behavior in `daemon/session_shim_ambiguous_launch_commit_test.go`.

## Addendum 2026-09-02 — the same obligation, one step earlier

The decision above concerns a launch that has already **durably adopted** its
session and then loses the answer to its adoption-batch commit. The same
question — what must be true about the host before an aborted spawn is reported
— arises one step earlier, at the launch's very first gate: a worker that has
published **no discovery record** when its discovery bound expires (see
`ADR-2026-08-17-session-shim-adoption.md` §D10, row *Launched worker has not
published a discovery record when the launch bound expires*, and its
*Amended 2026-09-02* section). Previously that path returned the accept failure
and left the process running; it now stops the launched process group and reaps
the direct child first.

At that earlier point, step 2's release reduces to its process half, and the §4
`OnSpawnAborted` contract reads as follows — weaker in one bullet because
nothing exists yet to be published, and STRONGER in another because the proof is
local:

- **"not adopted"** — unchanged, and unconditional.
- **"published in a complete snapshot"** — **vacuous here.** The launch never
  reached its per-session adoption, so the control plane holds nothing live for
  this lineage, no batch can be refused for omitting it, and a quarantine entry
  would need a shim identity the missing discovery record never delivered. There
  is nothing to publish, and nothing is published.
- **"asked to stop"** — satisfied by a different verb. No controller was ever
  dialled (the record that would carry the socket is exactly what never
  appeared), so the generation-fenced Controller-Stop cannot be sent; the
  process group this daemon itself started is the only handle, which is the same
  fallback step 2 already takes when its controller is nil.
- **"terminal evidence reported if its tombstone landed"** — **not applicable.**
  No lineage was ever durably attested, so no terminal evidence is owed to
  anyone.
- **"not guaranteed reaped"** — **stronger here.** The reap is not a tombstone
  another process must publish and this daemon must wait for; it is waitpid on
  this daemon's own child, performed synchronously before the error returns. When
  the stop reports success, the direct child **is** reaped. What remains
  unprovable is only a surviving descendant that was never this daemon's child —
  the same limit the direct-child lane carries.

An embedder can therefore read an aborted spawn at this earlier gate as "no
process of mine is running" whenever the stop succeeded, and must still read the
general §4 contract — "not guaranteed reaped" — for the post-adoption path the
decision above governs.

## Known gaps (recorded as follow-ups)

- **No shim-absent attestation construction exists in production code.**
  `ADR-2026-08-17`'s core contract rule 10 defines the shim-absent attestation
  as the reporting-only statement that closes what a daemon owes the batch
  completeness rule when a shim was killed without writing a tombstone. This
  decision's discharge path always has a real stop request in flight and
  therefore always has a route to a genuine tombstone, so it does not itself
  need the attestation. But no code anywhere in the execution layer yet
  constructs that attestation for the sibling case — a shim killed out from
  under the daemon with no stop request and no tombstone. That gap is
  unrelated to this decision's own correctness and remains open.
- **The satellite poll loop in the closed embedder does not NACK on
  accept-work failure.** This is a platform-side gap outside this corpus's OSS
  boundary, noted here only because it sits on the same launch-failure surface
  this ADR hardens. Tracked in the platform mirror.
