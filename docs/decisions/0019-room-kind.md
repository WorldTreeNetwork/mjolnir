# ADR 0019 — Room kind

**Status:** Draft, revision 3 (path trial). Not accepted. Fresh advise of `openspec/changes/add-open-room-kind/` is still owed. Implementation waits on that accept and on the open product boxes in `tasks.md`.
**Change:** [`add-open-room-kind`](../../openspec/changes/add-open-room-kind/proposal.md)
**Argument:** [`design.md`](../../openspec/changes/add-open-room-kind/design.md). Claim facts, kept as history: [`notes/claim-option.md`](../../openspec/changes/add-open-room-kind/notes/claim-option.md).
**Reviews:** path contract sent back, [`reviews/2026-11-25-advise.md`](../../openspec/changes/add-open-room-kind/reviews/2026-11-25-advise.md). Claim contract sent back, [`reviews/2026-11-25-advise-2.md`](../../openspec/changes/add-open-room-kind/reviews/2026-11-25-advise-2.md).
**Spike:** [`spikes/path/finding.md`](../../openspec/changes/add-open-room-kind/spikes/path/finding.md).

## History

| Revision | Choice | What happened |
|---|---|---|
| 1 (`1552e85`) | Root marker | Advise sent it back. Withdrawn. Offline log kept. |
| 2 (`f2821aea`) | Dedicated `kind` claim, one name one room | Advise sent it back. Verifier and store costs were the blockers. |
| 3 (this file) | Root marker, retried | Duke, 2026-11-26: try the path and see if it is cleaner. Same owner and name MAY be two identities for this trial. |

Revision 3 does not copy revision 1. It answers that review's path findings: full-root identity on the handoffs, protected credentials do not cross kind, explicit-open clients fail on the old mint, body-only mint authority, and an honest edge residual.

## The two options

| | Root marker `t/<owner>/~open/<room>` | Dedicated claim `"kind": "open"` |
|---|---|---|
| Relay at the pin | Admitted by today's relay | Refused until a verifier change and a relay deploy |
| One name, one kind | Not provided. Two roots. | Needs a durable record and a conflict response |
| Lasting cost | Every client and every downstream key must carry the full root | Verifier ownership or a carried moq-auth patch, plus store, migration, and drain |
| Mixed mint | Two rooms | Refused while a record is live |

## Decision under trial

1. The kind is the signed root. Protected stays `t/<owner>/<room>`. Open is `t/<owner>/~open/<room>`. The marker is the literal segment `~open`, which the mint room alphabet cannot express. No `kind` claim is minted or read. moq-auth is not patched.
2. A classifier returns `open`, `protected`, or `invalid` from that verified string by literal slash, exact arity, canonical owner, and the room alphabet. It does not decode. The relay's own grammar stays broader, so wide roots still span both rooms. The WebRTC edge rejects every class except `open`, including a wide root on an open URL.
3. The mint reads `kind` from the JSON body only, under `relay:join` and the owner in `sub`. The response always returns `kind` and `root`. There is no room-kind directory and no issuance switch. Today's relay is the reader.
4. The edge (`.13`) is the WebRTC gate, with the leg's own token. The relay admits both kinds. A buggy edge with a protected publish token can still publish plaintext into that protected room. Accepted residual.
5. Deploy is the controller only, after advise accept. Rollback ships the old mint. Explicit-open clients fail closed when `kind` or the `~open` segment is missing. Already-issued open tokens remain valid until `exp`.

## Costs of the trial

Eliminated: custom verifier, moq-auth patch, durable `RoomKinds` state, legacy drain, store-loss recovery, relay restart for the feature.

Remaining: two identities per display name; full root in invite, KDF, roster, metering, and TURN; wide grants; edge enforcement that the relay does not repeat; client fail-closed behavior that does not exist until `.15`.

## Consequences

- Do not fold WHIP/WHEP behavior into this change. It is unbuilt and belongs to `.13`. The page belongs to `.15`.
- A room bearer still cannot mint. An owner app that forwards untrusted participant input into the mint is exercising the owner's `relay:join`.
- Fresh advise is required before activation. This ADR does not record that advise.
