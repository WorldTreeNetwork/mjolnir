## ADDED Requirements

### Requirement: Accepted blobs are content-addressed

A storage provider SHALL identify an object by the Blake3 hash of the
bytes it stores. The object key SHALL be
`blob/b3/{base58(hash)}`, with an optional sibling
`blob/b3/{base58(hash)}.obao` as defined by `recrypt-storage`.
A provider SHALL refuse a PUT whose bytes do not hash to the claimed
key. A second PUT of the same hash SHALL be a no-op.

#### Scenario: Re-PUT of the same bytes

- GIVEN an accepted object at `blob/b3/{h}`
- WHEN a client PUTs the same bytes under `{h}` again
- THEN the store reports success
- AND no second object is created

#### Scenario: Hash does not match bytes

- GIVEN a client claims hash `{h}` for bytes whose Blake3 is not `{h}`
- WHEN the provider handles the PUT
- THEN it refuses
- AND `{h}` is not accepted

### Requirement: B2 is the canonical copy

An object SHALL NOT be reported accepted until a canonical copy exists
on Backblaze B2 under the same content-addressed key. A Mjolnir guest
running MinIO is a working set. Destroying, replacing, or snapshotting
that guest SHALL NOT be the durability mechanism for accepted objects.

#### Scenario: The MinIO guest is destroyed

- GIVEN an object that was reported accepted
- WHEN the provider VM is destroyed
- THEN a GET of that hash from B2 (or a replacement provider that
  registered the same hash) returns the same bytes

#### Scenario: Guest snapshot is proposed as the backup

- GIVEN a change that treats a BTRFS snapshot of the MinIO guest as
  the blob backup
- WHEN it is reviewed
- THEN it is rejected against this requirement

### Requirement: This VM class does not use filesystem-snapshot backup

A storage-provider VM SHALL NOT be enrolled in Mjolnir filesystem
snapshot backup to B2 (`mjolnir-qwp`, or an equivalent `btrfs send` /
rclone of the guest root or data volume as the object archive).
Image snapshots for faster spawn remain allowed and SHALL NOT be
treated as the blob archive.

#### Scenario: New provider VM is spawned

- GIVEN the `add-minio-mesh` recipe
- WHEN the VM is running
- THEN no snapshot-backup timer or hook is attached to it for blob
  durability
- AND MinIO’s B2 remote is configured

### Requirement: Hosts store hashes, not bytes

A consuming host (first: Taskmaster) SHALL persist a content hash for
a blob and SHALL NOT persist the blob bytes in the work-graph
database. Ready SHALL remain derived from edges.

#### Scenario: Evidence attachment is saved

- GIVEN a Taskmaster node gains a large attachment
- WHEN the write commits
- THEN the graph database contains the hash (and optional metadata)
- AND it does not contain the attachment bytes

### Requirement: The store is untrusted for confidentiality

MinIO and B2 SHALL be treated as untrusted for confidentiality.
Encryption to a personal key (then PRE-share) or to a Guild-Key, when
present, SHALL happen above the store. A host SHALL NOT treat bucket
ACLs or LUKS on the provider guest as the confidentiality boundary
for guild or personal objects.

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
