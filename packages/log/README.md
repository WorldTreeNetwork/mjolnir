# mjolnir-log

MIT. Bun for dev/build/runtime. Published on npm.

Pino logger that writes:

- **stdout** (default) — color pretty on a TTY, ASCII / JSON when `NO_COLOR`, `--plain`, or non-TTY
- **syslog** — RFC 3164 UDP when `syslog: { host, port }` is set; MSG is the pino JSON line (no ANSI)

Every record includes `schema` (from the originating app's type file / generated JSON Schema id).

```ts
import { createLogger } from "mjolnir-log";

const log = createLogger({
  name: "myscape",
  schema: "myscape/v1",
  syslog: { host: "127.0.0.1", port: 5514 },
});
log.info({ url: "/worlds/xela.glb" }, "probe ok");
```

Unset `syslog` → stdout only. Syslog send failure does not throw on the log call (UDP).
