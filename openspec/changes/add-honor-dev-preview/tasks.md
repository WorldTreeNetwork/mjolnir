# Tasks

- [ ] Bootstrap script on `ubuntu-24.04`: bun, git, grok CLI,
      clone Forgejo `VirtueInnova/hypersigil-store-frontend`
- [ ] `.env` / Vite: `VITE_MEDUSA_BACKEND_URL=https://api.hypersigil.world`
- [ ] `bun run dev --host`; confirm `mj url` loads the storefront
- [ ] tmux `session=main`; grok available on that session
- [ ] `XAI_API_KEY` in `/run/mjolnir/` tmpfs; snapshot does not
      contain it
- [ ] Per-friend snapshot `hosted-<xid>` with `preserve_iroh_key`;
      shared bootstrap snapshot does not preserve Iroh key
- [ ] Note ticket host for `update-hypersigil-store-cors`

Handoffs:

- `/term` passkey — `add-identikey-being-client`
- git key — `add-vm-git-subkey` then `add-honor-git-remote`
- CORS — `update-hypersigil-store-cors` (`mjolnir-x97p.6`)
