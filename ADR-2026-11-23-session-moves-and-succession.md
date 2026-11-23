---
status: Proposed
date: 2026-11-23
boundary: shared
split: sibling-extensions
---

# ADR-2026-11-23 — Session moves: a session ends with a successor on another host, harness or account

**Status:** Proposed (2026-11-23). Nothing here is built, and no reference document changes until acceptance.
**Date:** 2026-11-23
**Boundary:** shared. This file is the canonical ADR. `rensei-architecture` carries a `status: Mirrored` stub and a platform-only companion ADR.
**Authors:** agent:claude (Fable 5.2), for the product owner

## Context

A session is bound to the host that claimed it, the harness that runs it and the login
it was admitted with. Three situations need the work to continue somewhere else:

1. **The host is going away.** A drain today waits for every seat, up to the drain
   bound. A seat that outlasts the bound is stopped.
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
distinct and are joined by a **continuation record**. Execution always stays in the
execution context that placement selected. No part of the agent loop moves to a control
plane.

### D1 — A session move is a succession, not a recovery

1. A session never changes host or execution cell. A session move ends the **predecessor**
   with end reason `moved` and admits a **successor** as a new session with its own
   admission receipt, claim and incarnation numbering.
2. A session move is a deliberate act (D7). It is not a member of the recovery taxonomy
   of `ADR-2026-08-31` D1, and absence never selects it. An unplanned loss of the
   predecessor's host is still "classify further".
3. Same-host continuation is unchanged. A live process is adopted, and a stopped one is
   resumed under `ADR-2026-10-07` D8, as the same session.
4. The successor says plainly what it was started from (D4). This is the difference from
   a `restart`, where "prior work is not carried".
5. Successions chain. A successor may itself be moved. The **chain** is the ordered list
   of sessions joined by continuation records, and it has exactly one live session.

### D2 — The move protocol

A move has a **move record** with a closed state list: `proposed`, `reserved`,
`stopping`, `continuing`, `completed`, `refused`, `stranded`.

1. **Propose.** The requester (D7) names the predecessor and may narrow the destination
   (D6). The move record is written `proposed`.
2. **Reserve.** Placement resolves the successor (D6), and the successor is admitted and
   claimed in a **held** state: it holds its claim and starts nothing. The record
   becomes `reserved`. If no destination survives, the move is `refused` with every
   candidate's typed reason, and the predecessor is not touched.
3. **Stop.** The predecessor's runner is asked to stop for a move. This is the stop of
   `ADR-2026-10-07` D8 steps 1 to 3 with stop reason `session_move`:
   - no new turn starts, and the current tool call finishes within the stop bound;
   - a tool call still running at the bound is interrupted and listed as lost;
   - the harness flushes, and the session record (D3) is complete through the stop;
   - a **move checkpoint** of each repository is pushed (D5).

   A harness that supports `interrupt` (`ADR-2026-11-20` D1) is interrupted at the safe
   point instead of waiting for the turn to end.
4. **End the predecessor.** Unlike a stop for resume, the runner posts the session's
   terminal status with end reason `moved`, carrying the continuation record's digest.
   The claim, the workarea lease and any fence rows are released by the ordinary
   terminal path (`ADR-2026-08-17` rule 10). The record becomes `continuing`.
5. **Start the successor.** Only after the predecessor's terminal status is recorded and
   its process group is proved gone is the held successor activated. It materializes
   its workarea (D5), prepares dependencies, and starts with its starting context (D4).
6. **Complete.** The successor's first `effective_settings` event (`ADR-2026-11-20` D3)
   completes the move.

Failure rules:

- **Before step 4 nothing is lost.** If the stop cannot reach a safe point within its
  bound, or the move checkpoint cannot be pushed, the held successor is released, the
  move is `refused`, and the predecessor keeps running.
- **After step 4 the continuation record is the durable state.** If the successor fails
  to start, it is placed again by the single fallback rule
  (`ADR-2026-08-12-placement-composition-law-and-single-fallback-rule.md`). If nothing
  survives, the move is `stranded`: the continuation record is kept, the work is
  dispatchable again from it, and the operator is told. A `stranded` move never ends
  silently.
- **A move is never retried by re-running the predecessor.** Its terminal status stands.

### D3 — The session record is the conversation source

1. The conversation a successor continues from is the **session record**: the normalized
   event stream of `ADR-2026-11-20` D4, in order, for every session in the chain.
2. In the standalone runtime the record is the session journal. A composing control
   plane persists the same stream and may serve it to a successor on any host.
3. A move requires the record to be durable through the stop. A predecessor whose record
   cannot be confirmed complete is not ended (D2 failure rule 1).
4. The record of every session in a chain is retained at least until the chain ends.
5. Reading the record for a successor is a read. It never appends to the predecessor's
   event log (`ADR-2026-08-19-session-data-lifecycle-tiering-and-rehydration.md`).

### D4 — The successor's starting context

Each successor starts in one of two ways, recorded as its provenance.

**`briefed`** is always available. The successor starts a fresh harness conversation and
receives a **continuation briefing** built from the session record. The briefing is
deterministic: the same record and budget give the same bytes. It is a selection, never
a model-written summary.

| Part | Content | Rule |
|---|---|---|
| Goal | the work item binding and the first operator input | always included, never shortened |
| Latest exchange | the last operator input and the last `final` assistant message | always included |
| State | the latest `plan` item, the files changed so far (path, change, additions, deletions), the open `interactive_request` if any, the work lost at the stop | always included, from typed events |
| Workarea | repositories, branch, move checkpoint, pull request if any | always included |
| History | turn items, newest first | included until the budget is spent |
| Omitted | references to every item left out | always included |

- The budget is the smaller of a configured cap and a share of the destination model's
  context window. The new operator input, if any, is never shortened to make room.
- The successor is offered a **record-reading tool** that pages the full record of the
  chain, so omitted history is retrievable on demand.
- A briefing never carries the predecessor harness's reasoning, its native tool state,
  or attachments by value. The briefing says so.
- Delivery uses the adapter's history import when it declares one (D8), and otherwise an
  attributed context block ahead of the first input. The delivery outcome is recorded.
  An unknown outcome starts a fresh harness conversation and delivers again. It never
  continues a conversation that may already hold half of it.
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
   with the work branch restored and the uncommitted state replayed as uncommitted. No
   root, leaf or lease transfers between sessions, so
   `ADR-2026-08-22-session-owned-multi-repository-workarea.md` D3 is unchanged.
3. Ignored and derived files do not cross. The successor runs dependency preparation as
   any new session does (`ADR-2026-11-11-session-independent-dependency-preparation.md`).
   A tree the predecessor touched is never captured as a dependency snapshot
   (`ADR-2026-10-08-kit-dependency-stores.md`).
4. Files in the predecessor's workarea root that are outside every repository do not
   cross. The briefing lists them. Carrying a whole-root archive to a successor is a
   later decision, because it changes who may restore an archive.
5. The predecessor's workarea root is disposed of by its ordinary terminal release. A
   composing control plane may archive it for the chain's lifetime.
6. Move checkpoints are removed when the chain ends.

### D6 — The destination is an ordinary placement

1. The successor is a new dispatch intent for the same work, resolved by the placement
   law. A session move adds no placement power: it cannot reach a pool, harness or login
   the work could not have been dispatched to.
2. The requester may narrow the destination by harness, model, subscription provider,
   pool or host. A named host is a pin and is hard within the law.
3. The trigger adds exclusions, each a typed viability reason:
   - `host-drain` excludes the draining host;
   - `provider-refusal` excludes the refused login, with the provider's reset time when
     it reports one.
4. Each candidate harness runs the instruction translation of `ADR-2026-11-20` D2 for
   the predecessor's `Instructions`. A candidate that reports a required instruction
   `unsupported` is excluded with that reason. The report is shown before an operator
   confirms a move, and the successor's `effective_settings` event shows what applied.
5. Subscription logins keep their rules. Viability, the guard and billing boundaries of
   `ADR-2026-11-19` S5 to S7 apply to the successor as to any dispatch. A move never
   starts a successor past a billing boundary the tenant's policy disallows.
6. An empty surviving set refuses the move, loudly and with reasons. It never widens.

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
   | `ask` (default) | the session stops at the refusal and waits; the operator is asked to move, wait or end |
   | `move` | a move is proposed at once, with the refused login excluded |
   | `wait` | the session stops for resume on its host and continues after the reset |

   `wait` reuses the stop-for-resume path with stop reason `allowance_wait`, and a
   harness that is not resume-qualified continues `seeded_fresh` from a briefing.
4. **Drain order.** The restart preflight's order becomes: adopt a live process, stop
   for resume, propose a session move where a destination can be reserved, then wait.
5. **Moves are bounded.** A chain allows a configured number of consecutive moves in
   which no turn completed. At the bound the next move is refused.

### D8 — Capabilities

1. Every harness can be a move source and a `briefed` destination. A move needs only the
   cooperative stop and a normalized record.
2. `SupportsInterrupt` shortens the stop. `SupportsSessionResume` with a passing resume
   fixture enables `native_import`.
3. A new capability, `SupportsHistoryImport`, declares that the adapter can load prior
   messages into a fresh harness conversation as history. Without it the briefing is
   delivered as an attributed context block.
4. Capabilities are computed from fixtures, never declared by hand
   (`ADR-2026-08-13-capability-realization-registry-and-viability-of-absence.md` D6).
   The conformance suite of `ADR-2026-11-20` D7 gains a move fixture per adapter: stop a
   scripted session, build the briefing, start a successor, and observe the goal, the
   plan and the changed files in its first turn's context.

### D9 — Budgets, completion and addressing

1. **Budgets belong to the chain.** Stage budget meters and turn counters continue from
   the predecessor's readings. A move never resets a cap.
2. **`moved` is not a completion.** It is a non-failure end with no charge and no
   failure backoff. No completion contract fires and no stage moves on it. The work item
   binding passes to the successor.
3. **One outcome per chain.** The session that finishes the work writes the outcome the
   work item sees.
4. **Addresses follow the chain.** A verb addressed to a moved session answers with a
   typed redirect naming the live successor. Operator surfaces present a chain as one
   timeline and follow the successor without operator action.
5. **Open requests do not cross.** A pending approval or question is ended as
   `interrupted` on the predecessor and listed in the briefing. The successor asks
   again if it still needs the answer.

### D10 — Standalone behaviour

The OSS layer ships a working move on one machine: a session moves to another harness or
another login on the same host, with the local daemon as the authority and the session
journal as the record. The move record, the continuation record, the briefing format,
the move checkpoint and the verbs are all OSS contracts. A move between hosts needs a
control plane that both hosts report to. The hosted delta is in the platform corpus.

## Consequences

### Positive

- A host can be drained or updated without waiting out, or losing, its seats.
- A session that hits its account limit can continue on another login or provider
  instead of failing.
- A cross-harness move does not depend on harness resume qualification, so it can ship
  before any adapter qualifies.
- One admission per session stays true. No change to the session reference, the release
  rule or the workarea ownership clause is needed.
- The briefing is deterministic and replayable, so a poor continuation can be diagnosed
  from the record.

### Negative

- A `briefed` successor loses the predecessor's reasoning, native tool state and any
  provider-side cache. The first turns after a move cost more and may repeat work.
- Session identity changes at a move. Every surface and every verb that takes a session
  id must follow a chain.
- The move checkpoint adds refs to the operator's remote.
- Untracked files that are ignored, and files outside every repository, do not cross.

### Risks

- **Two writers on one branch.** If the successor started before the predecessor was
  gone, both would push to the work branch. D2 step 5 orders the start after the
  recorded terminal status and the process-group proof.
- **A stranded move.** After the predecessor ends, a successor that cannot be placed
  leaves the work stopped. D2 keeps the continuation record dispatchable and tells the
  operator.
- **Move loops.** A refusal on each destination in turn could bounce work between
  logins. D7.5 bounds consecutive moves without progress.
- **Briefing quality across harnesses.** The same briefing reads differently to
  different models. D8.4's fixture catches a briefing that fails to carry the goal, the
  plan or the changed files; it does not measure task quality.
- **Unintended spend.** A move into a keyed or billed mode costs money. D6.5 applies the
  billing-boundary rules to every successor.

## Alternatives considered

- **Keep one session and give each incarnation its own admission.** The session id would
  survive a move. It requires changing the session reference to hold a receipt per
  incarnation, relaxing "admission is reused, not repeated", adding a release without a
  terminal status to `ADR-2026-08-17` rule 10, and letting a workarea archive restore
  under a different cell. Rejected for the size of the amendment. D9.4 gives operators
  the continuity that a stable id would.
- **Resume the harness's own conversation on the new host as the default.** No adapter
  is resume-qualified, a subscription login's conversation is tied to its account, and a
  different harness cannot read it at all. Kept as the `native_import` fast path.
- **A model-written summary as the briefing.** It costs a model call at the worst
  moment, it is not reproducible, and it can invent state. A selection plus typed state
  plus a reading tool carries more with less risk. A summary may be added later as an
  optional enrichment.
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

1. **Successor session or same session.** D1 chooses a successor. The alternative keeps
   the id at the cost of four amendments.
2. **Session classes in the first phase.** The contract covers every class. The proposal
   is to build headless dispatched sessions first and interactive sessions after.
3. **The standalone default for `onRefusal`.** `ask` is proposed for both layers.
4. **The move bound.** Three consecutive moves without a completed turn is proposed.
5. **Whole-root archives.** Whether files outside every repository must cross.

## Affected documents

These edits land in the accepting commit, not before.

- `001-layered-execution-model.md` — sessions: succession, the chain, and `moved`.
- `002-provider-base-contract.md` — `SupportsHistoryImport`; the move fixture.
- `011-local-daemon-fleet.md` — the restart preflight order; the move verb.
- `013-orchestrator-and-governor.md` — `moved` as a non-completion end; chain budgets.
- `014-tui-operator-surfaces.md` — a chain renders as one timeline.
- `ADR-2026-08-31-session-recovery-taxonomy-and-state-vocabulary.md` — forward note: a
  session move is a succession, outside the recovery table.
- `ADR-2026-10-07-headless-session-shim-adoption.md` — amend the out-of-scope line:
  continuation on another host is a session move; add stop reasons `session_move` and
  `allowance_wait`.
- `ADR-2026-11-19-host-observation-contract.md` — S4 gains `onRefusal`; a note under G6
  that a provider refusal and an explicit act are the only move triggers.
- `ADR-2026-11-20-harness-interaction-contract.md` — D1 capability addition; D7 fixture.

No `BOUNDARY-SYNC` region changes.

## Affected work items

The tracker references are in the platform companion ADR.

## Implementation notes

Suggested order, each phase useful alone:

1. The continuation briefing and the record-reading tool, exercised by a same-host move
   between two harnesses in the standalone runtime.
2. The move checkpoint and workarea materialization from it.
3. The move record, the held successor and the `moved` end, with the drain preflight.
4. `provider-refusal` and `onRefusal`.
5. `SupportsHistoryImport`, then `native_import` once an adapter is resume-qualified.
