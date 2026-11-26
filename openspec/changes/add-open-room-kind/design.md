# Design: add-open-room-kind

Author: design sub-agent (Opus 5.5), 2026-11-25. Reader next: independent advise (Astra per Duke's 2026-11-25 preference recorded on the bead; the ladder would pick Fable for protocol blast).

## Context

- Room tokens are moq-auth JWTs minted by `Mjolnir.Relay.Mint` with exactly `root`, `publish`, `subscribe`, `iat`, `exp`, `jti`. Root `t/<owner>/<room>`, publish `<participant>/**`, subscribe `**`. Owner is the caller's verified `sub` (living `relay-room-auth`).
- The relay (`native/mjolnir_relay`) verifies with the pinned moq-auth `KeySet::verify`, then `profile` (expiry, issue time, ttl, `root_allowed`), then scopes every path to the root (`path_in_root`, `ext_grant`).
- `root_allowed` requires `t`, a canonical owner, and any further segments that are not empty, `.` or `..` (`lib.rs:50`). It does not care how many segments follow the owner.
- The pinned moq-auth wire `Claims` is `#[serde(default, deny_unknown_fields)]` (`rs/moq-auth/src/wire.rs:21`). The comment at `:47` says why: "Every other claim is refused, since an unknown one may narrow the grant." Only `root`, `put`, `get`, `publish`, `subscribe`, `exp`, `iat`, `nbf`, `jti` are read. `iss` and `sub` are read and dropped. The test `test_claims_refuse_mixed_or_unknown_fields` (`claims.rs:594`) pins this behaviour.
- The spike edge verifies with `mjolnir_relay::assess(token, "", keys, …)`, checks the URL `<room>` against the last root segment, and opens its relay session with the same token (`finding.md`, "The edge").
- `call-e2ee`: protected clients hold a credential Mjolnir never sees. Their context is `mjolnir-call/v1/<owner>/<room>/<label>`, and "this capability SHALL NOT require a deployed relay change". The controller cannot observe that a room is protected. It can only record what the owner declared.
- The add-relay-room-auth lesson: the first contract trusted the caller-supplied `x-owner-id`. Here the kind is an authority input of the same class. It must come from the authenticated owner's request body, never from a header or from a participant.

## D1. Where the kind lives, and why it is the same for every participant

**Choice: the kind is part of the room's address, carried in the signed `root` claim.** Protected: `t/<owner>/<room>` (unchanged). Open: `t/<owner>/~open/<room>`. No component stores a room's kind.

Why `~open`:
- `~` is outside `\A[A-Za-z0-9_-]{1,64}\z`, so `~open` can never be a protected room's name, and no protected root equals or contains `t/<owner>/~open`. Both the relay (`path_in_root`: equal or `root + "/"` prefix) and moq-auth (`strip_prefix`, segment-aligned) match roots by whole segment. So an open root and a protected root never cover each other. A marker drawn from the room alphabet (`open`, `_open`) would collide with a protected room of that name, whose `**` subscribe would then cover the open room.
- `~` is unreserved in RFC 3986, so a WebTransport URL path carries it without percent-encoding. moq-pattern treats only `*` as special (`moq-pattern/src/pattern.rs:84`). moq-auth `path::validate` refuses only an over-long root, a bad `\` escape and an empty segment. End-to-end proof is H1.
- Putting the marker under the owner keeps `root_allowed` true, so the relay needs no change (D2). A different top-level prefix (`o/<owner>/<room>`) would be refused by every deployed relay (`parts[0] != "t"`).
- Protected keeps today's spelling, so the default costs nothing: every live token, every shipped client and the `call-e2ee` context and paths are untouched. Absence of the marker means protected, and this fails closed: a parser that does not recognise the root admits no WebRTC (D3).

How the kind stays the same for every participant: there is no per-room record to diverge. "Room `standup`, open" and "room `standup`, protected" are two rooms. The owner mints each token, and each token names exactly one of them.

What an attacker or a confused client can do under this choice:

| Who | Tries | Result |
|---|---|---|
| The owner, or the owner's app by mistake | Mints `open` for alice and `protected` for bob, both in `standup` | Two rooms. Alice cannot read or publish into bob's room, and the reverse. The call is split, visibly (`kind` and `root` in each response). Protected media is not exposed and the protected room takes no plaintext from alice. |
| A participant who controls the owner's app input (if the app passes `kind` through) | Asks for an open token to inject plaintext or play over WebRTC | Gets a token for the open room only. The protected room is unreachable with it. The same participant could already be denied or admitted by that app. Choosing the kind is the owner app's authority, as choosing the label already is. |
| Another tenant | Mints an open room under someone else's owner | Impossible as before: the root owner is the caller's verified `sub`. `kind` cannot change the owner. |
| Anyone | Sends `x-room-kind: open`, `?kind=open`, or a room segment `~open` | Header and query are ignored. The room segment fails the segment rule (400). |
| A holder of the mint key | Signs any root | Already a living limit (host-wide key). Not widened. |
| A buggy edge | Parses the root loosely | `room_kind` is strict and returns open only for exactly `t/<canonical owner>/~open/<valid room>`. The edge also presents the leg's own token to the relay, so even a wrong admission cannot publish or read outside that token's root (D3). |

Rejected alternatives:

- **The controller remembers each room's kind on first mint** (ETS or Postgres keyed by owner and room, first writer wins). It needs a lifetime (rooms are not stored today, and "room ended" is not observable), it needs restart persistence (`:pg_enabled` is false in tests and best-effort by design contract), and a second controller host needs a shared store. First-mint-wins lets a stale or buggy app mint lock a room to the wrong kind until an unspecified expiry, with no operator surface to clear it. All of that buys protection against the owner contradicting themself, which the address scheme already makes harmless.
- **A new `kind` claim.** Refused by every deployed relay (D2), needs a moq-auth patch, and still needs the store above.
- **Overloading `sub` or `iss`** (read and dropped by moq-auth, so accepted today). It is invisible to the relay, so it gives no namespace separation, and it misuses registered claims. It would still need the store.
- **Inconsistency allowed and made harmless by the edge alone.** If the kind were in a side claim with no namespace split, an open-token holder's plaintext WHIP would land in the same broadcast namespace as protected readers. That is exactly the S7 gap.

The owner's decision says "a signed claim in the room token, set by the owner at mint". This design reads `root` as that claim. The bead's assumptions name "a signed token claim or a root segment minted by the controller". Confirming this reading is an ASK.

## D2. Claim shape and how each verifier treats it

- No new claim. The mint SHALL still set no claim outside the moq-auth set (living text unchanged). The only difference in an open token is the `root` string.
- **Production relay today:** `KeySet::verify` deserialises the same claim names, so nothing unknown is present. `profile` passes: `t`, a canonical owner, and the segments `~open` and `<room>` are neither empty nor `.`/`..`. `assess` with a request path inside the root passes `path_in_root`. `ext_grant` prefixes the root to `<participant>/**` and `**`. Those parse because only `*` is special. **So the deployed relay accepts open tokens with no deploy.** Evidence owed: H2 (a test against the deployed relay commit's verifier). The relay source under `native/mjolnir_relay/src` has no commit after `4d2e599` (the controller release live on 2026-11-23). The last change to `lib.rs` is `c3d27ae`, 2026-11-22. The deployed binary's commit is still to be confirmed by the orchestrator, who has production access.
- **A token without the marker** (every token minted before this change, and every new token with `kind` omitted) is protected. Its bytes are shaped exactly as today: same claim names, same root.
- **Deploy order:** the relay needs nothing, so the only production step is the controller (`deploy.sh --app-only`, hot cutover). Before the controller deploy, an old controller mints only protected tokens, which is correct. After it, a request with no `kind` gets the same token as before, so existing callers and clients see no difference. A new client that asks for `open` gets a root that the live relay already admits. The edge (`.13`) deploys later. Until it does, an open room is just a MoQ room with a different root. Rollback is the controller alone: open tokens already issued stay valid until `exp` (at most the ceiling, 3600 s) and remain harmless, because they name rooms no protected client is in.
- **Old clients:** a client that builds its connect path from the response `root` works for both kinds. A client that hard-codes `t/<owner>/<room>` (the Iroh examples take the path as an argument) works for protected rooms and is simply never handed an open token unless its operator asks for one.

## D3. Who enforces what

- **The edge** (node `.13`) SHALL admit WHIP and WHEP only when `room_kind(root)` is open, and SHALL answer 403 `room_not_open` before any SDP answer otherwise. That covers protected roots and roots that are not room roots, such as an owner-wide `t/<owner>`, which the relay would accept if a key ever signed one. It SHALL open its relay session for that leg with that leg's own room token (the spike already does this), and SHALL hold no relay credential whose root reaches a protected room. Then the relay's root scoping is a second wall: an edge that admitted wrongly still cannot publish or play outside the open root the token names. The edge also checks the URL `<room>` against the root's room segment, as the spike does.
- **The relay** enforces nothing new and reads no kind. It cannot tell a WebRTC-origin publish (the edge is a MoQ client) from a native one, and it has no reason to refuse either kind on MoQ. What keeps the kinds apart is its existing root scoping, which this change relies on and tests with an `~open` root. Is anything lost because the relay does not check the kind? Only if some other bridge holds a wide relay credential. The edge rule above forbids that. A future bridge (recording, HLS) must follow the same rule. That is recorded as a requirement, not left to each node.
- **The mint** enforces only who may choose: the owner, through the body, under `relay:join`.
- **Clients:** protected readers render only authenticated instances (ADR 0017 item 2). That stays the in-room defence against plaintext over MoQ in a protected room, which no server component can detect.

## D4. Can a room change kind?

No. The kind is part of the address. To "switch" a room, the owner mints tokens of the other kind, which name another room, and moves participants there (the page re-joins). Tokens for the old room keep working until their `exp`. There is no revocation, as already listed in the living limits. An owner who opened a room by mistake cannot close it early. They can stop minting for it and wait out at most the token life. Protected to open is a deliberate act with a visible new `kind`. Open to protected cannot leak protected media into the old open room, because protected clients never join it.

## D5. Mint API

- Request: optional JSON body field `kind`, a string, exactly `"open"` or `"protected"`. Omitted means `"protected"`. `null`, any other string (case-sensitive, no trimming), a number, a boolean, a list or an object is 400 `bad_kind` before a signature.
- Refusal order: `kind` is checked right after the `ttl` type, so a malformed body is 400 whether or not the relay is configured, as `ttl` already is: scope, user principal, segments, `ttl` type, **`kind`**, env/ceiling/enabled/host, `ttl` range, owner, key mode and key.
- Source: the request body only. A header (`x-room-kind` or any other), the query string and the path SHALL NOT set or influence it. The route already builds the body from `conn.body_params`. Plug merges query params into `params`, not `body_params`, and the test owes that observation.
- Root: `t/<owner>/<room>` for protected, `t/<owner>/~open/<room>` for open. Publish and subscribe patterns are unchanged and relative to the root.
- Response: the existing keys plus `kind` (`"open"` or `"protected"`, always present). `add-turn-service` separately adds `ice_servers`. The two do not conflict.
- Log: the existing mint line gains `kind=<kind>` (still no token).
- Scope and principal: unchanged, `relay:join` and a user principal. Whether opening a room deserves its own scope is an ASK (recommendation: no; it is the owner's own room, and per-kind cost belongs to metering, `.4`).

## D6. Honest limits

- `protected` in a token is a declaration of what the owner intends, not proof that clients encrypt. A protected room's MoQ client can still publish plaintext. Protected readers ignore it (ADR 0017 item 2), plain MoQ readers can render it, and the relay cannot tell.
- `open` is a declaration too. A client in an open room may encrypt, and its media is then unplayable over WHEP (S7 claim 6 behaviour) and still invisible to the host.
- The `call-e2ee` credential context `mjolnir-call/v1/<owner>/<room>/<label>` does not include the kind. If an owner reuses one credential for "open `standup`" and "protected `standup`", the two rooms derive the same keys and opaque paths. A relay could then move a credential holder's ciphertext between them. That is the same holder's media under the same label, but it is cross-room replay that the context otherwise prevents between distinct room names. Handoff: the browser client should not offer encryption in an open room (ASK), or `call-e2ee` should fold the kind into the context. That is not changed here, because that spec is in flight under its own change.
- Room names are no longer unique per owner across kinds. Metering, roster and TURN usernames that key on `<room>` alone would merge two rooms. See the handoffs.
- No revocation, no kick, host-wide mint key: unchanged living limits.

## Limits to add to the living spec at fold

- "A room's kind is the owner's declaration. Protected does not prove that clients encrypt, and open does not prevent it."
- "An open and a protected room of the same name are two rooms. The `call-e2ee` context does not separate them."

## Handoffs (bullets, not owed here)

- `mjolnir-rurh.13` webrtc-edge: use `room_kind`, answer 403 `room_not_open` for WHIP, WHEP and roster on non-open roots, present the leg's own token to the relay, and own the product test of the refusal.
- `mjolnir-rurh.14` edge-roster: a room is `(owner, kind, room)`, and the room is the last root segment for both kinds.
- `mjolnir-rurh.4` metering: key rooms by root, not by `<room>` alone.
- `add-turn-service`: the call credential username `<expiry>:<class>.<owner>.<room>.<participant>` should distinguish an open room from a protected one of the same name (key by root, or add a kind segment; check that `~` is acceptable in a TURN username).
- `mjolnir-rurh.15` webrtc-room-client and `.5` browser-call-client: build the connect path from the response `root`, show `kind`, and (per ASK) offer no encryption in open rooms.

## Unverified hypotheses

- **H1** (`tilde-root-transports`): a root `t/<owner>/~open/<room>` works end to end. A native WebTransport client and a Chromium WebTransport page connect at that URL path with `?jwt=`. An Iroh client publishes and subscribes at the absolute path `t/<owner>/~open/<room>/<label>`. `ext_grant` yields non-empty publish and subscribe sets (it silently drops a pattern that fails to parse, which would fail closed, not open). Confidence: high (source reading: only `*` is special, and `~` is URL-unreserved). Verification: the relay unit test in tasks plus a laptop run with `wt-session`, `iroh-publish`/`iroh-subscribe` and the spike's Chromium page, with logs saved under `evidence/`. Synthesis path: if `~` fails anywhere, choose another non-alphabet marker that passes all three (candidates `@open`, `+open`), amend D1 and the deltas, and take fresh advise.
- **H2** (`deployed-relay-accepts-open-root`): the relay binary running on production admits an open-room token unchanged. Confidence: high (`root_allowed` source; no relay source commit after `4d2e599`). Verification: the orchestrator records the deployed relay's commit, and a test built from `native/mjolnir_relay` at that commit admits an `~open` fixture token on `assess` and `web_grant` and produces a non-empty `ext_grant`. Synthesis path: if it refuses, the deploy order becomes relay first (`deploy.sh --relay`, with drain) and then the controller, recorded in the deploy ASK.
