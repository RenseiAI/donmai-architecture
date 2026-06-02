---
status: Accepted
date: 2026-06-02
boundary: shared
split: sibling-extensions
---

# ADR-2026-06-02 — Interactive (non-headless) agent run mode

> Platform extensions: `rensei-architecture/ADR-2026-06-02-interactive-agent-run-mode-platform-extensions.md`.
> Driving plan: `runs/2026-06-02-interactive-interviews/00-PLAN.md` (+ `01-CONTRACT-FREEZE.md`).

## Context

The donmai runtime is **headless by design**. A session is one-shot: the runner clones the repo,
builds a prompt, spawns the provider (`claude -p --output-format stream-json …`), consumes events to a
single `ResultEvent`, posts a terminal status, and tears the sandbox down. Four independent layers
enforce this: (1) `provider/claude/cli_args.go` always prepends `-p` (print/one-shot); (2)
`runner/loop.go` hardcodes `Autonomous: true`; (3) `prompt/templates/system_base.tmpl` and the role
cards instruct "never ask the user a question"; (4) `spec_translation.go` always disallows
`AskUserQuestion`. This is correct for autonomous SDLC work and must remain the default.

A new product class — **interactive interviews** (Rensei's first non-technical, streaming-text,
end-user surface) — needs the *opposite*: a long-lived agent that asks one question, **stops**, waits
for a human reply, and continues *with full context* across many turns, streaming its output token by
token. The naive reading is "this fights all four headless layers." It does not. The donmai runtime
already ships the load-bearing primitive: the Claude provider declares
`SupportsMessageInjection = true` (`provider/claude/claude.go`), `Handle.Inject(text)` spawns
`claude --resume <session-id> -p <text>` whose JSONL streams onto the **shared events channel**, and
`runner/loop.go` already wires `OnInject → injectCh → drainMemoryInjects` for the Wave-3 memory-inject
transport. What is missing is a **run mode** that (a) does not terminate after the first turn, (b)
treats injected payloads as *user turns* (not just memory blocks), and (c) forwards incremental token
deltas rather than only whole `response` activities.

Per the corpus-wins rule (`001-layered-execution-model.md` boundary discipline; platform `CLAUDE.md`
and `AGENTS.md`), a change that softens the headless contract for any execution path requires an ADR
before code. This ADR establishes the OSS-substance contract for that mode. The platform-specific
consumers (the streaming relay, RBAC, workflow nodes, SDLC handoff) are the extension delta.

## Decision

Introduce an opt-in **`interview` run mode** in the donmai runtime. It is selected per dispatch
(`QueuedWork.Mode == "interview"`); when absent or any other value, behaviour is **byte-for-byte the
current headless path**. The mode is OSS-substance: any fork of donmai can drive an interactive agent
with it.

### 1. Non-terminating, inject-driven turn loop

`runner/loop.go` branches to a new `runInterviewLoop` when `Mode == "interview"`. The loop:

1. Spawns the provider once (the long-lived parent `claude` session in the cloned worktree).
2. Streams the agent's **question turn** out (see §3), then **parks** on `injectCh` instead of
   terminating — the agent has asked one question and yielded.
3. On a received inject of kind `user`, calls `Handle.Inject(text)` → `claude --resume`, whose events
   flow onto the shared channel; streams that turn; returns to park.
4. Exits cleanly on the completion sentinel `<!-- INTERVIEW_COMPLETE -->` in assistant text, an
   **idle-grace** timeout, or context cancellation. Steering / backstop / post-session are skipped.

The existing `drainMemoryInjects` is generalized to drain **between every turn** (not only at the
post-terminal seam) and to filter by inject kind. Claude's single-in-flight `--resume` contract is
preserved (one inject subprocess at a time, on the single runner goroutine).

### 2. Inject payloads carry a kind

`heartbeat.InjectPayload` gains `Kind` (`"memory" | "user"`; empty == `"memory"` for back-compat).
The memory-inject path is unchanged. User turns are a new producer of the same durable, dedup'd,
one-in-flight transport. The daemon — which today *decodes* inbox/inject metadata but does not route
it — routes a claimed `user` inject to the running session's `Handle.Inject`.

### 3. Token-delta streaming is a first-class output

The provider already runs with `--output-format stream-json`, which emits incremental
`content_block_delta` frames that the runner currently drops. In interview mode the runner maps those
to **token-delta frames** on a per-session channel, **batched** (flush at most every 100 ms or 20
tokens) so the activity/transport path is not flooded and replica-local activity buffers are not
evicted. Whole-turn `response` activities are still emitted (unchanged) so non-interview consumers and
durable history are unaffected. The frame shape and channel naming are platform-contract concerns; the
OSS contract is: *interview mode produces ordered, batched text deltas in addition to terminal turn
text.*

### 4. Minimal headless-layer reversal, scoped to the mode

Only what the loop needs changes, and only when `Mode == "interview"`:

- `-p` print mode and `--resume` turn-taking are **kept** — conversational turn-taking is achieved by
  the agent ending its turn and the platform injecting the next user reply, **not** by the
  `AskUserQuestion` tool, which **stays disallowed**.
- The non-terminating loop (§1) is the core behavioural change.
- The "never ask the user" persona is replaced **for this mode only** by an interview persona
  (one-question-per-turn, then stop). The default headless persona is untouched.
- The budget enforcer is replaced by an interview budget (wall-clock + idle-grace) because the
  finite-run caps (sub-agents/tokens) do not model an unbounded conversation.

### 5. Security envelope for user-text-in-cloned-repo

Interview mode routes **untrusted human text** into a tool-capable agent operating in a **cloned,
user-controlled repository**. The cloned repo's own `.claude/CLAUDE.md` can override system-prompt
directives (a confirmed production incident). The OSS contract therefore requires, for interview mode:

- A **hardened interview persona** delivered by a mechanism the cloned repo cannot override (a
  shadow/prepended instruction, and/or cloning without the repo's `CLAUDE.md`, and/or a read-only FS).
- **Code-authoring tools disallowed** (interview agents are thinking-only — like the research role);
  at most read-only repo inspection.
- The mode MUST NOT be selectable for a provider that does not declare
  `SupportsMessageInjection = true`.

The specific hardening implementation and its proof (a hostile-`CLAUDE.md` smoke) are a shared
concern; the contract above is the floor.

## Consequences

### Positive

- Reuses shipped primitives (`SupportsMessageInjection`, `--resume`, `OnInject/injectCh/drain`); the
  net-new is a loop variant + a payload kind + a delta mapper, not a runtime rewrite.
- Default headless behaviour is provably unchanged (single `Mode` discriminant; non-interview paths
  untouched).
- Interactive agents become an OSS capability, not a platform-only bolt-on.

### Negative

- A second, long-lived run path to maintain alongside the one-shot path.
- Per-turn `claude --resume` reloads growing context — latency and token cost grow with transcript
  length (mitigate with summarization if it bites).

### Risks

- Sandbox wall-clock: a long-lived interview can exceed provider/sandbox idle timeouts. Keep-alive and
  pause/resume are platform-extension concerns but the mode's idle-grace bounds the worst case.
- Persona-override by a hostile cloned `CLAUDE.md` — addressed by §5; must be proven before any
  production rollout.

## Alternatives considered

- **Gate-per-turn via the workflow engine** (one suspend/resume per question): structurally
  15–30 s/turn (graph rebuild + poll + boot) — a chat-feel regression. Rejected for the live loop.
- **Platform-side streaming LLM** (conversation driven by a direct model call; sandbox demoted to a
  grounding tool): better first-token latency and zero sandbox idle, but **cannot support
  `host-session` auth** (no logged-in CLI in a serverless function) and diverges from "the agent runs
  in the capacity pool." Rejected by the product owner; recorded here as the runner-up.
- **New agent runtime** instead of reusing `--resume`: unjustified given the injection primitive
  already exists.

## Affected documents

- `001-layered-execution-model.md` — interview mode is a new long-lived variant of the execution loop.
- `ADR-2026-04-29-long-running-runtime-substrate.md` — interactive sessions are a new long-running
  workload class.
- `ADR-2026-05-10-native-rich-providers.md` — `SupportsMessageInjection` becomes a hard requirement
  for a run mode, not just an optional capability.
- Platform extensions: `rensei-architecture/ADR-2026-06-02-interactive-agent-run-mode-platform-extensions.md`.

## Follow-on items

- donmai: `runner/interview_loop.go`, `InjectPayload.Kind`, daemon inject routing, token-delta mapper
  + batching, interview budget, persona shadow-prepend (Rensei lane REN-1563).
- Prove the hardened persona survives a hostile `CLAUDE.md` in smoke before rollout (REN-1570).

## Implementation notes

`Mode` is the only discriminant; everything else is gated on it. The token-delta frame shape, the
Redis channel name, the inject wire shape, and the completion sentinel are frozen in
`runs/2026-06-02-interactive-interviews/01-CONTRACT-FREEZE.md` and mirrored as constants in both repos
(platform `src/lib/interview/wire-types.ts` + a donmai Go constants file), the same manual cross-repo
sync discipline used for `AGENT_ENV_BLOCKLIST`.
