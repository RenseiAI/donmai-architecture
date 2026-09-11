# Proposed complete retired-source lifecycle fixtures

These attachments are proposed, not accepted architecture or runtime evidence.
Both corpora carry byte-identical copies. MANIFEST.json freezes every file.
The earlier retired-source-recovery-v1 corpus stays byte-identical.

PROPOSED-WIRE-VECTORS contains9 complete synthetic scenarios: current retirement
from either origin profile, repeated recovery, and true admitted3/4 disposal to
fresh ordinary2 or terminal release. PROPOSED-NEGATIVE-VECTORS contains71 exact
materialized scenarios and names the real production boundary/owner required.
Edits are resealed as recorded; semantic mismatches must not be masked by stale
outer hashes. A_root_receipt reseals only the changed root receipt and leaves
immediate token/Snapshot scalars valid, deliberately exposing scalar-only
consumers. No unsigned claim projection is a credential.

FIRST-ROOT-NEGOTIATION-VECTORS has12 refusal scenarios before the first v1 root.
Its authoritative checks are fixture setup, never caller-authorized booleans.
NEVER-ADMITTED-ROOM-LIVENESS specifies five required literal controls against
actual room/API/journal paths. Fake time does not create retirement authority.
PROPOSED-CONTROL-VECTORS fixes capability/inspection/reconcile/refusal objects;
transport bindings belong to the implementing composition.

All state digests, identifiers and counters are synthetic commitments, not
observed admission, retirement, adoption or terminal facts. Implementations must
construct those states through actual producers. Complete-chain and runtime
controls remain required in addition to fixture integrity.
