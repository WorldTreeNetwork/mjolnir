# add-relay-room-auth — design

Auth blast. Banner on the proposal stays PENDING. This amendment answers the send-back in `reviews/2026-11-22-advise.md`.

The relay verifies a moq-auth JWT from `/etc/mjolnir-relay/relay-keys.json` and refuses a root that is not `t/<canonical owner>` or below it (`openspec/specs/edge-relay/spec.md`, archived change `openspec/changes/archive/2026-11-23-add-edge-relay`). WebTransport closes a session at `exp`. Iroh did not, until `Authorization.expires` was set from the token (`105acf0`). This change does not claim that close was already true on both transports before that fix.

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
Maximum life stays 3600 seconds. The mint's default is that ceiling (D12). The client mints the next token and opens the next session before `exp`, then drops the old one. For that moment two sessions may hold the same broadcast path. The relay does not pick a winner. A forced gap after expiry is the failure case, not the plan.

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
Replace the public set at once with one new key. Do not publish the old public key. Delete `next.jwk` if a routine rotation was in flight, so that rotation cannot rename it onto `current.jwk` afterwards. Wait for `keys.active`. On `invalid`, or if it does not change within ten seconds, leave the new set in place. Do not restore the previous set. That restore is the routine path only. An emergency restore would put the stolen key back while the relay is slow or down. Still restart the relay. Exit non-zero when confirmation failed, and zero when it succeeded. Then switch `current.jwk` to the new key only if confirmation succeeded. If it failed, the new public key is what the relay will load when it is up, and the operator finishes the signer by re-running the script. The script must not sign with a missing private key.

A restart sends SIGTERM. The process drains for the `MJOLNIR_RELAY_DRAIN_SECONDS` it loaded at start (default 30) and then stops (`drain_then_stop`). This node does not add a control to shorten that drain. A live session on a stolen-key token survives the drain. New sessions are refused once the new set is loaded, which is the one-second key poll, or at the restart if the process is already down.

The mint key is host-wide. Whoever holds `current.jwk` can sign a root under any tenant.

No `/api` route accepts a private key or a public key. Both procedures are `scripts/relay-mint-key.sh` as root. One `flock` covers routine rotation, emergency revoke, and first install.

**D11. One signing key family is still one relay.**
`add-edge-relay` says a signing key is trusted by exactly one `:relay_host`. Rotation replaces the key on this host's file only. The mint returns `relay_host` from `MJOLNIR_RELAY_HOST`. The token dialect has no audience claim, and the mint must not add a default `aud`. A token presented to a different relay fails as an unknown key.

**D12. Default life is the ceiling, 3600 seconds unless `MJOLNIR_RELAY_TOKEN_MAX_TTL` is lower.**
A five-minute default ends every call every five minutes: when a participant reconnects, a subscriber that does not resubscribe loses that participant's media. The handoff measurement recorded that hole. Resubscribe-on-announce in the client is a precondition for a call longer than one token, and for returning to a short default. A guest still cannot mint. The token the owner handed them lasts until its own `exp`.

The ceiling is `MJOLNIR_RELAY_TOKEN_MAX_TTL` in `/etc/mjolnir-relay/relay.env`, default 3600 when the line is absent. The mint reads that file at each call. It does not read `MJOLNIR_RELAY_ENABLED`, `MJOLNIR_RELAY_HOST`, or the ceiling from the controller environment or from `config/config.exs`. Those three values have one source, the relay env file, which is `0640` root and readable by the root BEAM. Enabled other than `true`, or host unset, is 503. A `ttl` above the ceiling is 400 before a signature.

`ttl` is a JSON integer in the body, key `ttl`. Omitted means the ceiling. `0`, a negative, a value above the ceiling, a string, and a float are 400 before a signature.

The response is JSON: `token`, `expires` (unix seconds), `root`, `publish` (one string), `subscribe` (one string), `relay_host`. `Cache-Control: no-store`. No private key. Each token has a `jti` of 22 base64url characters from 128 random bits (ASCII graphic, 1 to 128). The mint logs the caller's `sub`, the owner, the room, the participant label, the `jti`, and `exp`, and not the token. The WebTransport token rides in `?jwt=`. This work does not log that query. Acceptance greps the relay journal for the token string.

Claims are only those moq-auth accepts: `root`, `publish`, `subscribe`, `exp`, `iat`, `nbf`, `jti`, `iss`, `sub`. `exp` and `iat` are integers. Algorithm is EdDSA. Header `kid` is the signing key's `kid`. No `aud`.

Opening the next session before `exp` is `call-client`'s obligation. This node does not promise a seamless call. Two sessions holding one publish path is hypothesis H-handoff.

The response is the token, its expiry, its root, its publish pattern, its subscribe pattern, and `relay_host`. No private key. Each token has a `jti`. The mint logs the caller's `sub`, the owner, the room, the participant label, the `jti`, and `exp`. It does not log the token. The WebTransport token rides in `?jwt=`. That query is not written to a log by this work.

Claims are only those moq-auth accepts: `root`, `publish`, `subscribe`, `exp`, `iat`, `nbf`, `jti`, `iss`, `sub`. `exp` and `iat` are integers. Algorithm is EdDSA. Header `kid` is the signing key's `kid`. No `aud`.

**D13. Disabled, missing key, and bad key mode are 503.**
No `current.jwk`, a key file the mode check rejects, relay env missing, `MJOLNIR_RELAY_ENABLED` other than `true`, or `MJOLNIR_RELAY_HOST` unset, all read from `/etc/mjolnir-relay/relay.env`: 503 and no signature. The earlier "Off" case that still returned a token is withdrawn. The mode check takes an injectable uid and path so `mix test` can run it without root. The relay's own check still requires uid 0. Rotation tests that call the relay loader run as root on the laptop.

**D14. Rotation state, lock, and the validator.**
`scripts/relay-mint-key.sh` takes `flock` on `/var/lib/mjolnir/relay-mint/rotation.lock` for routine rotation, emergency revoke, and first install.

Step 5 of routine rotation is a second invocation, `relay-mint-key.sh finish`, not a sleep inside the first process. The first invocation writes `/var/lib/mjolnir/relay-mint/rotation.json` (mode `0600` root) with the new `kid`, the unix time step 5 may run (`now + ceiling + 60`), and the hash of the two-key set. `finish` refuses to drop the old public key before that time. A reboot does not lose the file. A second routine rotation while that file names an unfinished overlap exits non-zero and keeps the oldest public key in the set.

First install, when `current.jwk` is absent: build the public set of the new key only, validate it, rename it into `relay-keys.json`, confirm `keys.active`, and only then write `current.jwk`. If the relay is not running, `keys.active` does not change. The script exits non-zero, leaves the new public set in place, and does not write `current.jwk`. The operator starts the relay and runs the script again.

The validator is `mjolnir-relay --check-keys <path>`. It loads the file with `load_verify_keys`, and it also rejects a key whose algorithm is not EdDSA or ES256 and a key with no `kid` or a duplicate `kid`. The loader's algorithm loop is empty today, so the script checks algorithm and `kid` itself before it calls `--check-keys`. `kid` matches `\A[A-Za-z0-9_-]{1,128}\z` (`moq-auth` `key_id.rs`). The script draws 128 random bits and encodes them base64url, which fits that alphabet. A `kid` with `:` is refused before the set is published.

**D15. The owner rule, byte for byte.**
No trim. The `sub` must equal its canonical re-encode. Legacy hex is `\A[0-9a-f]{64}\z` (lowercase, whole string). Uppercase hex, hex plus a newline, padded base58, a 31-byte id, and a non-canonical base58 spelling are 403. A hex `sub` and the base58 of the same 32 bytes are one owner. `Owner.parse/1` trims and is not this check. `claim/2` only compares. A new public function does the decode. `decode_legacy_hex` stays private.

**D16. The WebTransport decider that ships is the one tests call.**
`spawn_decider` moves into the library. `tests/webtransport.rs` uses it. The in-band refusal has an integration test: the session stays up and its grant does not change. S8 runs against that decider.

## Unverified hypotheses

- **H-mint. An Elixir signer can emit this token.** Claim: a token produced by the mint verifies under `KeySet::verify` at moq rev `4a6f522`, with `kid`, EdDSA, integer `exp` and `iat`, and no `aud`. Confidence: medium. Verification: the cross-language fixture, before the route is wired to clients. Kill condition: if the fixture does not verify, the mint does not ship on a different claim shape.
- **H-handoff. A subscriber keeps receiving across a publisher's make-before-break.** Claim: on WebTransport and on Iroh, a subscriber of one path still receives media when the publisher opens a second session on that path before dropping the first. moq-net tells subscribers `Restart` when a second publisher appears, so the handoff is visible. Confidence: low. This node does not promise a seamless call. Verification: one test per transport. Kill condition: if either transport stops delivering and does not resume without a new subscribe, the notes say so and `call-client` must resubscribe. The mint still ships.
