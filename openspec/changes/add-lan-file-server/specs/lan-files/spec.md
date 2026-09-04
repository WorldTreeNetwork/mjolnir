## ADDED Requirements

### Requirement: Share is Recrypt objects, not a directory NAS

A LAN file share on this host SHALL treat each stored object as a
Blake3-addressed Recrypt `File` subject. A filesystem path SHALL
NOT be the authorization subject. `extra_mounts` of a host
directory SHALL NOT be the file namespace.

#### Scenario: Put is content-addressed

- GIVEN an authenticated owner and file bytes
- WHEN the share accepts the put
- THEN the object is identified by Blake3 of those bytes
- AND a `recrypt-storage-auth` `Capability` for `SubjectKind::File`
  can name that hash

#### Scenario: Directory NAS is proposed

- GIVEN a change that authorizes `/photos/x.jpg` as a path without
  a 32-byte subject
- WHEN it is reviewed
- THEN it is rejected against this requirement

### Requirement: Identity is identikey-auth

The share SHALL verify an `identikey-auth` `Response` to a
challenge whose `aud` is this service. A password, LAN-trust, or
Iroh ticket SHALL NOT be the identity proof. The guest SHALL NOT
depend on `identikey-core`.

#### Scenario: Claimant holds the key

- GIVEN a challenge issued for this share's audience
- WHEN a valid `Response` is presented
- THEN `verify_response` succeeds
- AND the fingerprint is the classical public key fingerprint

#### Scenario: Hosted OP is proposed as the only proof

- GIVEN a change that requires `identikey-core` or
  `auth.identikey.me` inside the guest to serve files
- WHEN it is reviewed
- THEN it is rejected against this requirement

### Requirement: Data access is recrypt-storage-auth

Read of stored bytes SHALL require a `recrypt-storage-auth`
`Capability` whose `subject` is the file hash, `granted_to` is the
claimant's fingerprint, and permissions include `read`. The
recryption key SHALL remain the data bearer. The Mjolnir BEAM
SHALL NOT link `recrypt-storage-auth`.

#### Scenario: Cap permits read

- GIVEN a Capability for hash `h` granted to fingerprint `f` with
  `read`
- AND a verified identity whose fingerprint is `f`
- WHEN GET of `h` is requested
- THEN the bytes are returned

#### Scenario: Cap missing or wrong holder

- GIVEN identity `f` and no Capability granting `f` `read` on `h`
- WHEN GET of `h` is requested
- THEN it is refused
- AND the bytes are not returned

### Requirement: Blob-door stays TAP-only

Canonical bytes SHALL be stored via the host blob-door on
`:host_api_ip:7222`. The door SHALL NOT bind `0.0.0.0`, `::`, or
the host public NIC. LAN clients SHALL reach the guest Recrypt
HTTP, not the door.

#### Scenario: Guest talks to the door

- GIVEN the door bound at `10.200.0.1:7222`
- WHEN the share guest puts an object
- THEN the put uses `blob_door_url`
- AND `ss` on the host does not show `0.0.0.0:7222`

### Requirement: LAN and mesh ULA can reach the guest

The share HTTP SHALL be published onto the host IPv4 LAN address
and the Lightning Mesh ULA on this box. TAP-only bind SHALL NOT
satisfy this requirement.

#### Scenario: Ethernet client fetches

- GIVEN the share is running
- WHEN a host on `192.168.0.0/24` completes identity and cap
  checks
- THEN GET of an authorized hash succeeds

#### Scenario: Mesh ULA is reachable

- GIVEN the share is published on `fd01:d28c:7e4a`
- WHEN a mesh client completes the same checks
- THEN GET of an authorized hash succeeds

### Requirement: Mesh discovery is meshd, not iroh-blobs

`.mesh` discovery SHALL be `meshd publish` on the attached mesh
router. This host SHALL NOT run `mjolnir-meshd` for this change.
`add-iroh-blobs` SHALL NOT be opened as this share.

#### Scenario: iroh-blobs is proposed as the share

- GIVEN a change that treats iroh-blobs as the archive or the
  LAN file server
- WHEN it is reviewed
- THEN it is rejected against this requirement
