---
status: Accepted
date: 2026-07-10
boundary: OSS-only
---

# ADR-2026-07-10-deterministic-kit-packages-and-command-composition

**Status:** Accepted
**Date:** 2026-07-10
**Boundary:** OSS-only
**Authors:** Architecture execution lane
**Supersedes:** `005-kit-manifest-spec.md` last-applied-wins command rule,
manifest-as-signature-target wording, and scan-order identity resolution

## Context

A kit is a directory-backed execution contribution, not a standalone TOML
record. The manifest can reference detection executables, hooks, prompt
fragments, skills and their resources, agent templates, MCP executables, and
other files. Those files can execute or enter an agent prompt, so integrity of
only the manifest is not integrity of the installed kit.

The current catalog and consumer expose four contract gaps:

1. The catalog signing workflow signs the raw `kit.toml` bytes. A payload file
   can change while the manifest, manifest version, and signature bundle remain
   unchanged.
2. The installer verifies the fetched manifest, then persists the manifest and
   its signature bundle separately. Referenced assets are not installed, and a
   bundle-copy failure can leave the manifest visible. This is not an atomic
   package installation.
3. The reference composition rule says generic `build`, `test`, and `validate`
   commands are last-applied-wins. Application order is deterministic, but it
   is not authority: two kits can silently replace one another's executable
   command.
4. Registry discovery and release packaging do not bind a consumer to one
   immutable catalog snapshot. Selecting the first manifest found or allowing
   a later scan path to replace the same identity makes identical requests
   depend on mutable source state.

These are blockers for expanding the official catalog. Adding more kits before
the package and composition contracts are closed increases executable supply
without a complete integrity boundary.

This ADR defines the target contract only. It does **not** claim that the
catalog publisher, installer, composer, or binary release pipeline implements
it today. Until conformance evidence exists, the current trust state remains
manifest-only and catalog expansion remains held.

## Decision

A kit is distributed and trusted as a content-addressed **kit package** whose
signed descriptor binds every payload path, digest, size, and portable mode.
Consumers verify the complete package in a private staging area, preflight its
composition, and atomically activate an immutable package plus a deterministic
catalog lock. Commands retain owner-qualified identities; a generic alias has
one explicit owner or composition fails before any kit-controlled code runs.

The following sections are normative.

### 1. Package identity and signed closure

Each package has one root directory and contains:

- `kit.toml`, the kit manifest;
- zero or more payload files;
- `kit.package.json`, the package descriptor; and
- `kit.package.json.sigstore`, or an equivalent detached signature envelope
  selected by the trust implementation.

`kit.package.json` uses the `donmai.dev/kit-package/v1` schema and is serialized
as UTF-8 RFC 8785 canonical JSON. It contains at least:

```json
{
  "schema": "donmai.dev/kit-package/v1",
  "kit": { "id": "default/go", "version": "1.0.0" },
  "publisher": "<stable signer identity>",
  "manifest": "kit.toml",
  "entries": [
    {
      "path": "kit.toml",
      "sha256": "<lowercase hex>",
      "size": 1234,
      "mode": "0644"
    },
    {
      "path": "bin/setup.sh",
      "sha256": "<lowercase hex>",
      "size": 567,
      "mode": "0755"
    }
  ]
}
```

The descriptor is the signature subject. The package digest is the SHA-256 of
the exact canonical descriptor bytes. The descriptor does not list itself or
its detached signature, avoiding a self-reference; it lists every other
regular file exactly once, including `kit.toml`. Entries are sorted by the
UTF-8 bytes of their normalized path. Object-key ordering and number/string
encoding follow RFC 8785.

Package versions are immutable. `publisher` names the stable identity/namespace
policy the signature must satisfy; a self-declared value is never sufficient
without trust-policy authorization. Within one authorized publisher identity, a
`(kit.id, kit.version)` pair MUST resolve to exactly one package digest.
Changing any payload byte, inventory path, or executable mode requires a new
kit version. Seeing the same id/version with a different digest is an
equivocation error, not an update.

#### Path and mode rules

Inventory paths are forward-slash-separated, UTF-8 NFC, relative to the
package root, and non-empty. The encoded path MUST already be in NFC; a
consumer does not silently rewrite it. A path MUST NOT:

- be absolute, drive-qualified, UNC-qualified, or contain a backslash;
- contain an empty, `.` or `..` segment;
- contain `:`, `<`, `>`, `"`, `|`, `?`, `*`, or an ASCII control character;
- contain a segment ending in a dot or space;
- contain a segment whose case-insensitive basename (the portion before its
  first dot) is `CON`, `PRN`, `AUX`, `NUL`, `COM1`–`COM9`, `LPT1`–`LPT9`,
  `COM¹`–`COM³`, or `LPT¹`–`LPT³`;
- resolve outside the package root lexically or after filesystem resolution;
- collide with another entry under the portable collision key defined below;
  or
- name `kit.package.json`, its signature envelope, version-control metadata,
  a temporary file, or an installer marker.

For package schema v1, the **portable collision key** is
`NFC(full-case-fold(NFC(path)))`, applied to the complete forward-slash path
using the Unicode 15.1 `CaseFolding.txt` default full mappings (`C` + `F`). Two
distinct inventory paths with the same UTF-8 collision-key bytes are invalid.
Reserved metadata and Windows device basenames are compared under the same key.
A later schema that changes the Unicode table or collision algorithm is a new
package schema, not an implementation-local upgrade.

Packages contain regular files and directories only. Symlinks, hard links,
devices, sockets, and FIFOs are rejected. Payload file modes are normalized to
`0644` (data) or `0755` (executable). Other permission, owner, timestamp, ACL,
and extended-attribute metadata is transport noise and MUST NOT influence
package identity. A consumer materializes directories with a safe local mode;
directory mode is not a package entry.

#### Reference closure

Every manifest field that names a package-owned file MUST be a typed relative
path and MUST resolve to an inventory entry. Inline shell text, system command
names, URLs, and package paths are distinct value kinds; consumers MUST NOT use
slash/extension heuristics to guess which one was intended. A future manifest
revision that introduces those typed kinds is required before ambiguous legacy
fields can claim package conformance.

All payload files are inventoried, including resources reached only from a
`SKILL.md` or other payload document. Unreferenced but intentionally bundled
documentation is allowed because it is still signed and size-accounted. No
regular payload file may exist outside the inventory.

An archive, OCI artifact, git tree, or registry response is only a transport
for these files. Transport ordering, timestamps, compression, and ownership do
not define package identity; the canonical descriptor does.

### 2. Package verification and trust states

Before trusting, activating, or executing any package-owned content, a
consumer MUST:

1. read the descriptor and signature envelope without following links;
2. verify the descriptor signature, any required transparency evidence, signer
   policy, and the publisher's authority for the kit-id namespace from the
   pinned catalog snapshot or explicit local policy;
3. validate descriptor schema, canonical encoding, identity, uniqueness,
   normalized paths, declared sizes, and policy limits;
4. materialize files beneath a private staging root using containment-safe
   creation that cannot follow or replace links;
5. recompute every file digest, size, and portable mode from the staged bytes;
6. reject missing, duplicate, extra, mismatched, or special files;
7. parse `kit.toml`, require descriptor/manifest id and version equality,
   require any manifest author identity claimed as authoritative to agree with
   the authorized publisher policy, and validate every package path reference
   against the staged inventory; and
8. run command/composition preflight against the proposed active set.

Signature success on the descriptor is necessary but not sufficient; every
step above must pass before the trust state is `package-verified`. Consumers
MUST preserve distinct states for at least:

- `package-verified`;
- `package-signed-unverified`;
- `legacy-manifest-verified`;
- `legacy-manifest-unverified`; and
- `unsigned`.

`legacy-manifest-verified` means only that the historic manifest bytes matched
their signature. It MUST NOT be rendered, serialized, or audited as a verified
package.

Verification policy applies to the exact staged bytes that are later activated.
The installer MUST NOT verify one source path and then copy or fetch replacement
bytes from another path.

### 3. Atomic installation, activation, and rollback

Installation is a transaction over an immutable package and an active registry
generation:

1. Acquire an installer lock scoped to the package store and read the current
   active generation.
2. Create a private staging directory on the same filesystem as the package
   store. Apply configured file-count, total-size, per-file-size, and path-length
   limits before allocation or extraction.
3. Perform the complete verification and composition preflight in §2. Nothing
   in staging is discoverable by the registry, detection engine, hook runner,
   skill loader, or command resolver.
4. Move the verified staging directory into an immutable location keyed by
   package digest using an atomic same-filesystem operation. A pre-existing
   location is accepted only after re-verification proves identical content.
5. Construct a new registry generation that names exact package digests,
   catalog snapshot digest, and generic-command bindings. Atomically switch the
   active-generation pointer with compare-and-swap semantics against the
   generation read in step 1.
6. Retain the previous generation until the new pointer is durable and eligible
   for rollback. Garbage collection is separate from activation.

The descriptor, signature envelope, manifest, and payload are one transaction.
A signature-envelope write is never best-effort. On failure before the pointer
switch, the current generation remains active and staging is deleted or ignored
for later cleanup. On a compare-and-swap race, the installer re-preflights
against the new generation or returns a conflict; it never overwrites it.

Crash recovery ignores incomplete staging directories and selects only a
complete, atomically published generation. Detection, install hooks, and other
kit-controlled execution begin only after activation commits. Before rollback,
the consumer composition-preflights the previously verified generation against
the current target dimensions and policy. Only a successful preflight permits
an atomic compare-and-swap pointer switch; failure leaves the current
generation active.

Installing and enabling MAY remain separate user operations, but neither may
expose a partial package. If a command combines them, the visible outcome is
still the single activation transaction above.

### 4. Deterministic multi-kit command composition

Every command has a structured owner-qualified identity:

```text
(kit id, local command name, package digest)
```

`build`, `test`, and `validate` are generic aliases, not command identities.
The runtime may render a qualified identity for humans, but canonical records
retain the structured tuple so kit ids never need delimiter escaping.

Composition follows these rules:

1. Resolve package identity and scope before contributions. Two packages with
   the same kit id at the same effective scope are a conflict unless an
   explicit package/catalog lock selects one exact digest. Source or scan order
   never selects a winner.
2. Filter by target OS, work type, and path scope. Disjoint monorepo path scopes
   produce separate command plans. Only overlapping scopes participate in the
   same alias resolution.
3. Materialize every command under its owner-qualified identity. Distinct
   identities merge additively. Command strings are never concatenated,
   structurally merged, or deduplicated merely because their text matches.
4. Apply an OS-specific override only to the same command owned by the same
   package. This is specialization, not cross-kit replacement.
5. Resolve each generic alias to exactly one qualified owner. A binding is
   authorized only by either (a) an operator-approved composition lock naming
   the target dimensions and exact selected command or (b) a signed delegation
   issued by the displaced command's authorized owner, or by catalog policy
   explicitly authorized to act for that owner's namespace. A delegation names
   the alias, exact active displaced command, exact permitted replacement
   command, and applicable scope. A would-be replacement's own manifest may
   request that relationship, but it cannot authorize taking another kit's
   alias. Every edge in a replacement chain requires such authority; chains
   must be acyclic, all targets must exist, and there must be one terminal
   owner.
6. If zero commands claim an alias, the alias is absent. If exactly one claims
   it, that command owns it. If multiple commands claim it without one valid
   terminal binding, composition fails with every claimant and the required
   configuration action in the error.
7. `foundation → framework → project` order governs ordered contribution
   execution such as hooks; confidence, priority, order group, registry source,
   and discovery order MUST NOT silently decide a generic-command owner.

The composed result records the ordered active package digests, target
dimensions, every owner-qualified command, and every generic binding. Consumers
derive a composition digest from that canonical record and attach it to session
diagnostics/audit evidence so a command can be traced to the package bytes that
owned it.

The legacy v1 `[provide.commands]` map continues to create owner-qualified
commands and generic alias claims. Because it cannot express authorized
delegations, two v1 kits claiming the same alias conflict unless an explicit
external composition lock binds the alias. A new manifest revision MUST encode
structured command identity, alias claims, replacement requests, and
target-owner delegations; old consumers must reject that revision rather than
ignore the authority metadata. The exact TOML spelling and in-memory types are
implementation choices, but the semantics above are not.

### 5. Deterministic catalog publication and synchronization

An official catalog publication is an immutable, signed **catalog snapshot**.
Its canonical lock contains:

- catalog schema version, source revision, and publisher-monotonic sequence;
- a unique row for each kit id/version;
- the package descriptor locator, package digest, and authorized package signer
  policy;
- compatibility constraints required to read the package/manifest schemas; and
- deterministic ordering by kit id, version, then package digest.

The catalog snapshot itself is signed. Every referenced package is also signed
and independently verified. Mutable branch names, `latest`, directory walk
order, and “first valid manifest” are not resolution inputs.

An online catalog updater MUST follow The Update Framework (TUF) 1.0
consistent-snapshot and client-update semantics, or a separately reviewed
profile proving equivalent protections. That means a trusted root, target
lengths/hashes, versioned snapshot metadata, expiring timestamp/freshness
metadata, monotonically increasing trusted metadata versions, and
content-hash-addressed target retrieval. The catalog lock and package
descriptors are targets. This prevents mix-and-match, freeze, and implicit
rollback attacks while allowing publisher key rotation/delegation. A binary or
offline bundle may pin one exact lock digest without online timestamp refresh,
but then it MUST describe itself as a pinned snapshot and make no freshness
claim.

A consumer release or runtime synchronization pins the catalog snapshot digest.
Resolving `kit id + version` means looking up one row in that snapshot and then
requiring its exact package digest. Missing material, a digest mismatch, an
unsupported schema, a duplicate identity, or the same id/version under a new
digest fails closed; there is no fallback to another source.

Consumers reject a lower catalog sequence as a downgrade unless the operator
explicitly selects a previously verified snapshot as a rollback. The rollback
action is recorded with the old and new snapshot digests; network/source
failure cannot trigger it implicitly.

Updating a consumer catalog is a generation transaction: fetch/cache and verify
all required packages, preflight the proposed active set and command bindings,
then atomically switch the catalog/registry generation. The previous lock
remains available for rollback. Sessions record the catalog snapshot digest,
active package digests, and composition digest.

Local/operator packages may coexist outside the official snapshot, but their
source, trust state, exact digest, scope, and override authority are explicit in
the active lock. They do not mutate or impersonate the official snapshot.

The SaaS control plane may curate snapshots, add tenancy policy, and distribute
the same immutable artifacts. It inherits this OSS resolver and verification
contract; it does not define a second package identity or composition order.

### 6. Legacy compatibility and migration

Migration is explicit and phased by capability, not by an aspirational date:

#### Phase L0 — classify without upgrading trust

The first package-aware consumer may continue to discover already-installed
flat manifests. It reports their real state as `legacy-manifest-*`, warns before
activation, and applies the new fail-on-command-collision rules. New remote
legacy installs require an explicit compatibility policy; permissive trust or a
one-time unsigned override does not turn a legacy manifest into a verified
package.

#### Phase L1 — dual publication

For one declared consumer-compatibility window, the official catalog publishes
both complete signed packages/snapshot and the legacy manifest signature
artifacts needed by older consumers. Package-aware consumers always choose the
package path. Any payload change bumps the kit version and therefore produces a
new package digest and snapshot.

#### Phase L2 — package-required default

After the minimum supported consumer understands packages, official remote
install and catalog synchronization require `package-verified`. Existing local
legacy activations may continue only under an explicit legacy policy and remain
visibly classified. There is no automatic fallback from package verification
failure to manifest-only installation.

#### Phase L3 — compatibility removal

Legacy scanning/removal is a separate, announced breaking change gated on
support policy and migration evidence. It is not implied by this ADR.

Official legacy material is migrated by the publisher rebuilding the complete
package from source, bumping the version when payload bytes changed, and signing
the package descriptor and catalog snapshot. A local operator can package and
sign local material under the operator's own identity; wrapping a vendor-signed
manifest does not transfer the vendor's identity to the surrounding package.

Replacing an active legacy kit uses the atomic transaction in §3: verify the
new package, preflight composition, switch the active generation, and retain the
legacy generation for rollback until policy permits collection. No in-place
conversion or silent trust promotion is allowed.

### 7. Required conformance and release evidence

Before any implementation claims this ADR is delivered, evidence MUST cover:

- reproducible descriptor and catalog-lock bytes across clean builds;
- tamper tests for every payload class and for mode/path/inventory changes;
- traversal, absolute/drive/UNC path, backslash, colon/alternate-data-stream,
  forbidden-character, trailing-dot/space, reserved-device-basename,
  Unicode-15.1 portable-collision-key, symlink, hard-link, special-file,
  duplicate, extra-file, and resource-limit cases;
- descriptor/manifest identity mismatch and id/version digest equivocation;
- signer-policy failures and preservation of distinct legacy/package states;
- crash/fault injection at each install/activation boundary, concurrent
  generation races, and rollback;
- command alias collision, operator owner selection, unauthorized self-declared
  replacement, target-owner/catalog delegation, replacement cycles, missing
  targets, OS specialization, and disjoint/overlapping path scopes;
- signed snapshot synchronization, missing/stale package rejection, and exact
  catalog rollback; and
- cross-substrate installation/execution from the same package and composition
  lock.

The catalog MUST NOT expand or advertise complete signed-package installation
until publisher, consumer, and release evidence is green together. Passing a
manifest validator or verifying a legacy manifest signature is insufficient.

## Consequences

### Positive

- Signature verification covers the bytes that execute or enter prompts.
- A failed install cannot expose half a package or destroy the prior working
  generation.
- Multi-kit command ownership is explicit and auditable rather than an accident
  of map/application order.
- Catalog and consumer releases can reproduce exactly which packages and
  commands were active.
- The contract remains runnable in OSS; hosted catalog and tenancy policy are
  extensions rather than dependencies.

### Negative

- Publishers must build and sign a package descriptor plus catalog snapshot,
  not only each manifest.
- Consumers need an immutable package store, transactional generation pointer,
  resolver lock, and richer trust states.
- Existing framework/foundation pairs that both export generic commands will
  fail until a manifest revision or explicit composition lock declares the
  owner.
- Payload changes require version bumps, increasing release discipline and
  invalidating workflows that edited skills in place under a stable version.
- Dual publication temporarily increases catalog and CI complexity.

### Risks

- A canonicalization mismatch can make valid publications unverifiable. One
  shared conformance corpus and byte fixtures are required across publishers
  and consumers.
- Case-fold/Unicode rules may reject paths accepted by one host filesystem. The
  conservative portable rule is intentional; publishers must rename them.
- Retaining generations can consume disk. Garbage collection needs explicit
  liveness/rollback policy and must never remove the active generation.
- An overly broad legacy policy can prolong manifest-only trust. Product
  surfaces and APIs must keep the weaker state visible.

## Alternatives considered

### Continue signing only `kit.toml`

Rejected. The manifest refers to executable and prompt-bearing files whose
bytes and modes remain outside the signature.

### Sign archive bytes directly

Rejected as the package identity. Archive timestamps, ownership, ordering, and
compression vary across tools. An archive may transport a package, but the
canonical descriptor is the stable signature subject.

### Keep deterministic last-applied-wins commands

Rejected. Stable order makes an unsafe replacement reproducible; it does not
grant one kit authority to replace another kit's command.

### Merge command strings or accept identical strings

Rejected. Shell text equality does not prove equal environment, working
directory, package identity, or intent, and concatenating commands creates a
new unsigned program.

### Install files in place with a journal

Rejected. Readers can observe partial state and crash recovery becomes a repair
problem. Immutable content plus an atomic generation pointer gives a simpler
visibility boundary.

### Resolve from mutable registry priority or directory order

Rejected. The result changes when a source changes, disappears, or is reordered.
Signed immutable snapshots and exact digests make synchronization reproducible.

## Affected documents

- `005-kit-manifest-spec.md` — package identity/trust, command composition,
  registry selection, daemon installation, and legacy compatibility.
- `ADR-2026-06-13-official-language-kits-and-catalog-home.md` — clarifies that
  the shipped signature bundles currently establish manifest integrity only;
  package closure remains an implementation prerequisite.

## Affected work items

- `donmai-kits`: deterministic package/snapshot builder, conformance fixtures,
  dual publication, and versioned catalog migration.
- `donmai`: complete-package verifier, transactional installer/registry,
  command resolver, compatibility states, and synchronization evidence.
- Cross-substrate smoke suites: install and execute the same pinned package and
  composition lock on every supported substrate.

Catalog growth, hosted-catalog UX, community publication, and interoperability
remain partial/held until those implementation lanes satisfy §7.

## Implementation notes

Recommended implementation order:

1. Publish shared canonical descriptor/catalog fixtures and negative vectors.
2. Add package construction and dual publication without changing the current
   consumer default.
3. Add staged verification, immutable storage, generation switching, and the
   command-resolution preflight behind an explicit compatibility mode.
4. Run cross-substrate and rollback evidence, then make package verification
   the default for official remote installs.
5. Retire legacy publication/scanning only through the phased policy in §6.

Transport choice (archive, OCI, git, or registry API), physical cache layout,
quota values, and compatibility-window duration are deliberately left to
implementations and release policy. None may weaken the normative identity,
verification, composition, or atomicity rules above.

## Standards alignment

- [RFC 8785 JSON Canonicalization Scheme](https://www.rfc-editor.org/rfc/rfc8785.html)
  supplies invariant I-JSON serialization for signed descriptor and lock bytes.
  Package paths are normalized to NFC *before* serialization because JCS
  intentionally preserves strings rather than normalizing Unicode.
- [The Update Framework 1.0 specification](https://theupdateframework.github.io/specification/latest/)
  supplies consistent-snapshot, target hash/length, metadata version,
  expiration, rollback/freeze, and delegated-trust semantics for online catalog
  synchronization.

These standards do not define kit command ownership, package file modes,
manifest reference closure, or atomic activation; those remain the
application-specific contract in this ADR.
