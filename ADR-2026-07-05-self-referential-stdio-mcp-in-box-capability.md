---
status: Accepted
boundary: shared
split: sibling-extensions
date: 2026-07-05
---

# ADR-2026-07-05 — Self-referential stdio MCP server as the in-box capability delivery pattern

**Status:** Accepted (shipped this wave)
**Date:** 2026-07-05
**Boundary:** shared (canonical here; the platform delta — the capability resolver, dispatch stamping, and the version-gating operational rule — lands as the sibling extension / mirrored stub in `rensei-architecture` together with the platform-activation lane, W3)
**Authors:** code-intel capability run, W2 MCP-server wave (`runs/2026-07-04-code-intel-capability/`, decisions D1/D2)

**Summary:** Capabilities that must touch the **sandbox working tree** are delivered as **compiled-in stdio MCP servers**: a hidden `donmai mcp <capability>` subcommand inside the same binary that is already the per-session runtime on every execution target, spawned by the in-box runner with `Command = os.Executable()` and an **explicit `--root <absolute worktree path>`** (never cwd inheritance — no target guarantees the runner process cwd). The platform activates a capability by stamping a **typed block on QueuedWork** (`codeIntel` is the first instance); the **runner authors the MCP server entry** itself. Code intelligence ships as the archetype: server name `af-code-intelligence`, six `af_code_*` tools backed by the Wave-1 warm-cache engine. This is **the** pattern — `af_linear` and every future in-box capability reuse it (it discharges the long-standing `runner/loop.go` F.5 TODO).

## Context

- **Runner-in-box means the `donmai` binary is present on every execution target.** The per-session runtime IS the binary: local targets spawn `os.Executable() + [agent run]` from the daemon; docker/kubernetes/modal/daytona bake the binary into the `ghcr.io/renseiai/donmai-worker` image with `donmai agent run` as entrypoint; e2b bakes it into the sandbox template. (Target matrix: `runs/2026-07-04-code-intel-capability/discovery/03-cross-sandbox-runtime.md` §4.) Anything compiled into that binary ships to every target with **zero extra artifacts** — and the founder-locked all-Go constraint exists precisely because cloud boxes boot bare: a Node-based tool server would need node+packages installed in every box.
- **Some capabilities must run where the checkout is.** The runner clones the session repo into an in-box worktree. Code intelligence — the archetype — indexes and searches that working tree; it **cannot** be served from the platform HTTP MCP gate the way memory/linear/graph tools are (those query platform-side stores; the platform has no checkout). This is the load-bearing constraint that forces an in-box delivery model for this class of capability.
- **Every MCP-capable provider already consumes stdio MCP servers uniformly** — CLI providers via the runner's `--mcp-config` tmpfile, the native Go gemini provider via its in-process `runtime/mcp` client bridge. One stdio server serves them all with no per-provider special-casing.
- **The runner cwd is unreliable on every target** (Wave-0 checkout trace, `runs/2026-07-04-code-intel-capability/state.json` `w0Findings.checkoutTrace`): the worker image has no `WORKDIR` (cwd = `/`), the daemon child inherits whatever the daemon had, and e2b's cwd is host-controlled. `agent.MCPServerConfig` has no `Cwd` field and `runtime/mcp`'s `dialStdio` never sets `cmd.Dir`. Any in-box tool server that inferred its root from cwd would silently index the wrong tree on some targets.
- **The seam was pre-named.** `runner/loop.go`'s `defaultMCPServers` carried the F.5 TODO — "F.5 will layer additional entries (af_linear / af_code stdio plugins) once the daemon's installed-plugin set is wired through" — and `agent/types.go` (`Spec.MCPToolNames` doc, :352) pre-typed the fully-qualified example `mcp__af-code-intelligence__af_code_get_repo_map`. The engine itself shipped in Wave 1 (`ADR-2026-07-04-code-intel-index-schema-v2-go-authoritative.md`): a warm in-process `NativeRunner`, `IndexSchemaVersion`-gated persisted index, `Refresh()`/`Invalidate()`, git-root discovery.

## Decision

**In-box capabilities are delivered as self-referential stdio MCP servers compiled into the `donmai` binary, spawned by the runner via `os.Executable()` with an explicit `--root`, and activated by typed QueuedWork blocks stamped by the platform.** Code intelligence is the first instance; the shape below is the reusable pattern.

1. **The server is a hidden subcommand of the same binary: `donmai mcp code-intel`** (`afcli/mcp.go`, under the hidden `donmai mcp` group). It speaks newline-delimited JSON-RPC 2.0 over stdin/stdout (initialize, tools/list, tools/call, ping — `runtime/mcp/server`, a net-new Go MCP *server* mirroring the wire surface of the in-repo `runtime/mcp` client, no external MCP SDK dependency). stdout carries **only** JSON-RPC; warm-up and lifecycle logs go to stderr. The process holds **one** warm `codeintel.NativeRunner` (the Wave-1 warm cache) built once at startup and shared across all `tools/call` requests; it shuts down gracefully on stdin EOF.
2. **The root is always explicit — `--root <ABSOLUTE path>` is required; cwd inheritance is forbidden.** The Wave-0 finding stands as a rule for every future in-box server: **no target guarantees the runner process cwd**, so the runner passes the provisioned worktree path explicitly on every invocation (mirroring the kit-execer explicit-dir pattern). The server fails loud at startup on a non-absolute, missing, or non-directory root. Two more flags complete the frozen contract: `--repo-path` (optional subtree, RELATIVE to root, same no-absolute/no-escape validation semantics as the `donmai code` CLI group) and `--tools` (optional comma-separated subset of the six tool names; empty = all; an unknown name is a startup error). A tool argument that names a file (check-duplicate's content file) is likewise confined to the root — the server never reads outside `--root`.
3. **The platform signals activation via a typed QueuedWork block; nil = capability off.** `prompt.QueuedWork` gains `CodeIntel *CodeIntelWork` (JSON field `codeIntel`, omitempty): `{ repo string, ref?, repoPath?, tools? []string }`. `repo`/`ref` are carried for audit/correlation (the runner indexes the provisioned worktree regardless); `repoPath` and `tools` are forwarded to the server flags. An absent block is a strict no-op — byte-identical MCP defaults, spec, and system prompt to a pre-code-intel session. Old runners ignore the unknown JSON field; old platforms never emit it (tested in both directions in `prompt/queued_work_test.go`).
4. **The runner — not the platform — authors the MCP server entry.** When the block is present, `defaultMCPServers` (`runner/loop.go`, the F.5 seam, the single place the runner extends MCP defaults) appends
   `{ Name: "af-code-intelligence", Type: stdio, Command: os.Executable(), Args: ["mcp","code-intel","--root",<wpath>] (+ --repo-path/--tools when set) }`
   after the platform HTTP gate, built **after** worktree Provision so the path exists. This ownership split defuses the `mergeMCPServers` merge-collision hazard: runner-authored entries live in the defaults, and defaults win on name collision, so a platform-sent card entry that also names `af-code-intelligence` can never shadow the in-box server. Because the entry has no platform coupling, it is emitted even in standalone mode (no platform gate). `os.Executable()` keeps the entry portable across every target with no coupling to the binary's install name or path (fallback: the brand CLI name on PATH).
5. **Frozen names.** Server name `af-code-intelligence`; six tools `af_code_get_repo_map`, `af_code_search_symbols`, `af_code_search_code`, `af_code_check_duplicate`, `af_code_find_type_usages`, `af_code_validate_cross_deps`, backed 1:1 by `afclient/codeintel`. The fully-qualified prefix `mcp__af-code-intelligence__af_code_*` matches the example pre-typed in `agent/types.go` and the codex/gemini event mapping. Both build lanes (server, runner wiring) compile against the same literals; the runner intersects any requested `tools` subset with the canonical six so a typo can never allow-list a non-existent tool.
6. **Allow-listing and prompt guidance are capability-gated on the provider.** When the block is present and the resolved provider has `SupportsToolPlugins && AcceptsMcpServerSpec`, spec translation populates `Spec.MCPToolNames` with the FQ names (filtered to the block's subset) so autonomous agents call the tools without a permission prompt, and the composed system prompt gains a compact usage partial naming the FQ tools with one-line when-to-use guidance. Providers that ignore MCP specs instead get Bash-CLI fallback guidance (`donmai code <subcommand>` — the engine is in-box on every target either way), and never a dead MCP allow-list.

## This is THE pattern for in-box capabilities

The F.5 TODO always named two plugins: `af_linear / af_code`. This ADR ships `af_code` and fixes the recipe `af_linear` and every future in-box capability follow:

1. a **typed, omitempty QueuedWork block** the platform stamps (nil = off, zero behavior change, unknown-field-tolerant in both directions);
2. a **hidden `donmai mcp <capability>` subcommand** hosting a stdio MCP server compiled into the binary, taking its operating context via **explicit flags** (`--root` first among them), never cwd;
3. a **runner-authored `agent.MCPServerConfig` entry** in `defaultMCPServers` using `os.Executable()`, appended after the platform gate — the platform signals *that* a capability is on and with what scope; the runner owns *how* the server is launched.

`defaultMCPServers` remains the single extension point. A capability that does not need the working tree (linear proxying, memory) may still prefer the platform HTTP gate; this pattern is mandatory only when the capability must run where the checkout is — but its activation contract (typed block, runner-authored entry) is the house style for all in-box servers regardless.

## Consequences

### Positive

- **Zero extra delivery artifacts.** The server ships inside the binary that is already on every runner-bearing target (local / docker / kubernetes / modal / daytona / e2b); no sidecar image, no on-demand fetch, no node runtime in bare boxes.
- **One server, every provider.** CLI providers consume it via the existing `--mcp-config` tmpfile; native gemini via the in-process MCP bridge. No per-provider special-casing.
- **Additive and inert by default.** A session without the block is byte-identical to before; standalone (platform-less) runs get the capability too when a block is present.
- **The merge-collision class is closed by construction** — runner-authored entries are defaults and defaults win, so the platform cannot accidentally (or deliberately) shadow an in-box server with a card entry of the same name.

### Negative

- **Version coupling between the platform and the deployed runner fleet.** The typed block only works when the *reading* runner understands it. The forward direction is safe (old runners ignore the unknown `codeIntel` field and simply run without the capability — degraded, not broken), but that makes stamping before rollout a silent no-op: **the platform must not stamp a capability block until the runner version that reads it is deployed to the target pools.** This is the operational rule the W3 platform lane inherits; the platform-corpus sibling extension carries it.
- **One artifact per target must carry the right binary version.** The worker image and the e2b template bake the binary; every donmai release that changes an in-box server (or adds one) requires an image/template rebuild+push per target before the platform may activate it. Local targets pick the new binary up on upgrade.
- **A hand-rolled MCP server surface.** donmai deliberately takes no Go MCP SDK dependency; the JSON-RPC framing is in-repo (`runtime/mcp/server`), kept honest by conformance tests that drive it with the in-repo `runtime/mcp` *client* as oracle. Protocol-revision drift across agent CLIs is ours to track.

### Risks

- **Provider matrix asymmetry.** MCP-native today: **claude, codex, amp, gemini** (`AcceptsMcpServerSpec: true` — amp reuses the clijsonl `--mcp-config` path; gemini bridges in-process). **ollama, opencode, agycli** ignore MCP server specs and fall back to CLI guidance in the prompt (`donmai code <subcommand>` via Bash) — functional but unstructured: no typed tool results, no allow-list, quality depends on the model following prompt guidance. If a fallback provider family becomes a primary lane, its MCP support (opencode's own plugin system, agycli's deferred `AcceptsMcpServerSpec`) should be revisited rather than leaning harder on prompt guidance.
- **Warm-up cost at session start.** The server builds the index at startup (~5–10s first-run on a large repo, per Wave-1; incremental thereafter). Warm-up runs concurrently with serving — `tools/call` blocks on it rather than racing an unbuilt index — but a very early first tool call pays the wait.
- **Per-target binary arch** (e2b template is linux/amd64; worker image per its build; local is host arch) is already handled by the existing cross-compiles, but a new in-box server increases the blast radius of shipping a wrong-arch artifact: the whole capability, not just one subcommand, is absent.

## Alternatives considered

(Per `runs/2026-07-04-code-intel-capability/01-architecture.md` D1 and `discovery/03-cross-sandbox-runtime.md` §5a.)

- **Platform HTTP MCP gate (the memory/linear/graph route).** Rejected: the platform has no checkout. Code-intel is the one capability class that must index the sandbox working tree; an HTTP tool served from the platform physically cannot.
- **Sidecar image / separate tool binary.** Rejected: a second artifact per target with its own version-skew axis, for a capability already compiled into the binary that is present everywhere.
- **On-demand fetch of a tool binary at session start.** Rejected: cold-start cost and egress assumptions in bare boxes; another supply-chain surface.
- **Node stdio MCP server (the legacy `@donmai/code-intelligence` shape).** Rejected: requires node+packages in every bare cloud box — exactly the dependency the all-Go constraint removes.
- **Bash-CLI prompt guidance only (no MCP server).** Rejected as the primary surface: no typed results, no allow-listing, no tool discovery. Retained as the deliberate **fallback** for providers without MCP support.
- **Platform-authored MCP entry (platform sends the full server config in the card).** Rejected: the platform would have to know the in-box binary path and worktree path per target, and a platform-sent entry colliding with runner defaults is exactly the `mergeMCPServers` hazard the ownership split defuses. The platform signals scope; the runner owns launch.

## Affected documents

- `007-intelligence-services.md` — "Contract: what kits and agents see" is amended by annotation: the shipped Go delivery surface is the in-box stdio MCP server (`af-code-intelligence`, `af_code_*` FQ names) per this ADR; the legacy in-process `donmai_code_*` tool names describe the deprecated TS package. Updated in the same commit.
- `ADR-2026-07-04-code-intel-index-schema-v2-go-authoritative.md` — not edited (accepted ADRs are immutable); this ADR is the W2 consumer of its warm-cache/concurrency contract that it already anticipates.
- `rensei-architecture` (platform corpus) — owes the `Mirrored` stub plus the sibling platform extension (capability resolver, dispatch stamping, the must-not-stamp-before-rollout rule). Deliberately deferred to land **with** the W3 platform-activation lane, since none of the platform side has shipped yet.

## Affected work items

- `runs/2026-07-04-code-intel-capability/` — W2 (this ADR documents its shipped state); W3 (platform activation: resolver + dispatch stamp emit the `codeIntel` block and inherit the version-gating rule); W4 (cross-target delivery: image/template rebuilds that make activation safe per target); the future `af_linear` in-box server (pattern reuse, F.5's second named plugin).

## Implementation notes

Shipped in the `donmai` repo (branch `feat/codeintel-mcp-server`, on top of the Wave-1 engine):

- `prompt/queued_work.go` — `CodeIntelWork` typed block (`codeIntel`), round-trip/omitempty/unknown-field tests.
- `runner/codeintel.go` — frozen names, entry builder (`codeIntelMCPEntry`), FQ allow-list helper, prompt usage partial (MCP vs CLI-fallback flavors).
- `runner/loop.go` — `defaultMCPServers(qw, wpath)` F.5 seam: worktree path threaded in; entry appended after the platform gate; defaults-win collision proof in tests.
- `runner/spec_translation.go` — `Spec.MCPToolNames` populated behind `SupportsToolPlugins && AcceptsMcpServerSpec`.
- `runtime/mcp/server/` — net-new stdio JSON-RPC server (`names.go`, `config.go` flag validation, `server.go` codec + warm-up, `tools.go` six tools over one warm `NativeRunner`), conformance-tested against the in-repo `runtime/mcp` client.
- `afcli/mcp.go` — hidden `donmai mcp code-intel` subcommand (`--root` required/absolute, `--repo-path`, `--tools`), stderr-only logging.

Verified via `GOWORK=off go build ./... && go test ./...` plus `CGO_ENABLED=0` builds; cross-lane JSON→Spec composition proven in `runner/codeintel_integration_test.go`.
