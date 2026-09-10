# Tasks

- [x] `POST /api/vms/:id/freeze` `{name}` parks and tears down the source
- [x] `POST /api/snapshots/:name/thaw` restores the original vm_id
- [x] `GET /api/snapshots` and `GET /api/snapshots/:name` include `kind`
- [x] `POST /api/vms` with a memory snapshot name returns 400 pointing at thaw
- [x] `mj freeze` / `mj thaw`; snapshot show/list print kind
- [x] Pass `secrets_mode` + vsock into freeze; reseed then reopen secrets before `:running`
- [x] `BTRFS.delete_snapshot/1` removes the `.mem` sibling
