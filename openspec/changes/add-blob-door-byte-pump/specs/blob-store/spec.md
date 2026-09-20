## ADDED Requirements

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
incoming (unaccepted) file. Wiping the cache directory SHALL NOT
lose an object the door already reported accepted (B2 still has it).

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
