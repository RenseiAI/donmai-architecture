---
status: Accepted
date: 2026-09-16
boundary: shared
split: sibling-extensions
---

# ADR-2026-09-16 — Refreshable protected HTTP MCP authorization

**Status:** Accepted 2026-09-17 UTC by the root coordinator under delegated
architecture authority after paired corpus and independent final review.
Implementation may proceed through D8's staged gates. Compatibility claims,
release, deployment, activation, and live acceptance remain separate and
pending.

## Context

A protected HTTP MCP server currently receives an effective authorization
header during pre-spawn adaptation. That is enough for a short-lived process,
but it freezes the launch bearer into the process configuration. A long-running
native client cannot continue after the bearer expires even when the session
authority has correctly rotated the content of its already-managed bearer file.

The existing architecture already separates the common config-file binding from
the protected-MCP requirement, requires immutable evidence before credentials or
spawn, and preserves exact adapter-version realizations. The missing contract is
a closed way to prove that the one protected server reads its current bearer
from the same acknowledged file while keeping the launch receipt immutable.

This is a contract change rather than a clarification. It adds a v2 protected
configuration requirement and materialization, joins them to an existing common
config materialization, and introduces a trusted runtime-only helper seam. V1
bytes and semantics remain unchanged.

## Decision

### D1 — V2 keeps the v1 projection and adds one closed authorization source

`execution-preflight-protected-mcp-config/v2` retains the v1 fields and their
canonical meaning:

- `requirementId`;
- `authorityBindingDigest`;
- `operationalPayloadDigest`;
- `serverName`;
- `transport`, exactly `http`;
- `endpointDigest`; and
- sorted, unique `headers`, including the initial effective `Authorization`
  `valueDigest` without any bearer bytes.

The v2 requirement adds exactly one `authorizationSource`:

```text
authorizationSource = {
  kind: "session_mcp_bearer_file",
  configRequirementId: <exact common preflight-config requirement ID>,
  targetEnv: "MCP_GATEWAY_TOKEN_FILE",
  mode: "0600"
}
```

The v2 materialization echoes those four fields and adds, inside
`authorizationSource`:

```text
configReferenceDigest: <digest of the joined common config materialization>
fileReferenceDigest:   <digest of the matching bearer-file binding reference>
helperCommandDigest:   <SHA-256 of the exact trusted helper command UTF-8 bytes>
```

The protected materialization's outer `configReferenceDigest` continues to
cover its whole canonical projection after clearing only that outer self-field.
The nested digest does not change or replace that rule. Existing canonical JSON
and digest primitives are the sole codec; v2 does not introduce a second
serialization.

V1 rejects every v2-only field. V2 rejects missing or unknown fields, a wrong
contract version, duplicate headers, an unexpected source kind, target or mode,
and any authority, payload, endpoint, header or reference disagreement.

### D2 — Materialization joins actual common evidence with exact cardinality

A nested digest is not proof by itself. The materializer resolves exactly one
already-produced common config materialization named by
`authorizationSource.configRequirementId` and exactly one matching
session-bearer-file binding inside it. It verifies the common requirement
identity and full digest, source kind, target, private mode, initial bearer
content digest, and file-reference digest.

The helper's normalized launch bearer and effective authorization header must
match both the existing common file materialization and the frozen launch
source used to produce the protected header evidence. A valid file reference
with different normalized bearer/header evidence is a disagreement and denies;
no digest or reference match can substitute for this equality.

The daemon applies common config before protected MCP. It therefore retains and
passes the actual common materialization result into the protected
materializer. It never synthesizes a matching common record to make validation
succeed. Zero joins, multiple joins, the wrong binding kind, target or mode, a
changed reference, or a digest disagreement denies before credential delivery
or spawn.

The initial bearer-content digest in the common materialization and the initial
effective authorization-header digest in the protected materialization remain
launch evidence. Rotation changes only the mutable file content behind the
immutable file reference. It does not rewrite the plan, either materialization,
the applied receipt, or the acknowledgement.

### D3 — The executable helper is trusted runtime state, never authored wire

The runner installs a private, runtime-only, nonserialized helper-command slot
on its internal MCP server configuration. No JSON, YAML, queue, agent-card,
session-detail, public config builder, or ordinary caller-authored MCP entry can
populate that slot. Public decoding of apparent helper field names must leave
the slot empty.

Only the selected native adapter may read the slot. The runner applies it only
to the sole protected server selected by the exact acknowledged v2 realization,
after repeating the materialization join and helper-command digest checks. A
helper on an ordinary or caller-appended server, on a second server, on an
unselected session, or with mismatched evidence denies before spawn. A
conflicting literal, environment-derived, bearer-token, OAuth, saved operator,
or other ambient `Authorization` source on this rail also denies; native
precedence must not silently freeze the credential or fall back to an operator
credential. The protected server runs in the existing isolated native-client
credential context with the acknowledged file/helper source as its only
authorization source.

The private slot is cleared before recipe, public-config, or operational-payload
normalization. Ordinary authored MCP, other adapters, and public harness
behavior remain unchanged. This seam grants no general local-command execution
surface.

### D4 — The helper is an in-box, pure local file reader

The helper is a hidden child of the existing MCP command group and enters every
embedding binary through the existing root command registration. It accepts one
explicit absolute managed token-file path because the selected native client
clears custom helper environment variables. The path must resolve to a regular,
readable file; another file kind or a relative/unmanaged path refuses.

The daemon and runner use one canonical executable-path and command builder.
The exact command contains paths only, with operating-system-correct quoting;
it contains no bearer or fallback bytes. The helper reads at most 64 KiB of file
bytes, trims outer whitespace, and rejects an empty result. It rejects any
interior whitespace, ASCII control byte, DEL, or non-ASCII byte. The remaining
printable-ASCII token is opaque: the helper performs no JWT or other token
parsing and passes it through the existing bearer-to-header normalization before
JSON-encoding only the required `Authorization` header. Token content is never
interpolated into a shell command. The helper does not initialize
authentication, load general application configuration, contact a network
service, or depend on ambient credentials.

Missing, non-regular, blank, unreadable, over-64-KiB, or grammar-invalid input
exits nonzero without emitting a credential or disclosing it through
diagnostics. There is no credential fallback. The runner never overwrites a
daemon-owned file. Standalone execution retains its existing runner-owned
bootstrap-file fallback and must return the actual effective file path plus its
cleanup obligation to the same trusted builder; that bootstrap ownership rule
does not permit a helper-read fallback.

### D5 — Adapter and realization versions move without relabelling history

Changing the native integration from a fixed launch header to a refreshable
helper changes the adapter version. The selected interactive adapter/profile
moves from its existing tool-lifecycle v1 identity to v2. The family ABI and
pinned upstream native-client version remain unchanged.

Every capability realization at the new adapter version is re-registered with
truthful producer, fixture, observation and evidence digests, or explicitly
inherits only where the existing realization contract permits and its fixture
runs at the inheriting version. No v1 receipt is relabelled as v2, and no
released provenance is fabricated for development source. Existing v1
in-flight receipts remain readable under their old semantics; they cannot
authorize a v2 spawn or receive an in-place upgrade.

### D6 — Spawn verifies the immutable acknowledgement and current file binding

Before attaching the runtime-only helper, spawn requires the exact selected v2
adapter realization, exactly one matching common file materialization, exactly
one matching protected v2 materialization, and the corresponding retained host
receipt and acknowledgement. It recomputes the canonical executable path and
helper command and compares every source/reference digest and initial authority
binding, including the normalized launch bearer/header equality from D2.

A changed signing identity, target, session, handler inventory, realization,
receipt, file reference, or helper command denies. A successfully rotated file
can authorize a fresh request while the original launch materialization and
acknowledgement bytes remain byte-identical. Historical acknowledgement
reproduction never authorizes the old bearer as a current credential.

This decision does not add a refresh API, proxy, policy rule, permission UI,
database schema, or public helper field. The existing common file binding is the
authority seam; v2 proves and consumes it.

### D7 — Required native proof uses one process and one request retry

The pinned, model-free native integration control keeps one operating-system
process and one native thread alive. It performs an initial direct MCP tool
call, expires the launch bearer, atomically replaces the managed file, observes
the old bearer refused with HTTP 401, refreshes through the production helper,
and succeeds on the same call's one supported same-origin retry. It starts no
model turn.

The control asserts request order, unchanged process and thread identities,
and byte-identical production-generated plan, materialization and
acknowledgement evidence before and after rotation. It also proves, without
skips:

- missing and blank files produce no authenticated request;
- an unchanged stale file produces one rejected request and no retry request;
- explicit static or bearer/OAuth-shaped authorization takes native precedence,
  explaining why the protected production rail rejects the conflict;
- the production protected rail starts in its existing isolated client
  credential context, loads no saved operator OAuth or ambient credential, and
  refuses an explicitly configured alternative authorization source before
  spawn rather than falling back to it;
- the actual isolated credential store is populated with a syntactically valid
  saved-OAuth sentinel before the production protected configuration is built;
  the conflict is refused before native spawn, and the sentinel appears in no
  helper output, request, receipt, or diagnostic. An empty temporary home is not
  this proof;
- `insufficient_scope` HTTP 403 does not refresh;
- wrong-origin and non-authentication failures do not refresh; and
- the helper runs through the real embedded command root in a minimal local
  environment with no auth, general config, or network dependency.

The literal control restores the old static projection and requires renewal to
fail after the 401, then restores the helper projection and requires success.
Removing the helper/file-reference binding must make the codec and
acknowledgement controls fail; restoring it must make them pass. A skipped
native control is not passing evidence.

If the pinned fixture cannot prove that credential-context isolation and
explicit-source refusal against the actual native consumer, the positive v2
path remains inactive. Source inspection or a config readback is not equivalent
proof.

### D8 — Rollout remains staged and coherent

The first signed checkpoint freezes the actual exported v2 protocol types and
byte-identical golden vectors before downstream consumers implement against
field names. The helper and materializer may then stage behind the new exact
adapter realization while every production selector still refuses incomplete
consumer sets.

A coherent rollout requires the OSS producer, the embedding client, and the
acknowledgement consumer to agree on the same v2 bytes and exact adapter
realization. Development integration uses truthful source provenance. Public
version tags, released artifacts, activation, and live acceptance remain
separate gates. A fresh short-lived call proves initial authoring only; it is not
renewal acceptance.

## Consequences

The protected server can use a rotated session bearer without restarting its
native process, while the original receipt stays a truthful immutable statement
of launch. The cost is a new closed wire revision, a strict common/protected
join, a versioned adapter realization, and a small trusted local executable
surface that requires dedicated negative controls.

The design deliberately preserves v1, ordinary authored MCP entries, other
adapters, the public MCP builder, the parked admission plane, and standalone
operation. It also makes a partial rollout visibly unavailable instead of
silently reverting to a fixed credential.

## Alternatives considered

- **Rewrite the process configuration or acknowledgement after rotation.**
  Rejected because it destroys immutable launch evidence and confuses current
  credentials with historical proof.
- **Expose a public helper-command field.** Rejected because untrusted authored
  MCP configuration would gain local-command execution authority.
- **Embed the initial bearer as a fallback in the helper command.** Rejected
  because a missing or unreadable file would silently revive an expired secret.
- **Read the path from a custom environment variable.** Rejected because the
  pinned native client intentionally clears that environment.
- **Add a refresh service or authorization proxy.** Rejected because the
  daemon-managed file already carries the current credential and the native
  client already supports the bounded refresh retry.
- **Change v1 in place.** Rejected because old decoders, receipts and in-flight
  sessions must retain exact semantics.

## Affected documents

- `002-provider-base-contract.md` — harness adaptation now points to the
  accepted closed v2 source/join and runtime-only helper boundary.
- `011-local-daemon-fleet.md` — controller-registered preflight notes immutable
  launch acknowledgement across file rotation.
- `013-orchestrator-and-governor.md` — AgentRuntime dispatch notes exact v2
  realization and pre-spawn join verification.
- `ADR-2026-08-06-harness-adaptation-plan-and-receipt.md` — dated
  compatibility reference; no v1 vocabulary or outcome is changed.
- `ADR-2026-08-08-harness-as-versioned-deliverable.md` and
  `ADR-2026-08-13-capability-realization-registry-and-viability-of-absence.md`
  — cross-referenced, not amended; their adapter-version and evidence rules
  apply unchanged.
- `ADR-2026-08-08-harness-authority-admission-plane-parked.md` —
  cross-referenced, not amended; no parked authority store is revived.

The synchronized boundary section in `001-layered-execution-model.md` is not
changed.

## Protocol checkpoint and implementation mechanics

The wire names and closed helper input grammar in this ADR are normative.
Exported Go type, constructor and accessor names remain implementation mechanics
rather than wire contract. The producer's early signed protocol checkpoint
freezes the actual exported names and byte-identical golden vectors before sibling
consumers start, so those consumers never implement against guesses. This adds
no public serialized command field and does not change v1 semantics.
