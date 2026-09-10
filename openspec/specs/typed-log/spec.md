# typed-log

What is built. Folded from `add-typed-log`, `add-log-emit`,
`add-log-ingest`, and `add-log-subscribe` on 2026-09-10.
Decisions live in
[`docs/decisions/0010-typed-log.md`](../../../docs/decisions/0010-typed-log.md).

## Purpose

Apps emit typed pino JSON on stdout and optional RFC 3164 UDP syslog.
Mjolnir ingests host UDP and guest vsock ch2, then publishes
`:app_log` (JSON MSG with `schema`) or `:vm_syslog` (text) on
`Mjolnir.EventBus` (`:pg`). Pretty/LSP share an app-owned JSON Schema
generated from TypeScript types.

## Requirements

### Requirement: MIT npm package developed with bun

The typed-log TypeScript library SHALL live at `packages/log` in
identikey/mjolnir, SHALL be licensed MIT, SHALL be developed and
built with bun, and SHALL be published to npm as `mjolnir-log`
(or `@mjolnir/log` if that org is already owned at publish). The
runtime logger SHALL be pino.

#### Scenario: Local develop

- GIVEN a checkout of identikey/mjolnir
- WHEN a developer runs `bun test` in `packages/log`
- THEN tests complete without requiring Node as the package manager

### Requirement: Stdout and syslog sinks

The library SHALL write to stdout by default. When a UDP syslog
target is configured it SHALL also emit RFC 3164 syslog whose MSG
is the pino JSON object. Unset target SHALL mean stdout only, with
no error. Syslog emit failure SHALL NOT crash the process. The
syslog bytes SHALL NOT contain ANSI escape sequences.

#### Scenario: TTY pretty

- GIVEN a TTY stdout and no `NO_COLOR`
- WHEN the app logs a typed event
- THEN stdout is a colored rendering of parsed fields
- AND syslog MSG is JSON without ANSI

#### Scenario: Plain ASCII

- GIVEN `NO_COLOR` or `--plain` or a non-TTY stdout
- WHEN the app logs a typed event
- THEN stdout contains no ANSI

### Requirement: App-owned type file

An originating application SHALL provide TypeScript types for its
log events. A generate step SHALL emit JSON Schema. The library
SHALL validate records against that schema. Unknown fields SHALL be
preserved on the wire and reported as issues.

#### Scenario: Unknown field kept

- GIVEN a schema that does not list `extra`
- WHEN a record `{ schema, extra: true }` is validated
- THEN an issue names `extra`
- AND the JSON still contains `extra`

### Requirement: Host and guest ingest, EventBus subscribe

Mjolnir SHALL keep guest syslog on vsock channel 2 and SHALL
register the Listener as that channel's handler. Mjolnir SHALL
accept host application syslog on UDP (loopback port; guests MAY
send to `10.200.0.1`). A record SHALL publish as `:app_log` iff the
MSG is a JSON object with a `schema` field, regardless of `source`.
Non-JSON guest text SHALL publish as `:vm_syslog`. Subscribe SHALL
use existing `:pg` process groups. `EventBus.subscribe_logs/1` SHALL
join log-only groups (`:app_log_all` / `{:app_log, id}`) so
subscribers do not receive VM lifecycle events. Phoenix.PubSub SHALL
NOT be required. `:app_log` default sinks SHALL be `[:eventbus]`.
Records larger than 64 KiB SHALL be treated as malformed raw, not
dropped silently. App id SHALL be treated as self-asserted.

#### Scenario: Host app log reaches a log subscriber

- GIVEN a process has `EventBus.subscribe_logs("myscape")`
- WHEN myscape emits a typed log through UDP syslog
- THEN the process receives
  `{:mjolnir_event, "myscape", :app_log, record}`
- AND does not receive `:vm_spawned` for that id

#### Scenario: Guest logger still works

- GIVEN a running VM whose vsock ch2 handler is the Syslog.Listener
- WHEN a process inside the VM writes non-JSON syslog
- THEN EventBus publishes `:vm_syslog` for that VM id

#### Scenario: JSON from a guest is still :app_log

- GIVEN a guest process emits RFC 3164 whose MSG is JSON with
  `schema`
- WHEN the Listener parses the line
- THEN EventBus publishes `:app_log` (source stamp may be `:guest`)
