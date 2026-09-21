# Design — Forgejo write remote for the hosted being

Canonical: ADR
[`0011`](../../../docs/decisions/0011-honor-being.md) §§4, 7.
Steer residue on `mjolnir-x97p.4`: mimir
`VirtueInnova/hypersigil-store-frontend` is the write remote.

**Change:** `add-honor-git-remote`
**Bead:** `mjolnir-x97p.4`

## Decision 1 — repo write deploy key, not a machine user

The pubkey is already an identikey `ssh_git` device
(`add-vm-git-subkey`). ADR 0011 rejected a Forgejo deploy key
*with no identikey row*, not deploy keys as such. A Forgejo
**machine user** would be a second person on mimir; the VM is a
device of the friend's C2, not a second identity.

Register `device_public_key` as a write deploy key on that one
repo (`read_only: false`). Title includes `vm_id` (and xid if
known) so a leftover key is a named reconcile find.

Rejected:

- Machine user + password/token in the guest
- Deploy key with no `ssh_git` row
- Putting a Forgejo PAT on the guest or the snapshot

## Decision 2 — host talks to Forgejo; guest never sees the token

Mjolnir (host) calls Forgejo's repo-keys API with a token from
host config / deploy secrets. The guest authenticates `git`
with `/run/mjolnir/git_signing_key` only. Same split as opaque
git signing: C1-style custody on the host.

`GitSigning.revoke/1` already calls
`:git_signing_forgejo_revoke` first. This change supplies that
hook (delete by pubkey / key id). A failed delete is an error
— do not map it to `:ok`. Unconfigured (`:not_wired`) remains
the reconcile find only when the token is genuinely absent
(dev/test); prod hosted-being provision requires the token.

Revoke order stays: Forgejo delete → `revoke_device` → opaque.
If Forgejo delete fails, stop; opaque stays.

## Decision 3 — one SSH key for signing and push

Guest `core.sshCommand` / `IdentityFile` for
`mimir.worldtree.network` (or `forgejogit@…`) is the injected
signing key. No second keypair. Commit signing stays
`gpg.format ssh` + `user.signingkey /run/mjolnir/git_signing_key`.

Forgejo “verified” badge is out of scope (that wants the key
on a user). Acceptance is: the commit is **visible** on the
Forgejo repo after push.

## Decision 4 — guest remote is Forgejo SSH; GitHub is not required

Bootstrap already defaults
`HOSTED_BEING_REPO=forgejogit@mimir.worldtree.network:VirtueInnova/hypersigil-store-frontend.git`.
Once the deploy key exists, `git clone` / `git push` that URL
works. GitHub `aetherpunk108/hypersigil-store-frontend` stays a
human mirror; it is not the deploy trigger and need not appear
in the guest `remote -v`.
