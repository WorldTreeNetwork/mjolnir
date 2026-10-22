## ADDED Requirements

### Requirement: A recording index stores wraps beside a blob

The system SHALL record a recording as the Blake3 hash of ciphertext already stored by the blob backend, the owner's base58btc XID, and the owner wrap bytes. It SHALL record a friend wrap as that same hash, the friend's base58btc XID, and the wrap bytes the caller supplies. It SHALL NOT generate a data key, unwrap a data key, store plaintext, store a private scalar, or call IdentiKey.

The system SHALL refuse a registration whose hash is not already in the blob backend, and SHALL insert no row in that case. The presence check SHALL be `HEAD /storage/blob/b3/{hash}` for the door backend, or a file stat for the local backend. It SHALL NOT GET the ciphertext. An empty wrap, a wrap larger than 4096 bytes, or a wrap that is not a CBOR map with `alg` `x25519-xchacha20poly1305` and a 48-byte `ciphertext` SHALL be refused, and the wrap SHALL NOT be decrypted. Register, friend add, and GET SHALL require principal kind `:user` and SHALL bind the row to that JWT `sub`. A `:capability`, `:operator`, `:sites`, `:ceremony`, or `:public` caller SHALL be refused before any probe or write, and no row SHALL be written. The same owner wrap from that same `sub` SHALL succeed. The same owner wrap from a different `sub` SHALL be refused. A different owner wrap for that hash SHALL be refused. The check-and-write SHALL be serialized in the `Store` GenServer so two different wraps cannot both succeed. The file SHALL be `<sites_root>/recordings/<hash58>.json`, outside `blob/b3/`. The first `:user` to register a hash owns that row. That race is not the chunk route: a chunk hash has only one byte string, and this row does not. The stored owner XID is the registrant's claim, not a proof. One friend XID SHALL have one wrap. The same friend wrap from the registering `sub` SHALL succeed. A different friend wrap SHALL be refused. A friend add from any other `sub` SHALL be refused. A friend XID equal to the owner XID SHALL be refused. This index SHALL NOT be the path that delivers a wrap to a friend. The friend receives their wrap from the owner. The client keeps the owner wrap. The sites backup copies the row on its next daily run, not at ack.

A v1 recording SHALL be one ciphertext object within the existing 64 MiB blob-route body. A chunked recording is out of this requirement. Replacing the owner wrap after the owner's X25519 changes is out of this requirement. Recovery is a new ciphertext and a new hash.

The index row SHALL be an atomic fsync-and-rename file under the sites root, so the sites backup copies it. A restart SHALL read that file. Postgres SHALL NOT be required to serve the row.

`GET` of the index SHALL return the hash, the owner XID, the owner wrap, and the friend wraps only to the registering principal. Any other principal SHALL be refused. The body SHALL NOT return the ciphertext, the data key, or a private scalar. The friend list is social-graph metadata and is not given the same unscoped read as the ciphertext.

#### Scenario: An owner wrap is stored for an accepted blob

- GIVEN ciphertext whose Blake3 is `{h}` is already in the blob backend
- WHEN the owner registers `{h}` with their XID and a wrap
- THEN the index row stores that hash, that XID, and that wrap
- AND the blob bytes are unchanged

#### Scenario: A missing blob inserts nothing

- GIVEN `{h}` is not in the blob backend
- WHEN a caller registers an owner wrap for `{h}`
- THEN the call fails
- AND no index row exists

#### Scenario: A second owner wrap is refused

- GIVEN `{h}` is registered with owner wrap W
- WHEN a caller registers `{h}` with a different wrap W′
- THEN the call fails
- AND the stored wrap is still W

#### Scenario: A friend wrap is stored without calling IdentiKey

- GIVEN `{h}` is registered to an owner
- WHEN the caller adds a friend XID distinct from the owner and a wrap
- THEN the index stores that friend wrap
- AND no request is sent to an IdentiKey origin

#### Scenario: The owner is not a friend of their own blob

- GIVEN `{h}` is registered to owner XID `A`
- WHEN a caller adds friend XID `A`
- THEN the call fails
- AND no friend row is stored

#### Scenario: The index is not the data key

- GIVEN a registered recording
- WHEN the registering principal reads the index
- THEN the body contains the hash and the wrap bytes
- AND the body does not contain the ciphertext or a 32-byte data key field

#### Scenario: A different principal cannot add a friend

- GIVEN JWT subject P registered `{h}`
- WHEN JWT subject Q adds a friend wrap for `{h}`
- THEN the call fails
- AND no friend row is stored

#### Scenario: A biscuit and a Sites token cannot register

- GIVEN a `:capability` biscuit whose `user_id` is `"capability"`, and a `:sites` token
- WHEN either caller registers, adds a friend, or reads the index
- THEN each call is refused before a probe or a write
- AND no row is written

#### Scenario: Register does not download the ciphertext

- GIVEN ciphertext whose Blake3 is `{h}` is already in the blob backend
- WHEN a principal registers `{h}`
- THEN the presence check is a HEAD or a file stat
- AND the ciphertext bytes are not read

#### Scenario: The wrap file survives a restart

- GIVEN a registered owner wrap
- WHEN the process restarts
- THEN a read by the same principal returns that wrap
- AND the file is under the sites root
