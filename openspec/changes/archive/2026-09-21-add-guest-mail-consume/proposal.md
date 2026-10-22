# add-guest-mail-consume

> **ACTIVE BUILD**
>
> `do axsb.5` 2026-09-21. Bead `mjolnir-axsb.5.2`. Steer 2026-09-20:
> consume is a default loop inside `mjolnir-agent`, not
> personality-only. Peek/ack stay. Loop is new.

**Rigor:** change

## Why

Papyrus (or `mj message`) can POST a producer id and get 200, then
the guest never application-ACKs. Mail piles in `@mail/` and
`POST /done` is never honest. Peek/ack HTTP already exists; nothing
in the agent consumes by default.

## What

- Default consume loop in `mjolnir-agent`: peek inbox, record id
  durably, dispatch payload, application-ACK.
- Redelivered ids already recorded are ACK-only (idempotent).
- Peek/ack HTTP unchanged.
- Guest `POST /send` passes a mailbox producer id (steer AUTO).
- Capability `vm-mailbox` ADDED consume requirement.

## Impact

- Capabilities: ADDED on `vm-mailbox`
- ADRs: none (0006 already says application ACK tombstones)

## User journey & surfaces

No new UI because `mj message` / Papyrus POST already land in
`@mail/`. After `just deploy --agent`, a POSTed id is peeked,
recorded, acked; `/done` 409s while unacked.

- **Working** — POST id, guest records + acks, second peek empty.
- **Empty** — no mail; loop waits on notify.
- **Failed (today)** — 200 then silent pile; personality must poll.
- **Off** — `MJOLNIR_MAIL_CONSUME=0` skips the loop; peek/ack remain.

## Out of scope

- Rewrite `@mail` spool or guest HTTP peek/ack
- Papyrus send (`add-agent-mail`)
- Backchannel (`mjolnir-axsb.5.3`)
- Biscuit / roster
