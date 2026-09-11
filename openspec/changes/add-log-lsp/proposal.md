# add-log-lsp

> **ACTIVE BUILD**

Activated 2026-09-10. Bead `mjolnir-vzo6`. Architecture for a
schema-driven language server on typed-log. Code is `act` after
advise accept.

**Rigor:** architecture

## Why

ADR 0010 D4 says pretty and LSP share JSON Schema generated from
app TypeScript types. `validateRecord` shipped in `mjolnir-log`.
Myscape already has a hand-copied `schema.json` that omits pino
`name`, so every emitted record fails validation today. There is
no editor protocol, and no bun generate step, so diagnostics
cannot stay honest with the type file.

## What

- MODIFIED `typed-log`: `mjolnir-log` owns `generateSchema`
  (app const ∪ envelope → JSON Schema); closed-world, root-only
  properties; envelope required/optional/`err`/collision;
  `--check` drift gate; LSP consumes that schema.
- ADDED: stdio language server `mjolnir-log-lsp` in `packages/log`
  (`vscode-languageserver` optionalDependency). Diagnostics on
  NDJSON records (unknown field, type mismatch, missing required,
  unknown `$id`). Schema id / `$id` on the record selects the
  schema. Unknown fields kept and flagged.
- VS Code `.vsix` is a later thin client, not this change.

## Impact

- Capabilities: MODIFIED `typed-log`
- ADRs: none (0010 D4 already). Pointer from design.md.

## User journey & surfaces

Editor (neovim / zed / VS Code via generic LSP). Developer opens a
JSON log record or generated `schema.json`.

- **Working (after later act)** — unknown field, type mismatch,
  missing required, and unknown `$id` are diagnostics on NDJSON.
- **Empty** — no `mjolnir-log-lsp` binary; myscape `schema.json` is
  hand-duplicated from `types.ts`.
- **Failed (today)** — `validateRecord` only at runtime in tests /
  pretty; editors see untyped JSON.
- **Off** — Duke parks. ADR 0010 D4 is amended in place.

## Out of scope

- VS Code marketplace `.vsix` — later thin client
- Myscape type file rewrite — `mjolnir-4o4s`
  (`add-myscape-log-generate`); `mjolnir-asmx` stays closed
- Pretty rewrite / syslog / EventBus
- TS call-site completions on `log.info({ ... })` as the only
  product (allowed later; v1 is JSON-record diagnostics)
