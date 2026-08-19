# Tasks

Owed while this change is ACTIVE BUILD. Beads in parens.

- [x] Door process on the Mjolnir host: Linux build, `/opt/mjolnir/bin/mjolnir-blob-door`, systemd unit, `/etc/mjolnir/blob-door.env` (`mjolnir-u8v7.1`)
- [x] Bind `:host_api_ip:7222` (`10.200.0.1`) with `BLOB_DOOR_ALLOW_NONLOCAL=1`. Not loopback-only, not `0.0.0.0`, not the public NIC. Fail closed if the dummy address is missing.
- [x] INPUT allow TAP subnet (`10.192.0.0/10`) → `10.200.0.1:7222` (UFW, same shape as tenant Postgres 5432)
- [x] B2 keys only in `blob-door.env`. Door has no DELETE. (Host rclone key is scoped to `mimir-backups` and still has deleteFiles; cannot mint a child key without manageKeys.)
- [x] `just deploy-blob-door` builds/installs/restarts the door without restarting Elixir
- [x] Host `curl http://10.200.0.1:7222/health` → ok; `ss` shows listen on `10.200.0.1:7222` only
- [x] Vsock `configure_identity` + guest agent write `blob_door_url` into `/etc/mjolnir/vm.json` (`mjolnir-u8v7.2`). Needs `just deploy --agent`.
- [x] Prove from a guest: PUT then GET match; mismatch refused; re-PUT no extra B2 version; second guest GET; after door stop, B2 still has the object (`mjolnir-u8v7.3`)

Handoffs (not checkboxes):

- Sites Recrypt cutover (`mjolnir-u8v7.4`) — blocked: `Mjolnir.Sites.Crypto.blake3_hash/1` is still SHA-256. Pointing the adapter at the door 400s. Do not set `MJOLNIR_RECRYPT_STORAGE_URL` until that stub is real Blake3.
- `add-iroh-blobs` — mesh working set; iroh locator grammar
- `add-encrypt-blobs` — personal + PRE / Guild-Key
- Streaming above 64 MiB
