## ADDED Requirements

### Requirement: Door listens on the guest overlay

The door process SHALL bind TCP on `:host_api_ip` port 7222
(default `10.200.0.1:7222`). It SHALL NOT listen on `0.0.0.0`,
`::`, or the host's public NIC. It SHALL fail to start if that
address is not assigned. Host loopback MAY be used only in tests
(`BLOB_DOOR_BACKEND=memory`). Production SHALL set
`BLOB_DOOR_ALLOW_NONLOCAL=1` for this bind. INPUT from the TAP
subnet to that address and port SHALL be allowed; FORWARD SHALL
NOT be treated as the path.

#### Scenario: Guest can connect

- GIVEN `10.200.0.1/32` is assigned on `dummy-mjolnir`
- AND the door is running with `BLOB_DOOR_BIND=10.200.0.1:7222`
- WHEN a TAP guest opens TCP to `10.200.0.1:7222`
- THEN the connection is accepted
- AND `ss` on the host does not show `0.0.0.0:7222`

#### Scenario: Dummy address missing

- GIVEN `10.200.0.1` is not assigned
- WHEN the door is started with that bind
- THEN it does not start
- AND it does not fall back to `*` or `0.0.0.0`

#### Scenario: Public bind is proposed

- GIVEN a change that sets `BLOB_DOOR_BIND=0.0.0.0:7222`
- WHEN it is reviewed
- THEN it is rejected against this requirement

### Requirement: Guests are told the door URL, never B2 keys

On every boot the host SHALL inject `blob_door_url` (the overlay
HTTP origin, e.g. `http://10.200.0.1:7222`) into the guest via
vsock `configure_identity`. The guest SHALL persist it in
`/etc/mjolnir/vm.json` next to `api_url`. The guest SHALL NOT
receive `B2_*` credentials or the door's environment file.

#### Scenario: Fresh spawn

- GIVEN a VM has booted
- WHEN `/etc/mjolnir/vm.json` is read
- THEN it contains `blob_door_url` equal to `http://10.200.0.1:7222`
- AND it does not contain a B2 application key

#### Scenario: B2 keys appear in the guest

- GIVEN a change that copies `blob-door.env` or `B2_*` into a VM
- WHEN it is reviewed
- THEN it is rejected against this requirement

### Requirement: A guest puts and gets through the overlay door

A guest SHALL put and get blobs only via HTTP to `blob_door_url`
on the Sites blob routes. Large objects SHALL NOT use
`deliver_message`.

#### Scenario: PUT then GET from a guest

- GIVEN a running guest with `blob_door_url`
- WHEN it PUTs bytes whose Blake3 is `{h}` to
  `{blob_door_url}/storage/blob/b3/{h}`
- AND the door has accepted
- THEN GET of that URL from the same guest returns those bytes
- AND GET of that URL from a second guest returns those bytes

#### Scenario: Door dies, B2 still has it

- GIVEN a guest PUT the door reported accepted
- WHEN the door process is stopped
- THEN HeadObject or GET of `blob/b3/{h}` on B2 returns the same bytes

### Requirement: Sites talks to the door

When `:sites_storage_backend` is `Mjolnir.Sites.Storage.Recrypt`,
`MJOLNIR_RECRYPT_STORAGE_URL` SHALL be the blob door origin. Sites
SHALL NOT hold B2 credentials. Sites SHALL NOT require recrypt-server
`/files` for chunk put/get.

#### Scenario: Recrypt backend round-trip

- GIVEN `MJOLNIR_RECRYPT_STORAGE_URL` points at the door
- WHEN Sites puts a chunk and outboard
- THEN GET of `/storage/blob/b3/{hash}` on the door returns the ciphertext
- AND GET of `/storage/blob/b3/{hash}.obao` returns the outboard

#### Scenario: recrypt-server /files is proposed as the door

- GIVEN a change that sends Sites chunks through recrypt-server `POST /files`
- WHEN it is reviewed
- THEN it is rejected against this requirement
