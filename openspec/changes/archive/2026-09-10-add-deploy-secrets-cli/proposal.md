# add-deploy-secrets-cli

> **ACTIVE BUILD**

**Rigor:** change

## Why

Deploy secrets live in `/var/lib/mjolnir/deploy/secrets/<slug>.json` and
are injected at spawn. Operators still merge keys over SSH. Connecting
Stripe (or rotating SES) should be `mj secrets set`, same shape as
`mj domain set`.

## What

- ADDED capability `deploy-secrets`.
- `mj secrets set <app> KEY` (prompt / `--stdin` / `KEY=VALUE`) merges
  into the existing file. Never replace the whole map.
- `mj secrets ls <app>` lists **key names only**.
- `mj secrets unset <app> KEY`.
- Owner of the app (or localhost). Responses and logs never include values.

## Impact

- Capabilities: ADDED `deploy-secrets`
- ADRs: none (same host-escrow file as today)

## User journey & surfaces

From a laptop, authenticated `mj`:

```
mj secrets set hypersigil-api STRIPE_API_KEY
mj secrets ls hypersigil-api
```

No new UI because this is the CLI. The running guest still needs a
redeploy to pick up the env.

## Out of scope

- Injecting into a running guest without redeploy
- Returning secret values over the API
- Per-VM LUKS Iroh inject (`secrets_mode: persistent`)
