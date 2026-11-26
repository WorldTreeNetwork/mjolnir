# ADR 0019 — Room kind as a signed claim

**Status:** Draft, revision 2. Duke chose the claim on 2026-11-25. Implementation waits on a fresh advise pass over `openspec/changes/add-open-room-kind/` and the open ASK boxes in its `tasks.md`.
**Change:** [`add-open-room-kind`](../../openspec/changes/add-open-room-kind/proposal.md)
**Full argument:** [`design.md`](../../openspec/changes/add-open-room-kind/design.md). Facts: [`notes/claim-option.md`](../../openspec/changes/add-open-room-kind/notes/claim-option.md). Spike: [`spikes/claim-route.md`](../../openspec/changes/add-open-room-kind/spikes/claim-route.md).
**Review:** first contract sent back, [`reviews/2026-11-25-advise.md`](../../openspec/changes/add-open-room-kind/reviews/2026-11-25-advise.md).
**Evidence for the need:** [`add-webrtc-edge/spikes/finding.md`](../../openspec/changes/add-webrtc-edge/spikes/finding.md) claim 6 and node D item 5.

## The two options

| | Root marker (`t/<owner>/~open/<room>`) | Dedicated claim (`"kind": "open"`) |
|---|---|---|
| Relay at the pin | Accepted by today's relay (`root_allowed`); no relay deploy | Refused by today's relay (moq-auth `deny_unknown_fields`); relay deploy first |
| One name, one kind | Not needed: open and protected of one name are two rooms the relay keeps apart | Needs a durable controller record and a 409 on conflict |
| Lasting cost | A second identity for the same name, everywhere (clients, E2EE context, roster, metering, TURN) | An owned signature step in the relay, a room store, a relay restart to roll out |
| Mixed mint | Splits the call silently into two rooms | Refused |

Author recommended the root; the advise reviewer recommended the claim; the orchestrator recommended the root. **Duke chose the claim** (2026-11-25): "one name is one room with one kind".

## Decision (draft)

1. A room token's kind is a top-level claim `kind`. The mint writes `"kind": "open"` for open rooms and no `kind` for protected rooms. Absent means protected, which covers every token minted before this ADR and keeps protected tokens valid on any relay version.
2. The relay reads the claim by verifying room-token signatures itself (jsonwebtoken plus rind, as moq-auth does), removing `kind`, and handing moq-auth's strict `Claims` decoder the rest, which still refuses every other unknown claim. moq-auth and the moq pin are not patched. Rejected: forms the decoder tolerates (`sub`, `iss`, a header parameter), because none is a dedicated claim and old readers would silently ignore it; a carried moq-auth patch, because it is not needed. Parity with moq-auth is a differential test over its shared corpus.
3. The controller keeps one record per `(owner, room)` in `/var/lib/mjolnir/relay-rooms/` (root-only, file per room, atomic writes, one serialising process). A conflicting mint is 409 `room_kind_conflict` and changes nothing. A room lives until the latest `exp` minted for it. Reuse after that is an owner ASK.
4. The kind comes from the mint body only, under `relay:join` and the owner taken from `sub`. Never from a header, the query or the path.
5. The edge (`.13`) admits WHIP and WHEP only for a verified open kind, with the leg's own token. The relay admits both kinds alike: it cannot tell WebRTC origin.
6. Rollout: relay, edge, controller, then `MJOLNIR_RELAY_OPEN_ROOMS=true`. Rollback: switch off, wait out the ceiling.

## Costs accepted with the claim

- A relay restart and drain to roll out, which is an owner gate, and a relay-first order fenced by a switch.
- Mjolnir owns room-token signature verification, a security-sensitive path, held to parity with moq-auth by test.
- A durable store with its own failure modes (fails closed on a read or write error) and a bounded exposure if it is lost (one token ceiling).
- A buggy edge holding a protected participant's token remains able to publish plaintext into that room. Accepted pending an authenticated edge identity.
- A second controller per relay would need a shared store.

## Consequences

- Clients must check the response `kind` against the kind they asked for and fail visibly otherwise. A protected credential is used only on a protected join.
- `call-e2ee` may bind the kind into its credential context (handoff). Roster, metering and TURN key on the room identity, and record the kind.
