# add-log-lsp

> **ACTIVE BUILD**

Activated 2026-09-10. Bead `mjolnir-vzo6`. Architecture for a
schema-driven language server on typed-log. Code is `act` after
advise accept.

**Rigor:** architecture

## Why

ADR 0010 D4 says pretty and LSP share JSON Schema generated from
app TypeScript types. `validateRecord` shipped in `mjolnir-log`.
Myscape already has a hand-copied `schema.json`. There is no
editor protocol, and no bun generate step, so diagnostics and
tokens cannot stay honest with the type file.

## What

- MODIFIED `typed-log`: bun generate step (app TS types → JSON
  Schema) is the schema source; LSP consumes that schema.
- ADDED: stdio language server `mjolnir-log-lsp` in `packages/log`
  (`vscode-languageserver`). Diagnostics on JSON records (unknown
  field, type mismatch, missing required). Schema id / `$id` on
  the record selects the schema. Unknown fields kept and flagged.
- VS Code `.vsix` is a later thin client, not this change.

## Impact

- Capabilities: MODIFIED `typed-log`
- ADRs: none (0010 D4 already). Pointer from design.md.

## User journey & surfaces

Editor (neovim / zed / VS Code via generic LSP). Developer opens a
JSON log record or generated `schema.json`.

- **Working (after later act)** — unknown field and type mismatch
  are diagnostics; hover/tokens from schema types.
- **Empty** — no `mjolnir-log-lsp` binary; myscape `schema.json` is
  hand-duplicated from `types.ts`.
- **Failed (today)** — `validateRecord` only at runtime in tests /
  pretty; editors see untyped JSON.
- **Off** — Duke parks. ADR 0010 D4 is amended in place.

## Out of scope

- VS Code marketplace `.vsix` — later thin client
- Myscape type file (closed `mjolnir-asmx`)
- Pretty rewrite / syslog / EventBus
- TS call-site completions on `log.info({ ... })` as the only
  product (allowed later; v1 is JSON-record diagnostics)
