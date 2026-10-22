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
