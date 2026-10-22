# honor-being

Delta for `add-honor-being` (change-id unchanged; the product is a
**hosted being**). Not living truth until fold of an implementing
change.

## ADDED Requirements

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

### Requirement: Browser passkey opens /term

Login to the hosted being `/term` from a browser SHALL complete
WebAuthn assertion at `https://auth.identikey.me` (RP ID
`auth.identikey.me`). It SHALL NOT use `connect.identikey.io` /
Keycloak. Assertion SHALL NOT create an account. PTY attach SHALL
be authorized by `authorize_vm` on `owner_id` equality (ADR 0004:
the foreign-origin page SHALL NOT hold the Mjolnir JWT). grok in
the guest SHALL authenticate to xAI with `XAI_API_KEY` injected
into guest tmpfs (`/run/mjolnir/`), not with a grok.com session
and not with an IdentiKey OIDC token as a grok.com credential.

#### Scenario: Passkey opens /term

- GIVEN a friend with a registered passkey on the C2 identikey
  and a hosted VM whose `owner_id` is that XID
- WHEN they complete assertion at `/authorize`
- THEN wrug `/term` attaches to tmux session `main`
- AND the Mjolnir JWT is not held by a foreign-origin page

#### Scenario: Grok uses XAI_API_KEY only

- GIVEN the hosted being is running grok
- WHEN grok calls the xAI API
- THEN the credential is `XAI_API_KEY` from guest tmpfs
- AND `GROK_OIDC_ISSUER` is not required
- AND a bootstrap snapshot of the VM does not contain the key

### Requirement: Injected SSH git-signing key of kind ssh_git

The hosted VM SHALL sign git commits with an SSH key whose private
half is stored under SecretStore `_opaque/vms/<id>/` and injected
over vsock on boot into guest tmpfs. The private half SHALL NOT
appear on the VM struct, StateStore, or API views. The public
half SHALL be `credentials.device_public_key` on the `ssh_git`
row and SHALL be registered for push on the Forgejo remote
`forgejogit@mimir.worldtree.network:VirtueInnova/hypersigil-store-frontend.git`.
The host is custodian of the private half. Revocation SHALL
delete the opaque blob, revoke the credentials row, and remove
the Forgejo key.

#### Scenario: Signed commit

- GIVEN the hosted being has been injected
- WHEN grok creates a git commit in `hypersigil-store-frontend`
- THEN `git log --show-signature` reports an SSH signature
- AND the verifying key is `credentials.device_public_key`

#### Scenario: Opaque private key

- GIVEN a running hosted VM
- WHEN `GET /api/vms/:id` is called
- THEN the response does not contain the git private key

### Requirement: Dev preview on the ticket URL, prod API

The hosted being SHALL run the storefront in Vite dev mode
reachable at `https://<ticket>.vm.worldtree.network`. That HTTP
surface SHALL NOT require passkey (the passkey gate is `/term`).
The frontend SHALL use `https://api.hypersigil.world` as the
Medusa backend. Prod Medusa CORS SHALL list that exact ticket
origin and SHALL NOT use a `*.vm.worldtree.network` wildcard. The
VM SHALL clone `ubuntu-24.04` and MAY persist a per-friend
snapshot `hosted-<xid>` (not a catalog entry; ADR 0009). It SHALL
NOT add a declared `@base/` name.

#### Scenario: Preview talks to prod API

- GIVEN Vite is up and the ticket URL loads
- WHEN the storefront fetches products
- THEN requests go to `https://api.hypersigil.world`
- AND they do not require a guest-local Medusa

### Requirement: Respawn is a new device; ticket held per-friend

A respawn SHALL mint a new `vm_id`, a new SSH key, a new
`ssh_git` credentials row, and a new Forgejo key, and SHALL
revoke the previous device (opaque delete, `revoke_device`,
Forgejo key delete). Spawn from the per-friend snapshot
`hosted-<xid>` SHALL set `preserve_iroh_key: true` so the ticket
URL (and the CORS entry) survive. Spawn from a shared bootstrap
snapshot SHALL NOT preserve the Iroh key.

#### Scenario: Kill and respawn from the friend's snapshot

- GIVEN the being was snapshotted as `hosted-<xid>` with an Iroh key
- WHEN the VM is stopped and spawned from that snapshot with
  `preserve_iroh_key: true`
- THEN the ticket URL is unchanged
- AND a new `ssh_git` device exists
- AND the previous `ssh_git` row is revoked
