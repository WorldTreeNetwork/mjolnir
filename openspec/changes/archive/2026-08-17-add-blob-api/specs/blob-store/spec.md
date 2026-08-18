## ADDED Requirements

### Requirement: Callers speak the door, never B2

A caller SHALL put and get blobs only through the door. The door
SHALL be the only process that holds B2 credentials for this
bucket. A change that gives a Taskmaster process, a guest image,
or a browser B2 keys SHALL be rejected.

#### Scenario: Taskmaster uploads an attachment

- GIVEN a Taskmaster host with an attachment to store
- WHEN it writes the object
- THEN it HTTP PUTs to the door
- AND it does not hold a B2 application key

#### Scenario: B2 keys appear in the app VM

- GIVEN a change that injects B2 credentials into Taskmaster
- WHEN it is reviewed
- THEN it is rejected against this requirement

### Requirement: First face is HTTP on the Sites blob routes

v1 SHALL expose:

```
PUT  /storage/blob/b3/{hash}
PUT  /storage/blob/b3/{hash}.obao
GET  /storage/blob/b3/{hash}
GET  /storage/blob/b3/{hash}.obao
HEAD /storage/blob/b3/{hash}
```

`{hash}` SHALL be the base58 Blake3 of the stored bytes. A parallel
`/blob/put` or Taskmaster-only path SHALL be rejected. Large objects
SHALL NOT be transferred via `deliver_message`.

#### Scenario: PUT then GET

- GIVEN the door is running
- WHEN a client PUTs bytes whose Blake3 is `{h}` to
  `/storage/blob/b3/{h}`
- AND the door has accepted
- THEN GET `/storage/blob/b3/{h}` returns those bytes

#### Scenario: GiB via Mjolnir message

- GIVEN a change that sends blob bodies through `deliver_message`
- WHEN it is reviewed
- THEN it is rejected against this requirement

### Requirement: The door is a process, not a store VM

v1 SHALL run the door as a process on an existing Linux host (the
Mjolnir host sidecar). It SHALL NOT require a new VM class and
SHALL NOT run MinIO.

#### Scenario: First deploy

- GIVEN the Mjolnir host
- WHEN the door is started
- THEN it is a sidecar process
- AND no MinIO guest exists for this purpose

### Requirement: Put path acks only after B2 confirms

The door SHALL hash the body with Blake3, refuse a mismatch, treat
an already-present same-hash object as a no-op (no extra B2
version), write to B2 under `blob/b3/{hash}`, and SHALL NOT report
accepted until `HeadObject` or GET on that B2 key succeeds.

#### Scenario: PUT 200 without HeadObject

- GIVEN B2 returns 200 on PutObject
- WHEN the door has not yet HeadObject/GET that key
- THEN it has not accepted
- AND it does not return 2xx accepted to the caller

#### Scenario: Re-PUT does not add a version

- GIVEN `{h}` is already accepted on B2 with versioning on
- WHEN the same bytes are PUT again
- THEN the caller gets success
- AND B2 does not gain a new version of `{h}`

### Requirement: Durability proof is B2, not a replacement provider

After the door dies, a GET of an accepted hash SHALL succeed from
B2 under the same content-addressed key. A working-set cache or
“replacement provider” SHALL NOT satisfy the accept-time proof.

#### Scenario: Door is killed

- GIVEN an object the door reported accepted
- WHEN the door process is gone
- THEN HeadObject or GET of that key on B2 returns the same bytes
