# add-open-room-kind

> **PENDING**

Node `mjolnir-rurh.11` (open-room-kind), parent `mjolnir-rurh` (platform-calls). Rigor: architecture (auth, token protocol, touches the live mint). Group: human-gate + review-pair. Blocks `mjolnir-rurh.13` (webrtc-edge).

Revision 3, 2026-11-26. Trial of the signed-root marker, authorized by Duke ("ok, try out the path method") after the claim revision was sent back. This trial accepts that an open room and a protected room with the same owner and name are two identities. It does not restore the withdrawn contract at `1552e85`. The claim revision (`f2821aea`, advise `reviews/2026-11-25-advise-2.md`) stays in history. Nothing here is advise-accepted or activated.

## Why

The WebRTC edge (`add-webrtc-edge`, node `.13`) bridges WHIP and WHEP into a MoQ room and reads the media. That is acceptable only in a room whose owner chose it. Spike S7 showed that a room token does not say which kind of room it is. This trial puts the kind in the signed root, which today's relay already admits, instead of a new JWT claim.

## What

- **Protected root, unchanged:** `t/<owner>/<room>`.
- **Open root:** `t/<owner>/~open/<room>`. The marker is the reserved literal segment `~open`, which the mint's room alphabet (`[A-Za-z0-9_-]{1,64}`) cannot produce. Names `open` and `_open` stay ordinary protected rooms.
- **No kind claim.** The mint does not add a claim. The relay verifier is not patched and does not grow a room-kind store. A token carrying `kind` remains a bad token on the pinned verifier.
- **Signed root is authoritative.** After verification, a pure classifier returns exactly `open`, `protected`, or `invalid`. It splits the verified root on literal `/`, checks exact arity, a canonical 32-byte base58 owner, and an exact room segment. It does not decode, trim, normalize, or interpret patterns. The relay's broader admission grammar is unchanged.
- **Mint:** optional JSON body field `kind` (`open` or `protected`, default `protected`). Any other JSON value is 400 `bad_kind`. Header, query, and path are ignored for kind. The response always includes `kind` and the canonical `root`. Scope stays `relay:join`. The owner is the verified `sub`.
- **Same display name, two rooms.** There is no 409 and no durable kind record. A protected mint and an open mint for `standup` sign two roots. Wide grants (`t/<owner>` and anything broader that the relay already allows) can span both. The edge (`.13`) refuses those credentials even when the request URL looks open.
- **Enforcement residual.** The relay admits both kinds, and it admits a protected publish token into the protected room no matter who presents it. The edge is the WebRTC gate. A buggy edge holding a protected participant's token can still publish plaintext into that protected room. That residual is accepted for this trial and is not fixed here.
- **Rollback.** The current mint ignores `kind` and returns `t/<owner>/<room>` with no `kind` field. A client that asked for open fails closed on a missing or mismatched `kind` or root. It does not connect, publish, or import a credential. Existing open tokens keep working until `exp`, because the relay did not gain a verifier this change can roll back.

Capabilities touched: `relay-room-auth` (MODIFIED ×1, ADDED ×1). `edge-relay` is restated so the profile does not gain a `kind` claim. The WHIP/WHEP product scenarios stay on `.13`. The page stays on `.15`.

## Impact

- After activation, code would be `lib/mjolnir/relay/mint.ex`, its router tests, and one shared classifier used by the edge. Not in this revision: `native/mjolnir_relay` admission, moq-auth, a `RoomKinds` store, backup, or a relay deploy.
- Clients, invites, KDF, roster, metering, and TURN must carry the full root (`t/<owner>/~open/<room>` or `t/<owner>/<room>`). Those are handoffs, not built here.

## User journey & surfaces

No new UI because the mint response grows `kind` and a longer `root`, and the page that shows them is `mjolnir-rurh.15`.

- **Owner, protected (default):** mints with no `kind`. Response `kind` is `protected`, root is `t/<owner>/<room>`, token claims are today's six names. MoQ clients join as before.
- **Owner, open:** mints with `{"kind":"open"}`. Response `kind` is `open`, root is `t/<owner>/~open/<room>`. MoQ clients join that root on today's relay. WebRTC admission is `.13`, and only for a verified open classification.
- **Same name, other kind:** both mints succeed. They do not see each other's broadcasts. An empty roster on one root is an empty room, not a sign that the sibling is empty.
- **Failed:** a bad `kind` is 400 `bad_kind`. `x-room-kind` and `?kind=` do not change the root. A client that asked for open and receives a protected root or a response without `kind: "open"` stops.
- **Wide credential:** the relay may admit `t/<owner>`. The edge refuses it before a relay session or an SDP answer.
- **Off:** with the relay not configured, the mint is 503 `relay_unavailable` as today.

## Preparation

- Read 2026-11-26: both advise reviews, `notes/claim-option.md`, ADR 0019 revision 2, the root-option offline log, and the claim spike. Duke's path trial replaces the claim choice for this contract only.
- Spike this revision: `spikes/logs/path-offline.log` (manual clock through `KeySet::verify` and `assess`) and `spikes/logs/path-live.log` plus `path-live-extra.log` (local production decider, dummy key). Findings and gaps: `spikes/path/finding.md`.
- Outcome: revised contract and a local transport spike. Fresh advise is owed. Banner PENDING.

## Out of scope

- Edge WHIP/WHEP refusal, product tests, and gateway code: `mjolnir-rurh.13`.
- The page's kind display and the explicit-open fail-closed client: `mjolnir-rurh.15`.
- Invite and KDF binding of the full root: `add-call-e2ee`.
- Roster identity: `mjolnir-rurh.14`. Metering: `.4`. TURN username identity: `add-turn-service`.
- An authenticated edge identity that would let the relay refuse a buggy edge. Recorded residual only.
- Relay deploy, drain, a room-kind directory, and migration of legacy tokens. Protected tokens do not change shape, so there is no unrecorded-kind overlap to drain.
