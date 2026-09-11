# Tasks

- [ ] identikey-core migration: `kind = 'ssh_git'` + shape CHECK +
      comment that this is git-signing, not OP auth
- [ ] identikey-core: insert `ssh_git` row under A3 + consent-log
      `add_device`; refuse Elect-only
- [ ] Mjolnir: generate SSH keypair; `put_opaque(vm_id, "git_signing",
      priv)`; never on VM struct / StateStore / API views
- [ ] Mjolnir: vsock inject to `/run/mjolnir/git_signing_key` (not
      the Buzz `env_entries` map); guest git config
      `gpg.format ssh`, `user.signingkey` that path, `commit.gpgsign`
- [ ] Respawn path: mint new device; revoke old Forgejo →
      `revoke_device` → opaque
- [ ] Tests: API view has no private key; inject file mode 0600;
      CHECK rejects `ssh_git` without `device_public_key`

Handoffs:

- Forgejo registration — `add-honor-git-remote` (`mjolnir-x97p.4`)
- A3 login — `add-identikey-being-client` (`mjolnir-x97p.2`)
