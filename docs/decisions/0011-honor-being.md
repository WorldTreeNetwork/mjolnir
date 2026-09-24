# ADR 0011 — Hosted being (vibe-coder VM)

**Status:** Accepted
**Date:** 2026-09-10
**Change:** [`add-honor-being`](../../openspec/changes/archive/2026-09-20-add-honor-being/proposal.md)
**Living spec:** [`openspec/specs/honor-being/spec.md`](../../openspec/specs/honor-being/spec.md)
**Epic:** `mjolnir-x97p`

Full argument:
[`openspec/changes/archive/2026-09-20-add-honor-being/design.md`](../../openspec/changes/archive/2026-09-20-add-honor-being/design.md).

Amended 2026-09-10 after Fable send-back (S1–S4).
Renamed 2026-09-10: first intend line was transcribed “a honor being”;
the intent is a **hosted being**. Change-id `add-honor-being` is
unchanged.

## One screen

1. **Friend C2; the VM is a device.** Not a second XID. Not a Sign
   key on the document. Duke may hold Elect recovery.
   `owner_id` = friend's XID = public OIDC `sub` from
   `auth.identikey.me`. `/term` authorized by `authorize_vm` on
   that equality.
2. **Passkey gates `/term`, not the preview URL.** WebAuthn at
   `auth.identikey.me`. grok uses **`XAI_API_KEY` only**, injected
   to `/run/mjolnir/` tmpfs. No grok.com session. No
   `GROK_OIDC_ISSUER` against identikey in v1. No Keycloak growth.
3. **`ssh_git` credential + A3 consent.** Fresh A3 assertion +
   consent-log `add_device`. Not Elect. SSH private key in
   `_opaque/vms/<id>/`, vsock-injected, `gpg.format ssh`. Host is
   C1-style custodian of that key. Revoke, in order: Forgejo key
   delete + `revoke_device` + opaque delete — fail closed, so a
   delete that cannot be confirmed stops the revoke (landed
   `add-honor-git-remote`, 2026-09-24).
4. **Forgejo on mimir is the write remote.** GitHub origin does
   not deploy. `git push main` is the accepted prod-cutover risk.
5. **Ticket URL + prod API + per-ticket CORS.** No
   `*.vm.worldtree.network` wildcard. Ticket host is
   unauthenticated HTTP; named subdomain (v2) stabilizes CORS.
6. **ubuntu-24.04 → per-friend snapshot `hosted-<xid>`, not
   `@base/hosted`.** Clone inside the guest. Reuse wrug `/term` +
   tmux `main`.
7. **Respawn is a new device.** New key, new credentials row, new
   Forgejo key; old revoked. URL held by `preserve_iroh_key` from
   the per-friend snapshot only.
8. **Code is later nodes.** `add-identikey-being-client`,
   `add-vm-git-subkey` (owns `ssh_git` migration),
   `add-honor-git-remote`, `add-honor-dev-preview`,
   `update-hypersigil-store-cors`.

## Built vs remaining

Built: spawn, Iroh ticket, `preserve_iroh_key`, wrug `/term`,
identikey-core passkey OP (discovery 200), opaque inject
pattern, `owner_id` + `authorize_vm`, Forgejo deploy.yml, prod
storefront/API.

Not built: grok bootstrap, Keycloak cutover, preview CORS.
(`ssh_git` kind, A3 `add_device` consent and SSH inject landed with
`add-vm-git-subkey`; Forgejo registration and `owner_id` = public
XID `sub` with `add-honor-git-remote` / `add-identikey-being-client`.)

Remaining: the five implement landings. This change folds the ADR
only.
