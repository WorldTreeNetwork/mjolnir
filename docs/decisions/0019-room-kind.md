# ADR 0019 — Room kind in the token root

**Status:** Draft. Duke has not accepted it. Implementation waits on an advise pass over `openspec/changes/add-open-room-kind/` and the ASK boxes in its `tasks.md`.
**Change:** [`add-open-room-kind`](../../openspec/changes/add-open-room-kind/proposal.md)
**Full argument:** [`design.md`](../../openspec/changes/add-open-room-kind/design.md)
**Evidence:** [`add-webrtc-edge/spikes/finding.md`](../../openspec/changes/add-webrtc-edge/spikes/finding.md) claim 6 and node D item 5. Plan: [`webrtc-turn-sfu.md`](../plans/webrtc-turn-sfu.md) Q3.
**Steer:** Duke, 2026-11-25: the room's kind is a signed claim in the room token, set by the owner at mint, protected by default, the same for every participant.

## One screen

1. A room is `(owner, kind, name)`. Protected: root `t/<owner>/<room>`, unchanged. Open: root `t/<owner>/~open/<room>`. The kind lives in the signed `root` claim. No new JWT claim is added.
2. Why not a new claim: the pinned moq-auth refuses unknown claims (`rs/moq-auth/src/wire.rs`, `deny_unknown_fields`), so every deployed relay would refuse the token.
3. Why the address and not a store: no controller memory, so nothing to persist, expire, or share across hosts. If the owner mints both kinds under one name, they get two rooms that the relay's root scoping already keeps apart. The call splits, but the protected room is not weakened.
4. Absence of the marker means protected. Every token minted before this ADR is protected and unchanged. A parser that does not recognise a root admits no WebRTC.
5. The mint takes body `kind` (`open` | `protected`, default protected; anything else 400 `bad_kind`), never a header or query. Scope `relay:join` and the owner taken from `sub` are unchanged.
6. The WebRTC edge admits WHIP and WHEP only for an open root (`mjolnir_relay::room_kind`), answers 403 `room_not_open` otherwise, and reaches the relay with the leg's own token. The relay reads no kind and admits both kinds alike.
7. No relay deploy: the live relay already admits `t/<owner>/~open/<room>` (`root_allowed`). The production step is the controller only.
8. A room cannot change kind. The other kind is another room. Old tokens run to `exp`.
9. The kind is the owner's declaration. Protected does not prove encryption, and open does not forbid it.

## Consequences

- Room names are unique per owner and kind, not per owner. Metering, roster and TURN usernames must key by root.
- The `call-e2ee` context `mjolnir-call/v1/<owner>/<room>/<label>` does not separate the open and the protected room of one name. Recommended: clients offer no encryption in an open room.
- Any future bridge that reads media (recording, HLS) inherits rule 6: open roots only, with the leg's own token.
