## ADDED Requirements

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
