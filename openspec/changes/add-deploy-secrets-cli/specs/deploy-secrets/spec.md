## ADDED Requirements

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
