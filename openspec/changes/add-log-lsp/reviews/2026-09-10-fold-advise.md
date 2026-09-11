# add-log-lsp — fold advise (before archive)

> **ADVISE:** accept
> **READER:** opus-5-fold-reader
> **SPAWN:** /Users/dukejones/work/IdentiKey/mjolnir/.spawns/add-log-lsp-1789102171-31724-2a32f120

Reader on the **fold**, not the design. Question answered here: what
may enter `openspec/specs/typed-log/spec.md` as a SHALL that is true
in code at `e9d732e`, and what must be refused.

## Blind take (written before design.md / tasks.md)

Sources: `proposal.md` Why/What, living `openspec/specs/typed-log/spec.md`,
ADR 0010, and the landed code — `generate.ts`, `schema.ts`, `lsp.ts`,
`lsp-deps.ts`, `index.ts`, `bin/mjolnir-log.ts`, `bin/mjolnir-log-lsp.ts`,
`package.json`.

1. **Refuse to keep the living spec's current direction of generation.**
   The standing requirement says the app provides *TypeScript types* and a
   generate step emits JSON Schema. Code is the inverse: `generateSchema`
   eats an app **const** shaped like JSON Schema, and `LogFromSchema` derives
   the TS type from that const. Fold must MODIFY that requirement, not only
   append. Leaving it is the LEARNINGS 2026-08-16 failure in reverse — a
   living SHALL no code implements.
2. **Pin — the envelope is library-owned and closed.** `PINO_ENVELOPE` is
   the sole source; required is `level, time, schema, app, name`; `msg` and
   `err` optional. An app const that names an envelope key is a hard error,
   in `properties` and in `required` both. This is the defect from Why
   (Myscape's hand-copied schema omitting `name`) and it is now structural.
3. **Pin — the closed-world subset, by its refusals.** Root keys limited to
   `$id/type/properties/required/additionalProperties`; property keys limited
   to `type`; `enum/items/$ref/anyOf/oneOf/allOf`, nesting, and `array`
   rejected; types are `string|number|boolean|object`; output is always
   `additionalProperties: false`. Spec the refusals, not the allow-list alone.
4. **Pin — `validateRecord` treats an unknown declared type as an issue.**
   Hand-written schemas bypass generate, so the checker must not trust them.
5. **Pin — the drift gate is canonical-or-parsed-equal.** `--check` passes on
   byte-identical canonical JSON or on parse-then-canonicalize equality, so a
   formatter pass does not fail CI. `--check` without `--out` is a usage error.
6. **Pin — LSP schema selection.** The record's `schema` string is matched
   against a schema's `$id`. No match is a diagnostic on the `schema` field;
   two files claiming one `$id` is an `ambiguous schema id` diagnostic, never
   a silent first-wins. Registry is `**/*schema.json` minus `node_modules`/`.git`.
7. **Pin — what the server stays silent about.** Only `.jsonl`/`.ndjson`, and
   `.log` whose first non-empty line opens `{`. A line that is not JSON, or a
   JSON object with no `schema` field, yields no diagnostic. Silence on noise
   is a contract, not an oversight; say so or someone "fixes" it.
8. **Pin — the LSP never loads inside the logger.** `index.ts` exports no LSP
   symbol; the LSP deps are dynamically imported only by the bin, which exits
   1 with an install line when they are absent. Testable, and the reason the
   npm package stays light.
9. **Refuse to import** the `.vsix` client, completions/hover of any kind
   (only diagnostics exist), a severity taxonomy (everything is Warning), and
   any Myscape claim — `mjolnir-4o4s` is still open and Myscape's schema is
   still hand-written, so "every emitted record fails validation today" is
   **still true after this change**. The fold must not imply otherwise.
10. **Tradeoff to name once, in the spec.** Root-only + no arrays buys a tiny
    validator and an honest drift gate; the price is that any real payload
    (`err`, a request, a list) degrades to `type: object`, which the checker
    cannot see into. Apps will flatten or go opaque. That is the unlock the
    next change buys, and it belongs in the living text so it is chosen, not
    rediscovered.

## Comparison with design.md / tasks.md / delta spec

**Short form: accept.** Every SHALL in the delta is backed by code at
`e9d732e`. `bun test` in `packages/log` is 35 pass / 0 fail. The refusal
list is correctly scoped: no `.vsix`, no completions or hover, no Myscape
claim. The change is foldable as written.

Take items 2–5 and 8 are already the delta's text, and my item 1 — the
inversion from "app supplies TypeScript types" to "app supplies a const,
the type is derived" — is the amend the author made after F3/F5. Design
D2 names the rejection (`ts-json-schema-generator`, heavy, and the first
consumer's truth is already a const). I withdraw it as a concern; it
survives only as the reason the fold cannot be additive.

### Fold obligations the delta does not cover

1. **The living Purpose paragraph is now wrong twice, and a delta cannot
   reach it.** It says the schema is "generated from TypeScript types"
   (inverted, per above) and that "Pretty/LSP share" it. `pretty.ts`
   imports neither `validateRecord` nor any schema; it renders parsed
   pino fields. Only the LSP consumes the schema. Fold must rewrite that
   sentence, or the living spec ships a false claim in its first screen
   while every Requirement under it is true.
2. **Two built behaviours live only in the act notes.** Duplicate `$id`
   across schema files yields one `ambiguous schema id` diagnostic rather
   than a silent first-wins (`lsp.ts`), and a line that does not parse as
   JSON yields no diagnostic at all (`diagnosticsForLine`). Both are
   load-bearing — the first is the reason glob order cannot change which
   schema validates a record, the second is the reason a log file full of
   non-JSON noise is usable. A folder importing only the delta drops them.
   One sentence each on the language-server Requirement.
3. **One SHALL is an obligation, not a check.** "`$id` … SHALL be the same
   const passed to `createLogger({ schema })`" is enforced nowhere in the
   library; `validateRecord` never compares `rec.schema` to `$id`. The LSP
   surfaces a violation as `no schema for <id>` at selection time, which is
   adequate for v1 and is the layer design D2 assigns. Keep the SHALL, but
   the fold should not let it read as a generate-time guard.

### Standing after the fold

`mjolnir-4o4s` is still open and Myscape's `schema.json` is still
hand-written, so the defect the Why opens with — every emitted record
failing validation on the missing `name` — is **not** fixed by this
change. It is now fixable in one step. Fold text must not imply it is done.

### LEARNINGS

One line is warranted, and it is not about the LSP: ADR 0010 said TS types
generate the schema; what shipped derives the type from a const, and pretty
never consumed the schema at all. A living Purpose line survived two folds
asserting both. Worth the dated line.

### Tradeoff, restated for the record

Root-only properties with no arrays and no nesting is what makes the drift
gate honest and the checker small. The price is that `err`, a request, or
any list degrades to `type: object`, which the validator cannot see into.
The README carries the flattening advice. One line in the living spec would
make it a chosen bound rather than a discovered one.
