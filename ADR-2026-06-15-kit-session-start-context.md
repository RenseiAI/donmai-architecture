---
status: Accepted
boundary: shared
split: sibling-extensions
---

# ADR-2026-06-15-kit-session-start-context

**Status:** Accepted
**Date:** 2026-06-15
**Boundary:** shared (OSS canonical; platform-extension stub in rensei-architecture)
**Authors:** agent r1-w3-kit-bootstrap

## Context

Three gaps blocked reliable kit-provided context from reaching the session:

1. **Stale skill detection.** `afcli/agent_run.go` pre-computed `KitSkillSources`
   against the daemon's current working directory before clone. This means the
   detection ran against whatever code was checked out in the daemon's worktree at
   spawn time, not the code the agent would actually operate on. Skills whose
   `SKILL.md` files lived in paths that exist only after clone (e.g., inside a
   vendor sub-directory that is `.gitignore`d) were systematically missed.

2. **Prompt fragments not injected at runtime.** The kit manifest schema already
   defined `[provide.prompt_fragments]` (doc `005`), the TOML parser emitted
   `PromptFragments`/`When` into the parsed struct, and `005` specified
   workType-filtered concatenation. But no runtime code loaded or injected them —
   `ManifestView` had no `PromptFragments` field, the daemon's registry exposed no
   method for computing sources, and the runner had no step that built or appended
   the fragment block.

3. **Missing GIT identity in cloud sandboxes.** Cloud-provisioned runners execute
   inside a fresh sandbox with no global git config. `runner/backstop.go:runGit`
   spawned git without inheriting the process environment (no `cmd.Env` set, which
   on Go means an empty env), so backstop commits failed with `Author identity
   unknown`. The session env injected into the agent subprocess was also missing
   GIT identity vars, meaning agent-issued commits could also fail.

## Decision

**Post-clone re-detect.** The runner introduces two new option fields on
`runner.Options`: `KitSkillDetector` and `KitPromptFragmentDetector`, both of
type `func(repoRoot, targetOS string) ([]T, error)`. `afcli/agent_run.go` passes
`kitReg.SkillSourcesForRepo` and `kitReg.PromptFragmentSourcesForRepo` as the
detectors. In `runner/loop.go` step 2c, after the worktree is cloned and kit
toolchains provisioned, the runner calls both detectors against the real worktree
path (`wpath`), replacing any pre-computed sources. The legacy `KitSkillSources`
slice field is retained for backward compatibility but is overridden when
`KitSkillDetector` is set.

**Prompt fragment runtime injection.** `internal/kit/compose.ManifestView` gains
`PromptFragments []PromptFragmentEntry`. The daemon's `manifestToView` projects
`[provide.prompt_fragments]` entries into this field. `KitRegistry` gains
`PromptFragmentSourcesForRepo`, which mirrors `SkillSourcesForRepo`. A new
`LoadPromptFragments(sources []KitPromptFragmentSource, workType string) (LoadedPromptFragments, error)`
function in `internal/kit/skill_loader.go` reads each fragment's declared file,
skips entries whose `when` field does not intersect `workType` (empty `when` =
matches all), and concatenates the result into `LoadedPromptFragments.SystemAppend`.
In `runner/loop.go` step 5a, after the skill block is appended, the fragment
block is appended in `SystemAppend` form.

Per-run reset: `r.promptBuilder.SkillAppend` is set to `""` at the top of each
run so long-lived runner instances do not bleed skills or fragments from one
session into the next.

**GIT identity env.** `runner/loop.go:buildSessionEnv` now stamps four vars:

```
GIT_AUTHOR_NAME    = "Donmai Agent (<issueIdentifier>)"  // or "Donmai Agent" if none
GIT_AUTHOR_EMAIL   = "agent+<sessionId>@donmai.dev"
GIT_COMMITTER_NAME = same as AUTHOR_NAME
GIT_COMMITTER_EMAIL = same as AUTHOR_EMAIL
```

`runner/backstop.go:runGit` is updated to set `cmd.Env = os.Environ()` so the
subprocess inherits the session's GIT identity from the process environment.

## Consequences

### Positive

- Kit skills from paths that only exist post-clone (sub-modules, generated files,
  etc.) are now detected correctly.
- Kit-declared prompt fragments are injected into the system prompt with
  workType filtering, completing the promise in doc `005`.
- Backstop commits succeed in cloud sandboxes with no git global config.
- Agent-issued commits carry a consistent, session-scoped identity.
- The session's `SkillAppend` is reset per-run, preventing inter-session bleed.

### Negative

- Post-clone detection adds a second pass over the repository's kit manifests
  after clone. For large repositories with many nested manifests this is a
  measurable latency hit (typically < 100 ms, bounded by manifest count not
  file count).

### Risks

- If `KitSkillDetector` or `KitPromptFragmentDetector` errors, the runner falls
  back to the pre-clone skill sources (for skills) or no fragments (for
  fragments) with a `WARN`-level log. This is intentional: a detection failure
  should degrade gracefully rather than abort the session.

## Alternatives considered

**Pre-clone detection against a shallow fetch.** Would preserve timing but
requires a git fetch before the full clone, adding more latency than the
second-pass approach and complicating the clone lifecycle.

**Inject GIT identity via a `.gitconfig` file in the worktree.** More portable
across git versions but requires filesystem mutation before the agent starts;
env vars are sufficient and avoid the file creation.

## Affected documents

- `005-kit-manifest-spec.md` — `[provide.prompt_fragments]` runtime injection
  is now implemented; the spec's description of workType filtering is now
  enforced in `LoadPromptFragments`.

No synchronized `BOUNDARY-SYNC` sections are affected by this ADR.

## Affected work items

R1/W3 (kit/session-start context bootstrapping wave).

## Implementation notes

- donmai: `runner/loop.go` (steps 2c + 5a), `runner/runner.go` (Options fields +
  Runner struct), `runner/backstop.go` (runGit env), `afcli/agent_run.go`
  (detector wiring), `daemon/kit_detect.go` (manifestToView), `daemon/kit_skill_sources.go`
  (PromptFragmentSourcesForRepo), `internal/kit/compose.go` (ManifestView),
  `internal/kit/skill_loader.go` (LoadPromptFragments).
- platform (platform-extension — see rensei-architecture mirror stub):
  `src/app/api/daemon/sessions/[id]/route.ts` (memory block injection for
  cloud runners, gated on `resolveProjectMemoryConfig().enabled`).
