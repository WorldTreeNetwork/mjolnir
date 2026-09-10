## MODIFIED Requirements

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

#### Scenario: Generate from types

- GIVEN an app type file that lists `url: string`
- WHEN the bun generate step runs
- THEN the emitted JSON Schema has `url` with type string
- AND `$id` matches the record `schema` field the logger stamps

## ADDED Requirements

### Requirement: Schema language server

`packages/log` SHALL ship a stdio LSP (`mjolnir-log-lsp`) that
loads the generated JSON Schema and reports diagnostics for
unknown fields, type mismatches, and missing required fields on
JSON log records. Schema selection SHALL use the record's
`schema` / `$id`. The LSP SHALL NOT drop unknown fields from the
document. A VS Code extension SHALL NOT be required for v1.

#### Scenario: Unknown field diagnostic

- GIVEN a generated schema that does not list `extra`
- AND the LSP is attached to a JSON record `{ "schema": "myscape/v1", "extra": true }`
- WHEN the document is validated
- THEN a diagnostic names `extra`
- AND the document text still contains `extra`
