1. Pin a host deposit boundary that accepts opaque bytes and an explicit owner identity without extending guest authority.
2. Pin a fresh path-safe secret identifier; refuse caller-controlled overwrite of an existing secret record.
3. Pin exactly 32 CSPRNG salt bytes and Biscuit.secret_commit/2, with no unsalted digest or substitute Blake3 implementation.
4. Pin JSON metadata compatible with read_record/1: salt_b64, lowercase commitment_hex, and the owner's protocol fingerprint.
5. Pin production mint to the cached durable authority; missing or inconsistent root configuration must fail closed.
6. Pin right(secret_id, "redeem") plus an appended holder check; refuse authority holder facts or returning the intermediate bearer token.
7. Pin validation of the owner fingerprint's encoding and namespace so malformed input cannot become Biscuit policy text.
8. Pin success to a complete value/meta pair and the final bound token; specify failure cleanup, collisions, and concurrent writers.
9. Refuse secret bytes in token, response metadata, logs, exception details, or command arguments; test failures as well as success.
10. Tradeoff: two opaque files can preserve the existing reader contract without a new database, but require explicit publication and crash semantics.
