# steer add-site-cert-subject

**When.** 2026-10-15
**Depth.** explicit

## Decided

- Authority: any `vms:spawn` login, if a live site alias exists (user)
  Why: Open issuance. No per-site stamp, no fresh signature, no sites-token grant.
- Install: `[[cert]]` only for a site-only name (user)
  Why: A new `[[domain]]` apex defaults to Iroh fallthrough, and that disposition never reaches the sites resolver.
- Collision: an app custom domain owns the whole host (user)
  Why: The app owner check and the VM route stay as they are. The site path does not run for that name.
- Renewal: re-resolve, and a host that is neither keeps today's ensure (user)
  Why: Site-only renewal stays `[[cert]]` only. Hand-installed names such as `zine.identikey.io` still renew.

## Skipped

- none

## Feeds change

Lookup is app, then live alias, then `404 name_not_found`. A site-only install writes `[[cert]]` and does not add `[[domain]]`. Renewal classifies the same way. A `sites:publish` token stays `403`. Certificate list adds live site-alias hosts for any lister. The command stays `mj cert issue <fqdn>`.
