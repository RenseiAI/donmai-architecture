---
status: Accepted
date: 2026-11-23
boundary: shared
split: sibling-extensions
---

# ADR-2026-11-23 — Session view attach: a bounded snapshot, a position, and paged history for every client

**Status:** Accepted (2026-11-23, product-owner acceptance). The affected-document
edits landed in the accepting commit. Nothing here is built yet.
**Date:** 2026-11-23
**Boundary:** shared. This file is the canonical ADR. `rensei-architecture` carries a `status: Mirrored` stub and a platform-only companion ADR.
**Authors:** agent:claude (Fable 5.2), for the product owner

## Context

A client that opens a session wants two things: what the session looks like now, and
everything that happens next. For a session that has run for days, how it gets the first
decides whether the session opens at once or after a long replay.

The corpus already separates a session's evidence into channels with their own
positions. `ADR-2026-08-19-durable-execution-event-bus-and-bounded-subscriptions.md` D3
says session replay "may carry a cursor tuple containing ledger sequence, structured
sequence, and terminal byte offset", that "a cursor below the retained floor returns
`cursor_expired` and an archive or rehydration path", and that "no consumer silently
resets to the current head".

The terminal byte channel already attaches well. `protocol/interactive-attach-v1.md`
gives a late viewer a screen snapshot and a tail, and says "resume cost is therefore
O(1) in session age".

The structured channel does not. `ADR-2026-11-20-harness-interaction-contract.md` D6
says the runner forwards the normalized stream and that consumers derive their views
from it, and it stops there. It does not say how a consumer joins late or reconnects.
What exists in the OSS layer today:

- The session journal holds the full normalized stream, one event per line, with no
  sequence field and no size bound.
- The host watch tails that file by byte offset. The offset lives in memory, it breaks
  when the file is truncated, and by default the watch starts at the end of the file and
  shows no history.
- The local daemon serves a session list and a session detail. It serves no events.
- A second journal, used for upload, assigns each record a strictly increasing
  structured sequence. The two journals do not share it.

Each consumer therefore rebuilds its own view from the first event it can reach, and a
reconnect starts again. The cost grows with the length of the session, which is the
opposite of what a long session needs.

Prior art: the open-source t3code project treats persisted projections as the source of
truth and keeps its event log for a bounded window. A client gets a bounded snapshot
stamped with a sequence and then the events after it. A reconnecting client sends its
last sequence and gets a short replay or a fresh snapshot, and older history is a
separate paged read. Streaming output is coalesced and never replayed.

## Decision

Every client attaches to a session's structured content the same way: it receives a
bounded **session view** stamped with a **position**, then the events after that
position. A reconnecting client sends its position and receives a bounded replay or a
fresh view. Older history is a separate paged read. No client replays a session from its
first event to show its current state.

This decision covers the structured channel only. The terminal byte channel keeps the
attach of `protocol/interactive-attach-v1.md`.

### A1 — Every durable event has a sequence

1. Each normalized event of a session (`ADR-2026-11-20` D4) carries `structuredSeq`: a
   per-session integer that starts at 1, increases by exactly 1, and is assigned once by
   the session's runner, the single writer.
2. The sequence survives a runner restart and every incarnation of the session. A new
   incarnation continues from the last recorded value.
3. The session journal records the sequence. The sequence a runner assigns for upload
   and the sequence in the journal are the same number.
4. The sequence is the structured position of `ADR-2026-08-19` D3's cursor tuple. This
   ADR adds no second ordering.

### A2 — Durable events and transient updates

1. A **durable event** changes the record: an item started, completed, failed or was
   interrupted; a message completed; a plan was replaced; a turn began or ended. It
   carries a `structuredSeq`.
2. A **transient update** reports progress inside an item that is still running: partial
   assistant text, partial reasoning, a tool progress tick, running tool output. It
   carries the item id and a per-item revision that only increases. It has no
   `structuredSeq`.
3. Transient updates are coalesced by the server to a bounded rate and are **never
   replayed**. A view carries the latest transient state of every running item (A3), so
   a client that misses them loses nothing durable.
4. A producer may persist transient updates for its own purposes. The attach contract
   never serves them from history.

### A3 — The session view

A session view is the state of a session at one position. It is derived from the record
and is bounded however long the session has run.

| Part | Content |
|---|---|
| `position` | the position the view is true at (A4) |
| `session` | status, end reason, harness, model, the latest `effective_settings`, usage totals, the record's completeness level |
| `chain` | the predecessor and successor session, when the session was moved (`ADR-2026-11-23-session-moves-and-succession.md`, Proposed) |
| `window` | the newest items, each in its latest state, oldest first |
| `live` | what is in progress: running items with their latest transient state, the current plan, the open interactive request, whether a turn is running or the session waits for input |
| `history` | a cursor for the page before the window, and whether there is one |

1. **Items, not events.** A view holds one entry per item id in its latest state: a tool
   call with its result, a message with its phase, a plan as last replaced. This is the
   same pairing `ADR-2026-11-20` D5 makes normative. A client never assembles an item
   from a call event and a result event it has to find.
2. **The window is bounded** by operator turns, by item count and by bytes, whichever is
   reached first (A8). An item body over its cap is cut and marked `truncated`, with a
   way to read the rest.
3. **The view is stored, not recomputed.** A producer keeps the view up to date as it
   records each durable event, so serving it costs the same for a session an hour old
   and a session a week old.
4. **Durable before live.** A view and the events after it are served only from what is
   durable (`ADR-2026-08-19`). A view never includes an event that could be lost.

### A4 — The position

1. A position is opaque to the client. The client stores it and sends it back.
2. To the server it is the cursor tuple of `ADR-2026-08-19` D3 for the channels the view
   draws on. In the standalone runtime that is the structured sequence. A composing
   control plane may add its own channels.
3. A position is exclusive: attaching with it yields what came after it.
4. Positions are per session. A position from one session means nothing to another,
   including the other sessions of a chain.

### A5 — Attach and reattach

A client attaches with no position, or with the last position it applied.

| Client sends | Server answers |
|---|---|
| no position | the session view, then every durable event after its position |
| a position within the replay bound | the durable events after it, then live |
| a position the server cannot serve from | a fresh session view marked `resync`, with the reason |

The `resync` reasons are closed:

| Reason | Meaning |
|---|---|
| `gap_too_large` | more events, or more bytes, lie after the position than the replay bound allows |
| `cursor_expired` | the position is below the retained floor |
| `cursor_ahead` | the position is past what the server has, for example after the server's store was restored |

1. A `resync` is explicit. It is never a silent reset to the head: the client is told
   why, the view states its position, and everything before the window is still reachable
   through history (A6), or is reported as expired there.
2. Durable events arrive in sequence order, at least once. A client applies an event
   only if its sequence is the next one, drops one it has already applied, and reattaches
   if it sees a gap.
3. A client commits its cached view and its position together, and only after it has
   applied an update. An interrupted update never advances the position.
4. Attaching, reattaching and reading history never append to the session's record.

### A6 — History

1. History is a separate read: pages of items before a cursor, newest page first, each
   bounded like the window. A client asks for the page before its oldest item.
2. Items in history are in their final state.
3. Where the page before a cursor lies below the retained floor, the read answers
   `cursor_expired` with the archive or rehydration path, when one exists
   (`ADR-2026-08-19-session-data-lifecycle-tiering-and-rehydration.md`, Proposed).
   History never ends silently at a retention boundary.
4. A client that received a `resync` keeps the items it already has and shows a gap
   between them and the new window. It fills the gap from history on demand.
5. History crosses a chain. The page before a successor's first item is the move
   briefing item, then the predecessor's newest items.

### A7 — One contract for every consumer

1. The operator surfaces of `014-tui-operator-surfaces.md`, an embedding binary, a
   coordinating agent's tools and any hosted client all attach through this contract.
2. A consumer renders the view with the presentation rules of `ADR-2026-11-20` D5.
   This ADR decides what a client receives and when, not how it draws it.
3. A session that ended has a view too. Its `live` part is empty and its last durable
   event is the end. A client attached when a session is moved receives that end with
   the successor named, and attaches to the successor with no position.
4. A session in a pseudo-terminal has both channels. Its structured view attaches here,
   with whatever its record holds, and states its completeness level. Its terminal
   attaches through the attach protocol.

### A8 — Bounds

The bounds are part of the contract. Their values are configuration. The proposed
defaults:

| Bound | Default |
|---|---|
| view window | 10 operator turns, 75 items, or 1 MiB |
| replay on reattach | 100 events or 1 MiB |
| history page | 20 operator turns, 150 items, or 1 MiB |
| transient updates | at most one per item every 50 ms |
| item body in a view | 16 KiB, then `truncated` |

A producer that cannot meet a bound says so in the view. It never silently serves more
or less.

### A9 — Standalone behaviour

The OSS layer ships a working implementation on one machine.

1. The session journal records `structuredSeq` (A1) and is the record.
2. The local daemon keeps a session view per live session and serves three reads under
   its existing localhost surface: the view, the events after a position as a stream,
   and a history page.
3. The host watch attaches through those reads. It no longer tails the journal by byte
   offset, it shows the current view when it starts, and it survives a truncated or
   rotated journal.
4. A journal written before this ADR has no sequence. The daemon assigns one in file
   order when it first reads it and records that it did.

A composing control plane serves the same contract to hosted clients from its own store.
The hosted delta is in the platform corpus.

## Consequences

### Positive

- Opening a session costs the same whether it is an hour or a week old.
- A reconnect after a short drop replays a handful of events instead of the session.
- Every consumer gets the same items in the same state, so two surfaces can no longer
  disagree about what a session did.
- Streaming output stops being a storage and replay cost.
- The host watch shows a session's current state when it starts.

### Negative

- A producer must keep a view up to date as it records, which is more work on the write
  path than appending a line.
- Every consumer has to be moved. Until one is, it keeps its old cost.
- A client that wants every event in order, for audit or debugging, must use the record
  or the replay reads, not the attach contract.

### Risks

- **A view that disagrees with the record.** A view updated outside the record's own
  commit could drift. A3.4 and the conformance check below guard it: rebuilding a view
  from the record must give the same view.
- **Unbounded items.** A single tool result can exceed any window. A3.2 caps the body in
  the view and offers the rest by reference.
- **Clients that assume completeness.** A client that treats the window as the whole
  session would hide history. A3 always carries the history cursor, and A6.4 requires a
  visible gap after a `resync`.
- **Sequence gaps after a crash.** A runner that assigned a sequence and died before
  recording the event must not reuse or skip it. A1.2 requires the next incarnation to
  continue from the last recorded value.

## Alternatives considered

- **Replay from the first event, faster.** Paging and compression lower the constant,
  not the growth. Rejected.
- **A bounded replay window with no stored view.** Serving the last N events is simple,
  but the client must still pair calls with results and rebuild plans, and an item that
  started before the window arrives half-described. Rejected in favour of items in
  their latest state.
- **One total order across every channel of a session.** It would make the position a
  single number. `ADR-2026-08-19` D3 rules it out: a bus position "does not order
  independent session evidence channels against one another".
- **Persisting and replaying every streaming delta.** It gives a perfect replay of how
  text appeared. It multiplies storage and replay for no state a late client needs.
- **Leaving each surface to tail the journal.** It is what exists. It breaks on
  truncation, cannot serve a remote client, and gives every surface its own bugs.
- **Folding the structured view into the terminal attach protocol.** The terminal
  channel carries rendered bytes for one pseudo-terminal process. A headless session has
  none.

## Open questions for the product owner

None remain. The product owner accepted the A8 default bounds as proposed, and the view
of an ended session is kept for the life of its record.

## Affected documents

These edits landed in the accepting commit.

- `001-layered-execution-model.md` — sessions: the session view and the position.
- `011-local-daemon-fleet.md` — the three daemon reads; the host watch attaches through
  them.
- `013-orchestrator-and-governor.md` — the runner assigns `structuredSeq`; the journal
  records it.
- `014-tui-operator-surfaces.md` — every operator surface attaches through the
  contract; a visible gap after a resync; "load earlier".
- `ADR-2026-11-20-harness-interaction-contract.md` — D4 gains `structuredSeq` and the
  durable and transient classes; D6 names this ADR as how a consumer joins the pipeline;
  D7 gains the view conformance check.
- `ADR-2026-08-19-durable-execution-event-bus-and-bounded-subscriptions.md` — forward
  note: the structured position is the runner-assigned sequence, and `resync` is the
  explicit form of a reset.

No `BOUNDARY-SYNC` region changes.

## Affected work items

The tracker references are in the platform companion ADR.

## Implementation notes

- **Conformance.** `agent/conformance` gains a view check: for a recorded transcript,
  the view built event by event equals the view rebuilt from the whole record, and a
  client that reattaches at every position ends with the same items as one that never
  disconnected.
- Suggested order: the sequence in the journal; the daemon's view and its three reads;
  the host watch on them; transient updates; history across a chain.
