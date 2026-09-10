# steer add-buzz-relay

**When.** 2026-09-10
**Depth.** standard

## Decided
- RELAY_URL domain: `buzz.identikey.me` (user)
  Why: `*.identikey.me` already CNAMEs to the gateway; wildcard Origin cert; community identity set before first boot.
- Owner pubkey: existing Desktop identity `f3dbbf663cd541de2503a541bfbf9652075dd28cebc624d21ee9ab0d1c118c1d` (auto)
  Why: already the NIP-OA attester on cgcoop Fizz/Honey; Join with the same identity.
- Shape: Block production compose in one VM; data on guest rootfs (auto)
- TLS: Mjolnir gateway, not nested Caddy (auto)
- Lifecycle: named stateful app, no casual deploy cutover (auto)
- Policy: `BUZZ_ALLOW_NIP_OA_AUTH=true` + closed membership (auto)
- Memory / image: 4096 MB, `ghcr.io/block/buzz:main` (auto)

## Skipped
- none

## Feeds change
B0 is one named VM `buzz-relay` running Block's `deploy/compose/` behind `wss://buzz.identikey.me`. Gateway TLS. Secrets in `mj secrets`. NIP-OA on so `buzz-backend-mjolnir` has a hive that will accept provider-deployed agents. Not B1, not the provider deploy op, not host-sidecar data.

## Amend after 2026-09-10 send-back
- Runtime: native systemd units, not compose (guest kernel has no NETFILTER/BRIDGE; virtiofsd has no --xattr). Compose `.env` is the contract.
- DNS/TLS: live host is HTTP-01 per name; add `buzz.identikey.me` A 45.76.77.97; no wildcard Origin cert. Gateway-routing.md is stale.
- Bind: Registry adopt, not `mj deploy` (Detector is SvelteKit-only; cutover empties the hive).
- Secrets: VM-level `secrets_mode: managed` + POST /api/vms/:id/secrets. `mj secrets` requires redeploy.
- Snapshot: `mj snapshot create` is crash-consistent; freeze is not backup.
