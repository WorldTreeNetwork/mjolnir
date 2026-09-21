# blob-store

What is built. Folded from
[`add-blob-store`](../../changes/archive/2026-08-17-add-blob-store/proposal.md),
[`add-blob-api`](../../changes/archive/2026-08-17-add-blob-api/proposal.md),
and
[`add-blob-client`](../../changes/archive/2026-08-17-add-blob-client/proposal.md)
on 2026-08-17, and
[`add-blob-door-overlay`](../../changes/archive/2026-08-19-add-blob-door-overlay/proposal.md)
on 2026-08-19, and
[`add-blob-door-byte-pump`](../../changes/archive/2026-09-20-add-blob-door-byte-pump/proposal.md)
on 2026-09-20. Decisions that are not yet code (iroh-blobs working
set, encryption) live in
[`docs/decisions/0003-blob-store-mesh.md`](../../../docs/decisions/0003-blob-store-mesh.md).

## Purpose

Content-addressed blobs. Address is Blake3 of the stored bytes,
layout is recrypt `blob/b3/{base58}`. Canonical copy is Backblaze
B2. Callers speak our HTTP door, never B2. Taskmaster stores
hashes, not bytes. We are not doing MinIO.

## Requirements

### Requirement: Accepted blobs are content-addressed

The put path SHALL identify an object by the Blake3 hash of the
bytes it stores. The object key SHALL be
`blob/b3/{base58(hash)}`, with an optional sibling
`blob/b3/{base58(hash)}.obao` as defined by `recrypt-storage`.
The put path SHALL refuse a write whose bytes do not hash to the
claimed key. A second write of the same hash SHALL be a no-op.
These checks SHALL live on the put path (a `BlobStorage`
implementation or the service in front of B2), not on raw S3.

#### Scenario: Re-PUT of the same bytes

- GIVEN an accepted object at `blob/b3/{h}`
- WHEN a client submits the same bytes under `{h}` again
- THEN the put path reports success
- AND no second object is created

#### Scenario: Hash does not match bytes

- GIVEN a client claims hash `{h}` for bytes whose Blake3 is not `{h}`
- WHEN the put path handles the write
- THEN it refuses
- AND `{h}` is not accepted

### Requirement: B2 is the canonical copy

An object SHALL NOT be reported accepted until a canonical copy
exists on Backblaze B2 under the same content-addressed key. The
put path SHALL confirm that copy with `HeadObject` or a GET of
that key before returning the hash. Delayed transition, asynchronous
replication, and filesystem snapshots SHALL NOT satisfy this
requirement. Destroying, replacing, or snapshotting any working-set
process or guest SHALL NOT be the durability mechanism.

#### Scenario: The door or a cache guest is destroyed

- GIVEN an object that was reported accepted
- WHEN the door process or any working-set guest is destroyed
- THEN a GET of that hash from B2 (or a replacement provider that
  registered the same hash) returns the same bytes

#### Scenario: Guest snapshot is proposed as the backup

- GIVEN a change that treats a BTRFS snapshot of a cache guest as
  the blob backup
- WHEN it is reviewed
- THEN it is rejected against this requirement

#### Scenario: ILM or async replicate is proposed as the ack

- GIVEN a change that reports accepted after queueing an ILM
  transition or an asynchronous replicate to B2
- WHEN it is reviewed
- THEN it is rejected against this requirement

### Requirement: Working-set guests are not snapshot-backed as the archive

If a later node adds an iroh-blobs working-set guest, that guest
SHALL NOT be enrolled in Mjolnir
filesystem snapshot backup to B2 (`mjolnir-qwp`, or an equivalent
`btrfs send` / rclone of the guest root or data volume as the
object archive). Image snapshots for faster spawn remain allowed
and SHALL NOT be treated as the blob archive. v1 SHALL NOT require
such a guest.

#### Scenario: An iroh-blobs working-set VM is spawned

- GIVEN the `add-iroh-blobs` recipe
- WHEN the VM or Lightning Mesh node is serving the working set
- THEN no snapshot-backup timer or hook is attached to it for blob
  durability
- AND accepted objects are still confirmed on B2

### Requirement: Hosts store hashes, not bytes

A consuming host (first: Taskmaster) SHALL persist a content hash
for a blob and SHALL NOT persist the blob bytes in the work-graph
database. Ready SHALL remain derived from edges.

#### Scenario: Evidence attachment is saved

- GIVEN a Taskmaster node gains a large attachment
- WHEN the write commits
- THEN the graph database contains the hash (and optional metadata)
- AND it does not contain the attachment bytes

### Requirement: The store is untrusted for confidentiality

B2 and any working-set cache (iroh-blobs peer or local disk)
SHALL be treated as untrusted for confidentiality. Encryption to a
personal key (then PRE-share) or to a Guild-Key, when present,
SHALL happen above the store. A host SHALL NOT treat bucket ACLs,
LUKS on a guest, or Iroh connection encryption as the
confidentiality boundary for guild or personal objects.

#### Scenario: Guild object is stored

- GIVEN a guild object that this system encrypts
- WHEN it is accepted
- THEN the bytes at the content hash are ciphertext
- AND the provider is not given the guild or personal private key

### Requirement: Consume recrypt-storage; do not grow a third layout

New provider and client code SHALL use `recrypt-storage`’s
`BlobStorage` key layout and hash function, or a client that speaks
that layout bit-for-bit. A change that introduces a parallel path
scheme or a different hash for the same objects SHALL be rejected.

#### Scenario: A Taskmaster-only key scheme is proposed

- GIVEN a change that stores objects at `/taskmaster/{uuid}` or under
  SHA-256 of the filename
- WHEN it is reviewed
- THEN it is rejected against this requirement

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

### Requirement: Taskmaster talks to the door

Taskmaster SHALL put and get blobs only via the blob door HTTP
surface. It SHALL persist the content hash (and optional size /
content-type) in its work-graph database. It SHALL NOT persist blob
bytes and SHALL NOT hold B2 credentials.

#### Scenario: Attachment is stored

- GIVEN `BLOB_DOOR_URL` points at a door
- WHEN Taskmaster accepts a body
- THEN it PUTs to `/storage/blob/b3/{hash}` on that door
- AND it writes a row keyed by that hash
- AND the row does not contain the body

#### Scenario: Door URL is missing

- GIVEN `BLOB_DOOR_URL` is unset
- WHEN a put or get is attempted
- THEN it fails closed
- AND no B2 environment variable is read

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

### Requirement: The door pumps bytes through host disk

The door SHALL stream PUT bodies to a host-disk incoming file and
SHALL hash Blake3 incrementally. It SHALL NOT buffer a whole object
in RAM as the put path. GET SHALL stream a cache file or the
canonical store. A configurable per-object ceiling
(`BLOB_DOOR_MAX_BYTES`, default 1 TiB) MAY refuse a PUT with 413.
Disk exhaustion SHALL be 507, not a silent truncate.

#### Scenario: PUT larger than the old RAM cap

- GIVEN a client PUTs 128 MiB whose Blake3 is `{h}`
- WHEN the door accepts
- THEN the process did not hold the 128 MiB as a single request
  `Bytes` extract
- AND GET `{h}` returns those bytes

#### Scenario: Disk is full

- GIVEN the cache filesystem cannot take the next write
- WHEN a PUT is in flight
- THEN the door returns 507
- AND `{h}` is not accepted

### Requirement: Local disk is a cache, not the accept proof

The door MAY retain accepted objects on host SSD as a working-set
cache and MAY serve GET/HEAD from that cache. The cache SHALL NOT
satisfy accept-time durability. A PUT SHALL NOT return 2xx accepted
until B2 HeadObject or GET confirms the key. GET SHALL NOT serve an
incoming (unaccepted) file. A GET fill SHALL NOT be published into
`objects/` if local flush or sync fails; a later GET SHALL fall
back to B2 rather than serve the partial file. Wiping the cache
directory SHALL NOT lose an object the door already reported
accepted (B2 still has it). Concurrent promotions and evictions
SHALL keep actual retained bytes at or under the configured budget
and SHALL fall back to B2 when a cache open races with eviction.

#### Scenario: Cache hit after accept

- GIVEN the door accepted `{h}` and the object is in the cache
- WHEN a client GETs `{h}`
- THEN the bytes are those accepted bytes
- AND the door does not need a B2 GET to answer

#### Scenario: Cache is wiped

- GIVEN `{h}` was accepted
- AND the cache directory is empty
- WHEN a client GETs `{h}`
- THEN the door fetches from B2
- AND returns the same bytes
- AND MAY refill the cache

#### Scenario: Ack from local file only is proposed

- GIVEN a change that returns 2xx accepted after the incoming file
  is renamed, before B2 HeadObject
- WHEN it is reviewed
- THEN it is rejected against this requirement

#### Scenario: Cache under btrfs_root is proposed

- GIVEN a change that places the door cache under `btrfs_root`
  (including `@blobs` or any nested subvolume on the data volume)
- WHEN it is reviewed
- THEN it is rejected against this requirement
  because VM and named snapshots would CoW-pin cache extents and
  the disk would fill monotonically

#### Scenario: Encoded traversal of the cache root

- GIVEN a GET or HEAD whose path is an absolute path or contains
  `..` after URL decoding
- WHEN the door handles the request
- THEN it returns 4xx
- AND it does not read a file outside `objects/`
- AND it does not serve an `incoming/` file

#### Scenario: Failed GET fill is not published

- GIVEN a GET miss that streams from B2
- AND the local fill flush or sync fails
- WHEN the request completes
- THEN `objects/` does not contain that hash
- AND a later GET of the same hash is served from B2

#### Scenario: Concurrent promotions stay under budget

- GIVEN an empty cache whose budget is 100 bytes
- WHEN two distinct 80-byte objects are promoted at once
- THEN at most one is retained
- AND the sum of sizes of files under `objects/` is ≤ 100

#### Scenario: Cache open races with eviction

- GIVEN `{h}` is accepted on B2
- AND a cache hit path is unlinked before open
- WHEN a client GETs `{h}`
- THEN the door returns the B2 bytes
- AND it does not return 404

### Requirement: Object identifiers are hashes before any filesystem access

GET, HEAD, and PUT SHALL treat the `{hash}` path parameter as a
Blake3 digest in base58 (optional `.obao` suffix) and SHALL reject
anything else with 4xx **before** joining it onto the cache or
store path. `DiskCache::object_path` SHALL NOT be reachable with a
string that is an absolute path or that contains a path separator
or `..`.

#### Scenario: Absolute path in GET

- GIVEN a GET whose `{hash}` decodes to an absolute filesystem path
- WHEN the door handles it
- THEN the response is 4xx
- AND the named file is not read

#### Scenario: Parent traversal in GET

- GIVEN a GET whose `{hash}` is `..%2Fincoming%2F<name>`
- WHEN the door handles it
- THEN the response is 4xx
- AND no `incoming/` file is served

### Requirement: Cache root is enforced on the resolved path

Production start and the install script SHALL resolve
`BLOB_DOOR_CACHE_DIR` (and any fallback) and SHALL refuse a
location whose resolved path is under `btrfs_root`. A textual
prefix check alone SHALL NOT satisfy this requirement. Custom
accepted paths SHALL stay inside the unit's `ReadWritePaths`.

#### Scenario: Symlink into the data volume

- GIVEN `BLOB_DOOR_CACHE_DIR` is a symlink whose target is under
  `btrfs_root`
- WHEN the door starts or the installer runs
- THEN it refuses that directory
- AND it does not write cache files on the data volume

#### Scenario: Fallback still under btrfs_root

- GIVEN a configured cache dir that fails the check
- AND the fallback would also resolve under `btrfs_root`
- WHEN install or start runs
- THEN it still refuses
- AND it does not silently accept the unsafe fallback
