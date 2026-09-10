# typed-log

Delta for `add-typed-log`. Not living truth until fold.

## ADDED Requirements

### Requirement: MIT npm package developed with bun

The typed-log TypeScript library SHALL live at `packages/log` in
identikey/mjolnir, SHALL be licensed MIT, SHALL be developed and
built with bun, and SHALL be published to npm as `mjolnir-log`
(or `@mjolnir/log` if that org is already owned at publish). The
runtime logger SHALL be pino.

#### Scenario: Install from npm

- GIVEN a published version of the package
- WHEN an application adds it with npm or bun
- THEN the package name resolves on the npm registry
- AND the license field is MIT

#### Scenario: Local develop

- GIVEN a checkout of identikey/mjolnir
- WHEN a developer runs the package test/build scripts with bun
- THEN tests and build complete without requiring Node as the
  package manager

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
- AND the record is still valid JSON or a plain ASCII rendering
  of it

### Requirement: App-owned type file

An originating application SHALL provide TypeScript types for its
log events. A generate step SHALL emit JSON Schema. The library
and later LSP SHALL load that schema. Records SHALL include a
schema identifier. Unknown fields SHALL be preserved on the wire.

#### Scenario: Myscape type file

- GIVEN myscape's generated JSON Schema
- WHEN `mjolnir-log` pretty-prints a matching event
- THEN fields are colored by schema type
- AND a field absent from the schema still appears on the JSON
  wire

### Requirement: Host and guest ingest, EventBus subscribe

Mjolnir SHALL keep guest syslog on vsock channel 2 and SHALL
register the Listener as that channel's handler (this is
`add-log-ingest` work; the guest forwarder already exists).
Mjolnir SHALL accept host application syslog on UDP (loopback
port; guests MAY send to `10.200.0.1`). Unix datagram SHALL NOT
be required of the TypeScript emitter. A record SHALL publish as
`:app_log` iff the MSG is a JSON object with a `schema` field,
regardless of `source`. Non-JSON guest text SHALL publish as
`:vm_syslog`. Subscribe SHALL use existing `:pg` process groups.
Phoenix.PubSub SHALL NOT be required. `:app_log` default sinks
SHALL be `[:eventbus]`. Records larger than 64 KiB SHALL be
treated as malformed raw, not dropped silently.

#### Scenario: Host app log reaches a subscriber

- GIVEN a process has `EventBus.subscribe("myscape")` or
  `EventBus.subscribe(:all)`
- WHEN myscape emits a typed log through UDP syslog to the
  configured host port
- THEN the process receives
  `{:mjolnir_event, "myscape", :app_log, record}`

#### Scenario: Guest logger still works

- GIVEN a running VM whose guest agent forwards `/dev/log` and
  whose vsock ch2 handler is the Syslog.Listener
- WHEN a process inside the VM writes non-JSON syslog
- THEN EventBus publishes `:vm_syslog` for that VM id

#### Scenario: JSON from a guest is still :app_log

- GIVEN a guest process emits RFC 3164 whose MSG is JSON with
  `schema`
- WHEN the Listener parses the line
- THEN EventBus publishes `:app_log` (source stamp may be
  `:guest`)
