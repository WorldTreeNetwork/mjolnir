# steer add-lan-file-server

**When.** 2026-09-04
**Depth.** standard (decide-for-me closed remaining forks)

## Decided

- Product: Recrypt share (user | decide-for-me)
  Why: `recrypt-storage-auth` subjects are 32-byte hashes, not paths.
- Who: `identikey-auth` Challenge/Response (user)
- What on bytes: `recrypt-storage-auth` Capability (user)
- Serving: Recrypt HTTP in a Mjolnir guest; blob-door TAP-only (auto)
- Bind: `192.168.0.18` + `fd01:d28c:7e4a` ULA (auto)
- Mesh: `meshd publish` on attached router, no `add-iroh-blobs` (auto)
- Rebuild `/opt/mjolnir`: yes, tracked on `mjolnir-h2fp.1` (auto)

## Skipped

None.

## Feeds change

A LAN-reachable Recrypt share, not a NAS. Guest verifier uses
`identikey-auth`. Caps use `recrypt-storage-auth` File subjects.
Bytes stay on blob-door. BEAM does not link Recrypt auth. Guest
does not depend on `identikey-core`.
