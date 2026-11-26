# add-open-room-kind

> **PENDING**

Node `mjolnir-rurh.11` (open-room-kind), parent `mjolnir-rurh` (platform-calls). Rigor: architecture (auth, token protocol, touches the live mint). Group: human-gate + review-pair. Blocks `mjolnir-rurh.13` (webrtc-edge).

## Why

The WebRTC edge (`add-webrtc-edge`, node `.13`) bridges WHIP and WHEP into a MoQ room, and it reads the media to do so. That is acceptable in a room whose owner chose it, and not in a room whose clients encrypt (`call-e2ee`). Spike S7 showed the edge cannot tell the two apart: a WHEP play of a protected broadcast fails only because no catalog is found, and a plaintext WHIP publish into a protected room is admitted and merely ignored by readers, because "a room token does not say what kind of room it is" (`add-webrtc-edge/spikes/finding.md`, claim 6 and "What this means for node D" item 5). The owner decided on 2026-11-25 that the room's kind is a signed claim in the room token, set by the owner at mint, protected by default, and the same for every participant. This change puts that mark where the relay and the edge can read it, and says who refuses what.

## What

- **The kind lives in the signed `root` claim**, not in a new claim. A protected room keeps today's root `t/<owner>/<room>`. An open room has root `t/<owner>/~open/<room>`. `~` is outside the room segment alphabet, so no protected room can be named `~open` and the two namespaces cannot overlap. A root without the marker is protected.
- **Why not a new claim:** the pinned moq-auth deserialises claims with `deny_unknown_fields` (`rs/moq-auth/src/wire.rs:21`, comment at `:47`). Every relay in production today would refuse a token carrying `kind` as a bad token. Adding one would also need a patched moq-auth, and it would still need a store to keep the kind the same for every participant.
- **Same kind for every participant, with no store:** the kind is part of the room's address. If the owner mints `open` for one label and `protected` for another under the same room name, those labels are in two different rooms, and the relay's existing root scoping keeps them apart. A mixed mint does not weaken the protected room. It splits the call.
- **Mint API:** an optional body field `kind`, either `"open"` or `"protected"`, defaulting to `"protected"`. Any other value is 400 `bad_kind` before a signature. The response gains `kind`. The kind is never read from a header, the query or the path. Scope `relay:join`, the user principal and the owner taken from the verified `sub` are unchanged.
- **Who enforces what:** an edge that admits WebRTC SHALL refuse WHIP and WHEP unless the token's root is an open room root, and SHALL reach the relay for that leg with the leg's own token. The relay keeps treating both kinds alike: it cannot tell a WebRTC-origin publish from a MoQ one, and its root scoping is already what keeps the rooms apart.
- **The predicate is shared:** `mjolnir_relay::room_kind(root)` parses a root strictly into open, protected, or not a room. The edge (node `.13`) uses it. This change ships it with tests, plus a captured run of the spike edge gated on it.
- **No relay deploy:** the production relay already admits `t/<owner>/~open/<room>` (`root_allowed`, unchanged since `c3d27ae`). The compatibility test against the deployed relay's verifier is owed before the controller deploy.
- Capability touched: `relay-room-auth` (MODIFIED ×2, ADDED ×1). `edge-relay` is unchanged.

Design and reasons: [`design.md`](design.md). Draft ADR: [`docs/decisions/0019-room-kind.md`](../../../docs/decisions/0019-room-kind.md).

## Impact

- Capabilities: MODIFIED `relay-room-auth` ("The controller mints a room token for the caller"; "A room path binds publish to one participant label"). ADDED `relay-room-auth` ("A room's kind is fixed by its root").
- ADRs: draft `docs/decisions/0019-room-kind.md` (architecture rigor: auth and token protocol).
- Code, after activation: `lib/mjolnir/relay/mint.ex` (body field, root, response, log), `test/mjolnir/relay/mint_test.exs`, a router-level test, `native/mjolnir_relay/src/lib.rs` (`room_kind` plus tests; no change to admission), a fixture of a token minted before this change. `CLAUDE.md` relay line.
- Not changed: the relay binary's admission, moq-auth, the key file, rotation, `edge-relay`, the `call-e2ee` credential context, guest images.
- Deploy: controller only (`deploy.sh --app-only`), after the compatibility tasks pass. Old tokens and old clients keep working. Order is an ASK in `tasks.md`.

## User journey & surfaces

No new UI because the outcome reaches existing surfaces: the mint route `POST /api/relay/rooms/:room/participants/:participant/token`, whose JSON response gains `kind` and whose `root` encodes it, and the edge's WHIP/WHEP answers from node `.13`. The browser page that shows an open-room warning is `mjolnir-rurh.15` (webrtc-room-client).

- **Owner, protected (default):** mints with no `kind` (or `"protected"`). Gets `root` `t/<owner>/<room>` and `kind: "protected"`, the same token as today. MoQ clients join as before. A WHIP or WHEP request with this token gets 403 `room_not_open` from the edge, with no SDP answer.
- **Owner, open:** mints with `"kind": "open"`. Gets `root` `t/<owner>/~open/<room>` and `kind: "open"`. MoQ clients connect at that root. WebRTC clients are admitted by the edge. The page must say the host can read the media (`.15`).
- **Mixed by mistake:** alice gets an open token, bob a protected one, both for `standup`. Each joins a room where the other never appears. Neither can read or publish into the other's room. The `kind` in each response shows why.
- **Failed:** `"kind": "Open"`, `""`, `null`, `1` or `["open"]` give 400 `bad_kind`. A header `x-room-kind: open` is ignored and the token is protected.
- **Off:** with the relay not configured, the mint is 503 as today. A request with a valid `kind` changes nothing about that answer, and a bad `kind` is still 400 first, as a bad `ttl` type is.

## Preparation

- Inputs read 2026-11-25: `bd show mjolnir-rurh.11` (steer note: signed claim, owner at mint, protected default, same kind for all participants; Duke "go with recs"); living `relay-room-auth` and `edge-relay`; `lib/mjolnir/relay/mint.ex`; the route in `lib/mjolnir/api/router.ex:239`; `test/mjolnir/relay/mint_test.exs`; `native/mjolnir_relay/src/lib.rs` (`root_allowed`, `profile`, `assess`, `ext_grant`); pinned moq-auth `4a6f522` `wire.rs` and `path.rs`, and moq-pattern; `add-webrtc-edge/spikes/finding.md` and `claim4-auth.sh` / `claim6-protected.sh`; `docs/plans/webrtc-turn-sfu.md` Q3; `add-call-e2ee` spec and ADR 0017; `add-turn-service` (also adds a field to this mint's response); `docs/LEARNINGS.md` add-relay-room-auth entries.
- Upstream: `mjolnir-rurh.3` (relay-room-auth) is folded and live. No other dependency.
- Outcome: new contract. Authority: none recorded for nodes `.11`–`.16` beyond steer answers, so the banner is PENDING. Activation needs Duke.

## Out of scope

- The edge itself, its WHIP/WHEP routes, and its product test of the refusal: `add-webrtc-edge` (`mjolnir-rurh.13`). This change supplies the predicate, the requirement and a captured spike-edge run.
- The page's open-room notice and kind display: `mjolnir-rurh.15`.
- Forbidding or requiring encryption by kind. A client in an open room may still encrypt (unplayable over WebRTC). A client in a protected room may still publish plaintext over MoQ (ignored by protected readers). See design D6.
- Revoking a room or switching a live room's kind. No revocation before `exp` remains a living limit.
- Metering and limits per kind (`mjolnir-rurh.4`). Roster parsing of open roots (`mjolnir-rurh.14`). TURN username room segment for open rooms (`add-turn-service`). Handoffs in `design.md`.
- A forwarding SFU for protected WebRTC calls (plan Q3 option (a)); not asked for.
