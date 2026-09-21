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
