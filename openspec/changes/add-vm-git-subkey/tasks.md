# Tasks

- [x] identikey-core migration: `kind = 'ssh_git'` + shape CHECK
      (`0003_ssh_git_credentials.sql`)
- [ ] identikey-core: insert `ssh_git` row under A3 + consent-log
      `add_device`; refuse Elect-only (HTTP/ceremony still owed)
- [x] Mjolnir: `GitSigning.put/2` opaque `git_signing`; generate
      via `ssh-keygen`
- [x] Mjolnir: vsock `inject_file` → `/run/mjolnir/git_signing_key`
      (guest allowlist); bootstrap sets `gpg.format ssh`
- [ ] Respawn path: mint new device; revoke old Forgejo →
      `revoke_device` → opaque
- [x] Tests: opaque 0600; inject_file ≠ Buzz env map

Handoffs:

- Forgejo registration — `add-honor-git-remote` (`mjolnir-x97p.4`)
- A3 login — `add-identikey-being-client` (`mjolnir-x97p.2`)
