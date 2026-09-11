# mjolnir-log

MIT. Bun for dev/build/runtime. Published on npm. The `mjolnir-log` and
`mjolnir-log-lsp` bins require **bun on PATH**.

Pino logger that writes:

- **stdout** (default) — color pretty on a TTY, ASCII / JSON when `NO_COLOR`, `--plain`, or non-TTY
- **syslog** — RFC 3164 UDP when `syslog: { host, port }` is set; MSG is the pino JSON line (no ANSI)

Every record includes `schema` (from the originating app's type file / generated JSON Schema id).

```ts
import { createLogger, generateSchema, type LogFromSchema } from "mjolnir-log";

export const logSchema = {
  $id: "myscape/v1",
  type: "object",
  properties: {
    url: { type: "string" },
  },
} as const;

export type MyscapeLog = LogFromSchema<typeof logSchema>;

const log = createLogger({
  name: "myscape",
  schema: logSchema.$id,
  syslog: { host: "127.0.0.1", port: 5514 },
});
log.info({ url: "/worlds/xela.glb" }, "probe ok");
```

`generateSchema(logSchema)` merges the library pino envelope (`level`, `time`,
`schema`, `app`, `name`, optional `msg` / `err`) with app fields and always sets
`additionalProperties: false`. Apps do not hand-list envelope keys.

```
mjolnir-log generate --from ./log-schema.ts --export logSchema --out schema.json
mjolnir-log generate --from ./log-schema.ts --export logSchema --out schema.json --check
```

`--check` compares canonical JSON (stable key order, 2-space indent, trailing
newline) or parsed-equal.

v1 properties are **root-level only**. Nested objects flatten into top-level
fields until `validateRecord` recurses. `log.child({ requestId })` bindings are
app fields and belong on the const.

Unset `syslog` → stdout only. Syslog send failure does not throw on the log call (UDP).

`validateRecord(rec, schema)` reports unknown fields as issues; it does not drop them from the JSON.

**LSP.** `mjolnir-log-lsp` is a stdio server (neovim / zed / any LSP client).
`vscode-languageserver` and `jsonc-parser` are optionalDependencies; the logger
entry does not import them. Attach to `.jsonl`, `.ndjson`, and `{`-leading `.log`.

OTP: `Mjolnir.EventBus.subscribe_logs("myscape")` or `subscribe_logs(:all)` for `:app_log` without VM lifecycle noise.
