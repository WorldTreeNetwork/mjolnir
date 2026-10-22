# typed-log

What is built. Folded from `add-typed-log`, `add-log-emit`,
`add-log-ingest`, and `add-log-subscribe` on 2026-09-10, and
from `add-log-lsp` on 2026-09-10.
Decisions live in
[`docs/decisions/0010-typed-log.md`](../../../docs/decisions/0010-typed-log.md).

## Purpose

Apps emit typed pino JSON on stdout and optional RFC 3164 UDP syslog.
Mjolnir ingests host UDP and guest vsock ch2, then publishes
`:app_log` (JSON MSG with `schema`) or `:vm_syslog` (text) on
`Mjolnir.EventBus` (`:pg`). Pretty/LSP share an app-owned JSON Schema
generated from a TypeScript const schema object union the
library pino envelope (`mjolnir-log` `generateSchema` /
`mjolnir-log-lsp`).

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

An originating application SHALL provide a TypeScript const schema
object for its log events; the field type SHALL be derived from
that object via a helper exported by `mjolnir-log`. `mjolnir-log`
SHALL export `generateSchema` (or a `generate --check` bin) that
emits JSON Schema: library-owned pino envelope union the app's
fields. Closed-world enforcement SHALL live in that library
function, not per app. Envelope required keys SHALL be `level`
(number), `time` (string), `schema` (string), `app` (string),
`name` (string). Envelope optional keys SHALL be `msg` (string)
and `err` (`type: object`). Generated schema SHALL set
`additionalProperties: false`. An app key that collides with an
envelope key SHALL fail generate. Apps SHALL NOT hand-list
envelope keys. `$id` on the emitted schema SHALL be the same
const passed to `createLogger({ schema })`. The generate step
SHALL fail on any construct outside the subset `validateRecord`
checks, including nested `properties` until the validator
recurses. Library-owned `--check` SHALL fail when the committed
schema file differs from generated output. The library SHALL
validate records against that schema. Unknown fields SHALL be
preserved on the wire and reported as issues. An unknown JSON
Schema `type` SHALL be a validation issue, not a pass.

#### Scenario: Unknown field kept

- GIVEN a schema that does not list `extra`
- WHEN a record `{ schema, extra: true }` is validated
- THEN an issue names `extra`
- AND the JSON still contains `extra`

#### Scenario: Generate from types

- GIVEN an app const schema object that lists `url: string` and
  does not list envelope keys
- AND the library envelope fragment
- WHEN `generateSchema` runs
- THEN the emitted JSON Schema has `url` with type string
- AND required envelope keys `level`, `time`, `schema`, `app`, `name`
- AND optional envelope keys `msg` and `err`
- AND `additionalProperties` is false
- AND `$id` matches the record `schema` field the logger stamps

#### Scenario: Envelope key collision

- GIVEN an app const schema object that lists `level`
- WHEN `generateSchema` runs
- THEN it fails
- AND no schema file is written

#### Scenario: Closed world

- GIVEN an app const schema object that uses `enum`, `type: array`,
  or nested `properties`
- WHEN `generateSchema` runs
- THEN it fails
- AND no schema file is written

#### Scenario: Drift check

- GIVEN a committed `schema.json` that differs from generate output
- WHEN library-owned `--check` runs
- THEN the step fails

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

### Requirement: Schema language server

`packages/log` SHALL ship a stdio LSP (`mjolnir-log-lsp`) that
loads the generated JSON Schema and reports diagnostics for
unknown fields, type mismatches, missing required fields, and
unknown `$id` on NDJSON log records (one JSON object per line;
`.jsonl` / `.ndjson` / `{`-leading `.log`). Schema selection
SHALL use the record's `schema` / `$id` against a registry of
workspace `**/*schema.json` plus `initializationOptions.schemaPaths`.
An NDJSON line with no `schema` key SHALL produce no diagnostic.
The LSP SHALL map each `ValidationIssue.path` onto a text range
via a position-preserving JSON parser; unresolved paths SHALL
use the whole line. The LSP SHALL NOT drop unknown fields from
the document. `vscode-languageserver` and the parser SHALL be
optionalDependencies of `mjolnir-log`; the logger entry SHALL
NOT import them. A VS Code extension SHALL NOT be required for v1.

#### Scenario: Unknown field diagnostic

- GIVEN a generated schema that does not list `extra`
- AND the LSP is attached to an NDJSON record `{ "schema": "myscape/v1", "extra": true }`
- WHEN the document is validated
- THEN a diagnostic names `extra`
- AND the document text still contains `extra`

#### Scenario: Unknown schema id

- GIVEN no loaded schema whose `$id` is `myscape/v2`
- AND an NDJSON line `{ "schema": "myscape/v2" }`
- WHEN the document is validated
- THEN one diagnostic names `myscape/v2`

#### Scenario: Untyped line

- GIVEN an NDJSON line `{ "msg": "hello" }` with no `schema` key
- WHEN the document is validated
- THEN there is no diagnostic on that line
