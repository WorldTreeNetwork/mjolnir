# add-honor-dev-preview

> **PENDING**

Bead `mjolnir-x97p.5`. ADR 0011 Decisions 2, 5, 6. Product is a
**hosted being** (change-id keeps `honor`).

**Rigor:** change

## Why

The friend needs grok and a Vite storefront on a ticket URL, talking
to prod `https://api.hypersigil.world`. No such VM exists. Prod
`hypersigil-store` is not that box.

## What

- Spawn `ubuntu-24.04` (or a snapshot of a grok+bun+git bootstrap).
  No new `@base/` name (ADR 0009).
- Install Linux grok (`curl -fsSL https://x.ai/cli/install.sh`);
  `XAI_API_KEY` in `/run/mjolnir/` tmpfs only (not the snapshot).
- Clone `hypersigil-store-frontend` **inside** the guest (extra_mounts
  still ignored, `mjolnir-gge.1.9`).
- `VITE_MEDUSA_BACKEND_URL=https://api.hypersigil.world`.
- `bun run dev --host` on the guest; `mj url` is
  `https://<ticket>.vm.worldtree.network`.
- tmux `session=main` (wrug `/term` + `mj connect --session main`).
- Per-friend snapshot `hosted-<xid>` with `preserve_iroh_key: true`
  so the ticket (and later CORS) survive respawn. Shared bootstrap
  snapshot does not preserve Iroh identity.
- Preview HTTP is unauthenticated (passkey gates `/term` only).

## Impact

- Capabilities: implements ADR 0011 preview SHALLs. CORS for the
  ticket origin is `update-hypersigil-store-cors` (`mjolnir-x97p.6`).
- ADRs: none new.

## User journey & surfaces

Friend opens `/term/<id>` (after `add-identikey-being-client`) and
the ticket URL in another tab.

- **Working (after act)** — grok in tmux `main`; storefront loads on
  the ticket URL; product fetches hit `api.hypersigil.world`.
- **Empty** — no grok key in tmpfs → grok cannot call xAI; page
  still paints.
- **Failed (today)** — no hosted VM; prod site is not a Vite server.
- **Off** — spawn without bootstrap.

## Out of scope

- Passkey `/term` — `add-identikey-being-client`
- Git signing key — `add-vm-git-subkey`
- Prod Medusa CORS — `update-hypersigil-store-cors`
- Named subdomain
- `GROK_OIDC_ISSUER`
