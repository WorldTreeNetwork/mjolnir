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

## Fingerprint join (explicit, not by accident)

`identikey-auth` §5 fingerprint is `Blake3(dcbor(PublicKey))` —
for Ed25519 that is the self-describing `{alg,key}` map, not the
bare 32 bytes. `recrypt-storage-auth` `granted_to` is
`Blake3(raw Ed25519 bytes)`. Those are distinct namespaces by
construction (auth-challenge v1 §5). This change does not amend
Recrypt.

The share maps `Response` classical public key → storage-auth
fingerprint (`Blake3` of the raw Ed25519 key bytes) **before**
the cap check, and issues Caps in that namespace. GET compares
`granted_to` to the mapped fingerprint, never to the §5
fingerprint. Interop is the map, named here.

Put is identikey-auth gated. First successful put of hash `h`
records `ownership(h) = g_putter` via `OwnershipStore::register`
(first putter wins; a different owner is refused). GET requires
the presented Capability (or chain root) `issuer` to equal
`ownership(h)`. Issuer verifying keys are learned from `Verified`
at auth time, keyed by `g`. A cap the claimant self-issues for
someone else's hash SHALL NOT read.

## `aud` is a service id, not a locator

`identikey-auth` `aud` is one fixed identifier for this share (a
URN or the share's own fingerprint). It is the same on LAN v4,
mesh ULA, and `.mesh`. It is never derived from `Host`, bound
address, or port.

## How LAN sees it

The guest TAP IP is not the local network and is IPv4-only
(`Network.allocate_ip/1`). Publish is host-side:

- IPv4: DNAT or a reverse-proxy matched on the Ethernet
  interface (example address `192.168.0.18/24` when that iface
  is up).
- IPv6: a **host userspace proxy** on the wifi interface's
  stable-privacy ULA (or an `ipv6.token`). TAP has no IPv6, so
  DNAT66/NAT64 is not the v6 leg. Example prefix
  `fd01:d28c:7e4a::/48` is not an address; `h2fp.4` publishes
  the stable ULA, not a temporary address and not the GUA.

Binds are **by interface**, not by a hardcoded address. When
the named interface has no address, publish waits or fails. It
does not fall back to `0.0.0.0`, `::`, or the Comcast GUA.
Blob-door bind is unchanged. Publish port is not 7222 on any
non-TAP address.

## Mesh

This laptop is a mesh *client*, not `mjolnir-meshd`. Discovery is
`meshd publish <name> --ip <stable-ULA> --port <p>` on the
attached OpenWrt router
(`lightning-mesh` `docs/deploy/mesh-app-publishing.md`). `--ip`
scopes the name as `<name>.<node>.mesh`. Radio (802.11s / babel)
already carries IP. `add-iroh-blobs` stays ADR 0003 remaining.

## Guest HTTP is not stock recrypt-server

Unmodified `recrypt-server` does not satisfy this share:
`GET /files/{hash}` is public; auth is dual-sig + nonce, not
`identikey-auth`; storage is memory|local, not blob-door; default
persistence is memory. `h2fp.3` is Recrypt HTTP that does four
things: (1) identikey-auth Challenge/Response with the fixed
`aud`, (2) cap-gated GET using the mapped storage-auth
fingerprint, (3) PUT/GET bytes on `blob_door_url`, (4) durable
caps/index (guest subvolume snapshot or a durable mount). Patch
`recrypt-server` or a small guest that links `identikey-auth` +
`recrypt-storage-auth` and speaks the door. Do not AGPL-link
those crates into the BEAM.

## Contrast rejected

Guest HTTP dir + `extra_mounts` | host sidecar LAN bind of blob-door
| Sites/gateway ServeDir | iroh-blobs as archive | LAN-trust |
password | Iroh ticket only.
