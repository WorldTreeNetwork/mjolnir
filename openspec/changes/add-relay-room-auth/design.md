# add-relay-room-auth — design

Auth blast. Banner on the proposal stays PENDING. This amendment answers the send-back in `reviews/2026-11-22-advise.md`.

The relay verifies a moq-auth JWT from `/etc/mjolnir-relay/relay-keys.json` and refuses a root that is not `t/<canonical owner>` or below it (`openspec/changes/add-edge-relay`). WebTransport closes a session at `exp`. Iroh did not, until `Authorization.expires` was set from the token (`105acf0`). This change does not claim that close was already true on both transports before that fix.

## Decisions

**D1. The controller API mints. The gateway does not.**
The mint is a route on the Elixir API, the process that runs as root. It is not the `mjolnir-gateway` process and not a guest. Alternative: a separate mint binary. Rejected because the node says the mint is the Mjolnir API under the existing scope model.

**D2. Scope is `relay:join`, and the route is user-only.**
`Authz.require_scope/2` is necessary and not sufficient. A verified user JWT receives the full scope list in `Mjolnir.API.Auth`, and the operator socket is assigned that same list (`auth.ex` gives `@all_scopes` to the operator principal). Appending `relay:join` therefore gives it to the operator too. The route additionally requires `principal_kind == :user`. The operator, a sites token, and a capability or ceremony principal are refused with 403 before a signature. Alternative: add the scope on the user path only and leave it off `@all_scopes`. Rejected because the operator path copies that list in one assignment, and a later edit that appends to the list would silently grant the operator the mint. The kind check stays the refusal even if the scope leaks onto the operator.

**D3. The owner is the caller's verified `sub`.**
`Mjolnir.Deploy.Owner.resolve/2` is what spawn uses. For a principal other than `"localhost"` it returns that principal and ignores the header. This route never calls it for the operator, because D2 refuses the operator first. For a user it takes `sub` from the verified claims, ignores `x-owner-id`, and ignores a body `owner_id`.

`sub` must be an owner id the relay will accept. `Owner.parse/1` accepts canonical base58 and rejects 64-hex. A legacy 64-hex `sub` is the same 32 bytes (`owner.ex` documents that, and `claim/2` rewrites it). The mint re-encodes that hex to canonical base58 and uses the base58 form in the root. Anything else is 403 before a signature, not a token rooted at a string the relay would refuse. A user who sends another owner's id in the header still receives a token rooted at their own `sub`, or a 403 when their own `sub` is not an owner id. They never receive the other tenant's root.

The earlier draft said the header matches spawn. That was false. Spawn stamps a signed-in caller as their `sub`.

**D4. Private key on the controller, root-only, not in `/etc/mjolnir`.**
The signing key lives at `/var/lib/mjolnir/relay-mint/current.jwk` (mode `0600`, owner root:root). The directory is `0700` root:root. The next key, before the signer switches, is `next.jwk` beside it, same mode. There is no `previous.jwk`. The mint never signs with a retired key, so keeping its private half has no use. The BEAM runs as root and can read these files. The gateway user `mjolnir` cannot. The key is not a deploy secret and not under `/etc/mjolnir`. It is not in `relay-keys.json`: that file is a public verify set.

Each mint reads `current.jwk` from disk and checks the file and its directory: owner root, no group or other write on the directory, no group or other access on the file. A failure is 503 and no signature. A key cached at boot is not used.

**D5. The public half is written by root, on this host, into the file the relay already watches.**
Controller and relay are one host for this node. The mint's installer renames a public-only JWK set into `/etc/mjolnir-relay/relay-keys.json` as root. The relay reloads that file and writes its SHA-256 to `/run/mjolnir-relay/keys.active`, or `invalid`. The gateway user is not in the path. A relay on another machine needs its own root-run copy and the same `keys.active` check. This node does not specify that copy.

First install replaces the file. The set becomes exactly the mint key. An operator fixture key already in the file is removed, not kept beside the mint key. A token signed by the fixture then fails as an unknown key.

**D6. Rooms are not stored. The minter is trusted for every label in its rooms.**
A room exists when a token is minted for it. There is no room table. Participant names are labels the minter chooses, not authenticated identities. The owner can mint a second token for a label that is already in use. Two live sessions may publish as `alice`. That is accepted because the only minter for a tenant is that tenant's account. A different account cannot mint here by presenting the other owner's header. The earlier sentence that "the root would not verify against their header" was false: the header is whatever they send. D3 is the control.

**D7. Path and the exact patterns.**
`t/<owner id>/<room>/<participant>/<rest>`.

- `<owner id>` is the canonical id from D3.
- `<room>` and `<participant>` are one segment each. The whole segment matches `\A[A-Za-z0-9_-]{1,64}\z`. An Elixir `^…$` is not the check: it accepts a trailing newline.
- The token `root` is `t/<owner id>/<room>`.
- `publish` is `["<participant>/**"]`.
- `subscribe` is `["**"]`.

`foo` matches only `foo`. `foo/**` matches `foo` and everything under it. `**` matches every path under the root (`moq-pattern`, pinned moq). A bare `<participant>` would grant one broadcast of that exact name and would refuse `<participant>/track`. The earlier hypothesis that a bare segment is a prefix is withdrawn.

On WebTransport the session is rooted at the token root, so the client publishes `P/track` and subscribes inside the room. On Iroh the relay prefixes the root itself, and the client uses the absolute path `t/<owner>/R/P/track`. Both transports match the same patterns. Dialing a deeper path does not shift them: moq-relay scopes the session to the grant's root.

The relay already rejects a path outside that grant. A token for room R, once admitted, cannot read a broadcast under room S. The test is that read, not a second dial aimed at S.

**D8. Refresh is reconnecting before expiry. In-band AUTH is refused.**
Maximum life stays 3600 seconds. The mint's default is 300 seconds (D12). The client mints the next token and opens the next session before `exp`, then drops the old one. For that moment two sessions may hold the same broadcast path. The relay does not pick a winner. A forced gap after expiry is the failure case, not the plan.

WebTransport can present another token on a live session (`moq-net` AUTH, `Admission::attached`). The earlier draft said no such message exists. That was false. The decider now refuses `attached()` (`web_grant` returns `in-band token`). A test first showed the second token admitted, then passed once the refusal was added. This node does not adopt in-band refresh. Iroh's handler admits once per connection and has no in-band AUTH. An Iroh client refreshes the same way: a new session before `exp`. The relay closes either session when its own token expires.

Alternative: adopt in-band re-auth on WebTransport so the session survives the first `exp`. Rejected for this node. It is not available on Iroh, the pinned JavaScript client was not shown to present it, and the refusal is already the code.

**D9. Routine rotation revokes nothing early.**
Every mint key has a unique `kid`. Every minted token carries that `kid`. At the pinned revision a token with no `kid` verifies only when the set holds exactly one key and that key has no `kid`, and a duplicate `kid` makes the set fail to parse. The overlap set holds two keys, so a missing `kid` would refuse every token.

The operator, as root, on the controller host:

1. Generate the next EdDSA key with a new `kid`. Write it to `next.jwk` (`0600` root:root, via rename). Leave `current.jwk` in place. The mint still signs with `current.jwk`.
2. Build the public set `{current, next}`. Validate it with the relay's own loader (public keys only, EdDSA or ES256, unique `kid`s, file shape the unit accepts). Do not rename yet.
3. Rename that set into `/etc/mjolnir-relay/relay-keys.json`. Wait until `/run/mjolnir-relay/keys.active` equals that file's SHA-256. If it reads `invalid`, or it does not change within ten seconds, rename the previous set back and exit non-zero. The signer has not changed.
4. Only then rename `next.jwk` onto `current.jwk`. New mints sign with the new key. Tokens already signed by the old key still verify, because its public half is in the set.
5. After the longest life the mint will issue (3600 seconds) plus 60 seconds, rename a public set of the new key only, confirm `keys.active` again the same way, and delete nothing that can still sign: the old private half was never kept.

Routine rotation is key hygiene. It shortens no token and removes no participant. A token signed by the old key keeps working until its own `exp`, and its holder may reconnect until then. A session already admitted stays up until that `exp`, including after step 5.

The mint is never observed signing with a key that is absent from the set `keys.active` has confirmed.

**D10. Emergency revoke is a different procedure, and it is host-wide.**
Replace the public set at once with one new key. Do not publish the old public key. Confirm `keys.active`, then switch `current.jwk` to that new key. Restart `mjolnir-relay` so live sessions end. Every call of every tenant on the host drops. New sessions need a token signed by the new key. A compromised mint key uses this procedure. Routine overlap would keep the stolen key trusted until the old tokens expire.

No `/api` route accepts a private key or a public key. Both procedures are `scripts/relay-mint-key.sh` as root.

**D11. One signing key family is still one relay.**
`add-edge-relay` says a signing key is trusted by exactly one `:relay_host`. Rotation replaces the key on this host's file only. The mint returns `relay_host` from `MJOLNIR_RELAY_HOST`. The token dialect has no audience claim, and the mint must not add a default `aud`. A token presented to a different relay fails as an unknown key.

**D12. Default life is 300 seconds. The caller may ask for less or more, up to 3600.**
With no kick, the default is the real bound on a removed participant. Alternative: default to the maximum, 3600 seconds. That is one line simpler and leaves a removed participant in the room for up to an hour, reconnecting the whole time. The short default makes the owner mint again, or hand a new bearer to a guest, when the call should continue. The client is expected to reconnect before `exp`, so 300 seconds is a mint interval, not a media gap. The relay's `MJOLNIR_RELAY_TOKEN_MAX_TTL` and the mint's ceiling are the same number. If the mint's ceiling were larger, every token would be refused. The mint reads the relay's ceiling and will not issue above it.

The response is the token, its expiry, its root, its publish pattern, its subscribe pattern, and `relay_host`. No private key. Each token has a `jti`. The mint logs the caller's `sub`, the owner, the room, the participant label, the `jti`, and `exp`. It does not log the token. The WebTransport token rides in `?jwt=`. That query is not written to a log by this work.

Claims are only those moq-auth accepts: `root`, `publish`, `subscribe`, `exp`, `iat`, `nbf`, `jti`, `iss`, `sub`. `exp` and `iat` are integers. Algorithm is EdDSA. Header `kid` is the signing key's `kid`. No `aud`.

**D13. Disabled, missing key, and bad key mode are 503.**
No `current.jwk`, a key file the mode check rejects, `MJOLNIR_RELAY_ENABLED` not `true`, or `MJOLNIR_RELAY_HOST` unset: 503 and no signature. The earlier "Off" case that still returned a token is withdrawn.

## Unverified hypotheses

- **H-mint. An Elixir signer can emit this token.** Claim: a token produced by the mint verifies under `KeySet::verify` at moq rev `4a6f522`, with `kid`, EdDSA, integer `exp` and `iat`, and no `aud`. Confidence: medium. Elixir JWT libraries often set `aud` or string timestamps, and moq-auth refuses an unknown claim. Verification: the cross-language fixture in the tasks, before the route is wired to clients. Kill condition: if the fixture does not verify, the mint does not ship on a different claim shape. Synthesis: that fixture task.
