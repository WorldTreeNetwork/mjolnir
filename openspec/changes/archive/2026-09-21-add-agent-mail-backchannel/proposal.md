# add-agent-mail-backchannel

> **ACTIVE BUILD**
>
> `do axsb.5` 2026-09-21. Bead `mjolnir-axsb.5.3`. Steer: caller
> mailbox + REST peek/ack. REQ/REP = two spools. Same accept
> primitive as `@mail/`. Do not make Papyrus a VM.

**Rigor:** change

Uses folded ADR 0006. No new ADR.

## Why

Papyrus can POST into a VM mailbox. The reply has nowhere durable
to land if the laptop is closed and there is no Iroh attach. OTP
process mailboxes are RAM. PTY is not the reply path.

## What

- A mailbox address that is not a VM UUID: `@mail/<mailbox_id>/`
  via the existing `Mailbox` module.
- `GET /api/mail/:id/messages` peek (no tombstone).
- `POST /api/mail/:id/ack` tombstones.
- `POST /api/mail/:id/messages` accept (200 = fsync).
- Guest `/send` to a non-VM target `Mailbox.accept`s that id
  instead of 404.

## Impact

- Capabilities: ADDED on `vm-mailbox`
- ADRs: none

## User journey & surfaces

No new UI because Papyrus already POSTs; it peeks its own
mailbox id over REST.

- **Working** — guest send to caller id; GET after laptop relaunch
  still lists the message until ACK.
- **Empty** — no files under `@mail/<id>/`.
- **Failed (today)** — guest send to a non-VM is `:not_found`.
- **Off** — VM-only POST `/api/vms/:id/messages`.

## Out of scope

- Making Papyrus a VM
- OTP process mailbox as ledger
- Iroh as the turn ledger (notify only)
- Rewrite `@mail` spool
- Biscuit / roster
