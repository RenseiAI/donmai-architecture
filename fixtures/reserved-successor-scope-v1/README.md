# Reserved-successor Scope edge matrix

This supplemental fixture derives from the accepted
[Scope boundary-whitespace clarification](../../protocol/reserved-successor-retirement-v1.md#scope-boundary-whitespace--clarification-2026-09-17).
It records normative expectations, not observations of a released implementation.
The fixed set has 26 code points. Each has a leading refusal, trailing refusal
and unchanged interior acceptance, plus three ordinary valid-scalar controls.

For every case, apply `scope` independently to `orgId` and `sessionId` in the
original canonical request and its paired result, recompute the existing
source/request/state/result digests, and invoke the actual codec parser. An
accepted result preserves the exact Scope value. A refused case must not be
trimmed or normalized into acceptance. Do not add these fixture-only metadata
keys to any wire object. Existing malformed UTF-8, lone-surrogate, empty-string
and byte-limit controls still apply independently.

Provenance: the seven original retirement fixture files remain byte-identical
to public corpus commit `5bc7a04bf4e18f71da57c158b4d257f4753e599c` under
[`../reserved-successor-retirement-v1/`](../reserved-successor-retirement-v1/README.md).
Their manifest is unchanged. This directory has its own manifest; its expected
outcomes come from the fixed predicate rather than either language's trim API.
