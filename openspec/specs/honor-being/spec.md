# honor-being

What is built. Seeded by
[`add-honor-dev-preview`](../../changes/archive/2026-09-19-add-honor-dev-preview/proposal.md)
on 2026-09-19. The change-id keeps `honor` (a mis-transcription of
*hosted*); the product is a **hosted being**.

Only the dev-preview landing is living truth here. ADR
[`0011`](../../../docs/decisions/0011-honor-being.md) also carries
passkey `/term`, the `ssh_git` git-signing device, the Forgejo write
remote, and prod CORS — none of those have landed, so none of them
are SHALLs below. They arrive with `add-identikey-being-client`,
`add-vm-git-subkey`, `add-honor-git-remote`, and
`update-hypersigil-store-cors`.

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

> Enforcement is narrower than the intent. Bootstrap guards the
> storefront `.env` only; grok's own config dir, shell history, and
> anything written before `mj snapshot create` are unguarded. Full
> snapshot-level enforcement is beaded, not built.
