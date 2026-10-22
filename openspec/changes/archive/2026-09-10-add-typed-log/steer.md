# steer add-typed-log

**When.** 2026-09-10
**Depth.** standard
**Bead.** `mjolnir-t28i`

## Decided

- License: MIT (user)
- Toolchain: bun for dev, build, and native runtime (user)
- Registry: publish on npm; bun is not the publish target (user)
- Package home: `packages/log` in identikey/mjolnir; npm name `mjolnir-log` (decide-for-me / activate all). `~/work/WorldTree/mjolnir` is not on disk.
- Bus: `Mjolnir.EventBus` `:pg`. No Phoenix.PubSub (auto; user said Elixir covers subscribe)
- Sinks: stdout on by default; syslog always; `NO_COLOR` / `--plain` / non-TTY strip ANSI (auto from intend)
- Ingest: host unix datagram for apps (myscape on Mac) **and** keep guest `/dev/log` → vsock ch2 (decide-for-me)
- Type file: TypeScript types in the originating app → generated JSON Schema consumed by pino serializers, pretty, and LSP (decide-for-me)

## Skipped

None. Activate all took remaining recommendations.

## Feeds change

One MIT npm package, developed with bun, lives next to the Elixir syslog ingest. Wire is syslog (JSON in MSG). Host apps and guest VMs both arrive at `Syslog.Router` → EventBus. Pretty/LSP share the app's generated schema. Code landings after advise: emit, ingest, subscribe, lsp, myscape types.
