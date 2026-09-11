## MODIFIED Requirements

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

## ADDED Requirements

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
