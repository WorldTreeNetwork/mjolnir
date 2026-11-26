# add-open-room-kind — design (path trial)

Revision 3. The claim design is not the contract. Its notes and spike stay as evidence of what this trial is not doing.

## D1 Classifier

One function, shared later by the edge and by tests. Input is the verified token root, the original string, not a URL.

Split on the literal character `/`. No percent-decoding, no `+` to space, no dot-segment removal, no case-folding, no Unicode normalization.

| Result | Shape |
|---|---|
| `protected` | exactly 3 segments: `t`, a canonical 32-byte base58 owner, a room matching `[A-Za-z0-9_-]{1,64}` |
| `open` | exactly 4 segments: `t`, that owner, the exact segment `~open`, that room |
| `invalid` | everything else |

`invalid` includes the owner alone (`t/<owner>`), extra segments, empty segments, `.`, `..`, `%7Eopen`, `%257Eopen`, `~Open`, `~~open`, a room outside the alphabet, and a non-canonical owner. The relay does not use this function. It keeps `root_allowed` and `path_in_root`.

## D2 Mint

Body field only. Omitted `kind` is `protected`. `"open"` and `"protected"` are the only accepted strings, compared exactly. `null`, numbers, booleans, lists, objects, and any other string, including `"Open"` and `"open "`, are 400 `bad_kind` before a signature.

Check order, first failure wins: scope `relay:join` (403), user principal (403), room and participant segments (400 `bad_segment`), `ttl` type (400 `bad_ttl`), `kind` (400 `bad_kind`), env and ceiling (503 `relay_unavailable`), `ttl` range (400 `bad_ttl`), owner (403), key mode and key (503). There is no room record and no open-room switch. The current relay admits the open root (`root_allowed` is true; live spike admitted it).

Protected root: `t/<owner>/<room>`. Open root: `t/<owner>/~open/<room>`. Publish and subscribe patterns are unchanged (`<participant>/**` and `**`). Claim names on the token stay `exp`, `iat`, `jti`, `publish`, `root`, `subscribe`. The response adds `kind` (`open` or `protected`) and returns that root. `Cache-Control: no-store`. The log line adds the validated kind and does not log the token or the raw `kind` value.

A header or query `kind` is not read. Two concurrent mints of the two kinds both succeed. They sign different roots.

## D3 What the relay already does

Ordinary room tokens are confined by whole segments. A subscribe `**` is under the signed root, so it does not cross from `t/<owner>/<room>` to `t/<owner>/~open/<room>`. The live spike's native WebTransport sessions showed that: each root received its own marker broadcast, and the other root's session was `unauthorized`. Encoded marker paths, sent without prior decoding, were refused. A tenant-wide token rooted at `t/<owner>` was admitted on both URLs. That last fact is the isolation limit. The edge must refuse any verified root the classifier does not call `open`, including a wide root presented with an open-looking URL.

Iroh uses absolute paths. With the publisher ready first, each own-root read received its marker (`PAIR-OPEN`, `PAIR-PROT`). A cross-root `Node::subscribe` did not resolve inside 6 seconds and did not return `unroutable`. See `spikes/path/finding.md`. That wait is not a reason to invent a relay change in this trial.

## D4 Edge handoff (not built)

`.13` does not stop at `KeySet::verify`. One decision uses one trust snapshot: the key set copied for that call, the same snapshot `TokenPolicy::decide` passes to `assess` (`native/mjolnir_relay/src/lib.rs`). On that snapshot the admission operation is, in order: token present, `KeySet` verification, `profile` (required `iat` and `exp`, TTL against the ceiling, future-`iat` refusal, root present and shaped), session-path containment when the session path is non-empty, and `grant_from` validation. It returns the original authenticated root and the validated grant. A future-`iat` token that verifies and then fails `profile` is a refusal. The pure classifier runs only on that returned root. It is not a second verifier.

That whole admission finishes before a relay connection, a relay publish or subscribe, or an SDP answer. At grant expiry the leg tears down before any further relay or SDP side effect. The edge has no standing relay credential. The leg uses the token just admitted.

The expected full root comes from the invitation or join context, not from the token being checked. On initial join, credential replacement, and renewal, both kinds require exact equality with the authenticated root. Any response `root` or `kind` is compared with that same authenticated identity. A route that already carries an owner is compared too. A route that has only a room name derives the owner from the admitted root and carries `t/<owner>/~open/<room>` or `t/<owner>/<room>` from then on. Wrong owner, wrong room, the sibling kind, and a response that disagrees with the token are refused before the credential is stored or media starts. The refusal names the effective kind and which check failed. A protected refusal is distinct from a bad token. A wide root, a protected root on an open join, and `invalid` are refused. Verified class for an open WebRTC join is `open`. The URL room segment equals the root's room segment, literally. The grant covers the operation.

Residual, accepted: the relay cannot tell a WebRTC bridge from any other client. With a valid protected publish token it will accept a publish into that protected room. Host-readable subscribers can see that plaintext. Authenticating readers discard it. Independent relay enforcement would need an authenticated edge identity and a relay policy, which this trial does not add.

## D5 Identity handoffs (not built)

The full root is the room identity.

These are preparation and release obligations. Their implementation stays on the owning node. Plaintext open MoQ does not wait on an E2EE migration. Encrypted open does not ship on the current owner/name/label context.

- **Clients (`.15`), before the first open issuance.** An explicit open join, replacement, or renewal fails visibly when the response has no `kind: "open"` or the root is not exactly `t/<owner>/~open/<room>`. It does not reconnect, publish, or import the credential. A protected credential is imported only when the join's verified class is `protected`, including renewals. No plaintext fallback under a protected invitation. The release gate includes that check and the rollback case: the old mint's body `{"kind":"open"}` has no response `kind` and root `t/<owner>/<room>`.
- **`call-e2ee`, before any encrypted open room.** Protected-only E2EE stays on its current context. Encrypted open requires a versioned KDF and invite that bind the full root, refuse an incompatible version, and fail a same-secret cross-kind vector (protected material does not open the sibling, and the reverse). The current call-e2ee owner/name/label invite is not that binding. This trial does not mark it reconciled.
- **Roster (`.14`), before an open room appears there.** Membership and labels are keyed by the full root. A sibling does not appear. Until that key exists, the roster path does not list open rooms.
- **Metering (`.4`), before open usage is accounted.** Attribute usage to the full root. Until that ships, open usage is not folded into the protected room's quota.
- **TURN (`add-turn-service`), before any open-room TURN credential.** The live grammar is `<unix>:<class>.<owner>[.<room>.<participant>]` (`add-turn-service` design, credential section). Room-mint segments cannot contain `.`, and `~open` is outside the room alphabet, so the marker is not a username segment. Protected room mints stay class `c1`. Open room mints use class `c2`: `<unix>:c2.<owner>.<room>.<participant>`, with `<room>` the display name and no tilde. Equal expiry, owner, room, and participant then still differ by class. The owning TURN task adds `c2`, the equal-expiry sibling inequality test, and the collision test before that path ships. Until `c2` is in that contract, this change does not mint a TURN username for an open room and does not hand a `c1` username to one. A TURN allocation may outlive the username expiry; a TURN credential grants no MoQ admission. This is a deferral of kind-separated accounting, not an approval to deploy TURN.

## D6 Deploy and rollback

Controller only, after this contract is advise-accepted and activated. No relay binary change, no drain, no `/var/lib/mjolnir/relay-rooms`.

Rollback is "stop issuing open roots" by deploying the previous mint. Clients that request open then fail closed, which is why `.15` has to ship that check with or before open issuance. Tokens already signed for `t/<owner>/~open/<room>` remain valid until `exp` on the current relay. Tell holders to expect the sibling to go quiet at expiry. Do not treat a relay restart as the rollback.

## D7 Costs of this trial

Eliminated relative to the claim revision: a Mjolnir-owned signature verifier, a moq-auth patch, a durable kind store, migration and drain of unrecorded protected tokens, store-loss fencing, and a relay-first rollout.

Still paid, on every client and on every downstream identity: two rooms for one display name; full-root threading through invite, KDF, roster, metering, and TURN; explicit-open fail-closed on the old mint; edge rejection of wide credentials; the buggy-edge residual.

## D8 Spike

Local dummy key, pinned relay libraries, production `spawn_web_decider` and `TokenPolicy`. Clock table: `spikes/logs/path-offline.log`. Live table: `spikes/logs/path-live.log` and `path-live-extra.log`. Narrative: `spikes/path/finding.md`. Not a production run.
