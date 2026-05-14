# Migration Pizza Box: Optional Per-Service Postgres Migration State Machine

**Status:** Design (2026-05-13) — DEFERRED until Mjolnir's own migrations stabilize
**Owner:** Duke

---

## 1. Goal

For each service that owns a Postgres role with write access to a database,
provide an *optional* migration state machine: deposit a migration script
plus the git hash that introduces it, and the system runs the migration
exactly once when the deployed code reaches that hash. Totally optional —
services can keep managing migrations by hand via raw SQL or any tool
they prefer.

The mental model: a "pizza box" — drop your migration into the box, it
sits there waiting, and gets opened (executed) at the right moment.

## 2. Why this isn't built yet

We don't yet have a stable migration story for Mjolnir itself. Building
infrastructure for "everyone else's migrations" before stabilizing our
own is premature. This doc captures the design so it's ready to land
when our internal story crystallizes.

## 3. Inputs to the box

A migration is a directory or single file dropped into a per-service
deposit path:

    <service_data>/migrations/pending/<id>/
      migration.sql       # idempotent if possible; required
      target_hash         # the git hash this migration belongs to; required
      meta.toml           # optional: name, description, author, created_at

## 4. State transitions

```
[pending] -> [waiting_for_hash] -> [ready] -> [running] -> [done | failed]
```

- **pending**: migration is in the deposit dir but `target_hash` hasn't
  been parsed/validated yet
- **waiting_for_hash**: parsed; the runner checks `deployed_hash` against
  `target_hash` on each tick
- **ready**: `deployed_hash == target_hash`; ready to run
- **running**: psql process is executing the migration
- **done**: completed successfully; recorded in a durable log
- **failed**: errored; recorded with the error, requires manual intervention

## 5. Idempotency

The pizza box runner records every executed migration in a state table
in the target database itself:

    CREATE TABLE _mjolnir_migrations (
      id TEXT PRIMARY KEY,
      target_hash TEXT NOT NULL,
      ran_at TIMESTAMPTZ NOT NULL,
      checksum TEXT NOT NULL,  -- SHA-256 of migration.sql
      duration_ms INTEGER
    );

Before running a migration, the runner checks if `id` is already in
this table. If yes: skip. This makes the runner safe under restarts,
duplicate deploys, and parallel runners.

## 6. Detecting deployed_hash

Each service exposes its own `deployed_hash` via:
- A file written at deploy time (e.g. `<service_data>/deployed_hash`)
- An HTTP endpoint (e.g. `GET /health` returning `{git_hash: ...}`)
- A systemd EnvironmentFile

The pizza box runner is per-service so it can use whichever the
service supports.

## 7. Failure handling

On migration error:
- Record state as `failed` with the SQL error in the state log
- Stop processing any further migrations for that service (avoid
  cascade)
- Emit an event for operator attention (EventBus, log, optional
  webhook)
- Manual intervention required: operator either fixes the migration
  and resubmits, or marks the failure as resolved

## 8. Why this is optional

Some services prefer to manage migrations themselves (especially those
using Ecto, Alembic, Flyway, or similar). The pizza box exists for
services that just want "deposit + forget" semantics. A service can:
- Use only the pizza box
- Use only its own tooling
- Use both (e.g., framework migrations for app-level changes, pizza
  box for one-off ops)

## 9. Open questions for later

- Per-service or global runner? Per-service is simpler operationally
  but multiplies daemon count; a single global runner with per-service
  views is more efficient.
- Migration ordering when two migrations target the same hash? Lexical
  by id is the safe default.
- Rollback support? Probably out of scope — pizza box is forward-only;
  rollback is an operator's manual job.
- Postgres-only or generalize to other databases? Postgres-only for
  Phase 1.
- Authorization: who can deposit a migration? Filesystem permissions
  on the deposit dir today; signed deposits (IdentiKey?) later.

## 10. Relation to Mjolnir's own migrations

When Mjolnir gets a stable internal migration story (e.g. Ecto.Migrator
running at boot), we'll know what shape the pizza box should mirror or
diverge from. Until then, this doc is the canonical sketch.
