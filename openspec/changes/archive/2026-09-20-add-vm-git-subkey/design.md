# Design — ssh_git credential + vsock git-key inject

Canonical: ADR
[`0011`](../../../docs/decisions/0011-honor-being.md) §§3, 7.

**Change:** `add-vm-git-subkey`
**Bead:** `mjolnir-x97p.3`

## Decision 1 — new kind, not identikey_auth

`identikey_auth` is “a device key that can authenticate *to us*”.
A Forgejo signing key never does. Migration adds `ssh_git` to
`credentials_kind_known` and a shape arm: `device_public_key NOT
NULL`, WebAuthn/OIDC columns NULL.

## Decision 2 — A3 + consent-log, not Elect

Hosted signup drops Elect. Gate is a fresh WebAuthn assertion for
that XID and `consent_log.action = add_device`. Who: the friend.
Duke acting as the friend requires Duke's passkey as a second
credential on that XID (consent-logged, revocable) — not a
shortcut `owner_id` swap.

## Decision 3 — inject is not the Buzz env map

`Identity.env_entries/1` emits `BUZZ_PRIVATE_KEY` /
`BUZZ_RELAY_URL`. Git signing gets its own opaque key and a
second vsock payload (or a generalized inject that takes a
filename + bytes). Guest path is always
`/run/mjolnir/git_signing_key` (mode 0600, tmpfs). Snapshot of
the rootfs does not capture it.

## Decision 4 — respawn mints a new key

New `vm_id` → new keypair → new `ssh_git` row → new Forgejo key
(the last is `add-honor-git-remote`). Old triple revoked in order:
Forgejo, `revoke_device`, opaque. A crash between steps must leave
a stale Forgejo key as the reconcile find, not a live key with no
identikey row.
