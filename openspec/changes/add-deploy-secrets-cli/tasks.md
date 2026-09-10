# Tasks

- [x] `Mjolnir.Deploy.Secrets` merge/list/unset (atomic 0600 JSON)
- [x] PUT/GET/DELETE `/api/apps/:app/secrets` with Policy.App ownership
- [x] `mj secrets set|ls|unset`
- [ ] EYES: Host API running the new routes (Elixir release); guest still needs redeploy after set. Next: `just deploy` on the hypervisor, then `mj secrets ls <app>` against that host.
