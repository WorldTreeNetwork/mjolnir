# Design: add-open-room-kind (revision 2, dedicated claim)

Author: design sub-agent (Opus 5.5), 2026-11-25. Supersedes revision 1 (`1552e85`, kind in the root path), which advise sent back (`reviews/2026-11-25-advise.md`). The owner then chose a dedicated signed claim with a relay-first rollout: one room name is one room with one kind. Facts: [`notes/claim-option.md`](notes/claim-option.md). Spike: [`spikes/claim-route.md`](spikes/claim-route.md). Next reader: the same Astra reviewer.

## Context

- Room tokens are moq-auth JWTs minted by `Mjolnir.Relay.Mint` (Elixir, JOSE): `root` `t/<owner>/<room>`, `publish` `<participant>/**`, `subscribe` `**`, `iat`, `exp`, `jti`. Owner is the verified `sub` (living `relay-room-auth`).
- The relay verifies with `KeySet::verify` (`lib.rs:233`), then `profile`, path scoping and `grant_from`. WebTransport uses it through `spawn_web_decider`, and Iroh through `TokenPolicy` (`lib.rs:340-375`).
- The pinned moq-auth refuses any claim outside `root`, `put`, `get`, `publish`, `subscribe`, `exp`, `iat`, `nbf`, `jti`, `iss`, `sub` (`wire.rs:21,47`; test `claims.rs:594`). Today's production relay (`ca61ceb`, the same source as HEAD) refuses every token carrying `kind` (spike C1).
- The controller cannot observe that a room is protected: protected clients hold a credential Mjolnir never sees (ADR 0017). The kind is the owner's declaration.

## D1. How the relay accepts the claim at the pin: route (b)

Options in order of preference, from source and spike:

- **(a) Something the pinned decoder already tolerates.** Proven to exist (spike C7): today's verifier admits, and drops, a `sub` or `iss` string and a custom protected-header parameter. **Not chosen.** None is a dedicated claim, which is what the owner chose. `sub` and `iss` are registered claims with other meanings. A header parameter sits outside the claim set every moq verifier models. And an old reader admits such a token while silently ignoring the kind, so nothing forces the readers to be upgraded first.
- **(b) The relay verifies the JWT itself and hands moq-auth the rest. Chosen.** moq-auth signs and verifies over the exact token bytes, so it cannot be handed a stripped token. It can be handed a stripped payload, because the strict decoder is public: `moq_auth::Claims: Deserialize` goes through the same `deny_unknown_fields` wire struct. The relay's `room_token::verify`:
  1. decodes the header; requires `kid`; finds the key with `KeySet::find`; requires the header `alg` to equal the key's algorithm (EdDSA or ES256 only, as the loader already enforces); requires the key to permit Verify; refuses a key with a scope (mint keys have none, and refusing is stricter than re-implementing scope);
  2. verifies the signature with `jsonwebtoken::decode` and the `Validation` moq-auth builds (`key.rs:623-633`: no required spec claims, jsonwebtoken checks no `exp`/`nbf`/`aud`), with the rind provider moq-auth installs (`crypto.rs:5-11`);
  3. reads the payload as a JSON object, refusing a repeated member (as serde's derive does inside moq-auth) and an array;
  4. removes `kind` and accepts absent (protected), exactly `"open"`, or exactly `"protected"`, refusing anything else;
  5. decodes the rest with `moq_auth::Claims`, so any other unknown claim is still refused, then calls `Claims::validate`;
  6. refuses `exp <= now` and `nbf > now` on `kio::clock::wall()` (moq-auth `validate_times`), then runs the relay's existing `profile`, path check and `grant_from` unchanged.

  `assess` returns the kind with the grant. `web_grant` and `TokenPolicy` call `assess`, so both transports change at one call site. The edge (`.13`) calls the same function. It lives in `native/mjolnir_relay/src/room_token.rs` and is public; `.13` decides whether to split it into a small crate (the spike finding recommends one).
  Cost: Mjolnir, not moq-auth, owns signature verification for room tokens. Parity is kept by a differential test. For every token case in moq-auth's shared corpus (`rs/moq-auth/tests/corpus.json`, also replayed by the JS parser) with no `kind`, route (b) and `KeySet::verify` must agree. The one documented exception is that route (b) refuses a token with no `kid` (moq-auth admits one against a single kid-less key, and the relay's key loader already refuses kid-less keys). No crate is added: jsonwebtoken 11.1.0 and rind-jsonwebtoken are already in the relay lockfile through moq-auth (spike C8). The moq pin and moq-auth are untouched, so nothing changes for the E2EE work or the edge's vendored `moq-webrtc`.
- **(c) A carried moq-auth patch.** It works and is not chosen, because (b) needs no carried code. How it would be carried, and its upstream story: `notes/claim-option.md` (a). In short, `native/vendor/moq-auth` from `4a6f522` with an optional field, its manifest rewritten off `workspace = true`, and `[patch."https://github.com/moq-dev/moq"]` in every graph (relay, edge, any agreeing spike), so that each resolves one moq-auth, moq-relay's own dependency included. It must be carried on every pin move, and the field is too Mjolnir-specific to go upstream.

If advise finds (b)'s owned verifier riskier than a carried patch, (c) is the fallback. The spike harness already has both decoders' behaviour on record.

## D2. The claim

- Name `kind`, a top-level JWT claim. Values `"open"` and `"protected"`. Absent means protected.
- The mint writes `"kind": "open"` in open tokens and **writes no `kind` in protected tokens**. So a protected token is byte-shaped as today's: it verifies on an old relay, it survives a relay rollback, and every token minted before this change already means protected. The verifier accepts an explicit `"protected"` for forward compatibility; the mint never emits it.
- Authority: the verified owner at mint, from the JSON body field `kind`. A header (including `x-room-kind`), the query string and the path never set it. The router passes `conn.body_params` only (`router.ex:249-253`); Plug keeps query parameters out of `body_params`, and a test owes that observation. A participant never sets the kind. Only the owner's mint authority does, and an owner app that forwards participant input is exercising that authority.

## D3. The durable room-kind record

- **Where:** `/var/lib/mjolnir/relay-rooms/`, a new directory, root-owned, mode `0700`; files `0600`. The controller (Elixir) runs as root, and the gateway user cannot read it. Not `/var/lib/mjolnir/relay-mint`: that directory is the signing key's alone, under `relay-mint-key.sh` and its flock, and its contract is about key material. Not `/etc/mjolnir-relay`: that is the relay's root-owned configuration, not controller state. Not Postgres: `:pg_enabled` is optional, and by contract Postgres holds only rebuildable indexes, while this record is primary state.
- **Key and file:** `(owner, room)` → `<dir>/<owner>/<lowercase hex of the room name>.json`. Hex keeps case-distinct room names distinct on a case-insensitive test filesystem. Content: `{"v":1,"owner":…,"room":…,"kind":…,"created":<unix>,"last_exp":<unix>}`.
- **Process:** `Mjolnir.Relay.RoomKinds`, a GenServer under `Mjolnir.Supervisor`, serialises every decision. Disk is the truth; any in-memory state is a cache. A decision is `claim(owner, room, kind, exp)`:
  - no record, or (if reuse is allowed, ASK) a record with `last_exp <= now` → write a new record with this kind and `last_exp = exp`;
  - a live record (`last_exp > now`) of the same kind → write it with `last_exp = max(last_exp, exp)`;
  - a live record of the other kind → **409 `room_kind_conflict`**, nothing written, no token signed;
  - a record that cannot be read or parsed, or a write that fails (a full disk, for example) → 503 `relay_unavailable`, no token signed. It fails closed and logs the path, never the token.
  The write is tmp, fsync, rename, then fsync the directory, as `Mjolnir.StateStore` writes. The decision runs after every other check and **before** signing. A crash after the write and before the signature leaves a record whose life covers a token that was never issued, which is harmless. A crash cannot leave an issued token unrecorded.
- **Atomicity:** one process per BEAM node serialises concurrent first mints. Exactly one wins, and the other gets 409 if it asked for the other kind or the same record if it asked for the same kind. A hot cutover loads new beams into the same node and never runs two controllers on one host. A restart re-reads disk.
- **Lifetime and reuse:** a room is live while any token minted for it can still be presented, that is, until its latest `exp` (at most the ceiling after the last mint). After that, no token of the old kind can be presented, so "one name, one kind" holds at every instant even if the name takes the other kind. Reuse is the owner's ASK. Recommended: allow it after `last_exp`. Alternatives: never, or an explicit owner release endpoint. Records past `last_exp` are pruned after a day, or kept forever if reuse is refused.
- **Second host:** a room is effectively `(relay host, owner, name)`. Each relay host has its own controller and mint key today. A second controller minting for one relay would need a shared store, such as Postgres with a unique key on `(owner, room)` or a lease. That is out of scope and a handoff.
- **Backup:** the directory joins the existing B2 timer's sources (task). If the store is lost, the exposure lasts at most the ceiling: a name could take the other kind while tokens of the first are live. That is recorded as a limit.

## D4. Enforcement

- **Relay:** it reads the claim (D1) and refuses what it can tell from the token alone: a malformed `kind`, a repeated member, any other unknown claim, as today. It admits both kinds under the same rules. Nothing in a token or a session tells it whether a publish originates from WebRTC (the edge is an ordinary MoQ client), so it cannot refuse a WebRTC publish into a protected room. It also cannot consult the room record: it holds no controller state and should not.
- **Edge (owed by `.13`):** before opening any relay session or answering SDP, it verifies the token with `room_token::verify`, requires the verified kind to be open, checks the URL room against the verified root's room segment, and checks the operation against the grant. It reaches the relay only with that leg's own token (the `.13` steer: "the edge holds no authority of its own"). Otherwise it answers 403 `room_not_open`. It refuses a tenant-wide root (`t/<owner>`) even when the kind is open.
- **Residual exposure with a buggy edge:** a bug that admitted a WHIP with a protected participant's valid token would publish plaintext, within that token's grant, into the protected room. The relay admits it, because the token permits that publish. Authenticating protected readers discard it (ADR 0017 item 2); the host or a plain subscriber can read it (S7 observed both). A WHEP of a protected broadcast fails structurally (no readable catalog). Closing this residual needs an authenticated edge identity and a relay policy ("sessions from the edge must carry `kind: open`"). That is recorded, not built (ASK 6).

## D5. Rollout and rollback

Order, each step an owner gate where it touches production:
1. **Relay**, `deploy.sh --relay` with the route (b) verifier. This restarts `mjolnir-relay` and drains live sessions for `MJOLNIR_RELAY_DRAIN_SECONDS` (default 30). Owner gate. Clients reconnect with today's tokens, which carry no `kind` and verify unchanged.
2. **Edge** (`.13`) ships with the same verifier from its first release.
3. **Controller**, `deploy.sh --app-only` (hot cutover): body `kind`, the record store, `kind` in the response. Open issuance stays off.
4. **Switch:** `MJOLNIR_RELAY_OPEN_ROOMS=true` in `/etc/mjolnir-relay/relay.env` (root-owned, read by the mint on every call, beside `MJOLNIR_RELAY_ENABLED`). It is set only after step 1 is confirmed on that host (the live relay admits an open token). It is absent or anything but `true`: `kind: "open"` → 503 `open_rooms_unavailable`. Protected mints, including explicit `"protected"`, are unaffected and still recorded.

What each old reader or writer does:
- **An old relay given an open token** refuses it (`refused: unauthorized`, spike C1). The switch makes that impossible in normal operation; if it happens, open rooms fail closed and protected rooms are untouched.
- **Relay rollback with open tokens live:** turn the switch off, wait out the ceiling, then roll back. Otherwise those sessions fail on reconnect.
- **Controller rollback:** the old mint ignores `kind` and the store. A renewal that asks for open gets a protected, claim-free token for a room recorded open, which breaks "one name, one kind" for the rollback window. Fence: turn the switch off and wait out the ceiling before rolling back. Client rule (D7): a response without `kind`, or with a kind other than the one asked for, fails visibly. The store survives untouched, and its records are valid on roll-forward.

## D6. Mint API

- Request: optional body `kind`, exactly `"open"` or `"protected"`. Omitted means protected. `null`, other strings (compared exactly), numbers, booleans, lists and objects → 400 `bad_kind`.
- Check order, first failure answers: scope `relay:join` (403 `insufficient_scope`), user principal (403 `forbidden`), segments (400 `bad_segment`), `ttl` type (400 `bad_ttl`), `kind` (400 `bad_kind`), env file, ceiling, enabled and host (503 `relay_unavailable`), open switch when `kind` is open (503 `open_rooms_unavailable`), `ttl` range (400 `bad_ttl`), owner (403 `forbidden`), key mode and key (503 `relay_unavailable`), room record (409 `room_kind_conflict`, or 503 `relay_unavailable` if the store fails), then sign.
- Response: the existing keys plus `kind`, always present (`"open"` or `"protected"`). `Cache-Control: no-store`. `add-turn-service` adds `ice_servers` separately.
- Log: the existing line plus `kind=<open|protected>`, the validated value only. Never the raw request value, never the token. A conflict is logged with owner, room, the requested and recorded kinds, and no `jti` (nothing was signed).
- Scope and principal unchanged. A distinct scope for open rooms is ASK 4.

## D7. Clients and E2EE (handoffs to `.15`, `.5` and `add-call-e2ee`)

- A client that asked for a kind proceeds only if the response's `kind` equals it. A missing `kind` (an old controller) or a different kind is a visible join error, before it connects, publishes, or imports or uses a credential. Renewals check it again on every response.
- A protected content credential is accepted and used only on a protected join (response `kind: "protected"`). On an open join the client refuses to import or use a protected credential and never falls back to sending plaintext under a protected invitation. That holds for every supported client, including renewals.
- With one name one kind, two simultaneous rooms can no longer share a credential context. Across time, reuse after expiry (ASK 2) could put an open room where a protected one was. The client rule above prevents a protected credential from being used there. Binding the kind into the `call-e2ee` context (`mjolnir-call/v1/<owner>/<room>/<label>`), with a version bump and cross-kind vectors, is a handoff to `add-call-e2ee` and is not built here.

## D8. Honest limits

- The kind is the owner's declaration. Protected does not prove that clients encrypt, and open does not stop a client from encrypting (its media is then unplayable over WHEP).
- A tenant-wide token, rooted at `t/<owner>`, reaches every room of that owner whatever its kind. The mint never issues one; a holder of the mint key can. Isolation by kind is a property of room-mint tokens only.
- The relay cannot tell WebRTC-origin media, and the edge is the only enforcement point for "no WebRTC in a protected room" (D4 residual).
- A lost room store exposes at most one token ceiling. A second controller per relay is unsupported.
- No revocation and no kick, as today.

## Handoffs (bullets, not owed here)

- `mjolnir-rurh.13` webrtc-edge: D4 edge rules, the use of `room_token::verify`, 403 `room_not_open` before SDP or a relay session, and the product scenarios "WebRTC into a protected room" and "WebRTC into an open room" (moved out of this delta).
- `mjolnir-rurh.15` webrtc-room-client and `.5` browser-call-client: the D7 client rules, showing the kind, a specific join error on a kind mismatch or conflict, and the old-controller fixture from tasks.
- `add-call-e2ee`: a versioned room identity including the kind in the credential context, with refusal of incompatible versions and cross-kind vectors, before any encrypted open-room path is enabled.
- `mjolnir-rurh.14` roster: membership and visibility keyed by `(relay host, owner, room)` with the kind shown; a roster is never served across kinds.
- `mjolnir-rurh.4` metering: record the verified kind with each session; quotas and charges keyed by room identity plus kind across reuse.
- `add-turn-service`: the call credential username needs no kind while one name has one live kind. If reuse is allowed, attribution across reuse should key on the room record's `created` as well as the name, or accept aggregate accounting explicitly.

## Unverified hypotheses

- **H-parity** (`route-b-corpus-parity`): for every case in moq-auth's `tests/corpus.json` with no `kind`, route (b) and `KeySet::verify` agree, except kid-less tokens. Confidence: medium-high (the spike covered 19 cases, not the corpus). Verification: the differential test in tasks. Synthesis path: each disagreement is fixed in route (b) or listed as an intentional stricter refusal; any looser acceptance blocks act and reopens (c).
- **H-iroh** (`claim-on-iroh`): an Iroh client admitted with an open token publishes and subscribes, and a production `TokenPolicy` refuses the same token. Confidence: high (same `assess` call site). Verification: a live harness run, with `iroh-publish`/`iroh-subscribe` rebuilt.
- **H-chromium** (`claim-on-chromium-wt`): a Chromium WebTransport session (`@moq/net` from the pinned JS tree, `serverCertificateHashes`) with an open token transfers data through the route (b) relay, and is refused by the production decider. Confidence: high. Verification: a harness page plus a Playwright driver, with logs under `spikes/`.
