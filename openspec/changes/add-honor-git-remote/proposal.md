# add-honor-git-remote

> **ACTIVE BUILD**

Bead `mjolnir-x97p.4`. ADR 0011 Decisions 4 and 7. Steer: Forgejo
mimir `VirtueInnova/hypersigil-store-frontend` is the write remote;
GitHub origin is not the deploy trigger. `add-vm-git-subkey` left
`GitSigning.revoke/1` Forgejo delete as `:not_wired` (reconcile find).

**Rigor:** change

## Why

The hosted being can SSH-sign commits and inject the private key,
but it cannot `git push` to the Forgejo remote that cuts over prod.
Fresh `ubuntu-24.04` clone of
`forgejogit@mimir.worldtree.network:VirtueInnova/hypersigil-store-frontend.git`
is `Permission denied (publickey)`. Respawn leaves any Forgejo key
as a live write credential with no identikey row — the inverse of
the intended failure mode (learning 2026-09-20).

## What

- Register the `ssh_git` pubkey as a **repo write deploy key** on
  Forgejo `VirtueInnova/hypersigil-store-frontend` via the host
  Forgejo API. Guest never holds a Forgejo token.
- Guest `git` uses `/run/mjolnir/git_signing_key` for that host
  (same key as commit signing). Remote URL is the Forgejo SSH
  URL already in `hosted-being-bootstrap.sh`.
- Wire `Application.get_env(:mjolnir, :git_signing_forgejo_revoke)`
  so revoke deletes that deploy key **before** `revoke_device` and
  opaque delete. `:not_wired` mapped to `:ok` is no longer the
  configured path.
- GitHub origin is not required in the guest for prod cutover.

## Impact

- Capabilities: MODIFIED `honor-being` (Forgejo write remote +
  respawn revoke includes Forgejo key delete)
- ADRs: none new (0011 already accepted)

## User journey & surfaces

No new UI because `git` in the guest, `mj exec`, and Forgejo
already exist. Host registers the key; grok/`mj connect --session
main` pushes.

- **Working (after act)** — `git -C` the clone shows the Forgejo
  remote; a signed commit pushed to `main` is visible on mimir;
  `.forgejo/workflows/deploy.yml` is the cutover (existing
  `ENABLE_DEPLOY` gate).
- **Empty** — no A3 / no `ssh_git` row → no deploy key → not a
  hosted being.
- **Failed (today)** — clone is `Permission denied (publickey)`;
  revoke Forgejo step is `:not_wired`.
- **Off** — spawn without `git_signing`.

## Out of scope

- Prod Medusa CORS — `update-hypersigil-store-cors` (`mjolnir-x97p.6`)
- Snapshot `XAI_API_KEY` scrub — `add-honor-snapshot-key-scrub`
- Forgejo machine user / second Forgejo person (ADR 0011: VM is a
  device, not a second identity)
- Forgejo “verified” commit badge (needs a user; deploy key is
  push auth). Visible on the repo is the gate.
- GitHub origin as deploy trigger
- Branch protection / extra push gate (ADR 0011 accepted risk)
- Tokenator / passing a Forgejo PAT into the guest
- `extra_mounts` (`mjolnir-gge.1.9`)
