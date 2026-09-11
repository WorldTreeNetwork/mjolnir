# Tasks

Architecture artifacts for `add-log-lsp`. Package/binary are later
act after advise accept. Grok authored; advise reader must not be
Grok (ADR-005).

- [x] Write `design.md` (D1–D3)
- [x] Delta `specs/typed-log/spec.md` (generate + LSP)
- [ ] Advise accept from a non-Grok reader (Fable 5.1)
- [ ] After accept: pointer in `docs/decisions/0010-typed-log.md` if
      D4 needs a one-line LSP pin

Handoffs (not checkboxes):

- bun generate + `mjolnir-log-lsp` binary — act after accept
- VS Code `.vsix` — later
- Myscape generate wiring — first consumer already has types
- **Fold:** MODIFIED "generate step" and ADDED "SHALL ship a
  stdio LSP" fold only after the bin and generate exist
  (F4, LEARNINGS 2026-08-16). Do not import unimplemented SHALLs.

Owed (advise 2026-09-10, fable-5.1-arch-review, send-back —
see `reviews/2026-09-10-advise.md`):

- [x] D2: pin envelope ownership — `mjolnir-log` exports the pino
      envelope fragment (`level, time, schema, app, name, msg`);
      generated schema = envelope ∪ app fields; apps never hand-list
      pino keys (F1; Myscape fails on `name` today)
- [x] D3: pin the closed world — generate step fails on any construct
      outside what `validateRecord` checks; unknown `type` is an
      issue, not a pass (F2)
- [x] D2: name the authoring source (TS type via a TS→schema tool, or
      const object with derived type) and the drift gate
      (`bun generate --check` fails on diff) (F3) — **picked const
      object with derived type**
- [x] tasks/folder note: MODIFIED "generate step" and ADDED "SHALL
      ship a stdio LSP" fold only after the bin and generate exist
      (F4, LEARNINGS 2026-08-16)
- [x] D1: state document model (NDJSON vs `.json`), `path`→range
      parser, schema discovery, and where LSP deps live
- [ ] Re-advise on route `fable-5.1-arch-review`
