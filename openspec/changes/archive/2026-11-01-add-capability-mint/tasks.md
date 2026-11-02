# Tasks

- [x] Deposit writes opaque `value`, JSON `meta` (`salt_b64`, `commitment_hex`), and opaque `owner`, or leaves none of them
- [x] Production mint uses the durable root, appends a holder check, and puts no secret bytes, no holder fact, and no hop block in the token
- [x] The minted token authorizes only when the verifier injects that owner fingerprint
- [x] `mix test test/mjolnir/secrets/` deposits a secret, reads the owner fingerprint back, and shows the uninjected authorizer fails
- [x] An empty secret, a bad id, or a bad owner key fails closed without creating a directory
- [x] A second deposit, a partial directory, and a losing concurrent deposit leave the existing objects unchanged
- [x] A later write failure, a mint or append failure, and a cleanup failure return no token and no secret-bearing error; a leftover directory is not adopted
- [x] On fold, the living purpose no longer lists mint as unbuilt

## Advise owed

- [x] Fresh advise after preparation
- [x] R1 — Define exclusive creation for caller-supplied IDs, preserve existing/partial records on refusal, and cover duplicate IDs and concurrent writers without exposing replacement secrets to old tokens (reviews/2026-11-01-advise.md)
- [x] R2 — Define publication, rollback ownership, temporary-file cleanup, cleanup-failure and process-interruption semantics; cover later-write and mint/append failures before returning the final token (reviews/2026-11-01-advise.md)

## Out of scope

- Redeem, hop, the guest fence, and the mint-root file
