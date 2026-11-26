# add-open-room-kind

> **PENDING**

Node `mjolnir-rurh.11` (open-room-kind), parent `mjolnir-rurh` (platform-calls). Rigor: architecture (auth, token protocol, touches the live mint and the live relay). Group: human-gate + review-pair. Blocks `mjolnir-rurh.13` (webrtc-edge).

Revision 2, 2026-11-25. The owner chose a dedicated signed claim with a relay-first rollout, so that one room name is one room with one kind. The first contract (`1552e85`, kind in the root path) was sent back by advise (`reviews/2026-11-25-advise.md`) and is withdrawn. Its offline evidence is kept as the option not chosen (`spikes/README.md`).

## Why

The WebRTC edge (`add-webrtc-edge`, node `.13`) bridges WHIP and WHEP into a MoQ room and reads the media to do so. That is acceptable in a room whose owner chose it, and not in a room whose clients encrypt (`call-e2ee`). Spike S7 showed that the edge cannot tell the two apart, because "a room token does not say what kind of room it is" (`add-webrtc-edge/spikes/finding.md`, claim 6 and node D item 5). This change makes the kind a signed claim in the room token, set by the owner at mint. Protected is the default. The controller keeps one kind per room name, and the relay and the edge can read it.

## What

- **Claim:** `kind`, a top-level JWT claim. The mint writes `"kind": "open"` in open-room tokens and writes no `kind` in protected tokens. Absent means protected. That covers every token minted before this change, and keeps protected tokens valid on a relay that has not been updated.
- **How the relay reads it at the pin (route (b)):** the pinned moq-auth refuses unknown claims (`wire.rs:21`), and today's production verifier refuses any token carrying `kind` (spike C1). The relay therefore verifies room-token signatures itself, with the jsonwebtoken and rind provider moq-auth already uses. It takes `kind` out of the verified payload, accepts only absent, `"open"` or `"protected"`, and hands the rest to moq-auth's strict `Claims` decoder, which still refuses every other unknown claim. moq-auth is not patched, and no crate is added. Spike: `spikes/claim-route.md` (C1–C8).
- **One name, one kind:** the controller keeps a durable record per `(owner, room)` in a root-only directory, `/var/lib/mjolnir/relay-rooms/`. The first mint creates it. A mint whose kind differs from a live record is refused with 409 `room_kind_conflict` and changes nothing. A room is live until the latest `exp` of any token minted for it. Reuse of the name with the other kind after that is an owner ASK.
- **Mint API:** optional body field `kind` (`"open"` or `"protected"`, default `"protected"`). Any other value is 400 `bad_kind`. Header, query and path are never read for it. The response gains `kind`. The log carries only the validated value. Scope `relay:join`, the user principal and the owner taken from `sub` are unchanged.
- **Switch:** `kind: "open"` is refused with 503 `open_rooms_unavailable` unless `MJOLNIR_RELAY_OPEN_ROOMS=true` is in `/etc/mjolnir-relay/relay.env`. The operator sets it only after every relay that host's tokens reach runs the new verifier.
- **Enforcement:** the relay refuses malformed `kind` values. It admits both kinds alike, because nothing in a token tells it whether a publish comes from WebRTC. The edge refuses WHIP and WHEP unless the verified kind is open; that requirement is owed by `.13`, with a handoff on that bead.
- **Rollout:** relay first (restart and drain: an owner gate), the edge with the verifier from day one, the controller next, the switch last. Rollback is fenced by the switch. Clients fail visibly on an unexpected kind.
- Capabilities touched: `relay-room-auth` (MODIFIED ×1, ADDED ×3) and `edge-relay` (MODIFIED ×1, "Relay tokens have one profile").

Design and reasons: [`design.md`](design.md). Facts for the choice: [`notes/claim-option.md`](notes/claim-option.md). Draft ADR: [`docs/decisions/0019-room-kind.md`](../../../docs/decisions/0019-room-kind.md).

## Impact

- Capabilities: MODIFIED `relay-room-auth` ("The controller mints a room token for the caller"). ADDED `relay-room-auth` ("The relay reads the room kind claim", "One room name has one kind", "Open rooms are issued only after every verifier reads the claim"). MODIFIED `edge-relay` ("Relay tokens have one profile").
- ADRs: draft `docs/decisions/0019-room-kind.md`, recording both options, the owner's choice and its costs.
- Code, after activation: `native/mjolnir_relay/src/` (a `room_token` verifier, `assess` uses it, `TokenPolicy` follows, tests and fixtures); `lib/mjolnir/relay/mint.ex`; a new `Mjolnir.Relay.RoomKinds` (store and serialising process) under the supervisor; `test/mjolnir/relay/`, `test/mjolnir/api/relay_mint_router_test.exs`; the backup timer's source list; `CLAUDE.md` relay line.
- Not changed: moq-auth and the moq pin, the key file and rotation, room paths and roots, the `call-e2ee` credential context, guest images.
- Deploy: two production steps under owner gates. The relay (`deploy.sh --relay`, which restarts and drains) comes first, then the controller (`--app-only`). The switch is set after both.

## User journey & surfaces

No new UI because the outcome reaches existing surfaces: the mint route `POST /api/relay/rooms/:room/participants/:participant/token` (its JSON response gains `kind`, and its errors gain 409 and a new 503 reason), relay admission (unchanged for clients), and the edge's WHIP/WHEP answers from node `.13`. The page that shows the kind and the open-room notice is `mjolnir-rurh.15`.

- **Owner, protected (default):** mints with no `kind`. Gets `kind: "protected"`, a token shaped exactly like today's, and a room record `protected`. MoQ clients join as before.
- **Owner, open (switch on):** mints with `"kind": "open"`. Gets `kind: "open"`, a token whose payload carries `"kind": "open"`, and a record `open`. MoQ clients join through the updated relay. WebRTC clients are admitted by the edge (`.13`). The page must say the host can read the media (`.15`).
- **Conflict:** while `standup` is live as open, a mint for `standup` with no `kind` or with `protected` gets 409 `room_kind_conflict`. No token is signed and no record changes. The reverse also holds.
- **Renewal:** a mint of the same kind for a live room succeeds and extends the room's life. A client renewing an open room sends `"kind": "open"` every time.
- **Failed:** a malformed `kind` gives 400 `bad_kind`. `x-room-kind: open` or `?kind=open` is ignored, so the mint is protected (and conflicts if the room is live as open). With the switch off, `"kind": "open"` gives 503 `open_rooms_unavailable`.
- **Rollback seen by a client:** a client that asked for open and gets a response without `kind: "open"` stops. It does not connect, publish or import a credential, and it shows a join error.
- **Off:** with the relay not configured, the mint is 503 `relay_unavailable` as today.

## Preparation

- Inputs read 2026-11-25: `reviews/2026-11-25-advise.md` and `reviews/2026-11-25-blind-take.md`; the owner's decision on the bead (claim; one name, one kind; decision 2 to confirm); pinned moq-auth `4a6f522` (`wire.rs`, `key.rs`, `set.rs`, `claims.rs`, `crypto.rs`, `corpus.rs`); jsonwebtoken 11.1.0 (`header.rs`, `decoding.rs`); `native/mjolnir_relay/src/{lib.rs,main.rs}`; living `relay-room-auth` and `edge-relay`; `lib/mjolnir/relay/mint.ex`, the router and `relay_mint_router_test.exs`; `Mjolnir.StateStore`; `add-edge-keyframes/design.md` D4; `add-turn-service`; the `mjolnir-rurh.13` notes.
- Upstream: `mjolnir-rurh.3` folded and live. Production relay provenance `ca61ceb` (bead), the same source as HEAD for `native/mjolnir_relay`.
- Outcome: revised contract. Fresh advise is owed (same Astra reader). Banner PENDING: activation needs Duke.

## Out of scope

- The edge, its WHIP/WHEP refusal and its product tests: `add-webrtc-edge` (`mjolnir-rurh.13`). The handoff is on that bead.
- The page's kind display and open-room notice: `mjolnir-rurh.15`. The client rules on unexpected kinds and credential use are handoffs to `.15` and `.5` (design D7).
- Binding the kind into the `call-e2ee` credential context: a handoff to `add-call-e2ee`.
- Independent relay enforcement against a buggy edge (an authenticated edge identity plus a relay policy). It is recorded as a residual risk, not built.
- A second controller host minting for one relay (a shared store), revocation, and a kick.
- Metering, roster and TURN attribution: handoffs to `.4`, `.14` and `add-turn-service`.
