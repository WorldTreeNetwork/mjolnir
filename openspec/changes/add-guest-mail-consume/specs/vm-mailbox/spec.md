## ADDED Requirements

### Requirement: Guest agent consumes by default

`mjolnir-agent` SHALL run a consume loop that peeks the in-guest
inbox (the same peek as `GET /messages` / `GET /recv`), records
each producer id to a fsynced seen file, then sends application
ACK. Peek/ack HTTP SHALL remain. The loop SHALL NOT drain the
inbox as the only copy of host mail. A redelivered id already in
the seen file SHALL be application-ACKed without a second
dispatch. `POST /done` SHALL still 409 while the inbox is
non-empty. The loop MAY be disabled with `MJOLNIR_MAIL_CONSUME=0`.

#### Scenario: Record then ack

- GIVEN a POSTed id delivered into the guest inbox
- WHEN the consume loop runs
- THEN the id is in the seen file
- AND the host file is tombstoned after application ACK
- AND a later peek does not return that id

#### Scenario: Crash before ack

- GIVEN the loop peeked and has not yet application-ACKed
- WHEN the agent dies
- THEN the host file is still unacked
- AND a later peek can see the id again

#### Scenario: Redelivery of a recorded id

- GIVEN the id is already in the seen file
- WHEN the host redelivers
- THEN the loop application-ACKs
- AND it does not dispatch a second run

### Requirement: Guest send carries a producer id

Guest `POST /send` SHALL supply a mailbox producer id on the
vsock `send_message` (body `id` or a generated UUID). The host
SHALL pass that value as `Mailbox.accept` `id`. Omitting it SHALL
NOT be the default once this requirement is built.

#### Scenario: Guest send is retry-safe

- GIVEN the guest POSTs /send with `id: "turn-1"`
- WHEN the host accepts
- THEN `@mail/<target>/turn-1.json` exists
- AND a second send of `turn-1` is a duplicate
