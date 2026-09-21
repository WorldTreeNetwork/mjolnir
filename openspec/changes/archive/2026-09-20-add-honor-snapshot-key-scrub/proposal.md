# add-honor-snapshot-key-scrub

> **ACTIVE BUILD**

Activated 2026-09-20 (ASK halt: activate scrub; leave Buzz DNS
on the apex CNAME). Bead `mjolnir-x97p.7` (from `mjolnir-3s6t`,
fold 2026-09-19). Living
`honor-being` already refuses `XAI_API_KEY` in the storefront `.env`.
Grok config, shell history, and anything written before
`mj snapshot create` are unguarded.

**Rigor:** change

## Why

A `hosted-<xid>` snapshot can still carry `XAI_API_KEY` if grok or
the shell wrote it before snapshot. The living spec names this gap.
Tmpfs inject after boot is the intended home of the key.

## What

- Before `mj snapshot create` of a hosted being (or as a snapshot
  hook), scrub guest paths that can hold `XAI_API_KEY` (storefront
  `.env` already guarded; also grok config dir and shell history).
- Capability `honor-being` MODIFIED / ADDED snapshot-level guard.
- Key still injects to `/run/mjolnir/` tmpfs after boot.

## Impact

- Capabilities: MODIFIED `honor-being` (snapshot does not persist
  the grok key)
- ADRs: none (ADR 0011 Decision 2 already says tmpfs-only)

## User journey & surfaces

No new UI because `mj snapshot create` and the hosted-being
bootstrap already exist. Operator snapshots after bootstrap; the
scrub runs as part of that path.

- **Working (after act)** — `hosted-<xid>` tree has no `XAI_API_KEY`.
- **Empty** — no grok key in tmpfs → grok cannot call xAI; snapshot
  still clean.
- **Failed (today)** — storefront `.env` is refused; grok config and
  history are not.
- **Off** — snapshot without the scrub.

## Out of scope

- New `@base/` name — ADR 0009
- grok OIDC / `GROK_OIDC_ISSUER` — ADR 0011
- Fold of `add-honor-being` architecture SHALLs still unimplemented
- Passkey `/term`, Forgejo write key
