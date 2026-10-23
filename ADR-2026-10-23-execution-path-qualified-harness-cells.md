---
status: Accepted
date: 2026-10-23
boundary: shared
split: inline-addenda
amends: ADR-2026-10-01-explicit-endpoint-protocol-and-responses-surface.md
---

# ADR-2026-10-23 — Execution-path qualified harness cells

**Status:** Accepted (2026-10-23, founder decision; the edits under "Affected documents and boundary" landed in the accepting commit). Architecture only: source, the qualified cell, conformance promotion, release and consumer adoption are pending.
**Date:** 2026-10-23
**Boundary:** shared; this public file is canonical. A private corpus carries only a thin canonical pointer.
**Authors:** architecture lane (coordinator draft)

## Context

[ADR-2026-10-01](ADR-2026-10-01-explicit-endpoint-protocol-and-responses-surface.md) D3 gives the qualified `capability-matrix/v2` view one cell per exact `(harness, endpoint company, host, protocol)` tuple. Nothing in a cell limits the session modes it holds for, so a published cell reads as valid on every launch path the harness has. For most cells that is true. For Codex on the gateway's Responses surface it is not:

- The headless Codex driver runs one shared app-server child per provider instance. The child's model-provider configuration is fixed when it starts, so it cannot follow a per-session endpoint. The adapter therefore pins the first gateway route and refuses a later session that names a different one, instead of serving that session the first session's route.
- The interactive Codex path starts one terminal process per session, with its own private model-provider configuration ([ADR-2026-10-01](ADR-2026-10-01-explicit-endpoint-protocol-and-responses-surface.md) D4). A per-session gateway binding is real there.

The gateway isolates sessions by per-session bearer. A Codex × gateway (Responses) cell valid on both paths would be false on the headless path. Without a qualifier the matrix has two bad options. It can omit the cell, which leaves the real interactive path unrepresentable. Or it can publish it, which grants headless use the runtime cannot deliver. [ADR-2026-08-08](ADR-2026-08-08-harness-authority-admission-plane-parked.md) D3 rules out the second: a grant its executor will refuse is worse than no grant.

## Decision

### D1 — The execution-path vocabulary

```go
// package matrix
type ExecutionPath string

const (
    ExecutionPathHeadless    ExecutionPath = "headless"
    ExecutionPathInteractive ExecutionPath = "interactive"
)

func ExecutionPathForMode(agent.PromptSessionMode) (ExecutionPath, error)
```

There are exactly two values. They are the launch-lane labels that the generated harness support page already publishes, and the mapping is the one that page already uses: `autonomous` → `headless`, `human_controlled` → `interactive`. `ExecutionPathForMode` is that mapping made strict: any other mode returns `ErrExecutionPathUnknownMode` instead of defaulting to headless. The support page renders through it, and its bytes do not change. The execution-cell `SessionMode` ([ADR-2026-08-05](ADR-2026-08-05-versioned-execution-cell-and-session-reference.md)) has the same two values and converts to the prompt session mode by the existing exact mapping.

There is no third value. In particular there is no `interview` value: interviews were retired as a first-class feature, and this decision does not restore one as a path. The qualifier reads only the normalized session mode. A legacy mode label that the legacy adapter still normalizes reaches it only as that session mode.

These are accepted target signatures, not a claim that they ship.

### D2 — A narrowing-only list on the qualified cell

```go
// package matrix
type ProtocolCell struct {
    HarnessEndpointCell
    ExecutionPaths []ExecutionPath `json:"executionPaths,omitempty"`
}

func (cell ProtocolCell) AllowsPath(ExecutionPath) bool
```

`ProtocolMatrixView` ([ADR-2026-10-01](ADR-2026-10-01-explicit-endpoint-protocol-and-responses-surface.md) D1) carries its qualified cells as `ProtocolCell`. An empty `ExecutionPaths` means both paths, and a non-empty list means only the listed paths. `AllowsPath` returns true for every path when the list is empty, and otherwise only for a listed path.

- **Not identity.** `ProtocolCellKey`, `QualifiedKey()`, `CellKey` and `Key()` are unchanged. The path list is not part of uniqueness or sort order. Two declarations of one qualified tuple are a duplicate and refuse ([ADR-2026-10-01](ADR-2026-10-01-explicit-endpoint-protocol-and-responses-surface.md) D3), even when their path lists differ. One tuple is never split into per-path cells.
- **Not a layout change.** `HarnessEndpointCell` keeps the layout that [ADR-2026-10-01](ADR-2026-10-01-explicit-endpoint-protocol-and-responses-surface.md) D1 preserves. The list is authored on the qualified cell's source declaration, in the same authoritative source that already carries the internal legacy-default and retired classification (D2 of that ADR).
- **Not a grant.** A listed path still needs every existing admission predicate: inventory, auth, placement, capabilities and evidence. The list is source-declared. No caller, workflow or control-plane value sets it or widens it. It is not a caller permission flag, a `liveEligible` field or a per-caller override.

### D3 — Validation

Generation refuses each of the following. The errors support `errors.Is`.

1. An unknown value (`ErrExecutionPathUnknown`).
2. A repeated value (`ErrExecutionPathDuplicate`). The generator never de-duplicates.
3. A list that names every value (`ErrExecutionPathNotNarrowing`). The empty list is the only unrestricted spelling, so each meaning has one byte form.
4. A non-empty list on a cell that is a retained legacy default, anchors a legacy alias (`LegacyProviderID` set) or is source-marked legacy-only (`ErrExecutionPathLegacyCell`).
5. A listed path whose session mode has no prompt profile or no tool/lifecycle profile in the harness manifest (`ErrExecutionPathUnsupportedMode`).

Decoding a v2 artifact applies rules 1 to 3 and refuses the whole artifact on any failure. It never ignores or drops a value it does not know.

### D4 — The v2 projection

The v2 view emits `executionPaths` only on a restricted cell, in vocabulary order (`headless`, `interactive`). Absence means both paths. Endpoint rows, defaults and aliases are unchanged.

The field belongs to the first published `capability-matrix/v2` ABI (schema `p2.0`). A matrix schema minor bump has so far meant an additive key that old readers may ignore. A narrowing key cannot be ignored that way: a reader that skips it would grant the unlisted path. So if a v2 artifact without this field is published before the source lands, the field ships under a new contract ABI, not a schema minor bump. Every v2 consumer enforces the list before live use. The paired parity and link checks that [ADR-2026-10-01](ADR-2026-10-01-explicit-endpoint-protocol-and-responses-surface.md) D3 requires include a path-restricted fixture, and the consumer must refuse it on the path it does not list.

### D5 — The v1 view excludes path-restricted cells, and keeps byte parity

The retained v1 projection, the legacy cell list and alias map, and the support page never carry a path-restricted cell. v1 has no field for the restriction. A restricted cell projected into v1 would read as valid on both paths, which is a silent widening. Any v1 consumer would then enable a variant it cannot qualify. The runner's local admission producer is one example: it reads the legacy cell list and has no path check. [ADR-2026-10-01](ADR-2026-10-01-explicit-endpoint-protocol-and-responses-surface.md) D3 forbids this: consumers without qualified selection cannot enable new variants.

Exclusion and byte parity do not conflict. D3 rule 4 allows a restriction only on a cell that v1 never carried: a new qualified variant that is not a retained default, an alias anchor or a legacy-only record. So the v1 projection stays byte-identical to its output before this decision, apart from the version metadata that D3 of that ADR already allows.

A legacy cell found false on one path is not restricted under this decision. It needs its own decision that corrects v1 as well, either through the retirement exception of [ADR-2026-10-01](ADR-2026-10-01-explicit-endpoint-protocol-and-responses-surface.md) D2 or through a new ADR.

### D6 — Admission, claim and the runner refuse an unlisted path

Every gate applies the same rule. It derives the path from the session mode on the intent or receipt with `ExecutionPathForMode`, selects the qualified cell by its exact key, and refuses when `AllowsPath` is false. Every gate reads the list from the same generated artifact that its executor reads ([ADR-2026-08-08](ADR-2026-08-08-harness-authority-admission-plane-parked.md) D3.2). Each refusal fails closed with an existing code, so no closed wire vocabulary changes ([ADR-2026-10-01](ADR-2026-10-01-explicit-endpoint-protocol-and-responses-surface.md) D2).

- **Admission** writes a denied receipt with `unsupported_session_mode` before enqueue. Its `denialDetail` names the qualified key, the requested path and the listed paths, and carries no credential value. No quota is charged. Admission does not substitute another protocol, host or cell. A named fallback alternative is checked by the same rule. In a ranked candidate set ([ADR-2026-08-12](ADR-2026-08-12-placement-composition-law-and-single-fallback-rule.md)), an unlisted path is a viability exclusion of that candidate. When no candidate survives, admission denies with this code.
- **Claim.** A claim-bound host re-runs the check against its own artifact. When the path is not listed, or the artifact has no such qualified cell, the host denies with `host_ineligible`. No credential is delivered.
- **Runner.** The runner re-checks the admitted or claimed cell before it delivers credentials, binds the gateway, mints a session token or starts a process. A mismatch returns `HarnessAdmissionError` with `unsupported_session_mode` and the canonical denied receipt. An artifact that fails D3 validation counts as having no cell, and the existing denial applies.

An unknown session mode keeps its existing `unsupported_session_mode` denial. A resume, a new incarnation and a child are each their own admission and are checked again. A session never changes path within one admission. The per-harness executor attestation's session modes still apply, and admission intersects them with the cell's list. The Codex adapter's route pin stays as an independent guard at spawn. It is not the admission control.

### D7 — The Codex × gateway (Responses) cell

The qualified cell `(codex, openai, gateway, openai-responses)` lists `interactive` only. It is a new variant, published only in the v2 view, experimental and `Smoked=false` until executed evidence warrants promotion. It is neither a legacy default nor an alias anchor. It also needs the harness drive surface and the endpoint's full-manifest row for its tuple. Both come through the qualified projection of [ADR-2026-10-01](ADR-2026-10-01-explicit-endpoint-protocol-and-responses-surface.md). The cell does not add either by implication, and neither changes the v1 harness or endpoint artifacts.

Evidence for a path-restricted cell counts only when it was produced on a listed path. A proof that records no path, such as today's three-field cell proof, cannot promote the cell.

## Consequences

- **Positive:** the interactive Codex gateway cell can be published and is true. Headless use is refused at three gates instead of running on another session's route. v1 consumers, legacy cells, aliases, the support page and retained artifacts do not change.
- **Negative:** v2 consumers implement one more refusal before live use, and the source declaration gains one internal attribute. This mechanism cannot repair a legacy cell that is false on one path.
- **Risk:** a v2 reader that ignores unknown keys would widen the grant. The ABI rule in D4 and the restricted link fixture make such a reader fail before live use.

## Alternatives considered

- **A field on `HarnessEndpointCell`.** Rejected. It breaks the layout and the unkeyed literals that [ADR-2026-10-01](ADR-2026-10-01-explicit-endpoint-protocol-and-responses-surface.md) D1 preserves, and it reaches v1 marshalling.
- **The path inside `ProtocolCellKey`.** Rejected. One tuple could then carry two cells with different metadata, which reopens the uniqueness and default rules of D2 of that ADR.
- **`SessionMode` values (`autonomous`, `human_controlled`) in the list,** as the per-harness executor attestation uses. Rejected. The founder decision fixes `headless` and `interactive`, which are already the published launch-lane labels. The mapping in D1 is the single bridge between the two vocabularies.
- **Omitting the cell.** Rejected. The real interactive path would stay unrepresentable.
- **Granting both paths and relying on the adapter's route pin.** Rejected. That is the false grant [ADR-2026-08-08](ADR-2026-08-08-harness-authority-admission-plane-parked.md) D3 forbids, and the pin refuses only at spawn, after admission.
- **A new denial code.** Rejected. It would change a closed wire vocabulary for cases that `unsupported_session_mode` and `host_ineligible` already name.

## Verification and adoption gates

1. **Generation.** Each refusal in D3 has a test. The v1 artifacts stay byte-identical to their pre-change goldens. v2 output is deterministic with and without a restricted cell, and paired v1/v2 parity holds.
2. **Decode.** A v2 artifact with an unknown value, a repeated value or a list naming every value is refused.
3. **Headless-refusal check.** An autonomous intent for the Codex gateway cell is denied `unsupported_session_mode` before enqueue, with no quota charged. A claim-bound host whose artifact does not list the path denies `host_ineligible`. A forced receipt-bearing headless work item is refused by the runner, with no credential delivered, no gateway route bound, no token minted and no child process started. Unrestricted cells admit unchanged on both paths. The test sits on the admission input ([ADR-2026-08-08](ADR-2026-08-08-harness-authority-admission-plane-parked.md) D3.3).
4. **Removal controls.** A compile-preserving removal of the admission check, and separately of the runner check, turns the matching test red at runtime. Exact restoration turns it green.
5. **Consumer link check.** Every v2 consumer passes the restricted fixture of D4 before live use.
6. **Acceptance bar: a live interactive canary.** On a real host, an interactive Codex session admitted on the cell completes a model turn with a tool call and its follow-up. The turn runs through the loopback gateway's Responses surface under a per-session bearer. It streams, its cost is attributed, and it cleans up exactly: the route is unbound, the token revoked and the process gone. The same build passes check 3. Fixture conformance is not the canary, and a passing canary is not by itself a release or a promotion.

## Affected documents and boundary

This accepting change amends [ADR-2026-10-01](ADR-2026-10-01-explicit-endpoint-protocol-and-responses-surface.md) D3 and D4 with forward annotations. It adds short references in [ADR-2026-06-06](ADR-2026-06-06-two-axis-provider-model.md) D3, `002-provider-base-contract.md`, `006-cross-provider-interactions.md` (Seam 13) and `011-local-daemon-fleet.md`, and the index and read order change with it. No synchronized region is edited, and the shared boundary contract is unchanged. A private corpus carries only a thin canonical pointer. Implementation and adoption remain pending.
