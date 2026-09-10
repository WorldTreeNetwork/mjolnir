# add-buzz-relay

> **ACTIVE BUILD**
>
> Tracks `mjolnir-gti` (B0). Split out of PENDING `add-buzz-local-runtime`
> so the leftover facade / `@base/dev` / admit-crate bag does not gate
> the demo hive.

**Rigor:** architecture

## Why

`buzz-backend-mjolnir` can only fully work against a relay *we* run.
Block-hosted communities (`*.communities.buzz.xyz`, including the
current Desktop hive `wss://cgcoop.communities.buzz.xyz`) refuse the
provider-deployed identity class (desktop-minted key + NIP-OA
`auth_tag`) with `restricted: not a relay member`
([block/buzz#2663](https://github.com/block/buzz/issues/2663),
2026-08-05 correction). That is platform policy, not a bug in the
adapter. B0 is the demo environment, not the hosted product.

Block published the operator recipe on 2026-09-10:
https://engineering.block.xyz/blog/run-your-own-buzz-relay — one
Rust binary, Postgres 17, Redis 7, MinIO, compose in
`deploy/compose/`.

## What

- Run the Block `.env` contract as **four systemd units** in one
  named VM `buzz-relay` (not Docker compose: guest kernel has no
  NETFILTER/BRIDGE). Event log, blobs, and git volume stay on the
  guest rootfs. `mj snapshot create` is the hive backup
  (crash-consistent); `mj freeze` is not.
- Advertise `RELAY_URL=wss://buzz.identikey.me` from first boot.
  Point DNS at 45.76.77.97 (today it CNAMEs to a Linode apex),
  HTTP-01 cert, gateway TLS — no nested Caddy.
- Cutover-free `Deploy.Registry` adopt so `mj domain` / `mj cert`
  work without `mj deploy`.
- Closed membership + `BUZZ_ALLOW_NIP_OA_AUTH=true`. Owner is the
  existing Buzz Desktop identity. Secrets via `secrets_mode:
  managed` + `POST /api/vms/:id/secrets`, not `mj secrets` (that
  surface requires a redeploy).
- MODIFIED `buzz-local-client`: pin the B0 relay and the
  provider-deployed identity SHALL (moved here from
  `add-buzz-local-runtime`).

## Impact

- Capabilities: MODIFIED `buzz-local-client`
- ADRs: none (0002 already accepted; this is B0, not B1 / `mjolnir-80q`)

## User journey & surfaces

Duke, from the **Buzz desktop** on the Mac, plus `mj` on the same
machine talking to `https://api.vm.worldtree.network`.

1. Operator has a named app `buzz-relay` (4 GB VM, native units)
   adopted into `Deploy.Registry`. **Today: off.**
2. Desktop **Join a Community** with `wss://buzz.identikey.me`.
   **Today: off** (DNS is the Linode apex; no cert).
3. Owner identity is a relay member (`RELAY_OWNER_PUBKEY` bootstraps
   the `owner` row). **Today: off.**
4. A later `buzz-backend-mjolnir` `deploy` presenting `private_key_nsec`
   + `auth_tag` is not refused as `restricted: not a relay member`.
   **Today: failed** on Block-hosted; **off** here (no hive). Provider
   `deploy` itself remains a stub — this change only provides the
   target.

No new UI because Join, `mj domain`, `mj secrets`, and
`curl /_liveness` already exist.

## Out of scope

- Provider `deploy` op — `buzz-backend-mjolnir` PLAN.md P1
- Hosted product, billing, community egress — `mjolnir-80q`
- Recrypt / Blossom encryption — `mjolnir-800`
- Protocol facade, admit crate, `@base/dev` — remainder of
  `add-buzz-local-runtime`
- Nested Caddy / Let's Encrypt inside the guest
- Host-sidecar Postgres or Redis for this hive (forbidden)
- Casual `mj deploy` cutover of a stateful hive
- Guest kernel rebuild / virtiofsd `--xattr` / Docker-in-guest
- Pinning `ghcr.io/block/buzz` to a digest (B0 tracks `:main`)
