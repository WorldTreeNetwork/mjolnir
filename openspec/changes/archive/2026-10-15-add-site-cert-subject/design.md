# add-site-cert-subject

## Decision

A site alias is a second subject of the existing HTTP-01 issuer. It is not an app, and install must not make the gateway treat it as one.

Four rules, from steer 2026-10-15:

1. **Authority.** Any caller who already passed `vms:spawn` may issue for a live alias. There is no per-alias owner stamp. A `sites:publish` token never reaches that check.
2. **Collision.** If a `Deploy.Registry` entry has this custom domain, the app path wins for the whole host. The site path does not run. A caller who does not own the app still gets `404 app_not_found`.
3. **Install.** A site-only subject writes `[[cert]]` for that exact host and does not add a `[[domain]]` block. An apex that is already present stays. This change does not delete apexes.
4. **Renewal.** `renew_due` classifies the host again before install, then reinstalls the PEM. It does not append a `[[domain]]` that is not already in the file, on any branch. An app's first issue may still add an apex. A hand-installed name such as `zine.identikey.io` still renews; if its apex is already declared, that block stays, and renewal does not create one that was missing. An unreadable alias index is an error for that pass, not a miss, so a disk error cannot be classified as "neither" and then declare an apex.

`GET /api/certs` follows the open rule. A non-operator login sees certificates for app domains they own, plus every certificate whose host is a live site alias. The operator sees every `[[cert]]`. Bodies still omit PEMs. Hand-installed hosts that are not aliases stay operator-only.

The command stays `mj cert issue <fqdn>`.

## Why the apex is the hazard

`Mjolnir.Gateway.Certs.ensure/2` appends `[[domain]] suffix = <last two labels>` when that suffix is absent (`ensure_domain_block/2`). The gateway parses a missing fallthrough as Iroh (`parse_fallthrough/1`). `classify/2` then returns `Disposition::Iroh` for an unknown subdomain. Sites lookup runs only for `Parked` and `Reject`.

A site name works today because its apex is not declared, so `classify` returns `DomainMismatch` and the resolver serves the snapshot. Adding `example.com` as an Iroh apex to certify `blog.example.com` would dial Iroh for `blog` and never serve the site. `apex_of/2` is also the last two labels, so a name like `blog.example.co.uk` would declare `co.uk`.

SNI does not need the apex. `select_extra` matches `[[cert]] host`. HTTP-01 is served in `handle_connection` before `classify`.

## Lookup

Normalize the way `app_for_domain/1` already does: trim, strip one trailing dot, downcase.

1. App custom domain match → existing `authorize_app(..., :issue_cert)` and `Mjolnir.API.Certs.issue/1` with today's ensure.
2. Else `SecretStore.lookup_alias/1` hit → HTTP-01 issue, then ensure with domain insertion off.
3. Else `404 name_not_found`.

Before HTTP-01 on the site path, classify the host the way the gateway would. `Local` or `Iroh` → `409 host_routed_elsewhere`, and Let's Encrypt is not called. `Reject` and `Parked` still reach the sites resolver, so those issue. A `[[route]]` or gateway `[[alias]]` for that subdomain is `Local` or `Iroh` and refuses. An existing apex with fallthrough `none` or `parked`, and no route for that subdomain, still issues, and the apex is left as it is.

Wildcard refusal stays first, and stays `400 wildcard_not_supported`.

"Live alias" means the alias index has a hit for that host. A tombstone or a missing file is a miss. `lookup_alias/1` currently maps every read error to `:not_found`. Cert classification needs a read that returns `{:error, reason}` for anything other than a missing file, and both issue and renewal fail closed on that error (`503 alias_index_unreadable` on the request, and the renewal pass installs nothing).

`app_not_found` versus `name_not_found` tells a non-owner that some app holds the name. Custom domains are already public in DNS. That oracle is an accepted cost.

## Install seam

The later change adds a flag on `Gateway.Certs.ensure/2`, defaulting to today's behavior, that skips `ensure_domain_block/2`. Site-only issuance passes that flag. An app's first issue does not, so it may still add an apex. Renewal passes it on every branch, so a renewed PEM cannot declare a missing apex. PEMs still never leave the host. The one-shot stays `systemd-run` as `mjolnir`, because `ProtectSystem=strict` still cannot be given the http-01 directory.

## Renewal seam

`renew_due/1` calls `issue/2` directly, not the router. Classification has to live where both the route and the timer install. One due certificate per call stays. Wildcards stay skipped.

Renewal's ensure never appends a `[[domain]]`. First issue of an app still may. A renewed PEM always differs, so `ensure_origin_ca` would otherwise re-enter `ensure_domain_block` and declare a missing apex. That is how deleting `blog.example.com` would, on renewal day, append `example.com` as Iroh and take `docs.example.com` off the sites resolver. The bound is: reinstall the certificate, leave the apex list unchanged.

## Tradeoff on the bound

Steer said a stranger keeps today's install so `zine.identikey.io` still renews. Today's ensure also adds a missing apex. The bound keeps the renewal and drops only the append. An app whose apex was later deleted is not given that apex back by the timer. The next app issue can add it. That is the smaller blast.

## Tradeoff

Open issuance lets any `vms:spawn` login spend the host Let's Encrypt quota on any published alias, and `mj cert ls` then shows that name to every lister. The alias is already a public routing record (`GET /api/sites/aliases/lookup` is unauthenticated). Steer chose this over a login stamp, a fresh keypair signature, and a sites-token grant. The quota is the cost. The non-owner of an app still cannot issue for that app's name.

## Refusals

- No merged deploy pipeline.
- No path split on one host.
- No DNS-01 and no customer DNS credentials.
- No new client flag.
- No change to `sites-serve` miss policy.
