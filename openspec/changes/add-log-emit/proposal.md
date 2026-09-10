# add-log-emit

> **ACTIVE BUILD**

Activated with the typed-log DAG. Depends on `add-typed-log`
(Fable accept + amendment pins `c40b93f`).

**Rigor:** change
**Bead:** `mjolnir-tw17`

## Why

The ADR names a bun/pino package. Without it, myscape cannot emit
typed syslog and the ingest node has nothing to parse.

## What

- `packages/log` (`mjolnir-log`, MIT): pino, bun test/build,
  stdout default, UDP RFC 3164 syslog when configured, pretty vs
  plain ASCII, `schema` on every record.
- In-process streams (no `thread-stream` workers).

## Impact

- Capabilities: MODIFIED `typed-log` (emit SHALLs become true)
- ADRs: none (0010 already)

## User journey & surfaces

No new UI because the outcome already reaches stdout and UDP syslog.

- **Working** — `createLogger({ name, schema, syslog })` writes JSON
  (or colored TTY) and a 3164 datagram with JSON MSG.
- **Empty** — `packages/log` did not exist.
- **Failed** — console.log / ad-hoc rings.
- **Off** — syslog target unset: stdout only.

## Out of scope

- Host UDP listener / ch2 register — `add-log-ingest`
- LSP — `add-log-lsp`
- Myscape type file — `add-myscape-log-types`
