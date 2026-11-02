1. Pin deposit to a host-only entry point with a validated owner fingerprint and path-safe secret id.
2. Pin opaque value and JSON metadata to the exact shape the existing redeem reader consumes.
3. Pin a fresh 32-byte CSPRNG salt and the real domain-separated Blake3 commitment for every accepted deposit.
4. Pin production mint to the cached durable authority and fail closed if that authority is unavailable.
5. Pin the returned token to the deposited id, redeem operation, and an effective check for the intended holder.
6. Refuse reliance on owner metadata alone: redeem verifies integrity but does not compare the record owner with the token.
7. Refuse replacement that lets an older token redeem a different owner's newly deposited bytes at the same id.
8. Refuse check-then-write concurrency and rollback that can overwrite or remove another successful deposit.
9. Pin publication and failure ordering so success exposes a complete value/meta pair and no unbound intermediate token escapes.
10. Tradeoff: create-only ids and conservative crash residue simplify security, at the cost of retries needing fresh ids or explicit recovery.
