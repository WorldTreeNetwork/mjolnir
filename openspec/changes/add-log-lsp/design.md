# Design — add-log-lsp

**Status:** Proposed. PENDING until activate.
**Change:** `add-log-lsp`
**Bead:** `mjolnir-vzo6`
**Capability:** `typed-log` (ADR 0010 D4)

Grok authored. Advise reader must not be Grok (ADR-005). Fable 5.1
is the cross-family reader.

## Decision 1 — stdio LSP in `packages/log`

v1 ships a bun bin `mjolnir-log-lsp` using `vscode-languageserver`.
Editors that speak LSP (neovim, zed, VS Code via a later thin
client) attach to JSON records and generated schema files.

Rejected: VS Code extension as the product (locks neovim/zed);
TS-call-site-only intelligence (pretty/syslog still need schema).

## Decision 2 — Schema source is generated JSON Schema

App TypeScript types remain the authoring source. A bun generate
step emits JSON Schema (`$id` = record `schema` field). LSP loads
that schema. Hand-copied `schema.json` (myscape today) is a
consumer bug the generate step closes.

Unknown fields stay on the wire and are diagnostics, matching
`validateRecord`.

## Decision 3 — v1 language core stays `validateRecord`

Do not replace `packages/log/src/schema.ts`. The LSP maps
`ValidationIssue[]` onto LSP diagnostics. Nested objects and
arrays can grow the validator in this change if the schema needs
them; do not invent a second type checker.
