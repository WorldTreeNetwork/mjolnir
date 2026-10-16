## MODIFIED Requirements

### Requirement: Certificate lookup prefers an app, then a live site alias
<!-- base: 667fc9135d789c499d5f8f3502155e2670241979 openspec/specs/site-certs/spec.md -->

`POST /api/certs/issue` SHALL normalize the fqdn the way app custom-domain
lookup already does (trim, strip one trailing dot, downcase) and SHALL
resolve it in this order:

1. A `Deploy.Registry` custom domain → the existing app issue path,
   including the owner check.
2. Else a live site alias (`SecretStore.lookup_alias/1` hit) → HTTP-01
   issuance for any caller who already passed `vms:spawn`.
3. Else `404` with error `name_not_found`.

On the site-alias branch, before HTTP-01, the issuer SHALL classify the
host as the gateway would. Classification `Local` or `Iroh` SHALL return
`409 host_routed_elsewhere` and SHALL NOT call Let's Encrypt.
Classification `Reject` or `Parked` SHALL continue, because those
dispositions reach the sites resolver.

An unreadable alias index SHALL NOT be treated as a miss. Issue SHALL
return `503 alias_index_unreadable` and SHALL NOT call Let's Encrypt. A
missing index file remains a miss. A readable alias-index file that does
not parse SHALL be unreadable.

A wildcard SHALL be refused with `400 wildcard_not_supported` before
either lookup. A `sites:publish` token SHALL be refused with `403
insufficient_scope` and SHALL NOT issue. A tombstoned alias SHALL be a
miss. The success body SHALL be `fqdn`, `status`, and `not_after`, and
SHALL NOT contain a PEM. `app_not_found` and `name_not_found` differing
is an accepted existence oracle.

#### Scenario: Site alias issues

- GIVEN a live site alias for `blog.example.com`
- AND no deployed app has that custom domain
- AND the caller passed `vms:spawn`
- WHEN the caller posts `{"fqdn":"blog.example.com"}` to `/api/certs/issue`
- THEN the status is 200
- AND the body has `fqdn`, `status`, and `not_after`
- AND the body has no PEM field

#### Scenario: Neither binding

- GIVEN no app custom domain and no live site alias for `gone.example.com`
- WHEN a `vms:spawn` caller posts that fqdn to `/api/certs/issue`
- THEN the status is 404
- AND the error is `name_not_found`

#### Scenario: App owner wins the whole host

- GIVEN a deployed app has custom domain `shop.example.com`
- AND a live site alias also exists for `shop.example.com`
- AND the caller does not own the app
- WHEN the caller posts that fqdn to `/api/certs/issue`
- THEN the status is 404
- AND the error is `app_not_found`
- AND the site-alias path does not issue

#### Scenario: Sites token cannot issue

- GIVEN a caller authenticated with a `sites:publish` token
- WHEN the caller posts any fqdn to `/api/certs/issue`
- THEN the status is 403
- AND the error is `insufficient_scope`

#### Scenario: Wildcard still refused

- GIVEN any caller
- WHEN the caller posts `{"fqdn":"*.example.com"}` to `/api/certs/issue`
- THEN the status is 400
- AND the error is `wildcard_not_supported`

#### Scenario: Unparseable alias index

- GIVEN the alias index file for `blog.example.com` is readable
- AND its bytes are not a JSON alias record and not a single-colon legacy record
- AND no deployed app has that custom domain
- WHEN a `vms:spawn` caller posts that fqdn to `/api/certs/issue`
- THEN the status is 503
- AND the error is `alias_index_unreadable`
- AND Let's Encrypt is not called

### Requirement: Renewal classifies the host again
<!-- base: 667fc9135d789c499d5f8f3502155e2670241979 openspec/specs/site-certs/spec.md -->

The daily renewal pass SHALL classify a due host with the same three-way
rule before it installs, and SHALL still issue at most one certificate per
pass. Renewal SHALL reinstall the certificate and SHALL NOT append a
`[[domain]]` block that is not already present, on every branch. An
unreadable alias index SHALL fail or skip that pass and SHALL NOT be
classified as "neither". A missing index file remains a miss. A readable
alias-index file that does not parse SHALL be unreadable.

- App custom domain → reinstall the certificate. Do not add an apex.
- Live site alias and not an app → reinstall the certificate. Do not add an apex.
- Neither → reinstall the certificate. Do not add an apex.

Renewal SHALL NOT re-apply the site-path `409 host_routed_elsewhere`. A due
certificate whose host would now classify as `Local` or `Iroh` SHALL still
be reinstalled, and SHALL still not gain a new `[[domain]]`.

A wildcard host SHALL stay skipped.

#### Scenario: Site renewal does not add an apex

- GIVEN `blog.example.com` has an installed certificate inside the renewal window
- AND it is a live site alias and not an app custom domain
- AND it is the only due certificate
- WHEN the renewal pass runs
- THEN it re-issues that host over HTTP-01
- AND it does not add a `[[domain]]` apex

#### Scenario: Hand-installed name renews without a new apex

- GIVEN `zine.identikey.io` has an installed certificate inside the renewal window
- AND it is not an app custom domain and not a live site alias
- AND it is the only due certificate
- WHEN the renewal pass runs
- THEN the certificate is reinstalled over HTTP-01
- AND no `[[domain]]` block is added

#### Scenario: Deleted alias does not capture a sibling

- GIVEN `blog.example.com` had a site alias that is now gone
- AND its certificate is installed and due
- AND `docs.example.com` is a different live site alias
- AND gateway config has no `[[domain]]` for `example.com`
- WHEN the renewal pass renews `blog.example.com`
- THEN it does not add `[[domain]]` suffix `example.com`
- AND `docs.example.com` still classifies as a route-table miss that reaches the sites resolver

#### Scenario: Unreadable index does not renew as a stranger

- GIVEN a due certificate whose host is not an app custom domain
- AND the alias index cannot be read, and the failure is not a missing file
- WHEN the renewal pass considers that host
- THEN it does not install
- AND it does not add a `[[domain]]` block

#### Scenario: Renewal does not refuse a host that later routes elsewhere

- GIVEN `blog.example.com` has an installed certificate inside the renewal window
- AND it is a live site alias
- AND the gateway would now classify that host as `Local` or `Iroh`
- AND it is the only due certificate
- WHEN the renewal pass runs
- THEN it reinstalls the certificate over HTTP-01
- AND it does not add a `[[domain]]` apex

### Requirement: Certificate list shows live site aliases to any lister
<!-- base: 667fc9135d789c499d5f8f3502155e2670241979 openspec/specs/site-certs/spec.md -->

`GET /api/certs` SHALL keep omitting PEMs. The operator SHALL see every
installed certificate. Any other caller who passed the list scope SHALL see
certificates for app domains they own, plus every certificate whose host is
a live site alias. A hand-installed host that is not a live alias SHALL
remain operator-only.

When the alias index for a host cannot be read, and the failure is not a
missing file, `GET /api/certs` SHALL omit that host for a non-operator and
SHALL still return 200 with the caller's owned app hosts. It SHALL NOT fail
the list. A readable file that does not parse is that same failure. The
operator SHALL still see every installed certificate.

#### Scenario: Another login sees a site certificate

- GIVEN an installed certificate for `blog.example.com`
- AND `blog.example.com` is a live site alias
- AND the caller is not the operator and owns no app on that name
- AND the caller passed the certificate list scope
- WHEN the caller gets `/api/certs`
- THEN the list includes `blog.example.com`
- AND no entry contains a PEM

#### Scenario: Hand-installed host stays operator-only

- GIVEN an installed certificate for `zine.identikey.io`
- AND that host is not a live site alias
- AND the caller is not the operator and does not own an app on that name
- WHEN the caller gets `/api/certs`
- THEN the list does not include `zine.identikey.io`

#### Scenario: Unreadable index omits alias-only hosts

- GIVEN an installed certificate for `blog.example.com`
- AND the alias index cannot be read, and the failure is not a missing file
- AND the caller is not the operator
- AND the caller owns an app whose custom domain has its own installed certificate
- WHEN the caller gets `/api/certs`
- THEN the status is 200
- AND the list includes the owned app host
- AND the list does not include `blog.example.com`
- AND no entry contains a PEM

## ADDED Requirements

### Requirement: An unclassifiable gateway config fails closed on the site path

Before HTTP-01 on the site-alias branch, the issuer SHALL read the same
gateway config the gateway would, including route and alias declarations
from gateway drop-ins. A missing base file SHALL be an empty route table
(`Reject`), and issuance MAY continue. A missing drop-in directory SHALL be
ignored. A drop-in that fails to parse SHALL be skipped. Drop-ins SHALL NOT
add apexes. Any other failure to read or classify the base file SHALL return
`503 gateway_config_unreadable` and SHALL NOT call Let's Encrypt and SHALL
NOT install a `[[cert]]`. Renewal SHALL NOT consult this classification.

#### Scenario: Unreadable gateway config

- GIVEN `blog.example.com` is a live site alias and not an app custom domain
- AND the base gateway config cannot be read, and the failure is not a missing file
- WHEN a `vms:spawn` caller posts that fqdn to `/api/certs/issue`
- THEN the status is 503
- AND the error is `gateway_config_unreadable`
- AND Let's Encrypt is not called
