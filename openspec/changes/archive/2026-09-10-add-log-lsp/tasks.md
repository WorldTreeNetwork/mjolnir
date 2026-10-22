# Tasks

Architecture artifacts for `add-log-lsp`. Package/binary are later
act after advise accept. Grok authored; advise reader must not be
Grok (ADR-005).

- [x] Write `design.md` (D1–D3)
- [x] Delta `specs/typed-log/spec.md` (generate + LSP)
- [x] Advise accept from a non-Grok reader (Fable 5.1) —
      `reviews/2026-09-10-readvise2.md`
- [x] After accept: pointer in `docs/decisions/0010-typed-log.md` if
      D4 needs a one-line LSP pin

Handoffs (not checkboxes):

- bun generate + `mjolnir-log-lsp` binary — done this act
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
- [x] Re-advise on route `fable-5.1-arch-review` — done 2026-09-10,
      send-back; see `reviews/2026-09-10-readvise.md`

Owed (re-advise 2026-09-10, fable-5.1-arch-review, send-back —
see `reviews/2026-09-10-readvise.md`; F1–F4 closed):

- [x] D2: generator ownership — `mjolnir-log` exports `generateSchema`
      (or a `generate --check` bin) and the derived-type helper; apps
      supply only the const object; closed-world enforcement lives in
      the library once (F5)
- [x] D2 + scenario "Generate from types": envelope fragment contract —
      required = `level, time, schema, app, name`; `msg` optional;
      `err` optional `type: object` (pino default serializer emits it
      on `log.error(err)`); generated schema always
      `additionalProperties: false`; an app key that collides with an
      envelope key fails generate (F6)
- [x] D3: closed-world subset is root-level `properties` only; nested
      `properties` fail generate until `validateRecord` recurses
      (F7 architecture)
- [x] Act: flip `schema.ts:35` unknown-type to an issue, with a test
      (F7 shipped-code; after advise accept)
- [x] D1: NDJSON line with no `schema` key → no diagnostic (living
      spec `:app_log` iff `schema`); open tracker `mjolnir-4o4s`
      (`add-myscape-log-generate`; `mjolnir-asmx` stays closed) (F8)
- [x] Re-advise on route `fable-5.1-arch-review` — accept
      `reviews/2026-09-10-readvise2.md`

Act notes from that accept (not architecture owed):

- `--check` compares canonical bytes or parsed-equal
- duplicate `$id` → one "ambiguous schema id" diagnostic
- app `additionalProperties` ignored or must be false
- app `required` naming a missing or envelope key fails generate
- README: bun on PATH; `log.child` keys are app fields; nested
  shapes flatten until the validator recurses
- `validateRecord` does not compare `rec.schema` to `$id`; LSP
  selection owns that for v1
