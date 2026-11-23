---
status: Accepted
date: 2026-11-20
boundary: shared
split: inline-addenda
amends: 001-layered-execution-model.md, 002-provider-base-contract.md, 014-tui-operator-surfaces.md
---

# ADR-2026-11-20 — Harness interaction contract: one set of interactions, instructions and output for every harness

**Status:** Accepted (2026-11-20, product-owner acceptance). The affected-document
edits to `001`, `002` and `014` landed in the accepting commit. Implementation follows
the phases in § Implementation notes. Phase 0 (rendering fixes needing no contract
change) is in review; phases 1–5 are pending.
**Date:** 2026-11-20
**Boundary:** shared. This record is OSS-canonical for the execution-layer contract:
- the interaction verbs;
- the normalized instruction set and its per-harness translation report;
- the effective-settings event;
- event model v2;
- the presentation model and its shared vectors;
- translator conformance tests.

The platform corpus carries a mirrored stub with the hosted delta inline: persisting the
normalized stream, serving it to hosted clients, and displaying and verifying effective
settings.

**Authors:** architecture lane (coordinator draft)

> **Amended 2026-11-23 by
> [`ADR-2026-11-23-session-view-attach.md`](ADR-2026-11-23-session-view-attach.md).**
> D4: every durable normalized event carries a runner-assigned per-session
> `structuredSeq`, and events split into durable events and transient updates,
> which are coalesced and never replayed (A1, A2). D6: that ADR is how a consumer
> joins the pipeline; the host watch attaches through the daemon's view reads
> rather than reading the journal (A7, A9). D7: `agent/conformance` gains the view
> check (a view built event by event equals the view rebuilt from the record).

## Context

A harness is the agent loop the runner drives: a CLI or app-server such as Claude Code,
Codex, Pi, opencode, Gemini or a local model server. `002-provider-base-contract.md`
§ "Agent Runtime providers" already gives every harness three abstractions:

- **Interactions.** `agent.Provider` (`Spawn`, `Resume`, `Shutdown`) returns an
  `agent.Handle` (`Events`, `Inject`, `Stop`). Capability flags say which verbs work
  (`SupportsMessageInjection`, `SupportsSessionResume`, …). About ten adapters live
  under `provider/harness/`.
- **Input.** `agent.Spec` carries the prompt, model, `EffortLevel`, sandbox, MCP servers,
  allowed tools and so on. Each adapter translates it into its harness's native request
  (for example `provider/harness/codex/spec_translation.go`).
- **Output.** `agent.Event` is a closed union of twelve kinds (`init`, `system`,
  `assistant_text`, `llm_call`, `tool_use`, `tool_result`, `tool_progress`, `usage`,
  `context_usage`, `subagent`, `result`, `error`). Anything else is a `system` event with
  a free-form `Subtype` and `Message`.

These abstractions stop short in five places, and each gap has cost us.

1. **Translators are untested against the harness protocol.** A request field can be
   misnamed and nothing fails. The Codex reasoning effort was sent under a key Codex
   ignores, so every Codex run used the default effort for months. A drift test now
   exists for that one field of that one harness.
2. **Nothing reports what a harness actually applied.** The runner knows what it asked
   for (model, effort, sandbox, approval mode), not what the harness ran with. A silently
   ignored knob can only be found by reading source.
3. **The output union is too coarse.**
   - Reasoning, plans, file changes, approval requests and turn boundaries all travel as
     `system` subtypes. Each consumer re-parses the free-form `Message`, and several
     print it raw.
   - `tool_progress` carries no tool-use id. A tick cannot be tied to its call, so
     consumers append it as a new row instead of advancing the call's indicator.
   - Inconsistencies surface downstream. A Claude result arrives with only an id, so a
     consumer shows an anonymous "tool result". A Codex file change decodes its `kind`
     object as a string and loses both the kind and the diff. Codex moderation metadata
     arrives on every turn as raw classifier JSON.

   In practice, the routine moderation notices crowd out every other warning, and a
   visible share of tool rows repeats the row before them.
4. **No single pipeline.** The runner flattens events into a coarser activity shape
   before they leave the host. Every surface rebuilds labels from that shape and gets
   different harnesses wrong in different ways. Examples:
   - the TUI host watch, the TUI inbox and web clients each have their own tool
     summariser;
   - the runner had two copies of a Claude-only summariser.

   A new harness, or a harness that changes its protocol, needs fixes in every renderer.
5. **Instructions stop at execution knobs.** Plan mode, approval policy, tool policy and
   structured-output schemas differ across harnesses. Today each is either absent from
   `agent.Spec` or reached through harness-specific fields, and nothing says which
   harness honours which.

Prior art: the open-source t3code project normalizes Claude, Codex and Pi into typed turn
items, with these properties:
- assistant message with a commentary/final phase, reasoning, command execution with
  output and exit code, file change with additions, deletions and diff, plan, todo list,
  approval request, error, system notice;
- a status lifecycle `pending → running → completed | failed | interrupted`;
- deltas that never become rows.

Its web client folds consecutive tool work into one row per group, and errors, approvals
and notices stand alone. A native mobile client in this ecosystem adopted those
presentation rules on top of today's coarse wire and documented which ones the wire could
not support.

## Decision

Every harness is driven through one **harness interaction contract** with five parts:
standard interactions, normalized instructions with a translation report, an
effective-settings echo, event model v2, and a shared presentation model. Adapters own
all harness-specific translation, and conformance tests pin each translator to the
harness's own protocol schema. Downstream of the adapter there is one normalized stream,
and every consumer renders it with the same rules.

### D1 — Standard interactions

Each interaction verb is declared by capability and is never inferred:

| Verb | Today | Capability |
|---|---|---|
| `start(spec)` | `Provider.Spawn` | always |
| `resume(ref, spec)` | `Provider.Resume` | `SupportsSessionResume` |
| `steer(text)` (inject into the running turn) | `Handle.Inject` | `SupportsMessageInjection` |
| `interrupt()` (end the turn, keep the session) | — (new) | `SupportsInterrupt` |
| `respond(requestId, decision)` (answer an approval or a question) | — (new) | `SupportsInteractiveRequests` |
| `stop()` / `shutdown()` | `Handle.Stop` / `Provider.Shutdown` | always |

A verb the harness lacks returns the existing typed unsupported error. It never degrades
silently: an `interrupt` without native support is refused, not turned into `stop`.

### D2 — Normalized instructions and the translation report

`agent.Spec` keeps its execution knobs and gains an `Instructions` block of harness-neutral
intents:

| Instruction | Values |
|---|---|
| `planMode` | `off` · `plan-first` (plan, then proceed) · `plan-only` (plan, never edit) |
| `approvals` | `never` (run autonomously inside the sandbox) · `on-request` · `on-risk` |
| `toolPolicy` | allow and deny lists by tool family (`command`, `read`, `edit`, `search`, `web`, `agent`, `mcp`) and by exact name; deny wins |
| `outputSchema` | a JSON Schema the final message must satisfy |
| `effort`, `model`, `sandbox` | the existing knobs, now reported like the rest |

Each adapter's translator returns a **translation report** with one line per instruction:
`applied` (a native field carries it), `approximated` (prompt text or a nearest native
mode, with a one-line note), or `unsupported`.

A required instruction that comes back `unsupported` fails admission before spawn, with
the report in the error. An optional one runs and is reported. The report is
deterministic and is computed without starting the harness, so a control plane can show
it before dispatch.

### D3 — Effective-settings echo

After start, the adapter emits one `effective_settings` event. For each instruction and
knob it carries:
- `requested`: the normalized value;
- `applied`: the harness's own echo when the protocol returns one (a session-configured
  notification, the init frame's model and permission mode), else the translator's
  report;
- `evidence`: `native-echo` or `translator`;
- any `mismatch`.

A later change, such as a model reroute or an effort clamp, emits a new
`effective_settings` event carrying only the changed lines. Consumers show the latest.
A mismatch between requested and applied is a notice, never silent.

### D4 — Event model v2

The union stays closed. v2 is additive: v1 consumers keep working, and new kinds and
fields are optional.

- **Stable item ids.** Every event about a unit of work carries `itemId`, and for tools
  it is the tool-use id. `tool_use`, `tool_progress` and `tool_result` share it.
  `tool_progress` gains `itemId`. An adapter that cannot know the id leaves it empty and
  never guesses.
- **Item status.** Each item has the status lifecycle
  `started → running → completed | failed | interrupted`. A consumer holds per-item
  state. Progress and deltas update that state and never append.
- **New kinds**, promoted from `system` subtypes and parsed once in the adapter:

  | Kind | Payload |
  |---|---|
  | `reasoning` | text and summary (distinct from `assistant_text`) |
  | `plan` | steps with status, from plan or todo updates, replace-whole by `itemId` |
  | `file_change` | per-file `path`, `change` (`add`, `update`, `delete`, `move`), `movePath`, `additions`, `deletions`, unified `diff` |
  | `interactive_request` | an approval or a question with `requestId`, prompt, options; answered with `respond` |
  | `turn` | `started` / `completed` with `turnId`; replaces the turn-marker system subtypes |
  | `notice` | `severity` (`info`, `warning`, `blocked`) and one-line `text`. Routine harness metadata that carries no reader-facing signal maps to no event. |
  | `effective_settings` | D3 |
- **Assistant phase.** `assistant_text` gains `phase` (`commentary` or `final`).
- **Raw passthrough.** Every event keeps `raw`, the provider-native payload, for
  debugging and replay. No renderer reads `raw`.
- **Unknown future kinds** render as a `notice`, never as raw JSON.

### D5 — One presentation model, two implementations

`agent/present` (Go, pure, standard library only) defines the presentation of the
normalized stream:
- the tool **family**;
- a human **title**, with MCP tools as `server › tool`;
- a one-line **detail**: the command with its shell wrapper removed, the path, pattern,
  URL or description;
- decoding of content-part tool output into text.

`testdata/vectors.json` pins these rules. A second implementation in another language (a
web client) copies the vector file verbatim and must pass it. The rendering rules are
normative for every operator surface (`014`):

1. A call and its result are one row, paired by item id only, never by name or adjacency.
2. Progress never creates a row. It advances the item's activity indicator, a spinner
   frame per fresh tick that freezes when ticks stop and never animates on replay, and
   it names the running tool.
3. Adjacent tool rows fold into one expandable group with a plain-language summary
   (`4 tool events · Bash ×3, Read`). A failure, an interactive request or a notice
   breaks the run and stands alone.
4. Reasoning renders de-emphasised and distinct from the final message.
5. Raw JSON appears only on explicit expand.
6. Diffs render with `+`/`−` tint and `+A −D` counts.

### D6 — One pipeline

The runner forwards the v2 stream itself, not a flattened projection of it. Consumers
derive their views from the normalized events with the D5 rules:
- the local host watch reads the session journal;
- an embedding binary reads the same journal;
- a control plane persists the stream and serves projections.

Adding a harness means writing one adapter and its conformance fixtures. No renderer
changes. The OSS layer ships the full pipeline for local use. The hosted delta is in the
platform corpus.

### D7 — Translator conformance

`agent/conformance` gains a per-adapter suite that every harness adapter must pass:

- **Input.** For each `Spec` and `Instructions` value in the suite matrix, the native
  request the translator produces validates against the harness's published protocol
  schema. The schema is vendored with its version and provenance. The test asserts that
  the intended field carries the value, and it fails when a vendored schema update
  removes or renames the field.
- **Output.** Recorded harness transcripts (fixtures with synthetic content) map to an
  expected v2 event sequence. The suite covers tool call, progress and result sharing one
  id; a file change with kinds and diff; a plan; an interactive request; a turn boundary;
  and an error.
- **Report.** The translation report for the matrix is a checked-in golden. A change to
  what a harness honours shows up in review.

## Consequences

### Positive

- A harness or protocol change is fixed once, in its adapter, with a failing conformance
  test, instead of separately in every renderer.
- Operators and control planes can see and verify what each run really ran with.
- Progress drives an indicator instead of flooding the stream. Calls and results stop
  reading as duplicates.
- Plan mode, approvals, tool policy and output schemas become portable intents with an
  honest per-harness report, instead of harness-specific flags.

### Negative

- Adapters carry more: id plumbing, the translation report, and an effective-settings
  echo for each harness.
- Vendored protocol schemas need an update discipline. A harness release that changes its
  schema fails conformance until the vendored copy and the translator move together.
- Two presentation implementations, Go and a web language, must stay in step. The shared
  vectors bound this, but they only cover what the vectors encode.

### Risks

- Some harnesses do not echo applied settings, so `evidence: translator` is only as good
  as the translator. D7's input tests are the mitigation.
- Event volume grows with `effective_settings` and `turn`. Both are low-frequency, and
  progress remains unpersisted liveness.

## Alternatives considered

- **Normalize only at the consumer** (each renderer parses harness shapes). This is
  today's state. It produced the duplicated summarisers and per-surface drift this
  record fixes.
- **Adopt t3code's item model wholesale.** Its model is server-centric (threads,
  checkpoints, forks) and couples presentation to its own orchestration. We take its item
  kinds, status lifecycle and work-log folding, and keep `agent.Event` as the union so the
  existing adapters and consumers move additively.
- **Version-bump `agent.Event` to a new type.** Rejected for the same reason
  `002` § "v2 enrichments" rejected an API version bump: additive fields and kinds keep
  every adapter and consumer working through the transition.

## Affected documents

Landed in the accepting commit:
- `001-layered-execution-model.md` § "The ten plugin families" (harness tiers): the one-interaction-contract
  rule.
- `002-provider-base-contract.md` § "Agent Runtime providers": D1 verbs and capability
  flags, D2 instructions and translation report, D3 and D4 event kinds, D7 conformance.
- `014-tui-operator-surfaces.md`: the D5 rendering rules for operator surfaces.

## Affected work items

None tracked here. Implementation issues are filed against this record when it is
accepted.

## Implementation notes

Phased, in small pull requests:

0. **Rendering fixes on today's wire (shipping now, no contract change):**
   - `agent/present` with vectors, used by the activity poster and the host watch;
   - Codex file-change kind and diff decoding;
   - routine moderation metadata dropped, a block becomes a notice;
   - results named from their call;
   - host watch progress driving the card indicator instead of rows.
1. **D4 ids and kinds:**
   - `itemId` on `tool_progress`;
   - `reasoning`, `plan`, `file_change`, `turn` and `notice` promoted from system
     subtypes in the Claude, Codex and Pi adapters first;
   - consumers switch from subtype parsing.
2. **D7 conformance harness:**
   - vendored schemas for Codex app-server and Claude stream-json first;
   - output fixtures per adapter.
3. **D2 and D3:**
   - `Instructions` and the translation report;
   - `effective_settings` from native echoes where available.
4. **D1 verbs:** `interrupt` and `respond` for harnesses that support them.
5. **D6 pipeline:** the runner forwards v2 events, and consumers move off the flattened
   activity shape.
