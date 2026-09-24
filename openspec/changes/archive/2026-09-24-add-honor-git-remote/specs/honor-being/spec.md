## ADDED Requirements

### Requirement: Forgejo write remote uses the ssh_git pubkey

A hosted being SHALL push to
`forgejogit@mimir.worldtree.network:VirtueInnova/hypersigil-store-frontend.git`
authenticated as a repository write deploy key whose public key
is the identikey `ssh_git` `device_public_key`. The host SHALL
register and delete that key through the Forgejo API. The guest
SHALL NOT hold a Forgejo token. Guest `git` SHALL use
`/run/mjolnir/git_signing_key` for that host. GitHub origin SHALL
NOT be required for prod cutover.

#### Scenario: Injected key can push

- GIVEN a hosted being with an `ssh_git` device and a registered
  write deploy key
- WHEN the guest pushes a signed commit to the Forgejo remote
- THEN the commit is visible on
  `VirtueInnova/hypersigil-store-frontend`
- AND GitHub origin was not required for that push

#### Scenario: Guest has no Forgejo token

- GIVEN a bootstrapped hosted being
- WHEN the guest filesystem is searched for Forgejo tokens
- THEN none are present
- AND `git` still authenticates with `/run/mjolnir/git_signing_key`

#### Scenario: No identikey row means no deploy key

- GIVEN `git_signing: true` spawn without a consented `ssh_git`
  device (`xid` and `credential_id` for that pubkey)
- WHEN the host would register a Forgejo write key
- THEN registration does not run
- AND the storefront repo has no new deploy key

#### Scenario: Signing-only spawn cannot write the storefront

- GIVEN a VM minted with git signing but no hosted-being
  provisioning / A3 `ssh_git` row
- WHEN Forgejo deploy keys on
  `VirtueInnova/hypersigil-store-frontend` are listed
- THEN that VM’s pubkey is absent

### Requirement: Forgejo register and revoke keep recovery metadata

The host SHALL persist identikey `xid` and `credential_id` for the
exact pubkey **before** calling Forgejo register. A missing host
token after a key was registered SHALL fail revoke closed: device
metadata and opaque SHALL remain; `revoke_device` SHALL NOT run.
`:not_wired` SHALL apply only when no grant was ever registered
(dev/test). After a remote-create whose key id is not durably
stored, retry or cleanup SHALL still be able to name that grant
(pubkey delete), not leave a forgotten write key.

#### Scenario: Token lost after register

- GIVEN a registered deploy key and persisted xid/credential_id
- WHEN `MJOLNIR_FORGEJO_TOKEN` is unset and revoke runs
- THEN Forgejo delete is not treated as success
- AND opaque and device metadata remain

#### Scenario: Register timeout still recoverable

- GIVEN Forgejo created a key but the host did not persist `key_id`
- WHEN register is retried or revoke runs
- THEN delete-by-pubkey still removes that grant


## MODIFIED Requirements

### Requirement: Respawn is a new device; ticket held per-friend

A respawn SHALL mint a new `vm_id`, a new SSH key, and a new
`ssh_git` credentials row, and SHALL revoke the previous device
in order: Forgejo write-key delete, `revoke_device`, opaque
delete. A failed Forgejo delete SHALL stop the revoke (opaque
stays). Spawn from the per-friend snapshot `hosted-<xid>` SHALL
set `preserve_iroh_key: true` so the ticket URL survives. Spawn
from a shared bootstrap snapshot SHALL NOT preserve the Iroh key.

#### Scenario: Kill and respawn from the friend's snapshot

- GIVEN the being was snapshotted as `hosted-<xid>` with an Iroh key
- WHEN the VM is stopped and spawned from that snapshot with
  `preserve_iroh_key: true`
- THEN the ticket URL is unchanged
- AND a new `ssh_git` device exists
- AND the previous `ssh_git` row is revoked
- AND the previous Forgejo write deploy key is deleted
- AND a new Forgejo write deploy key is registered for the new pubkey

#### Scenario: Forgejo delete failure keeps opaque

- GIVEN Forgejo rejects delete of the old write deploy key
- WHEN `GitSigning.revoke/1` runs
- THEN `revoke_device` is not called
- AND the opaque private blob is not deleted
