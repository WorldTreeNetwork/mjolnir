# add-lan-file-server

> **ACTIVE BUILD**

Activated from intend 2026-09-04 (`mjolnir-h2fp.2`, wave 1).
Steer 2026-09-04 decide-for-me. Bead `mjolnir-h2fp.2`. Epic `mjolnir-h2fp`.

**Rigor:** architecture

## Why

This host already runs Mjolnir and is a Lightning Mesh *client*
(`fd01:d28c:7e4a` on wifi, `192.168.0.18` on Ethernet). A file
server that is only TAP-local is not on the LAN. A directory NAS
cannot use Recrypt's authorization crate: `recrypt-storage-auth`
subjects are 32-byte content addresses, not paths. Identity is
`identikey-auth` (possession proof), not a password and not the
AGPL hosted OP.

## What

- Add capability `lan-files`: a Recrypt share hosted in a Mjolnir
  guest, reachable on the host LAN and mesh ULA.
- Identity: `identikey-auth` `Challenge` / `Response` with a
  fixed service `aud` (not a locator). Cap checks use a mapped
  storage-auth fingerprint (`Blake3` of raw Ed25519), not the
  §5 fingerprint.
- Data access: `recrypt-storage-auth` `Capability` on `SubjectKind::File`
  (Blake3). Recryption key remains the data bearer (Recrypt D-5).
- Bytes live on the host blob-door (`10.200.0.1:7222`). The door
  stays TAP-only. The guest is what LAN/mesh see.
- Mesh discovery: `meshd publish --ip` on the attached OpenWrt
  router. Radio stays plumbing.

## Impact

- Capabilities: ADDED `lan-files`
- ADRs: none in Mjolnir. Recrypt D-5 and identikey-capability-v1
  three-layer split are cited, not amended.
- Does not bind blob-door on `0.0.0.0`.
- Does not link `recrypt-storage-auth` into the BEAM.
- Does not depend on `identikey-core` in the guest.
- Does not open `add-iroh-blobs`.
- Does not make Sites or the gateway a file server.

## User journey & surfaces

Who: a person on the home LAN or mesh wifi, with an IdentiKey.
Surfaces: Recrypt HTTP in the guest (after later act), blob-door
from the guest TAP, `meshd` on the attached router.

- **Working (after later act)** — owner puts a file; hash is the
  subject; a `Capability` with `read` is issued to a fingerprint;
  another machine on `192.168.0.0/24` proves identity and fetches
  the bytes. A mesh client can use the `.mesh` name once published.
- **Empty** — `openspec/specs/lan-files/` does not exist yet.
- **Failed (today)** — one VM on TAP only; blob-door inactive
  locally; no LAN publish; no Recrypt guest.
- **Off** — Duke parks. Design is amended in place.

## Out of scope

- Directory NAS / `extra_mounts` listing — rejected at steer
- `add-iroh-blobs` — ADR 0003 remaining (`mjolnir` blob-store)
- Biscuit Mjolnir agency (`exec` / `spawn`) — `update-identikey-capability`
- Hosted OP / `identikey-core` in the guest
- Binding blob-door on the public NIC — living `blob-store`
- `mjolnir-h2fp.1` local Elixir upgrade — brief/act, not this change
- `mjolnir-h2fp.4` mesh advertise implementation — after LAN serving
- Gateway rewrite / Sites ServeDir — ADR 0001
