# honor-being

What is built. Seeded by
[`add-honor-dev-preview`](../../changes/archive/2026-09-19-add-honor-dev-preview/proposal.md)
on 2026-09-19. The change-id keeps `honor` (a mis-transcription of
*hosted*); the product is a **hosted being**.

Living truth here is the dev-preview landing plus the `ssh_git`
git-signing device, folded from
[`add-vm-git-subkey`](../../changes/archive/2026-09-20-add-vm-git-subkey/proposal.md)
on 2026-09-20, plus the being-as-device and respawn rules from
[`add-honor-being`](../../changes/archive/2026-09-20-add-honor-being/proposal.md)
(architecture fold 2026-09-20). ADR
[`0011`](../../../docs/decisions/0011-honor-being.md) also carries
passkey `/term` — landed, but its SHALLs live in `web-pty-edge`, not
here — and the Forgejo write remote and prod CORS, which have not
landed and so are not SHALLs below. Those arrive with
`add-honor-git-remote` and `update-hypersigil-store-cors`.

## Purpose

A hosted being is a long-lived vibe-coder VM for one friend. It runs
grok and the storefront dev server side by side in tmux session
`main`, reachable at the VM's Iroh ticket URL
`https://<ticket>.vm.worldtree.network`.

Two things are deliberate and easy to break by accident:

- **The ticket origin is unauthenticated HTTP** (ADR 0011 D5). The
  z32 ticket *is* the secret — it is a capability URL. The passkey
  gates wrug `/term`, not the preview. A later fold must not assume
  auth exists on the preview origin.
- **`preserve_iroh_key` belongs to the per-friend snapshot only.**
  Respawning from `hosted-<xid>` preserves the Iroh node id, which is
  what keeps the ticket URL (and later the CORS allow-list entry)
  stable. A *shared* bootstrap snapshot must not preserve it — two
  VMs from one snapshot would collide on node id. The flag lives on
  `VM.spawn` / `POST /api/vms`, not on this capability.

## Requirements

### Requirement: grok and Vite share tmux main on the ticket URL

A hosted being SHALL have grok on PATH in tmux session `main` and
SHALL serve the storefront with a dev server that the ticket URL
`https://<ticket>.vm.worldtree.network` loads — binding `0.0.0.0` is
necessary but not sufficient; the server SHALL also accept the ticket
Host. Frontend env SHALL point at `https://api.hypersigil.world`.
`XAI_API_KEY` SHALL live only in guest tmpfs.

#### Scenario: Ticket URL paints the storefront

- GIVEN a bootstrapped hosted being
- WHEN the ticket URL is fetched
- THEN the response is 200 and the storefront renders
- AND a request bearing the ticket Host is not rejected as an
  unknown host

#### Scenario: Preview talks to prod API

- GIVEN Vite is up and the ticket URL loads
- WHEN the storefront fetches products
- THEN requests go to `https://api.hypersigil.world`

#### Scenario: grok key is not written to the storefront env

- GIVEN a `.env` for the storefront that contains `XAI_API_KEY`
- WHEN bootstrap runs
- THEN it refuses that `.env` and does not write the key to the
  BTRFS subvolume

### Requirement: Hosted snapshot does not persist XAI_API_KEY

A hosted-being snapshot SHALL NOT contain `XAI_API_KEY` in the
storefront `.env`, grok's config directory, or shell history.
The key SHALL remain injectable into guest tmpfs (`/run/mjolnir/`)
after boot from that snapshot.

#### Scenario: Snapshot tree is clean

- GIVEN a hosted being that has run grok
- WHEN `mj snapshot create` writes `hosted-<xid>`
- THEN the snapshot tree does not contain `XAI_API_KEY`
- AND a later spawn from that snapshot can still receive the key
  in `/run/mjolnir/` tmpfs

### Requirement: Git signing inject is not the Buzz identity map

The hosted being's SSH git private key SHALL be a distinct
SecretStore opaque blob (`git_signing` under `_opaque/vms/<id>/`)
and SHALL be injected to the fixed guest path
`/run/mjolnir/git_signing_key`. It SHALL NOT be written through
`Mjolnir.Identity.env_entries/1` (`BUZZ_PRIVATE_KEY`). The path
SHALL be stable across respawns so `git config user.signingkey`
does not need a rewrite when the key bytes change.

#### Scenario: Distinct blob

- GIVEN a hosted VM with both a Buzz nsec and a git signing key
- WHEN the guest tmpfs is listed
- THEN `/run/mjolnir/buzz.env` and `/run/mjolnir/git_signing_key`
  are separate files
- AND `GET /api/vms/:id` contains neither private material

#### Scenario: Stable path on new device

- GIVEN a respawn that minted a new `ssh_git` key
- WHEN grok commits
- THEN `user.signingkey` is still `/run/mjolnir/git_signing_key`
- AND the signature verifies with the new `device_public_key`

### Requirement: Hosted being is a device of a friend's C2 identikey

A hosted being SHALL be a Mjolnir VM bound to a C2 managed
identikey as a `credentials` row of kind `ssh_git`, not as a
second XID and not as an additional Sign key on the C2 document.
The VM's `owner_id` SHALL equal that XID as the public OIDC `sub`
issued by `auth.identikey.me`. Creating the device SHALL require
a fresh A3 (WebAuthn) assertion for that XID and SHALL append a
consent-log entry (`action = add_device`). Creating the device
SHALL NOT require an Elect signature.

#### Scenario: Friend identity survives a new hosted VM

- GIVEN a stored C2 identikey for the friend
- WHEN a hosted being is provisioned with a fresh A3 assertion
- THEN the friend's XID is unchanged
- AND a `credentials` row of kind `ssh_git` exists for that XID
- AND the VM's `owner_id` equals that XID
- AND the C2 document still has IdentiKey as the Sign+Auth holder
  and the user as Elect

#### Scenario: No implicit device without A3 consent

- GIVEN no fresh A3 assertion for the friend's XID
- WHEN a VM is spawned
- THEN it is not a hosted being
- AND no `ssh_git` credentials row is inserted

#### Scenario: Duke-owned spawn is not a hosted being

- GIVEN Duke's OIDC `sub` is not the friend's XID
- WHEN Duke spawns a VM under his own token
- THEN `owner_id` is Duke's `sub`
- AND the VM is not a hosted being of the friend

### Requirement: Respawn is a new device; ticket held per-friend

A respawn SHALL mint a new `vm_id`, a new SSH key, and a new
`ssh_git` credentials row, and SHALL revoke the previous device
(opaque delete, `revoke_device`). Spawn from the per-friend
snapshot `hosted-<xid>` SHALL set `preserve_iroh_key: true` so the
ticket URL survives. Spawn from a shared bootstrap snapshot SHALL
NOT preserve the Iroh key. Forgejo key delete on revoke is
`add-honor-git-remote`, not this requirement.

#### Scenario: Kill and respawn from the friend's snapshot

- GIVEN the being was snapshotted as `hosted-<xid>` with an Iroh key
- WHEN the VM is stopped and spawned from that snapshot with
  `preserve_iroh_key: true`
- THEN the ticket URL is unchanged
- AND a new `ssh_git` device exists
- AND the previous `ssh_git` row is revoked
