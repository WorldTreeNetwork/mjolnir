## ADDED Requirements

### Requirement: Non-VM callers have a mailbox

A mailbox id that is not a VM UUID SHALL use the same `@mail/<id>/`
spool, fsync accept, peek, and application-ACK tombstone as a VM
mailbox. `GET` of pending messages SHALL NOT tombstone. `POST` ack
SHALL. Kick/restore SHALL no-op when the id is not a live or
dormant VM.

#### Scenario: Peek after accept

- GIVEN `POST /api/mail/caller-1/messages` returned 200 for id `r1`
- WHEN `GET /api/mail/caller-1/messages`
- THEN `r1` is listed
- AND the live file still exists

#### Scenario: Ack tombstones

- GIVEN that peek
- WHEN `POST /api/mail/caller-1/ack` with `ids: ["r1"]`
- THEN a later GET does not list `r1`

#### Scenario: Guest send to a caller mailbox

- GIVEN the guest sends to `target_vm_id` that is not a VM
- WHEN the host handles `send_message`
- THEN `Mailbox.accept` writes `@mail/<target>/`
- AND the response is ok
