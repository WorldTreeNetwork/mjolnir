# Design — add-log-lsp

**Status:** Active (architecture amend after Fable re-advise send-back 2026-09-10).
**Change:** `add-log-lsp`
**Bead:** `mjolnir-vzo6`
**Capability:** `typed-log` (ADR 0010 D4)

Grok authored. Advise reader must not be Grok (ADR-005). Fable 5.1
is the cross-family reader. Re-advise on the same route after this
amend.

**Folder:** do not fold the MODIFIED generate-step SHALL or the
ADDED `mjolnir-log-lsp` SHALL into `openspec/specs/typed-log/`
until the bun generate step and the bin exist (LEARNINGS
2026-08-16). Living spec already carries an unbuilt generate
SHALL from the 2026-09-10 typed-log fold; this change is the
one that makes it true.

## Decision 1 — stdio LSP in `packages/log`

v1 ships a bun bin `mjolnir-log-lsp` using `vscode-languageserver`.
Editors that speak LSP (neovim, zed, VS Code via a later thin
client) attach. Rejected: VS Code extension as the product;
TS-call-site-only intelligence.

**Document model.** Log output is NDJSON (one JSON object per
line). The LSP attaches to `.jsonl`, `.ndjson`, and `.log` when
the first non-empty line starts with `{`. A generated
`schema.json` is a single JSON document (schema file, not a log).
v1 diagnostics run on NDJSON log documents. Hover is optional
once the schema is loaded; semantic tokens are out.

**`path` → range.** `validateRecord` returns `{ path, message }`
with `path` a property name (dotted for nested objects if the
validator grows). The server parses each NDJSON line with a
position-preserving parser (`jsonc-parser` or equivalent) and
maps `path` onto that parse tree's offsets. If the path cannot
be resolved, the diagnostic range is the whole line.

**Schema discovery.** Index `$id` from (1) workspace glob
`**/*schema.json` and (2) `initializationOptions.schemaPaths`.
A record's `schema` field selects the schema. Unknown `$id`
yields one diagnostic (`no schema for <id>`), not silence.
An NDJSON line with no `schema` key is not a typed-log record
(living spec: `:app_log` iff `schema`); the LSP emits no
diagnostic for it.

**Where LSP deps live.** Bin stays in `packages/log` so the LSP
cannot be older than the checker it wraps. `vscode-languageserver`
and the position-preserving parser are `optionalDependencies` of
`mjolnir-log`. The logger entry (`src/index.ts`) MUST NOT import
them. The bin exits with a clear error if they are missing.
Rejected for v1: sibling `packages/log-lsp` (second publish).

## Decision 2 — Schema source is generated JSON Schema

**Authoring source.** An app authors a TypeScript **const schema
object** (JSON-Schema-shaped) in a `.ts` file. The field type is
derived (`typeof` / a small helper), not a parallel hand-written
type. This is ADR 0010 D4 for v1 without a TypeScript-compiler
generator. Rejected: `ts-json-schema-generator` (heavy, and the
first consumer's truth is already a const object).

**Generator ownership.** `mjolnir-log` exports `generateSchema`
(and a derived-type helper). Apps supply only the const object.
Closed-world enforcement and envelope merge live in the library
once. Act may ship that as an export plus a thin app script or
as a `mjolnir-log generate --check` bin; the library owns the
logic either way. Each app writing its own merge is a second
checker.

**Envelope.** `mjolnir-log` exports the pino envelope fragment
`createLogger` actually stamps (`packages/log/src/index.ts` sets
`name` and `base: { schema, app }`; pino adds `level` / `time` /
`msg`; pino's default serializer emits `err` on `log.error(err)`):

- required: `level` (number), `time` (string), `schema` (string),
  `app` (string), `name` (string)
- optional: `msg` (string), `err` (`type: object`)
- generated schema always `additionalProperties: false`
- an app key that collides with an envelope key fails generate

Generated schema = envelope ∪ app fields. Apps never hand-list
pino keys. Myscape's current `types.ts` hand-lists five envelope
keys and omits `name`; the rewrite is bead `mjolnir-4o4s`
(`add-myscape-log-generate`; `mjolnir-asmx` stays closed).

**`$id`.** One const is both the object's `$id` and the value
passed to `createLogger({ schema })`. Generate copies `$id`; it
does not take a second flag.

**Drift gate.** Library-owned `generate --check` (or
`assertSchemaMatches`) fails when the committed `schema.json`
differs from generated output. A generate step that only writes
is the hand copy with a script.

Unknown fields stay on the wire and are diagnostics, matching
`validateRecord`.

## Decision 3 — v1 language core stays `validateRecord`

Do not replace `packages/log/src/schema.ts`. The LSP maps
`ValidationIssue[]` onto LSP diagnostics. Nested objects can
grow the validator in the same change that grows the generate
subset; do not invent a second type checker
(`vscode-json-languageservice` would disagree the first time
one supports a construct the other does not).

**Closed world.** Generate fails on any construct outside what
`validateRecord` checks. The checkable subset today is root-level
`$id`, `type` ∈ {`string`, `number`, `boolean`, `object`},
`properties`, `required`, `additionalProperties`. Nested
`properties` fail generate until `validateRecord` recurses.
`enum`, `items`, `$ref`, `anyOf` / `oneOf` / `allOf`, and
`type: array` (until the validator grows) fail the bun step.
`validateRecord` treats an unknown `type` as an issue, not a
pass (`schema.ts:35` currently returns `true` for anything else;
act flips that with a test).
