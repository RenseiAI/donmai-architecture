---
status: Accepted
date: 2026-07-09
boundary: shared
split: sibling-extensions
---

# ADR-2026-07-09: Host project enablement is independent of repository resources

**Status:** Accepted
**Date:** 2026-07-09
**Boundary:** shared
**Authors:** architecture lane

## Context

The local daemon currently represents an allowed project as an `id + repository`
tuple. The corresponding CLI asks an operator to allow a repository, while host
installation can also take a project, and status reduces the result to a count of
"projects allowed." These surfaces collapse three independent facts:

1. whether the daemon service is installed and running;
2. which project identities the host may serve; and
3. which zero-to-many repository resources belong to each project.

The collapsed model cannot enable an existing project that has no repository,
cannot faithfully represent a project with multiple repositories, and cannot say
which desired projects are actually registered and receiving work. It also makes
the first repository returned by a provider accidentally authoritative for
routing. That is unsafe: project admission is an authorization decision, while a
repository is a resource selected by an individual work item.

## Decision

The daemon MUST model **host project enablement** as a set of stable project IDs,
independent of repository resources. A project may have zero, one, or many
repositories. Repository presence never enables a project and repository absence
never disables it.

The canonical operator flow is:

```text
donmai host install
donmai host project enable <project-id>
donmai host project disable <project-id>
donmai host project list [--json]

donmai project repo list <project-id>
donmai project repo add <project-id> <repository>
donmai project repo update <project-id> <repository-id> ...
donmai project repo remove <project-id> <repository-id>
```

`host install` owns service lifecycle only. `host project enable|disable|list`
owns this machine's project admission. `project repo *` owns project resources.
Disabling a project stops new claims for that project but does not delete its
repository resources or terminate already-running sessions.

### Normalized host configuration

The in-memory model has two separate collections:

```yaml
projectAdmissionVersion: 2

enabledProjectIds:
  - project-alpha
  - project-beta

repositories:
  - id: repo-alpha-api
    projectId: project-alpha
    source: https://example.invalid/acme/api.git
    primary: true
    cloneStrategy: shallow
    git:
      credentialHelper: manager
  - id: repo-alpha-web
    projectId: project-alpha
    source: https://example.invalid/acme/web.git
    cloneStrategy: full
```

`enabledProjectIds` is the sole desired-state authority for project admission.
`repositories[].projectId` is a referential link, not an admission grant. At most
one repository per project may be marked `primary`. A project with no primary may
still receive work that does not require a repository; repository-requiring work
must name a repository explicitly or be rejected before spawn.

### Dispatch and admission

`SessionSpec` gains a required `projectId` in the v2 contract. Its source, when
present, identifies the selected repository resource (stable repository ID plus
provider-native source and ref). The daemon admits a session in this order:

1. require `projectId` and verify it is enabled;
2. if the work requires a repository, require an explicit repository selection
   or an explicitly marked primary repository;
3. verify that the selected repository belongs to `projectId`;
4. apply policy and credential checks; then
5. acquire the workarea and capacity slot.

The daemon MUST NOT choose the first repository returned by a provider. A
project/repository mismatch is a terminal pre-spawn rejection and consumes no
session capacity. Repository-free work remains legal when its work type does not
need a workarea source.

Every registration advertises project admission additively:

```go
type RegisterRequest struct {
    // existing fields remain
    ProjectAdmissionVersion int      `json:"projectAdmissionVersion,omitempty"`
    ProjectIDs              []string `json:"projectIds,omitempty"`
}
```

`projectAdmissionVersion: 2` distinguishes an explicitly empty project set from
a legacy peer that does not send the fields. In v2, empty means **serve no
projects**, never wildcard. An orchestrator dispatches only work whose
`SessionSpec.projectId` appears in the registered set.

### Scheduling and capacity

Project and repository identity do not create capacity partitions. All enabled
projects on one daemon share one machine-wide execution limiter derived from the
host capacity envelope. The scheduler is work-conserving up to that limit and
fair across ready project queues: an active project cannot reserve idle slots,
and a continuously busy project cannot starve another ready project. Repository
warmth may influence ordering after admission, but never authorization.

Registration or polling failures are isolated per registration context. A failed
context backs off independently while healthy contexts continue to feed the same
global limiter. The daemon never starts one limiter per project or context.

### Truthful desired and applied state

The daemon status contract exposes project state as rows, not only an aggregate
count. Human and JSON forms distinguish:

- **desired** — project ID is present in `enabledProjectIds`;
- **applied** — the current registration has acknowledged that project ID;
- **connection health** — ready, pending, backoff, draining, or error;
- **repository readiness** — configured repository count, primary selection,
  and any credential/clone warning.

Repository readiness is a warning unless the pending work requires that
repository. Status MUST expose desired/applied drift and MUST NOT report a
project as served merely because it appears in configuration.

### Additive migration and mixed versions

For one compatibility window, readers accept the legacy
`projects[].{id,repository,...}` shape. `projectAdmissionVersion` prevents a
legacy projection from resurrecting disabled projects:

- when `projectAdmissionVersion` is absent, add every legacy `id` to the
  normalized enabled set (the one-time bootstrap path);
- when `projectAdmissionVersion: 2` is present, `enabledProjectIds` is
  authoritative and legacy IDs MUST NOT be unioned into admission;
- convert every legacy tuple to one repository resource linked by `projectId`;
- deduplicate project IDs while retaining every distinct normalized repository;
- preserve clone strategy and credential-helper settings;
- when both repository shapes exist, take their union, with a v2 repository
  record winning on the same `(projectId, normalized source)` key.

The first successful v2 mutation writes the normalized fields atomically, keeps
a timestamped backup, sets `projectAdmissionVersion: 2`, and dual-writes a
legacy projection for **enabled, repository-bearing projects only** during the
compatibility window. Disabled projects retain their repository resources only
in the v2 collection, so an old daemon cannot resurrect them. A zero-repository
enabled project cannot be represented to an old daemon; the safe degradation is
that the old daemon does not serve it. Migration is idempotent.

Legacy command compatibility is equally bounded:

- `host project add|remove` warn and forward to `enable|disable`;
- `project allow <repository>` resolves the project unambiguously, adds the
  repository resource, and enables the project, otherwise it fails with the two
  canonical commands to run;
- `host install --project ...` installs the service and then enables the
  project, with a deprecation warning.

Old registration peers may continue using their existing token-scoped or legacy
project declaration. A v2 orchestrator never interprets absent project identity
as a wildcard, and it accepts a work item without `SessionSpec.projectId` only
when an authenticated legacy registration scopes that item to exactly one
project. Mutation and status payloads are additive during the same window.

## Consequences

### Positive

- Existing projects can be enabled without creating a repository binding.
- Multi-repository projects are first-class and repository choice is explicit.
- Installation, admission, resources, and runtime health have distinct user
  surfaces.
- One host remains efficient and fair as project count grows.
- Mixed deployments fail closed instead of treating missing fields as wildcard.

### Negative

- Config and wire readers must support two shapes for one compatibility window.
- Status becomes a structured table rather than a single count.
- Repository-requiring dispatchers must select a stable repository resource.

### Risks

- Incorrect legacy projection could resurrect disabled projects. The explicit
  config revision and enabled-only legacy projection are mandatory migration
  fixtures, alongside idempotency and v2-wins repository conflict tests.
- A dispatcher that omits `projectId` could be rejected after upgrade. The
  registration-version gate keeps the legacy fallback narrow and observable.
- Fair scheduling can reduce cache-local throughput under extreme load. The
  scheduler may bias toward warm repositories only after enforcing a bounded
  fairness window.

## Alternatives considered

### Keep `id + repository` and permit duplicate project rows

Rejected. It models repositories but not project admission, leaves a
zero-repository project impossible, and makes disable semantics ambiguous.

### Infer the enabled project set from repository resources

Rejected. Deleting the last repository would silently revoke host admission,
and adding a repository would silently grant it. Resource mutation must not be
an authorization side effect.

### Put project enablement back on `host install`

Rejected. Service lifecycle is machine-scoped and infrequent; project admission
is mutable desired state. Combining them makes routine configuration look like a
reinstall and obscures applied-state drift.

## Affected documents

- `004-sandbox-capability-matrix.md` — daemon configuration, admission, and
  shared-capacity scheduling.
- `ADR-2026-05-06-tui-noun-consolidation.md` — onboarding inserts explicit
  project enablement after service installation.
- `011-local-daemon-fleet.md` — canonical CLI journey, migration, and status.
- `013-orchestrator-and-governor.md` — registration and `SessionSpec.projectId`.
- `014-tui-operator-surfaces.md` — project-state operator primitive.
- Platform extension siblings for hosted multi-scope registration and status.

## Affected work items

Tracked in the composing product's project-management system; no tracker IDs are
stored in this public ADR.

## Implementation notes

Ship readers before writers, then the normalized daemon model, then registration
and dispatch, then canonical commands/status, and finally remove legacy writers
after all supported peers advertise project-admission v2. Behavior changes need
unit, migration, mixed-version, race, and end-to-end smoke coverage.
