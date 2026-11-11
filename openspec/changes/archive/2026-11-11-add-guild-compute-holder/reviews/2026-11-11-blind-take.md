# Independent blind take — add-guild-compute-holder

Written before opening this node's design.md, tasks.md, or spec deltas; evidence is the packet Why, cited runtime/archived/parent requirements, Biscuit and Redeem code, and ADR 0015.

1. Pin the consumer VM's algorithm-committing IdentiKey fingerprint as the holder proven by the execute request; a human member key stays outside the guest.
2. Pin a verified member-signed delegation from a current member to that exact holder, with explicit guild, purpose, scope, and lifetime bindings.
3. Pin the membership authority and the authenticated lookup response contract; caller-selected membership or token-authored facts cannot establish trust.
4. Pin freshness at admission after successful try-lock, with a hard deadline and evidence confined to the current occupancy attempt.
5. Refuse stale positive fallback on removal, lookup failure, missing delegation, expiry, or mismatched member/holder keys.
6. Pin delegation replacement and withdrawal semantics so cached or replayed signed bytes cannot silently restore a revoked grant.
7. Preserve resource-plus-operation Biscuit minting and verifier-only holder injection; do not add guild authority-block crypto or a new token holder class.
8. Preserve personal-fingerprint mint and execute without membership lookup, guild identifiers, or delegation infrastructure.
9. Pin an unambiguous signed delegation encoding and negative fixtures for cross-guild, cross-holder, cross-scope, malformed, and replayed evidence.
10. Accept the availability cost of a bounded online membership gate in exchange for current authorization; do not promise zero revocation latency beyond its stated freshness and admission boundary.
