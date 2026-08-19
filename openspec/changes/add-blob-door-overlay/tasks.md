# Tasks

Owed while this change is ACTIVE BUILD. Beads in parens.

- [ ] Door process on the Mjolnir host: Linux build, `/opt/mjolnir/bin/mjolnir-blob-door`, systemd unit, `/etc/mjolnir/blob-door.env` (`mjolnir-u8v7.1`)
- [ ] Bind `:host_api_ip:7222` (`10.200.0.1`) with `BLOB_DOOR_ALLOW_NONLOCAL=1`. Not loopback-only, not `0.0.0.0`, not the public NIC. Fail closed if the dummy address is missing.
- [ ] INPUT allow TAP subnet (`10.192.0.0/10`) → `10.200.0.1:7222` (UFW, same shape as tenant Postgres 5432)
- [ ] B2 keys only in `blob-door.env`. Application key: read/write, not delete. Bucket versioning on.
- [ ] `just` recipe to build/install/restart the door without restarting Elixir
- [ ] Host `curl http://10.200.0.1:7222/health` → ok; `ss` shows listen on `10.200.0.1:7222` only
- [ ] Vsock `configure_identity` + guest agent write `blob_door_url` into `/etc/mjolnir/vm.json` (`mjolnir-u8v7.2`). Needs `just deploy --agent`.
- [ ] Prove from a guest: PUT then GET match; mismatch refused; re-PUT no extra B2 version; second guest GET; after door stop, B2 still has the object (`mjolnir-u8v7.3`)
- [ ] `MJOLNIR_RECRYPT_STORAGE_URL` points at the door; tagged `:recrypt_storage` round-trip passes (`mjolnir-u8v7.4`)

Handoffs (not checkboxes):

- `add-iroh-blobs` — mesh working set; iroh locator grammar
- `add-encrypt-blobs` — personal + PRE / Guild-Key
- Streaming above 64 MiB
