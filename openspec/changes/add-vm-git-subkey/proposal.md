# add-vm-git-subkey

> **ACTIVE BUILD**

Bead `mjolnir-x97p.3`. ADR 0011 Decisions 3 and 7. Fable readvise
notes: generalize inject; stable guest path; revoke Forgejo →
`revoke_device` → opaque; friend (or consent-logged Duke passkey)
performs A3.

**Rigor:** change

## Why

The hosted VM must SSH-sign git commits. The private key is
host-custodied C1-style material in SecretStore
`_opaque/vms/<id>/`, vsock-injected, never on the VM struct.
identikey-core `credentials.kind` CHECK does not admit an SSH git
pubkey. `Identity.env_entries/1` hard-codes `BUZZ_PRIVATE_KEY` —
that message is not a generic inject.

## What

- identikey-core: new `kind = 'ssh_git'` with `device_public_key`
  populated; do not overload `identikey_auth`.
- Creating the row requires a fresh A3 assertion + consent-log
  `add_device` (not Elect).
- Mint an SSH keypair; store private under
  `_opaque/vms/<id>/git_signing`; inject to a **fixed** guest path
  `/run/mjolnir/git_signing_key` (tmpfs) so respawn does not rewrite
  `git config user.signingkey`.
- Guest: `gpg.format ssh`, `commit.gpgsign true`.
- Respawn is a new device (ADR 0011 §7). Revoke order: Forgejo key
  delete, then `revoke_device`, then opaque delete.
- `GET /api/vms/:id` never includes the private key.

## Impact

- Capabilities: implements ADR 0011 honor-being git-key SHALLs
  (living spec still waits on fold of an implementing landing).
  identikey-core `managed-custody` / credentials schema grows
  `ssh_git`.
- ADRs: none new.

## User journey & surfaces

Operator provisions a hosted VM for a friend who just completed A3.

- **Working (after act)** — `git commit` in the guest is
  SSH-signed; `git log --show-signature` verifies against
  `credentials.device_public_key`.
- **Empty** — no A3 → no `ssh_git` row → not a hosted being.
- **Failed (today)** — Buzz nsec inject only; no git key; CHECK
  rejects SSH pubkeys.
- **Off** — spawn without the provision path.

No new UI because `mj spawn` / vsock inject / `git` in the guest
already exist. Provisioning A3 is `/authorize` from
`add-identikey-being-client`.

## Out of scope

- Forgejo write registration — `add-honor-git-remote` (`mjolnir-x97p.4`)
- Vite preview — `add-honor-dev-preview` (`mjolnir-x97p.5`)
- Second XID Sign key
- Copying `_opaque` across vm_ids on respawn
