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
