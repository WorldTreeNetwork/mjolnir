# deploy-secrets

What is built. Folded from
[`add-deploy-secrets-cli`](../../changes/archive/2026-09-10-add-deploy-secrets-cli/proposal.md)
on 2026-09-10. No ADR — same host-escrow file as before the CLI.

## Purpose

Operators merge host-escrowed env for `mj deploy` with `mj secrets
set|ls|unset`. The host API is PUT/GET/DELETE `/api/apps/:app/secrets`.
Writes merge into `/var/lib/mjolnir/deploy/secrets/<slug>.json` and do
not replace the map. Authorization is `Policy.App` (`owner_id`), not a
Linux user. List and responses return key names only. The running
guest still needs a redeploy to pick up a newly set key.

File mode `0600 root:root` is hygiene (other Unix users on the
hypervisor), not confidentiality and not authorization. Recrypt PRE
and Biscuit Datalog are later tracks (`mjolnir-k8y.4`, `mjolnir-k8y.5`)
and are **not** this capability. See
[`docs/secrets-architecture.md`](../../../docs/secrets-architecture.md#what-0600-means-steer-2026-09-10).

Out of scope: injecting into a running guest without redeploy,
returning secret values over the API, per-VM LUKS Iroh inject
(`secrets_mode: persistent`).

## Requirements

### Requirement: Merge deploy secrets from the CLI

An authenticated app owner SHALL be able to set a secret for a deployed
app by name. The write SHALL merge into
`/var/lib/mjolnir/deploy/secrets/<slug>.json` and SHALL NOT drop other
keys. Key names SHALL match `[A-Za-z_][A-Za-z0-9_]*`. List SHALL return
key names only. Values SHALL NOT appear in API responses or logs.

#### Scenario: Set merges

- GIVEN an app whose secrets file already has `DATABASE_URL`
- WHEN the owner sets `STRIPE_API_KEY`
- THEN the file contains both keys
- AND the response lists key names, not values

#### Scenario: Non-owner cannot set

- GIVEN an app owned by alice
- WHEN mallory PUTs a secret
- THEN the response is 404 `app_not_found`
