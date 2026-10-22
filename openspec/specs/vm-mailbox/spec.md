# vm-mailbox

What is built. Folded from
[`add-mailbox-durable-accept`](../../changes/archive/2026-08-22-add-mailbox-durable-accept/proposal.md)
on 2026-08-22,
[`add-guest-mail-consume`](../../changes/archive/2026-09-21-add-guest-mail-consume/proposal.md)
and
[`add-agent-mail-backchannel`](../../changes/archive/2026-09-21-add-agent-mail-backchannel/proposal.md)
on 2026-09-21. Decisions live in
[`docs/decisions/0006-mailbox-as-spool.md`](../../../docs/decisions/0006-mailbox-as-spool.md).
Argument:
[`docs/philosophy/mailbox-as-spool.md`](../../../docs/philosophy/mailbox-as-spool.md).

## Purpose

`POST /api/vms/:id/messages` is a retry-safe at-least-once spool. 200
means the producer may forget. The filename is the producer id. Vsock
ACK is a RAM hint. Application ACK tombstones. One queue for every VM
state. Postgres is not the ledger. A front-proxy VM is not the accept
point.

## Requirements

### Requirement: Durable accept before 200

`POST /api/vms/:id/messages` SHALL NOT return 200 until the message
exists as a fsynced file at `{btrfs_root}/@mail/<vm_id>/<message_id>.json`.
The write SHALL fsync the file **and its directory entry** (tmp file,
`:file.sync`, exclusive link or equivalent, directory fsync). 200 means
the producer may forget. A host crash after 200 SHALL leave that file.
In-memory GenServer queues, vsock writes, and `DormantRegistry` debounce
SHALL NOT satisfy this requirement. Postgres SHALL NOT be the accept
ledger. The VM GenServer is the delivery consumer while the VM is in
`VMRegistry`. Delivery order is best-effort by `seq` in the file body.

#### Scenario: Laptop closes after 200

- GIVEN a POST that returned 200 with a `message_id`
- WHEN the producer process exits immediately
- THEN the file is present on disk
- AND a later delivery worker can send that id to the guest

#### Scenario: Host crashes between 200 and vsock

- GIVEN a 200 was returned
- WHEN the BEAM dies before vsock send
- THEN on restart the unacked file is still present
- AND a sweep redelivers it

#### Scenario: Debounced registry write is proposed as accept

- GIVEN a change that returns 200 after enqueueing a
  `DormantRegistry` mutation without fsync of the message file
- WHEN it is reviewed
- THEN it is rejected against this requirement

### Requirement: Producer id is identity

The producer MAY supply `id` on the POST body. That value SHALL be
the message identity and the filename. A second POST of the same
`id` for the same VM SHALL return 200 with `status: "duplicate"`
and SHALL NOT create a second live file, whether the first copy is
still unacked or already tombstoned. Tombstones SHALL be retained at
least seven days. If `id` is omitted, the host SHALL generate one,
return it, and SHALL treat retry safety as off unless the client
echoes that id on a later POST.

#### Scenario: Retried POST with the same id

- GIVEN an accepted file `@mail/<vm>/<id>.json`
- WHEN the producer POSTs the same `id` again
- THEN the response is 200 `{ok: true, message_id: <id>, status: "duplicate"}`
- AND the guest is not given a second distinct message

#### Scenario: Omitted id

- GIVEN a POST with no `id`
- WHEN the host accepts
- THEN 200 includes a host-generated `message_id`
- AND a retry without that id is a new message

### Requirement: One queue for every VM state

Unacked files SHALL be the only delivery queue. Running, booting,
dormant, and restoring SHALL NOT keep a second copy in a GenServer
list, a vsock cast, or `DormantRegistry.pending_messages`. VM state
SHALL gate when the delivery worker rings vsock or restore, never
whether the message exists. `take_pending_messages` that clears
before vsock success SHALL NOT remain the restore path.

#### Scenario: POST while running

- GIVEN a running VM
- WHEN a message is accepted
- THEN the file exists before 200
- AND vsock send is a subsequent delivery attempt

#### Scenario: POST while dormant

- GIVEN a dormant VM and Admit allows thaw
- WHEN a message is accepted
- THEN the file exists before 200
- AND restore is triggered because unacked mail exists

#### Scenario: POST while restoring

- GIVEN restore is in flight
- WHEN a second POST of a new id is accepted
- THEN it is a new file, not a `retry_deliver_message` race against
  a drained in-memory list

### Requirement: Vsock ACK does not complete delivery

A vsock `deliver_message_ack` SHALL mean the guest agent buffered
the frame. The host SHALL NOT delete or tombstone the file on that
ACK. The vsock frame SHALL carry the producer `message_id`.

#### Scenario: Guest agent ACKs then dies

- GIVEN vsock `deliver_message_ack` was received
- WHEN the guest agent process exits before application ACK
- THEN the host file is still unacked
- AND the worker redelivers

### Requirement: Application ACK tombstones

The guest SHALL expose a peek of pending messages that does not
destroy host mail. After the application has recorded or processed
an id, the guest SHALL send an application ACK. Only then SHALL
the host move the file to `@mail/<vm_id>/acked/` (or equivalent
tombstone) so a late producer retry stays a duplicate. A GET that
drains an in-memory inbox as the only copy SHALL NOT satisfy this
requirement.

#### Scenario: App crashes between peek and process

- GIVEN the guest peeked message `<id>`
- WHEN the app crashes before application ACK
- THEN the host file is still unacked
- AND a later peek can see `<id>` again

### Requirement: Unacked mail wakes a dormant VM

A dormant VM with unacked mail SHALL be restored (subject to Admit
thaw) without a separate activate API. `handle_done` SHALL NOT
require a barrier against concurrent POST: the file is already the
wake. Admit that rejects a never-message SHALL fail the POST
without a file. Admit that refuses thaw SHALL leave the file queued
and SHALL NOT restore.

#### Scenario: POST races signal_done

- GIVEN the guest is signaling done
- WHEN a POST returns 200
- THEN the file exists
- AND after dormancy the VM is restored and the message is delivered

### Requirement: Give-up is visible, not a silent drop of an unaccepted message

The host SHALL stop redelivering a message after a documented TTL
or maximum attempts, moving it to a dead/bounce location. The TTL
clock SHALL run from accept, including while Admit refuses thaw.
That path SHALL NOT be used in place of failing a POST that was
never fsynced. Mail for a VM that exists in neither `VMRegistry`,
`DormantRegistry`, nor `StateStore` SHALL be bounced.

#### Scenario: Wedged guest

- GIVEN unacked mail and a guest that never application-ACKs
- WHEN the give-up threshold is reached
- THEN the host stops waking on that id
- AND the original 200 remains true (the producer already forgot)
- AND an operator can see the bounced file

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
