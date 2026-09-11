## MODIFIED Requirements

### Requirement: App-owned type file

An originating application SHALL provide a TypeScript const schema
object for its log events; the field type SHALL be derived from
that object. A generate step SHALL emit JSON Schema that is the
library-owned pino envelope (`level`, `time`, `schema`, `app`,
`name`, `msg`) union the app's fields. Apps SHALL NOT hand-list
envelope keys. `$id` on the emitted schema SHALL be the same
const passed to `createLogger({ schema })`. The generate step
SHALL fail on any construct outside the subset `validateRecord`
checks. `bun generate --check` (or the package test) SHALL fail
when the committed schema file differs from generated output.
The library SHALL validate records against that schema. Unknown
fields SHALL be preserved on the wire and reported as issues.
An unknown JSON Schema `type` SHALL be a validation issue, not a
pass.

#### Scenario: Unknown field kept

- GIVEN a schema that does not list `extra`
- WHEN a record `{ schema, extra: true }` is validated
- THEN an issue names `extra`
- AND the JSON still contains `extra`

#### Scenario: Generate from types

- GIVEN an app const schema object that lists `url: string`
- AND the library envelope fragment
- WHEN the bun generate step runs
- THEN the emitted JSON Schema has `url` with type string
- AND it has envelope keys `level`, `time`, `schema`, `app`, `name`, `msg`
- AND `$id` matches the record `schema` field the logger stamps
- AND the app object does not itself list those envelope keys

#### Scenario: Closed world

- GIVEN an app const schema object that uses `enum` or `type: array`
- WHEN the bun generate step runs
- THEN it fails
- AND no schema file is written

#### Scenario: Drift check

- GIVEN a committed `schema.json` that differs from generate output
- WHEN `bun generate --check` runs
- THEN the step fails

## ADDED Requirements

### Requirement: Schema language server

`packages/log` SHALL ship a stdio LSP (`mjolnir-log-lsp`) that
loads the generated JSON Schema and reports diagnostics for
unknown fields, type mismatches, missing required fields, and
unknown `$id` on NDJSON log records (one JSON object per line;
`.jsonl` / `.ndjson` / `{`-leading `.log`). Schema selection
SHALL use the record's `schema` / `$id` against a registry of
workspace `**/*schema.json` plus `initializationOptions.schemaPaths`.
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
