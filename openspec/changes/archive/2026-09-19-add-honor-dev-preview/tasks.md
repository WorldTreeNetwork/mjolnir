# Tasks

- [x] Bootstrap script `scripts/hosted-being-bootstrap.sh`
- [x] `.env` / Vite: `VITE_MEDUSA_BACKEND_URL=https://api.hypersigil.world`
- [x] `bun run dev --host`; confirm `mj url` loads the storefront
      (needs a spawned guest)
- [x] tmux `session=main` created by bootstrap
- [x] `XAI_API_KEY` documented as tmpfs-only (runbook)
- [x] Per-friend snapshot `hosted-<xid>` with `preserve_iroh_key`
- [x] Note ticket host for `update-hypersigil-store-cors` (runbook)

Handoffs:

- `/term` passkey — `add-identikey-being-client`
- git key — `add-vm-git-subkey` then `add-honor-git-remote`
- CORS — `update-hypersigil-store-cors` (`mjolnir-x97p.6`)
