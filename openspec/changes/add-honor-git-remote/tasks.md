# Tasks

- [x] Host: register `ssh_git` pubkey as a write deploy key on
      Forgejo `VirtueInnova/hypersigil-store-frontend` (API, token
      from host config / deploy secrets — not the guest)
- [x] Guest: `git` remote is the Forgejo SSH URL; SSH identity is
      `/run/mjolnir/git_signing_key` (known_hosts for mimir)
- [x] Wire `:git_signing_forgejo_revoke` — delete that deploy key
      before `revoke_device` / opaque; failed delete does not map
      to `:ok`
- [x] Respawn: old Forgejo key gone; new pubkey registered
- [x] Tests: register + revoke against a fake Forgejo; unconfigured
      stays `:not_wired` reconcile find
- [x] Live: clone/push with the injected key; a signed commit is
      visible on mimir `main` (or the branch `deploy.yml` watches)

Handoffs:

- Prod CORS — `update-hypersigil-store-cors` (`mjolnir-x97p.6`)
- Snapshot key scrub — `add-honor-snapshot-key-scrub`

## Owed after independent advise (2026-09-24)

Review: [2026-09-24-advise.md](reviews/2026-09-24-advise.md), reader `astra-arch-review`, verdict `send-back`.

- [x] Contract: R1–R3 SHALLs and scenarios in the honor-being delta (2026-09-24)
- [x] R1: Gate Forgejo registration on the consented identikey `ssh_git`
      device for the exact public key and authenticated owner; persist XID
      and credential ID before granting write authority. Verify ordinary
      signing-only spawn cannot acquire the storefront write grant, and
      provisioning/respawn establishes the new credentials row. Add negative
      coverage for absent A3/row and mismatched owner/key.
- [x] R2: Fail revoke closed when a registered or uncertain Forgejo grant
      cannot be deleted because host configuration/token is missing; retain
      device metadata and opaque state and skip identikey revoke. Test token
      loss after registration, successful retry, and the genuine no-grant
      development case separately.
- [x] R3: Preserve recoverable registration state or confirmed compensation
      across remote-create-then-timeout, malformed success, and failure to
      persist the returned key ID. Specify durable retry/cleanup behavior
      and verify retries do not leave forgotten write grants.
- [x] Fresh advise after preparation — accepted by `astra-arch-review` in
      [2026-09-24-advise-2.md](reviews/2026-09-24-advise-2.md); reviewed contract
      SHA-256 `b8b20c149e91582126b5a4f013dad6ff1c7b34e99c01778f5994546293d7c0d1`.
