# lan-files

Contract. Folded from
[`add-lan-file-server`](../../changes/archive/2026-10-24-add-lan-file-server/proposal.md)
on 2026-10-24 (bead `mjolnir-h2fp.2`). No Mjolnir ADR. Recrypt D-5
and identikey-capability-v1 are cited, not amended.

Guest Recrypt HTTP, LAN publish, and `meshd` are later landings
(`mjolnir-h2fp.3`, `mjolnir-h2fp.4`). This file is the requirement
contract those landings have to meet. It is not a claim that the
share is running.

## Purpose

A LAN file share is Recrypt objects in a guest, not a directory
NAS and not a public bind of the blob-door. Identity is
`identikey-auth` with one fixed service `aud`. Data access is a
`recrypt-storage-auth` Capability on the Blake3 file hash, in the
storage-auth fingerprint namespace, rooted at the first putter.
Bytes stay on the TAP-only door. LAN and mesh reach the guest.

## Requirements

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

- GIVEN a challenge issued for this share's fixed service `aud`
- WHEN a valid `Response` is presented from LAN v4, mesh ULA, or
  `.mesh`
- THEN `verify_response` succeeds
- AND `aud` equals that same service id regardless of the address
  the client used
- AND the §5 fingerprint is `Blake3(dcbor(PublicKey))`, not the
  storage-auth fingerprint

#### Scenario: Hosted OP is proposed as the only proof

- GIVEN a change that requires `identikey-core` or
  `auth.identikey.me` inside the guest to serve files
- WHEN it is reviewed
- THEN it is rejected against this requirement

#### Scenario: Unmodified recrypt-server is proposed as the guest

- GIVEN stock `recrypt-server` (`GET /files/{hash}` public, no
  identikey-auth, storage not blob-door)
- WHEN it is reviewed as the LAN share
- THEN it is rejected against this requirement

### Requirement: Data access is recrypt-storage-auth

Read of stored bytes SHALL require a `recrypt-storage-auth`
`Capability` whose `subject` is the file hash, `granted_to` is the
storage-auth fingerprint of the claimant, and permissions include
`read`. The share SHALL map a verified `Response`'s classical
Ed25519 public key to that fingerprint as
`Blake3(raw 32-byte key)` before the cap check, and SHALL issue
Caps in that namespace. It SHALL NOT compare `granted_to` to the
identikey-auth §5 fingerprint. First put of `h` SHALL record
`ownership(h)` as the putter's storage-auth fingerprint. GET
SHALL require the Capability's root `issuer` to equal
`ownership(h)`. The recryption key SHALL remain the data bearer.
The Mjolnir BEAM SHALL NOT link `recrypt-storage-auth`.

#### Scenario: Cap permits read

- GIVEN a verified `Response` whose classical key is Ed25519 `K`
- AND `g = Blake3(K)` (raw key bytes, storage-auth namespace)
- AND `ownership(h) = g`
- AND a Capability for hash `h` granted to `g` with `read` whose
  root issuer is `g`
- WHEN GET of `h` is requested
- THEN the bytes are returned
- AND `granted_to` was not compared to `Blake3(dcbor(PublicKey))`

#### Scenario: Cap issued by non-owner

- GIVEN `ownership(h) = g_owner`
- AND a Capability for `h` granted to claimant `g` whose root
  issuer is not `g_owner`
- WHEN GET of `h` is requested
- THEN it is refused
- AND a self-issued cap does not read `h`

#### Scenario: Cap missing or wrong holder

- GIVEN a verified identity whose storage-auth fingerprint is `g`
- AND no Capability granting `g` `read` on `h`
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

The share HTTP SHALL be published onto the host IPv4 LAN
interface and the Lightning Mesh wifi interface. Publish SHALL
bind by interface. When a named interface has no address, publish
SHALL wait or fail; it SHALL NOT fall back to `0.0.0.0`, `::`, or
the host GUA. The IPv6 leg SHALL be a host userspace proxy (TAP
has no IPv6). TAP-only bind SHALL NOT satisfy this requirement.

#### Scenario: Ethernet client fetches

- GIVEN the Ethernet interface is up with an IPv4 address
- AND the share is running
- WHEN a host on that LAN completes identity and cap checks
- THEN GET of an authorized hash succeeds

#### Scenario: Mesh ULA is reachable

- GIVEN the wifi interface holds a stable-privacy (or
  `ipv6.token`) ULA
- AND the share proxy is bound to that address
- WHEN a mesh client completes the same checks
- THEN GET of an authorized hash succeeds

#### Scenario: Ethernet unplugged

- GIVEN the named Ethernet interface has no address
- WHEN publish starts
- THEN it does not bind `0.0.0.0` or the GUA
- AND the IPv4 publish path waits or fails
- AND the TAP-only door bind is unchanged

### Requirement: Mesh discovery is meshd, not iroh-blobs

`.mesh` discovery SHALL be `meshd publish` on the attached mesh
router. This host SHALL NOT run `mjolnir-meshd` for this change.
`add-iroh-blobs` SHALL NOT be opened as this share.

#### Scenario: iroh-blobs is proposed as the share

- GIVEN a change that treats iroh-blobs as the archive or the
  LAN file server
- WHEN it is reviewed
- THEN it is rejected against this requirement
