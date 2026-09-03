---
status: Proposed
date: 2026-09-03
boundary: shared
---

# Amendment — readoption window bounded by lineage liveness

This amendment supersedes the fixed worst-case carrier-fault retry window in rule 8 of `ADR-2026-08-17-session-shim-adoption.md`.

The orphan deadline remains authoritative for an unobservable shim. Carrier readoption is a separate recovery window bounded by observed shim-process liveness and continued lineage possession. While the embedder's liveness predicate confirms both facts, the readoption window may exceed the orphan deadline; the orphan clock is not allowed to reap a shim that is still observed alive and held by its lineage. If the shim becomes unobservable, recovery stops immediately and the ordinary orphan deadline governs the unresolved lineage.

The default readoption window is ten minutes. Retry intervals use exponential backoff capped at thirty seconds. Window exhaustion while the shim remains observably alive produces the configured post-window outcome and never fabricates terminal evidence. Repeated loss inside the configured window falls back to that outcome rather than granting an unbounded sequence of fresh windows.

Embedders that require the former behavior may explicitly select fixed-attempt mode; the zero-value policy remains source-compatible and does not silently change its lifecycle disposition.
