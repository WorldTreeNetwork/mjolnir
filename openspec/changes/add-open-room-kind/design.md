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

Iroh uses absolute paths. The saved run published on both absolute roots and read one protected frame. One cross-subscribe returned `unroutable`. Other Iroh reads did not return inside the bound. See `spikes/path/finding.md`. That gap is not a reason to invent a relay change in this trial.

## D4 Edge handoff (not built)

`.13` verifies with the existing relay verifier, classifies the verified root, and only then may open a relay session or answer SDP. Requirements for that node:

- Verified class is `open`.
- The URL's room segment equals the root's room segment, literally.
- The grant covers the operation.
- A wide root, a protected root, and `invalid` are refused. A protected refusal is distinct from a bad token.
- The leg uses its own token. The edge has no standing relay credential.

Residual, accepted: the relay cannot tell a WebRTC bridge from any other client. With a valid protected publish token it will accept a publish into that protected room. Host-readable subscribers can see that plaintext. Authenticating readers discard it. Independent relay enforcement would need an authenticated edge identity and a relay policy, which this trial does not add.

## D5 Identity handoffs (not built)

The full root is the room identity.

- **Clients (`.15`).** An explicit open join or renewal fails visibly when the response has no `kind: "open"` or the root is not `t/<owner>/~open/<room>`. It does not reconnect or publish. A protected credential is imported and used only when the join's verified class is `protected`, including renewals. No plaintext fallback under a protected invitation.
- **`call-e2ee`.** Before any encrypted open room, the KDF and the invite bind the full root, not owner plus display name. A protected credential must not open the sibling. Version the context so old invites do not match.
- **Roster (`.14`).** Membership and labels are keyed by the full root. A sibling room does not appear.
- **Metering (`.4`).** Attribute usage to the full root so the two rooms are not one quota.
- **TURN (`add-turn-service`).** If the username is `expiry/class/owner/room/participant`, put the marker in that identity so the siblings do not share a username at equal expiry. A TURN allocation is not MoQ admission.

## D6 Deploy and rollback

Controller only, after this contract is advise-accepted and activated. No relay binary change, no drain, no `/var/lib/mjolnir/relay-rooms`.

Rollback is "stop issuing open roots" by deploying the previous mint. Clients that request open then fail closed, which is why `.15` has to ship that check with or before open issuance. Tokens already signed for `t/<owner>/~open/<room>` remain valid until `exp` on the current relay. Tell holders to expect the sibling to go quiet at expiry. Do not treat a relay restart as the rollback.

## D7 Costs of this trial

Eliminated relative to the claim revision: a Mjolnir-owned signature verifier, a moq-auth patch, a durable kind store, migration and drain of unrecorded protected tokens, store-loss fencing, and a relay-first rollout.

Still paid, on every client and on every downstream identity: two rooms for one display name; full-root threading through invite, KDF, roster, metering, and TURN; explicit-open fail-closed on the old mint; edge rejection of wide credentials; the buggy-edge residual.

## D8 Spike

Local dummy key, pinned relay libraries, production `spawn_web_decider` and `TokenPolicy`. Clock table: `spikes/logs/path-offline.log`. Live table: `spikes/logs/path-live.log` and `path-live-extra.log`. Narrative: `spikes/path/finding.md`. Not a production run.
