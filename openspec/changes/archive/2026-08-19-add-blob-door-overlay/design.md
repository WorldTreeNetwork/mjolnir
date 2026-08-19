# Design — blob door on the guest overlay

Implements ADR 0003 Decision 1b on the private guest net. Not a new ADR.

**Status:** ACTIVE BUILD
**Change:** `add-blob-door-overlay`
**Parent:** ADR 0003 (accepted). Overlay IP from ADR 0005 / `add-host-sidecar-tenant`.

## Pins

1. **One overlay IP.** `:host_api_ip` default `10.200.0.1`, already
   assigned `/32` on `dummy-mjolnir`. Tenant Postgres is
   `10.200.0.1:5432`. The door is `10.200.0.1:7222`. Do not invent
   `10.255.255.1` or a second dummy. `Network.allocate_ip/1` already
   refuses this address.

2. **INPUT, not FORWARD.** Guest TCP to the dummy is INPUT on the
   TAP path. UFW/iptables must `allow from 10.192.0.0/10 to
   10.200.0.1 port 7222`. A valid URL with default-deny INPUT
   black-holes. Same lesson as `add-host-sidecar-tenant` (LEARNINGS
   2026-08-19). Dummy, not `lo` — TAP `/32` guests must ARP the bind.

3. **Allow-nonlocal hatch.** The binary refuses a non-loopback bind
   unless `BLOB_DOOR_ALLOW_NONLOCAL=1`. Production env sets both
   that and `BLOB_DOOR_BIND=10.200.0.1:7222`. Never `0.0.0.0`. Fail
   closed if `10.200.0.1` is missing — do not fall back to `*`.

4. **Locator, not credentials.** Vsock `configure_identity` grows
   `blob_door_url` (example `http://10.200.0.1:7222`). Guest writes
   `/etc/mjolnir/vm.json` next to `api_url`. Re-inject every boot.
   `B2_*` stay in `/etc/mjolnir/blob-door.env` on the host. A change
   that injects B2 keys into a guest is rejected against the living
   “Callers speak the door” requirement.

5. **Sites is a URL, not a second door.**
   `Mjolnir.Sites.Storage.Recrypt` already speaks
   `PUT/GET /storage/blob/b3/{hash}` and `.obao`. Point
   `MJOLNIR_RECRYPT_STORAGE_URL` at this process. Do not grow
   recrypt-server `/files` as a parallel door (`mjolnir-9bq.1`).

6. **Elixir restart is not the install path.** Installing or
   restarting the door unit must not `mix release` / restart
   `mjolnir.service` (that bounces every VM). Same reason
   `deploy.sh --gateway` is gateway-only.

## Not this change

Streaming multipart above 64 MiB. iroh-blobs. Encryption. A public
gateway route for the door.
