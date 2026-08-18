# Learnings

Hard-won facts from folded changes. One dated line each.

- **2026-08-16 / add-buzz-local-client:** Folding an architecture-plus-one-slice change must not import unimplemented SHALLs into `openspec/specs/`. Built truth is fail-closed `Mjolnir.Admit` plus `:never` refuses `DormantRegistry`; leftover SHALLs went to PENDING `add-buzz-local-runtime`.
- **2026-08-16 / add-buzz-local-client:** The I5 wake hole was `DormantRegistry` thaw on any `deliver_message`, not Reconcile — `restart_policy: never` already finalizes a stranded record.
- **2026-08-16 / add-buzz-local-client:** Same-family advise cannot sole-accept (ADR-005). Grok authored the ADR; Fable + Sol had to accept.
- **2026-08-17 / mjolnir-1pe:** SecretStore's envelope API cannot hold an unsigned nsec — `_opaque/vms/<id>/` is the store namespace. Guest `inject_identity` is in-tree; a live body still needs `just deploy --agent`. systemd `EnvironmentFile` wants `KEY=value` (no `export`) and `0640 root:agent`, not `0600`.
- **2026-08-17 / add-blob-store:** First draft named MinIO as the provider. Advise send-back: three layers (address / B2 canonical / working-set+transmit). We are not doing MinIO — not v1, not a later cache.
- **2026-08-17 / add-blob-api:** `recrypt-storage::put_with_outboard` does not hash-check (`s3.rs:217–248`); the door wraps it. Recrypt does not compile on macOS, so the door is a thin sidecar, not recrypt-core.
- **2026-08-17 / add-blob-client:** `BLOB_DOOR_URL` empty at boot so the public site still starts; put/get fail closed. Never put `B2_*` in the Taskmaster env.
