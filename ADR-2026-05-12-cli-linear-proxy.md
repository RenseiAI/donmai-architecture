---
status: Accepted
date: 2026-05-12
boundary: shared
split: sibling-extensions
---

# ADR-2026-05-12 — CLI Linear proxy via platform login session

**Status:** Accepted
**Date:** 2026-05-12
**Boundary:** shared (OSS-canonical contract here; platform-side proxy route captured in `rensei-architecture/013-orchestrator-and-governor-platform-extensions.md` § "CLI Linear proxy")
**Authors:** Mark Kropf (Rensei) + Donmai Agent

## Context

The `linear` subcommand tree shipped via `afcli.RegisterCommands` (16 subcommands in `agentfactory-tui/afcli/linear.go`) authenticates exclusively against `LINEAR_API_KEY` / `LINEAR_ACCESS_TOKEN` env vars. When a user has already authenticated with the platform via `donmai login` (rsk_ Bearer token) AND the platform holds a working Linear OAuth credential for the org (via the existing OAuth flow at `/api/integrations/linear/oauth/authorize`), the CLI cannot use that credential — it still hard-errors on the missing env var.

The bug is structural in two places:

1. **`afcli/commands.go:76`** registers `newLinearCmd()` with no `DataSource` argument, unlike every sibling that touches the platform API (`newAgentCmd(ds, ...)`, `newSessionCmd(ds, ...)`, `newProviderCmd(ds)`, `newKitCmd(ds)`, `newRoutingCmd(ds)`, `newWorkareaCmd(ds)`, …). The user's rsk_ token is therefore invisible to every linear subcommand by construction.
2. **Platform has no `/api/cli/linear/*` proxy routes**, only `/api/cli/{whoami,auth,cost,capacity,machines,session}`. The server-side primitives are ready — `ensureLinearTokenFresh()` + `getRateLimitedLinearClient()` in the platform's Linear provider module resolve the org's stored Linear OAuth credential and produce a working `LinearAgentClient` wrapped with TokenBucket + circuit breaker — but no HTTP edge calls into them.

The header comment of `afcli/linear.go:9-13` even calls the gap out as "future":

```
//   1. LINEAR_API_KEY env var → direct GraphQL calls to api.linear.app.
//   2. No key + AGENTFACTORY_API_URL + WORKER_AUTH_TOKEN → proxy mode (future).
//   3. Neither → hard error for commands that require auth.
```

"Future" never landed. Other Linear-touching paths work today (OAuth setup, workflow conditions, webhook handlers); the CLI read path is the only thing that bypasses the OAuth-managed credential.

## Decision

Three connected changes:

### D1 — `linear.Client` gains a `ProxyMode` toggle

The hand-rolled GraphQL client at `agentfactory-tui/internal/linear/client.go` gets a new boolean field. The request builder switches the Authorization header shape:

- `ProxyMode: false` (default, standalone `af`): `Authorization: <APIKey>` — raw Linear-direct, matches Linear's API expectation.
- `ProxyMode: true` (platform case): `Authorization: Bearer <rsk_token>` — platform unwraps and forwards under the org's OAuth credential.

A new constructor `linear.NewProxiedClient(platformBaseURL, rskToken)` builds the proxied variant with `BaseURL` pointing at `<platform>/api/cli/linear/graphql` and `ProxyMode: true`. All GraphQL queries, mutations, and response decoders are otherwise unchanged. The `linear.Linear` interface is unchanged.

### D2 — `afcli/newLinearCmd(ds func() afclient.DataSource)` accepts the platform DataSource

`commands.go:76` becomes `root.AddCommand(newLinearCmd(ds))`, matching every sibling command. Inside each subcommand, `newLinearClient(ds)` resolves the client via this resolution order:

1. **`LINEAR_API_KEY` / `LINEAR_ACCESS_TOKEN` env set** → existing direct path. Preserves standalone `af` behavior AND the worker-fleet path where `af agent run` injects the env var into the in-session shell.
2. **`ds()` returns an authenticated client (rsk_ token + non-empty baseURL)** → `linear.NewProxiedClient(baseURL, rskToken)`. The platform case.
3. **Neither** → hard error with a friendly message: *"Linear access requires either `LINEAR_API_KEY` env var or an rsk_ token via `donmai login`."*

Env wins precedence is deliberate: it preserves the worker-fleet path semantics (where `LINEAR_API_KEY` is injected per session) without conditional logic.

### D3 — Platform adds `POST /api/cli/linear/graphql`

GraphQL passthrough route. Auth via `getCliOrSessionAuth` (the canonical CLI auth resolver that accepts rsk_ Bearer + cookie + user_token). Resolve the org's Linear credential via `getRateLimitedLinearClient(auth.orgId)`, which already wraps `ensureLinearTokenFresh` + `TokenBucket` + `CircuitBreaker`. Forward the request body's `{query, variables}` to `api.linear.app/graphql` via the wrapped SDK client's `linearClient.client.rawRequest(...)` — back-pressure is preserved through the proxy chain in `back-pressure.ts`. Response is the verbatim Linear GraphQL `{data, errors?}` envelope.

## Consequences

### Positive

- `donmai linear *` works without `LINEAR_API_KEY` for any user who has run `donmai login` + connected Linear via OAuth. Closes a 6-month gap that was the second-most-friction UX issue for platform users.
- Standalone `af linear *` is unchanged. Worker-fleet `af agent run` paths are unchanged.
- The 16 subcommand call sites in `afcli/linear.go` need zero changes — they consume the same `linear.Linear` interface. The wire format switch is encapsulated in the client constructor.
- Rate-limiting + circuit-breaker come for free via the existing back-pressure wrapper. Linear API quota exhaustion at the org level is enforced server-side.
- The platform-side proxy can later be migrated to per-operation REST routes if fine-grained Cedar policy becomes a requirement, without touching the `linear.Linear` interface or call sites.

### Negative

- GraphQL passthrough exposes a programmable surface that mirrors what the user can do via the platform UI. Not strictly-new capability (the OAuth flow already grants programmatic web access) but it makes scripted bulk reads easier. Mitigated by the existing TokenBucket which caps per-org Linear API call rate.
- The CLI gains a new failure mode: 409 *"Linear integration not connected for this org"*. Users have to either run `rensei project trackers connect-linear` or fall back to `LINEAR_API_KEY`. The error message must be actionable.

### Risks

- **`linearClient.client.rawRequest` semantic drift** — the `@linear/sdk` GraphQL client uses `graphql-request` under the hood. If a future SDK version restructures the `.client.rawRequest` surface, the proxy route breaks. Pinning the SDK version is already in place; an upgrade flow needs to verify the rawRequest path.
- **GraphQL error normalization** — Linear's errors arrive as `ClientError` thrown by `graphql-request` (200 status, `errors` array in body). The route catches and normalizes to `NextResponse.json({data, errors}, {status})` so the CLI client decodes the same shape it sees from `api.linear.app/graphql` directly. Tests pin the shape.
- **Precedence ambiguity** — env wins over rsk_ when both are set. Documented in subcommand `--help` output. A future user who sets `LINEAR_API_KEY` for one project and forgets to unset it before working on another will silently bypass the proxy.

## Alternatives considered

- **Per-operation REST routes (`/api/cli/linear/get-issue`, `/create-comment`, …)** — 18 routes × ~30 lines each + duplicated TS types mirroring the Go `Issue`/`Comment`/etc. structs. Drift between Go and TS schemas is inevitable. Rejected: GraphQL passthrough is one route + zero schema duplication. Per-operation routes are a viable migration target if Cedar policy ever needs per-method granularity.
- **Add Linear methods to `afclient.DataSource`** — extend the existing platform-API client surface with `LinearGetIssue`/`LinearCreateComment`/etc. Same drift problem as per-operation REST, plus it bloats the DataSource interface (already 31 methods) with provider-specific surface. Rejected.
- **Localhost callback for OAuth on every CLI invocation** — skip stored credentials, run an ephemeral OAuth dance on each `rensei linear` call. Rejected: defeats the purpose of `rensei login` (single sign-on across the CLI surface) and creates a UX disaster (browser pop-up per command).

## Affected documents

- `rensei-architecture/013-orchestrator-and-governor-platform-extensions.md` — new § "CLI Linear proxy" documenting the platform-resident half (route, auth, credential resolution, rate-limit handoff).
- `rensei-architecture/ADR-2026-05-12-cli-linear-proxy.md` — mirrored stub pointing back at this canonical.

No edits to `002-provider-base-contract.md`, `005-kit-manifest-spec.md`, or `006-cross-provider-interactions.md` — the proxy is below the abstraction those docs cover. It's CLI plumbing + a platform HTTP edge, not a new architectural primitive or seam.

## Affected work items

- Closes the "proxy mode (future)" placeholder at `agentfactory-tui/afcli/linear.go:11-12`.
- Unblocks "rensei linear UX" follow-ups that have been stalling on the missing CLI auth path.

## Implementation notes

Lands across three repos in this order: corpus (this ADR + 013 addendum), platform (`/api/cli/linear/graphql/route.ts` + tests), then `agentfactory-tui` (`internal/linear/client.go` + `afcli/linear.go` refactor + release v0.7.6), then closed-source TUI bump (v0.6.8). Tests pin the wire shape at every boundary — the auth-header branch in the Go client, the response normalization in the platform route, and the resolution order in `newLinearClient`.
