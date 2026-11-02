# add-lan-file-server

> **ACTIVE BUILD**

## Why

The architecture change folded on 2026-10-24. `lan-files` is the
contract, and the share is not running. `mjolnir-h2fp.1` rebuilt
local `/opt/mjolnir`. Steer on 2026-10-26 picked the guest vehicle
for `mjolnir-h2fp.3`. This change is that implementation.

## What

- Capability touched: `lan-files` (already living). No new requirement.
- A small guest program links `identikey-auth` and
  `recrypt-storage-auth`, speaks the TAP-only blob-door, and keeps
  caps and the ownership index on the guest subvolume.
- Host IPv4 publish is DNAT on the Ethernet interface that holds
  the LAN address. No `0.0.0.0` fallback.
- `recrypt-server` stays unmodified. The BEAM does not link those crates.

## Impact

- Capabilities: none. Living `openspec/specs/lan-files/spec.md` is the contract.
- ADRs: none.

## User journey & surfaces

An operator on another machine on `192.168.0.0/24` reaches the share
over the host Ethernet address, not the guest TAP address and not
port 7222. They complete an `identikey-auth` challenge for the
share's fixed `aud`, then GET an authorized hash.

Working: the GET returns the bytes. Empty: the Ethernet interface
has no address, so IPv4 publish waits and does not open
`0.0.0.0`. Failed: a missing cap, a wrong holder, or a cap whose
root issuer is not the recorded owner is refused and the bytes
stay on the door. Off: the guest is not running, so the LAN
address does not answer.

## Out of scope

- Mesh ULA proxy and `meshd publish` — `mjolnir-h2fp.4`
- `add-iroh-blobs` — ADR 0003 remaining
- Patching `recrypt-server`
- Splitting `Mjolnir.VM` or `Mjolnir.API.Router`
