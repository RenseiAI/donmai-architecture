---
status: Accepted
date: 2026-11-23
boundary: shared
split: sibling-extensions
---

# ADR-2026-11-23 — Session moves: a session ends with a successor on another host, harness or account

**Status:** Accepted (2026-11-23, product-owner acceptance). Revised the same day with the product owner's rulings: a successor session, every session class in the first phase, no default timeout on an ask, and the defaults for the move bound and the quiet interval. The affected-document edits landed in the accepting commit. Nothing here is built yet.
**Date:** 2026-11-23
**Boundary:** shared. This file is the canonical ADR. `rensei-architecture` carries a `status: Mirrored` stub and a platform-only companion ADR.
**Authors:** agent:claude (Fable 5.2), for the product owner

## Context

A session is bound to the host that claimed it, the harness that runs it and the login
it was admitted with. Three situations need the work to continue somewhere else:

1. **The host is going away.** A drain today waits for every headless seat, up to the
   drain bound. A seat that outlasts the bound is stopped. A session in a pseudo-terminal
   survives a daemon restart by adoption, but not a host reboot.
2. **The login can no longer serve.** A subscription account that reaches its limit in
   the middle of a session leaves that session failed or idle until the window resets.
   Another host, or another harness on the same host, may hold a login with headroom.
3. **Someone decides the work belongs elsewhere.** An operator or a coordinating agent
   wants a different harness, model or host for the rest of the work.

What exists today covers none of these across hosts:

- `ADR-2026-10-07-headless-session-shim-adoption.md` D8 defines a cooperative stop and
  a resume on the **same** host. Its out-of-scope list names "resume on a different
  host". No harness adapter is resume-qualified yet.
- `ADR-2026-08-31-session-recovery-taxonomy-and-state-vocabulary.md` D1 has four
  mechanisms. `resume` keeps the session and reuses its admission. `restart` is a new
  session where "prior work is not carried".
- `ADR-2026-08-05-versioned-execution-cell-and-session-reference.md` gives a session one
  admission receipt, and a change to an admitted axis (harness, model, endpoint, auth
  binding) "requires a new dispatch intent and admission receipt".
- `ADR-2026-11-19-host-observation-contract.md` G6 stops every observation effect at
  claim: "no observation or policy change stops, pauses or preempts running work".

Two things that landed recently make a general answer possible:

- `ADR-2026-11-20-harness-interaction-contract.md` D4 and D6 give every harness one
  normalized event stream with stable item ids, typed plans, file changes, interactive
  requests and turn boundaries. That stream is a harness-neutral record of a session.
- `ADR-2026-11-19-host-observation-contract.md` S2 gives a subscription account one
  stable identity across hosts, and S5 a viability predicate with typed reasons.

One thing is weaker than it looks. A session that runs a vendor terminal program in a
pseudo-terminal (`ADR-2026-07-12-interactive-pty-session-host.md`) consumes no provider
event stream. Its structured record comes from an adapter tailing the harness's own
transcript file, best-effort, in the older event kinds, and one harness has no tail at
all. Its only complete artifact is the terminal recording.

Prior art, both open source:

- **t3code** keeps a thread on the machine that owns its workspace and never moves it.
  When the provider or account changes it starts a fresh provider conversation from a
  budgeted selection of the saved transcript, and gives the agent a tool to read what
  was left out. It resumes the provider's own conversation only when the account home
  is unchanged. It records that selection as a visible item in the thread.
- **Pi's durable harness package** checkpoints every model request and tool call in
  pluggable storage, so a new process continues a run. It has no writer fencing, it
  does not capture the filesystem, and it applies only to a harness built on it. It is
  not a way to make an existing harness movable.

Neither moves work between hosts. Both show that a conversation carried as a selected,
attributed record works across providers, and that the provider's own conversation is
worth keeping only when nothing about the account changed.

## Decision

A **session move** ends one session at a safe point and starts a **successor session**
that continues the same work in another execution context. The two sessions stay
distinct and are joined by a **move artifact**. Execution always stays in the execution
context that placement selected. No part of the agent loop moves to a control plane.
The decision covers every session class: headless dispatched sessions and sessions in a
pseudo-terminal, called **PTY sessions** below.

### Vocabulary

| Term | Meaning here | Not to be confused with |
|---|---|---|
| session move | the act: one session ends, a successor session starts | a stage move; a claim that is placed again after a nack |
| predecessor, successor session | the two sessions of one move | the attach protocol's carrier successor, which serves the *same* session |
| chain | the ordered sessions joined by moves; exactly one is live | a recovery chain |
| move record | the state of one move (D2) | |
| move artifact | the content-addressed object a successor starts from: the briefing, the checkpoint refs, the lost work, the meter readings | the read-only terminal continuation of `ADR-2026-09-28-interactive-vt-continuation.md` |
| move briefing | the selected conversation context inside the move artifact (D4) | a launch-time program block of a composing control plane |

### D1 — A session move is a succession, not a recovery

1. A session never changes host or execution cell. A session move ends the **predecessor**
   with end reason `moved` and admits a **successor session** as a new session with its
   own admission receipt, claim and incarnation numbering.
2. A session move is a deliberate act (D7). It is not a member of the recovery taxonomy
   of `ADR-2026-08-31` D1, and absence never selects it.
3. Same-host continuation is unchanged. A live process is adopted, and a stopped one is
   resumed under `ADR-2026-10-07` D8, as the same session.
4. The successor says plainly what it was started from (D4). This is the difference from
   a `restart`, where "prior work is not carried".
5. Successions chain. A successor may itself be moved. A chain has exactly one live
   session.
6. **A successor carries its origin.** It holds the predecessor's work item binding
   (the tracker work item and the pull request, when there are any) and a reference to
   the predecessor's session record and, for a PTY session, its terminal recording. An
   operator can always get from a successor back to what came before it.

### D2 — The move protocol

A move has a **move record** with a closed state list: `proposed`, `reserved`,
`stopping`, `continuing`, `completed`, `refused`, `stranded`.

1. **Propose.** The requester (D7) names the predecessor and may narrow the destination
   (D6). The move record is written `proposed`.
2. **Reserve.** Placement resolves the successor (D6), and the successor is admitted and
   claimed in a **held** state: it holds its claim and starts nothing. The record
   becomes `reserved`. If no destination survives, the move is `refused` with every
   candidate's typed reason, and the predecessor is not touched. A held successor does
   not count as a second live session against any concurrency limit.
3. **Stop.** The predecessor is asked to stop for a move, with stop reason
   `session_move`. The stop has one form per session class.

   *Headless.* The stop of `ADR-2026-10-07` D8 steps 1 to 3:
   - no new turn starts, and the current tool call finishes within the stop bound;
   - a tool call still running at the bound is interrupted and listed as lost;
   - a harness that supports `interrupt` (`ADR-2026-11-20` D1) is interrupted at the
     safe point instead of waiting for the turn to end.

   *PTY.* Today's stop of a PTY session is a kill. A stop for a move is not:
   - the safe point is the harness waiting for input: the adapter's turn-completed
     signal where it has one, otherwise terminal quiet for a configured interval, ten seconds by default;
   - every attached viewer is told that the session is about to move, and input is
     frozen from that moment. Text typed and not yet sent is lost, and the notice says
     so;
   - the harness is asked to exit by its own exit path so that it flushes its
     transcript. It is signalled only if it does not exit within the stop bound;
   - a stop that never reaches a safe point within the bound refuses the move.

   In both forms the session record is completed (D3) and a **move checkpoint** of each
   repository is pushed (D5).
4. **End the predecessor.** The runner posts the session's terminal status with end
   reason `moved`, carrying the move artifact's digest. The claim, the workarea lease
   and any fence rows are released by the ordinary terminal path (`ADR-2026-08-17`
   rule 10). The record becomes `continuing`.
5. **Start the successor.** Only after the predecessor's terminal status is recorded and
   its process group is proved gone is the held successor activated. It materializes
   its workarea (D5), prepares dependencies, and starts with its starting context (D4).
6. **Complete.** The successor's start acknowledgement completes the move: its `init`
   event, and for a PTY session the host's first connection with the harness process
   running. Where the adapter emits `effective_settings` (`ADR-2026-11-20` D3), that
   event is the acknowledgement.

Failure rules:

- **Before step 4 nothing is lost.** If the stop cannot reach a safe point within its
  bound, or the move checkpoint cannot be pushed, the held successor is released, the
  move is `refused`, and the predecessor keeps running. A PTY session's input is
  unfrozen and its viewers are told.
- **After step 4 the move artifact is the durable state.** If the successor fails to
  start, it is placed again by the single fallback rule
  (`ADR-2026-08-12-placement-composition-law-and-single-fallback-rule.md`). If nothing
  survives, the move is `stranded`: the move artifact is kept, the work is dispatchable
  again from it, and the operator is told. A `stranded` move never ends silently.
- **A move is never retried by re-running the predecessor.** Its terminal status stands.

### D3 — The session record is the conversation source

1. The conversation a successor continues from is the **session record**: the normalized
   event stream of `ADR-2026-11-20` D4, in order, for every session in the chain.
2. In the standalone runtime the record is the session journal. A composing control
   plane persists the same stream and may serve it to a successor on any host.
3. **A PTY session's record is completed at the stop.** While it runs, its record is
   whatever the adapter's transcript tail delivered, which may have gaps. At the stop the
   adapter reads the harness's own transcript from the session-owned state location and
   normalizes it into the same event kinds, filling the gaps. This **transcript read** is
   an adapter capability (D8).
4. **Completeness is stated, never assumed.** Each record carries one of three levels:

   | Level | Meaning |
   |---|---|
   | `complete` | every turn through the stop is in the record |
   | `partial` | the record has known gaps; they are listed |
   | `none` | no structured conversation exists; the terminal recording is the only account |

   The level is shown before a move is confirmed and is stated in the briefing. A move
   whose record is `none` needs an explicit operator or coordinator act and is never
   started by `provider-refusal` policy alone.
5. The terminal recording is evidence an operator can replay. It is never parsed into a
   briefing.
6. The record of every session in a chain is retained at least while the chain has a
   live session.
7. Reading the record for a successor is a read. It never appends to the predecessor's
   event log (`ADR-2026-08-19-session-data-lifecycle-tiering-and-rehydration.md`).

### D4 — The successor's starting context

Each successor starts in one of two ways, recorded as its provenance.

**`briefed`** is always available. The successor starts a fresh harness conversation and
receives a **move briefing** built from the session record. The briefing is
deterministic: the same record and budget give the same bytes. It is a selection, never
a model-written summary.

| Part | Content | Rule |
|---|---|---|
| Origin | the predecessor, its harness, the record's completeness level, and where to replay it | always included |
| Goal | the work item binding and the first operator input | always included, never shortened |
| Latest exchange | the last operator input and the last `final` assistant message | always included |
| State | the latest `plan` item, the files changed so far (path, change, additions, deletions), the open `interactive_request` if any, the work lost at the stop | always included, from typed events where the record has them |
| Workarea | repositories, branch, move checkpoint, pull request if any, and what did not cross | always included |
| History | turn items, newest first | included until the budget is spent |
| Omitted | references to every item left out | always included |

- The budget is the smaller of a configured cap and a share of the destination model's
  context window. The new operator input, if any, is never shortened to make room.
- The successor is offered a **record-reading tool** that pages the full record of the
  chain, so omitted history is retrievable on demand.
- A briefing never carries the predecessor harness's reasoning, its native tool state,
  or attachments by value. The briefing says so.
- **Delivery, headless.** The adapter's history import when it declares one (D8), and
  otherwise an attributed context block ahead of the first input.
- **Delivery, PTY.** The adapter's launch-context channel: the same channel that carries
  launch-time instructions to the terminal program. A briefing is never typed into the
  terminal and never rides the initial-prompt argument, which is too small for it.
- **First input.** A successor is given a directive to continue only when the
  predecessor stopped with work in progress: an interrupted turn, lost work, or queued
  input. A predecessor that was waiting for a person leaves a successor that waits too.
- The delivery outcome is recorded. An unknown outcome starts a fresh harness
  conversation and delivers again. It never continues a conversation that may already
  hold half of it.
- The briefing is a visible item in the successor's record, naming the predecessor, its
  harness, and how much was carried.

**`native_import`** continues the harness's own conversation. It is selected only from
evidence, as `ADR-2026-08-31` D1 requires, and every condition must hold:

- the successor's harness and adapter version match a resume-qualified adapter
  (`ADR-2026-10-07` D8);
- the successor's login is the **same observed account** as the predecessor's
  (`ADR-2026-11-19` S2 `itemKey`). An account reported `identity: host-scoped` never
  matches;
- the harness's session artifact reached the successor's session-owned state location
  and its digest matches the one recorded at the stop;
- the endpoint route is unchanged.

A `native_import` that the harness does not confirm after start is downgraded to
`briefed`, and the record says so. Until an adapter is resume-qualified, every move is
`briefed`.

### D5 — The workarea crosses as version-control state

1. At the stop, the runner pushes a **move checkpoint** for each repository in the
   workarea: one commit, on a ref outside the branch namespace, holding the tracked
   changes and the untracked files that are not ignored. It adds no commit to the work
   branch. This extends the WIP checkpoint of `ADR-2026-10-07` D8 step 3.
2. The successor's workarea is a **new** workarea, materialized from the move checkpoint
   with the work branch restored under its own name and the uncommitted state replayed
   as uncommitted. No root, leaf or lease transfers between sessions, so
   `ADR-2026-08-22-session-owned-multi-repository-workarea.md` D3 is unchanged.
3. Ignored and derived files do not cross. The successor runs dependency preparation as
   any new session does (`ADR-2026-11-11-session-independent-dependency-preparation.md`).
   A tree the predecessor touched is never captured as a dependency snapshot
   (`ADR-2026-10-08-kit-dependency-stores.md`).
4. Files in the predecessor's workarea root that are outside every repository do not
   cross, and a workarea with no repository has nothing to check out. The briefing lists
   what was left behind. The product owner accepted this for the first phase. Carrying
   a whole-root archive to a successor is a later decision, because it changes who may
   restore an archive.
5. The predecessor's workarea root is disposed of by its ordinary terminal release. A
   composing control plane may archive it for the chain's lifetime.
6. Move checkpoints are removed when the chain ends.

### D6 — The destination is an ordinary placement

1. The successor is a new dispatch intent for the same work, resolved by the placement
   law. A session move adds no placement power: it cannot reach a pool, harness or login
   the work could not have been dispatched to.
2. The successor is launched from the predecessor's own recorded launch request, with
   only the destination's changes applied. Its session class does not change.
3. The requester may narrow the destination by harness, model, subscription provider,
   pool or host. A named host is a pin and is hard within the law.
4. The trigger adds exclusions, each a typed viability reason:
   - `host-drain` excludes the draining host;
   - `provider-refusal` excludes the refused login, with the provider's reset time when
     it reports one.
5. Each candidate harness runs the instruction translation of `ADR-2026-11-20` D2 for
   the predecessor's `Instructions`. A candidate that reports a required instruction
   `unsupported` is excluded with that reason. The report is shown before an operator
   confirms a move.
6. Subscription logins keep their rules. Viability, the guard and billing boundaries of
   `ADR-2026-11-19` S5 to S7 apply to the successor as to any dispatch. A move never
   starts a successor past a billing boundary the tenant's policy disallows.
7. An empty surviving set refuses the move, loudly and with reasons. It never widens.

### D7 — What may start a move

The trigger list is closed.

| Trigger | Who | Notes |
|---|---|---|
| `operator` | a person with authority over the session | from any operator surface |
| `coordinator` | an agent principal with authority over the session | the same verb a person uses |
| `host-drain` | the host's operator, through the restart or drain preflight | one move per session; there is no batch move |
| `provider-refusal` | the session's own runner, on the provider's typed refusal | governed by the login's `onRefusal` policy (below) |

1. **A healthy session is moved only by an explicit act.** A guard, a warning, a policy
   change, an observation, a heartbeat gap or elapsed time never starts a move. This
   keeps `ADR-2026-11-19` G6: effects are not evaluated after the session starts.
2. **`provider-refusal` is evidence, not prediction.** It fires only when the provider
   refused a request for the account's allowance and the session cannot continue. A
   retryable rate limit is not a refusal.
3. A new kind-1 policy field, `onRefusal`, says what a refusal does:

   | Value | Effect |
   |---|---|
   | `ask` (default, in both layers) | the session stops at the refusal and waits; the operator is asked to move, wait or end |
   | `move` | a move is proposed at once, with the refused login excluded |
   | `wait` | the session stops for resume on its host and continues after the reset |

   - `wait` reuses the stop-for-resume path with stop reason `allowance_wait`, and a
     harness that is not resume-qualified continues `seeded_fresh` from a briefing.
   - **An ask has no deadline of its own.** The session waits until someone answers. A
     composing control plane may attach a deadline with an automatic answer only through
     its existing approval mechanism. This ADR adds no timeout.
4. **Drain order.** The restart preflight's order becomes: adopt a live process, stop
   for resume, propose a session move where a destination can be reserved, then wait. A
   daemon restart alone never moves a PTY session, because its process is adopted. A
   planned reboot or a decommission does.
5. **Moves are bounded.** A chain allows a configured number of consecutive moves in
   which no turn completed, three by default. At the bound the next move is refused.
6. **A session its host is not holding.** A host that vanished selects nothing (D1.2).
   An operator or coordinator may still ask for a successor, on two conditions: the
   session has first ended by the existing terminal-evidence rules, and the request is an
   explicit act. The successor then starts `briefed` from the record and from the last
   state pushed to the remote. No move checkpoint exists, and the briefing says so. This
   path is never automatic.

### D8 — Capabilities

1. Every harness can be a move source and a `briefed` destination. A move needs only the
   cooperative stop and a record whose completeness is stated.
2. `SupportsInterrupt` shortens the stop. `SupportsSessionResume` with a passing resume
   fixture enables `native_import`.
3. Two new capabilities:
   - `SupportsHistoryImport`: the adapter can load prior messages into a fresh harness
     conversation as history. Without it the briefing is an attributed context block.
   - `SupportsTranscriptRead`: a PTY adapter can read the harness's own transcript after
     the process exits and normalize it (D3.3). Without it a PTY session's record is
     whatever its tail delivered, and it is `partial` or `none`.
4. Capabilities are computed from fixtures, never declared by hand
   (`ADR-2026-08-13-capability-realization-registry-and-viability-of-absence.md` D6).
   The conformance suite of `ADR-2026-11-20` D7 gains a move fixture per adapter and per
   mode: stop a scripted session, build the briefing, start a successor, and observe the
   goal, the plan and the changed files in its first turn's context.

### D9 — Budgets, completion, lineage and addressing

1. **Budgets belong to the chain.** Stage budget meters, turn counters and wall-clock
   duration limits continue from the predecessor's readings. A move never resets a cap.
2. **`moved` is not a completion and not a cancellation.** It is a non-failure end with
   no charge, no refund and no failure backoff. No completion contract fires and no
   stage moves on it.
3. **One outcome per chain.** The session that finishes the work writes the outcome the
   work item sees. Anything waiting on a moved session's result waits on the chain's.
4. **Addresses follow the chain.** A verb addressed to a moved session answers with a
   typed redirect naming the live successor. Operator surfaces present a chain as one
   timeline and follow the successor without operator action.
5. **Lineage follows the chain.** A chain is one node in the spawn lineage. A child's
   recorded parent is not rewritten: authority over children, child events and shared
   budget reservations resolve a moved parent to its live successor. A session with live
   children can therefore be moved, and so can a coordinator.
6. **Attached viewers are told where the session went.** The attach protocol's ended
   state gains an optional `movedTo` session id, and its kill reasons gain `moved`. A
   viewer joins the successor with a new token and a new room. Both are additive, and an
   older viewer sees an ordinary end.
7. **Open requests do not cross.** A pending approval or question is ended as
   `interrupted` on the predecessor and listed in the briefing. The successor asks
   again if it still needs the answer.

### D10 — Standalone behaviour

The OSS layer ships a working move on one machine: a session moves to another harness or
another login on the same host, with the local daemon as the authority and the session
journal as the record. The move record, the move artifact, the briefing format, the move
checkpoint and the verbs are all OSS contracts. A move between hosts needs a control
plane that both hosts report to. The hosted delta is in the platform corpus.

## Consequences

### Positive

- A host can be drained, rebooted or retired without waiting out, or losing, its
  sessions.
- A session that hits its account limit can continue on another login or provider
  instead of failing.
- A cross-harness move does not depend on harness resume qualification, so it can ship
  before any adapter qualifies.
- One admission per session stays true. No change to the session reference, the release
  rule or the workarea ownership clause is needed.
- The briefing is deterministic and replayable, so a poor continuation can be diagnosed
  from the record.
- A session stranded by a lost host gains an explicit way forward.

### Negative

- A `briefed` successor loses the predecessor's reasoning, native tool state and any
  provider-side cache. The first turns after a move cost more and may repeat work.
- Session identity changes at a move. Every surface and every verb that takes a session
  id must follow a chain.
- A person attached to a PTY session sees it end and another begin. Scrollback is in the
  predecessor's recording, not in the new terminal.
- The move checkpoint adds refs to the operator's remote.
- Untracked files that are ignored, and files outside every repository, do not cross.

### Risks

- **Two writers on one branch.** If the successor started before the predecessor was
  gone, both would push to the work branch. D2 step 5 orders the start after the
  recorded terminal status and the process-group proof.
- **A stranded move.** After the predecessor ends, a successor that cannot be placed
  leaves the work stopped. D2 keeps the move artifact dispatchable and tells the
  operator.
- **Move loops.** A refusal on each destination in turn could bounce work between
  logins. D7.5 bounds consecutive moves without progress.
- **A thin record for PTY sessions.** A transcript tail drops events, and a harness
  with no readable transcript leaves nothing but a recording. D3.4 states the level
  before a move, and D8.3 makes the transcript read a tested capability.
- **Briefing quality across harnesses.** The same briefing reads differently to
  different models. D8.4's fixture catches a briefing that fails to carry the goal, the
  plan or the changed files; it does not measure task quality.
- **Unintended spend.** A move into a keyed or billed mode costs money. D6.6 applies the
  billing-boundary rules to every successor.

## Alternatives considered

- **Keep one session and give each incarnation its own admission.** The session id would
  survive a move. It requires changing the session reference to hold a receipt per
  incarnation, relaxing "admission is reused, not repeated", adding a release without a
  terminal status to `ADR-2026-08-17` rule 10, and letting a workarea archive restore
  under a different cell. Rejected by the product owner in favour of a successor session
  that links back to its origin (D1.6, D9.4).
- **Resume the harness's own conversation on the new host as the default.** No adapter
  is resume-qualified, a subscription login's conversation is tied to its account, and a
  different harness cannot read it at all. Kept as the `native_import` fast path.
- **A model-written summary as the briefing.** It costs a model call at the worst
  moment, it is not reproducible, and it can invent state. A selection plus typed state
  plus a reading tool carries more with less risk. A summary may be added later as an
  optional enrichment.
- **Build a briefing from the terminal recording.** A recording is rendered bytes, not a
  conversation. Parsing it would guess at roles and tool calls. Rejected; the adapter
  reads the harness's own transcript instead.
- **Rewrite a child's parent at a move.** It keeps lineage rows literal, but it makes
  re-parenting a general operation. Resolving lineage through the chain needs no write
  to a child.
- **Run the agent loop on a control plane with tools on the host.** A move would then be
  a change of tool environment. Rejected: execution stays where the operator routes the
  work, and host-login subscriptions exist only on the host.
- **Adopt a durable harness library for every harness.** It makes one harness durable,
  not the harnesses operators already use, and it does not address the workarea or the
  single-writer rule.
- **Start moves from the guard.** Moving work before a limit is reached would preempt
  healthy sessions and contradict `ADR-2026-11-19` G6. Rejected.
- **Carry the workarea as a whole-root archive.** It would carry files outside every
  repository. It also transfers an archive between sessions, which
  `ADR-2026-08-22` D3 forbids. Deferred to its own decision.

## Open questions for the product owner

None. On 2026-11-23 the product owner ruled on all three: the move bound is three
consecutive moves without a completed turn (D7.5), files outside every repository do not
cross in the first phase (D5.4), and the quiet interval is ten seconds (D2 step 3).

## Affected documents

These edits landed in the accepting commit.

- `001-layered-execution-model.md` — sessions: succession, the chain, and `moved`.
- `002-provider-base-contract.md` — `SupportsHistoryImport`, `SupportsTranscriptRead`;
  the move fixture.
- `011-local-daemon-fleet.md` — the restart preflight order; the move verb.
- `013-orchestrator-and-governor.md` — `moved` as a non-completion end; chain budgets;
  lineage through a chain.
- `014-tui-operator-surfaces.md` — a chain renders as one timeline.
- `protocol/interactive-attach-v1.md` — `movedTo` on the ended state; kill reason
  `moved`; the pre-move notice and input freeze.
- `ADR-2026-07-12-interactive-pty-session-host.md` — forward note: a stop for a move is
  not the kill path.
- `ADR-2026-08-31-session-recovery-taxonomy-and-state-vocabulary.md` — forward note: a
  session move is a succession, outside the recovery table.
- `ADR-2026-10-07-headless-session-shim-adoption.md` — amend the out-of-scope line:
  continuation on another host is a session move; add stop reasons `session_move` and
  `allowance_wait`.
- `ADR-2026-11-19-host-observation-contract.md` — S4 gains `onRefusal`; a note under G6
  that a provider refusal and an explicit act are the only move triggers.
- `ADR-2026-11-20-harness-interaction-contract.md` — D1 capability additions; the D7
  fixture; a note that PTY adapters normalize a transcript read into the same kinds.

No `BOUNDARY-SYNC` region changes.

## Affected work items

The tracker references are in the platform companion ADR.

## Implementation notes

Suggested order, each phase useful alone. Headless and PTY modes ship together in every
phase.

1. The move briefing and the record-reading tool, with the transcript read for PTY
   adapters, exercised by a same-host move between two harnesses in the standalone
   runtime.
2. The move checkpoint and workarea materialization from it.
3. The move record, the held successor, the `moved` end and the attach-protocol
   additions, with the drain preflight.
4. `provider-refusal` and `onRefusal`.
5. `SupportsHistoryImport`, then `native_import` once an adapter is resume-qualified.
