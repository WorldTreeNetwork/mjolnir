# Design — LAN Recrypt share

**Status:** Proposed. ACTIVE BUILD. Steer 2026-09-04 decide-for-me.
**Change:** `add-lan-file-server`
**Epic:** `mjolnir-h2fp`
**Bead:** `mjolnir-h2fp.2`
**Grok authored.** Advise reader must not be Grok (ADR-005).

This is the architecture write. Code is later `act` after advise
accept.

## Three layers. Do not collapse them.

From `identikey-capability-v1.md`:

| Layer | Crate / spec | This change |
|---|---|---|
| Identity | `identikey-auth` (protocol, permissive) | Guest issues `Challenge`, verifies `Response`. `aud` = this share. |
| Agency | Biscuit `identikey-capability-v1` | Not this node. Mjolnir `exec`/`spawn` stays `update-identikey-capability`. |
| Data | `recrypt-storage-auth` (AGPL) + Recrypt D-5 | `Capability` on Blake3 File subjects. Recryption key is the bearer. |

`identikey-core` is the AGPL hosted OP. It consumes `identikey-auth`
for the URN grant. The guest does not depend on it.

## Why not a directory NAS

`recrypt-storage-auth::Capability.subject` is `[u8; 32]` plus
`SubjectKind` (`file` \| `keyspace` \| `account`). A path like
`/photos/x.jpg` is not a subject unless hashed. Steer rejected
"both" (dir listing plus hashed GET) as two products.

## Where bytes live

Host blob-door on `:host_api_ip:7222` (`10.200.0.1`). Living
`blob-store` already forbids `0.0.0.0`. The guest is a Recrypt
HTTP process that PUTs/GETs the door over TAP INPUT. LAN clients
never speak to the door.

## How LAN sees it

The guest TAP IP is not the local network. Publish is DNAT or a
host proxy onto `192.168.0.18` (USB Ethernet) and the mesh ULA
`fd01:d28c:7e4a` (wifi RA). Blob-door bind is unchanged.

## Mesh

This laptop is a mesh *client*, not `mjolnir-meshd`. Discovery is
`meshd publish --ip <host>` on the attached OpenWrt router
(`lightning-mesh` `docs/deploy/mesh-app-publishing.md`). Radio
(802.11s / babel) already carries IP. `add-iroh-blobs` stays ADR
0003 remaining.

## Licence

Guest may run `recrypt-server` (AGPL binary). Mjolnir BEAM does
not link `recrypt-storage-auth` or `recrypt-core`. `identikey-auth`
is Apache-2.0 OR BSD-2-Clause-Patent and may live in the guest
verifier.

## Contrast rejected

Guest HTTP dir + `extra_mounts` | host sidecar LAN bind of blob-door
| Sites/gateway ServeDir | iroh-blobs as archive | LAN-trust |
password | Iroh ticket only.
