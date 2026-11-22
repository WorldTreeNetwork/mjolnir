# add-relay-room-auth — design

Auth blast. This file is the contract a Fable read reviews before any code. Banner on the proposal stays PENDING.

The relay already verifies a moq-auth JWT from `/etc/mjolnir-relay/relay-keys.json`, refuses a root that is not `t/<canonical owner>` or below it, and closes a session when the token's `exp` passes (`openspec/changes/add-edge-relay`). This change only decides who signs, which path is a room, and what rotation means.

## Decisions

**D1. The controller API mints. The gateway does not.**
The mint is a route on the Elixir API, the process that runs as root. It is not the `mjolnir-gateway` process and not a guest. Alternative: a separate mint binary. Rejected because the node says the mint is the Mjolnir API under the existing scope model, and a second process would need its own copy of the private key.

**D2. Scope is `relay:join`, added to the API scope list.**
`Authz.require_scope/2` is the check. The scope is appended to the full set a verified user JWT receives in `Mjolnir.API.Auth`. A sites service token stays on its publish scope and cannot mint. The operator socket stays scope-empty and cannot mint. Alternative: reuse `vms:spawn`. Rejected because a VM spawn is not a room, and a stolen spawn token should not also sign media grants.

**D3. The owner is the spawn header, not the body and not `sub`.**
The room owner is `x-owner-id`, parsed with `Mjolnir.Deploy.Owner.parse/1`. A missing or non-canonical value is 400. A body `owner_id` is ignored. This matches spawn. `sub` on a user JWT is an identity string and is not required to be a 32-byte owner id, so using it as the path would mint roots the relay already refuses. Alternative: require `sub` itself to be the owner. That excludes every current login whose `sub` is not a canonical owner id. Open only if a later login change makes `sub` that id; this node does not.

**D4. Private key on the controller, root-only, not in `/etc/mjolnir`.**
The signing key lives at `/var/lib/mjolnir/relay-mint/current.jwk` (mode `0600`, owner root:root). The directory is `0700` root:root. The BEAM runs as root and can read it. The gateway user `mjolnir` cannot. The previous key, during overlap, is `previous.jwk` beside it, same mode. The key is not a deploy secret: those files are injected into guest VMs. It is not under `/etc/mjolnir`: that tree is writable by the gateway user. It is not in `relay-keys.json`: that file is a public verify set and the relay refuses a private key there.

**D5. The public half is written by root, by rename, into the file the relay already watches.**
The mint's installer writes only the public JWK set to `/etc/mjolnir-relay/relay-keys.json` by rename, as root. The relay already reloads that file within five seconds and admits new sessions with the new set. The gateway user is not in the path: it does not own the directory, and no gateway route accepts a key. Alternative: the relay pulls a JWKS from the API. Rejected because that puts the gateway, or any API caller, on the trust path the last change removed.

**D6. Rooms are not stored.**
A room exists when a token is minted for it. There is no room table. Two callers who share an owner and both hold `relay:join` can both mint for the same room. That is the tenant. Callers of a different owner cannot, because the root would not verify against their header. Alternative: an ACL of participant ids. That is a registry, and this node does not have one.

**D7. Path.**
`t/<owner id>/<room>/<participant>/<rest>`.

- `<owner id>` is the canonical id from D3.
- `<room>` and `<participant>` are one segment each, matching `[A-Za-z0-9_-]{1,64}`.
- Neither segment may be `.`, `..`, empty, or `mjolnir-nopublish`.
- The token `root` is `t/<owner id>/<room>`.
- `subscribe` is one pattern that covers that room and everything under it.
- `publish` is one pattern that covers only `t/<owner id>/<room>/<participant>` and everything under it.
- `<rest>` is the track the client chooses. The mint does not name tracks.

The relay already rejects a session path outside the token root. The participant boundary is the publish pattern, not a second check invented beside moq. A token for room B presented to room A fails the existing "path outside the grant" rule.

**D8. A call outlives a token by reconnecting, not by refresh.**
Maximum life stays `:relay_token_max_ttl` (3600 seconds), counted from `iat` to `exp`, which the relay already enforces. The pinned session handler admits once, at the handshake, and closes the session when the token expires. There is no mid-session replace-the-token message. This node does not add one. When the session closes, the client mints again and connects again. Media between the close and the new session is gone. Alternative: refresh in place. That is a protocol change in the relay and is not required to meet the acceptance.

**D9. Revocation is key rotation. Live sessions are not cut.**
The operator, as root, on the controller host:

1. Generate a new EdDSA keypair. Write the private half to `current.jwk` only after copying the old private half to `previous.jwk` (both `0600` root:root, write via rename).
2. Write a public JWK set of the new key and the previous key to `/etc/mjolnir-relay/relay-keys.json` via rename.
3. From that rename, new mints sign with the new key only.
4. Wait `:relay_token_max_ttl` (3600 seconds) plus 60 seconds of clock skew.
5. Write a public set of the new key only, via rename. Delete `previous.jwk`.

During the wait, a token signed by the previous key still verifies. That is the overlap. After step 5, a new session with the old key is an unknown key and is refused. A session admitted before step 5 keeps that admission until its own `exp`, including across step 5. The relay already specifies that. Rotation does not abort it. A single participant cannot be kicked without waiting out their token. That kick list is out of scope (proposal).

**D10. Rotation is a root script, not an API route.**
`scripts/relay-mint-key.sh` on the controller host performs D9. No `/api` route accepts a private key or a public key. Alternative: `mj relay keys rotate` over the API. Rejected here because any route the gateway user can reach, or any bearer that can call the API, would be a path onto the verify set.

**D11. One signing key is still one relay.**
`add-edge-relay` already says a signing key is trusted by exactly one `:relay_host`. Rotation replaces that key. It does not copy the new public half into a second host's file. The mint returns `relay_host` from `MJOLNIR_RELAY_HOST` so the client knows which host the token is for. The token dialect still has no audience claim. A token presented to a different relay fails as an unknown key.

## Unverified hypotheses

- **H1. Room subscribe and participant publish are expressible as one moq grant pattern each.** Claim: the moq revision pinned by `native/mjolnir_relay` treats a grant pattern as a prefix covering that path and its children, so D7 needs no extra relay check. Confidence: medium. The current prover used concrete paths (`a/b`), not a wildcard, and `grant_from/1` passes the claim's path strings through. Verification: before any mint code, a fixture token whose publish pattern is only `<participant>` must be able to publish `<participant>/track` and must be refused for `<other>/track`, on both transports, against the pinned crate. If the pattern is exact-only, the mint uses the wildcard syntax that revision documents, and the spec's "covers" wording stays. Synthesis: the act task that names the pattern strings.
