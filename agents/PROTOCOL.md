# Agent Operating Protocol

Shared operating procedure for every agent working in a donmai-family repository.
Each repo's `AGENTS.md` routes here; this file owns the cross-repo procedures so
repo files stay short. Rules are procedures, not advice — follow them literally.

## P — Before the first edit

- P1. Read the repo's `AGENTS.md` top to bottom before any tool call that writes.
- P2. The task names a file, symbol, or error line? Your FIRST search goes there;
  treat the stated cause as a hypothesis until you see it at a `file:line`.
- P3. Before writing any new helper, command, node, or package: grep 2–3 keyword
  variants for prior art and open ONE existing example of the same kind; name the
  example you are matching. No example exists? Say so before inventing a pattern.
- P4. Task needs >2 file edits? Post a plan block before the first edit:
  GOAL (one line) / FILES (exact paths) / DONE-WHEN (a command) / CONSTRAINTS
  (verbatim every "don't / only / keep" the requester stated).
- P5. Run the narrowest relevant check first and record the baseline
  (`BASELINE: pass` or `BASELINE: N failures — <names>`). Already red? Report
  before starting — never guess "was that already broken?".
- P6. Contract-touching work (schema, CLI flag, wire type, extension point,
  user-visible UX): read the governing architecture docs FIRST, in the order the
  repo's `AGENTS.md` lists. The corpus is authoritative over code — align the
  code or open an ADR; never silently diverge.
- P7. Before the first tool call, restate in one line what the request is
  actually asking for; when the literal words and the code/context disagree,
  surface the mismatch instead of executing the letter of the ask.
- P8. Proceeding on a choice the request leaves open? Write
  `ASSUMPTION: <choice> — <evidence>` and continue; never ask a question the
  repo can answer, and never bury an assumption in prose.

## C — While editing

- C1. Read the enclosing function/type plus imports before the first edit of a
  file; under 250 lines, read the whole file (guessed edits patch the wrong code).
- C2. Never edit generated or vendored paths (`dist/`, `gen/`, `vendor/`,
  `node_modules/`, lockfiles, files marked `DO NOT EDIT`) -> instead: change the
  source or generator and re-run it, naming the generator command.
- C3. After renaming or changing any signature, flag, env var, config key, route,
  or enum: grep the OLD name repo-wide with no file-type filter, paste the hit
  list, and disposition every hit (`updated` / `unaffected — <reason>`).
- C4. Copy-adapted block: grep the file for each token you had to change and
  confirm no stale copy of the old token survives inside the new block.
- C5. New I/O, network, or parsing code implements the failure path explicitly;
  an empty error path on I/O code is a defect, not a simplification.
- C6. Match the repo's stated conventions exactly (error wrapping, test style,
  import extensions); the repo's `AGENTS.md` Conventions/Gotchas section wins
  over your habits.

## V — Before claiming done

- V1. "Done", "fixed", "works", "passing" may be written only beside fresh
  command output from THIS session, run AFTER the last edit. Otherwise write
  `EDITED-UNVERIFIED: <file>` (unrun code is unknown code).
- V2. Run every command in the repo's Gates section, in order. Lint and tests do
  NOT type-check in these repos — the type gate is a separate listed command and
  skipping it is the single most common way CI goes red after you leave.
- V3. Quote the result line of each gate verbatim. "0 tests ran" is a failure of
  verification, not a pass.
- V4. Multi-part request: list every distinct deliverable as VERIFIED (command),
  EDITED-UNVERIFIED, or NOT-DONE. Reporting NOT-DONE is acceptable; silently
  dropping it is not.
- V5. Run `git diff --stat` and justify every changed file against the goal in
  one line each; revert what you cannot justify.
- V6. New or changed behavior in a binary/service ships with smoke coverage in
  the repo's paired smokes project; state where the coverage lives or write
  `SMOKE-GAP: <what is uncovered>` in your final report.
- V7. Attack your own conclusion once before handing it over: name the
  strongest reason it could be wrong, then run the one check that would expose
  it — or record it as an open risk in the report.
- V8. Report shape: the answer first, then the reasoning, then the risks and
  unknowns. Label every claim `VERIFIED` (with its command), `ASSUMPTION`, or
  `UNVERIFIED` — a reader must never have to guess which is which.

Before sending any completion report, answer these five to yourself; any "no"
sends you back to work, not to the send button:

1. Did the gates run AFTER my last edit, and did I quote their output?
2. Is any claim in the report standing without a command/output behind it?
3. What is the strongest reason this is wrong — and did I check it?
4. Did I solve what was actually asked, or only what was literally written?
5. What breaks first downstream (CI, prod, a consumer repo) — did I say so?

## D — When something fails

- D1. Reproduce first: run the exact failing command and quote the line showing
  the reported symptom before changing code. Cannot reproduce? Say
  `CANNOT-REPRODUCE` with the commands you tried — never fix blind.
- D2. Write the cause before the fix: `CAUSE: <file:line origin> -> SYMPTOM:
  <file:line surface>`. Patching the symptom instead? Label it `WORKAROUND:` and
  say why the root cause is out of reach.
- D3. A downstream consumer silently no-ops? Check the writer side first — count
  rows in the upstream table/queue before debugging the consumer (empty input
  usually proves the producer is wrong).
- D4. Never re-run a failing command unchanged; state the hypothesis and what
  changed. After the 3rd failed fix attempt: form a NEW hypothesis from the full
  error text. After the 5th: stop and present the attempt ledger.
- D5. Race-flag test flakes (`-race`) are real findings, not noise — a local
  serial pass does not clear them; re-run the parallel race run.
- D6. NEVER make a failing check pass by weakening it (skip, deleted test,
  loosened assert, lint-disable) -> instead: quote the failure and propose the
  change.
- D7. Tripwires — the moment you catch yourself writing the left column, do the
  right column instead (these phrases look like competence and are not):

| About to write | Do instead |
|---|---|
| "probably unrelated" / "pre-existing" | prove it: stash your change, rerun on the clean tree, paste both results |
| "should work now" | run it and quote the output — there is no third option |
| "the test is flaky" | run it 3× in isolation and paste all three outcomes |
| "quick fix for now" | write the CAUSE line (D2) first, then decide |
| "must be a caching issue" | prove the executed code is the edited code, rerun with caches cleared, then claim |
| "easiest to just rewrite this" | state the root cause first — never rewrite to escape a bug you don't understand |

## W — Worktrees and parallel work

- W1. Code work happens in a sibling worktree `<repo>.wt/<branch-name>`, created
  with the repo's `scripts/create-worktree.sh <name>` where it exists — never
  directly on `main` in the primary checkout.
- W2. Sub-agents NEVER run `git worktree remove/prune`, `git reset --hard`,
  `git clean -fd`, `git restore .`, or checkout to another branch — the
  orchestrator owns worktree lifecycle (these destroy parallel agents' work).
- W3. Before dispatching parallel agents: enumerate the files each will touch;
  overlapping lanes get sequenced, not parallelized.
- W4. After any worktree operation, re-verify your CWD (`pwd`) before the next
  git command (CWD drift silently lands commits in the wrong tree).
- W5. Handoff/plan documents go stale within hours when agents run in parallel —
  verify claims against `git log` on disk before planning off one.

## R — Releases

- R1. Version numbers increment by the smallest step from the latest existing
  tag; check `git tag --sort=-v:refname | head -3` first — never leap.
- R2. Tag releases with an explicit SHA: `gh release create v<X> --target
  <sha>` — never `$GITHUB_REF_NAME` (on workflow_dispatch it names the branch
  and poisons future dispatches).
- R3. Coupled binaries that share a wire protocol ship lock-step: when the embed
  surface or wire contract moves, bump and release both sides together.
- R4. Publishing anything public (npm package, README, docs page, release
  notes): run the repo's Boundary greps first; a leaked private reference is
  irreversible once indexed.

## Escalation

Stop and surface to the orchestrator/user instead of pushing through when: an
auth proxy 401s (don't hunt for raw credentials), a migration you did not
author looks wrong, a gate can only pass by weakening it, or the task requires
a kind of change the plan never named (new dependency, schema change, deleted
public API).
