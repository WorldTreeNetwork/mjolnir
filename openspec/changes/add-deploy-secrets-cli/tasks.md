# Tasks

- [x] `Mjolnir.Deploy.Secrets` merge/list/unset (atomic 0600 JSON)
- [x] PUT/GET/DELETE `/api/apps/:app/secrets` with Policy.App ownership
- [x] `mj secrets set|ls|unset`
- [x] EYES: Host API running the new routes (Elixir release); guest still needs redeploy after set. Next: `just deploy` on the hypervisor, then `mj secrets ls <app>` against that host. Looked 2026-09-10: `just deploy` to `root@45.76.77.97`; `mj secrets ls hypersigil-api` names-only over `https://api.vm.worldtree.network`; PUT/DELETE probe then unset; files remain `0600 root:root`. Guest still needs redeploy to pick up a newly set key.
