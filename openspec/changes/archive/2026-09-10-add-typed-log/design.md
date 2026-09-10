# Design — typed log (pino → syslog → EventBus)

Canonical ADR index:
[`docs/decisions/0010-typed-log.md`](../../../docs/decisions/0010-typed-log.md).
This file is the full argument.

**Status:** Proposed. ACTIVE BUILD 2026-09-10.
**Change:** `add-typed-log`
**Epic bead:** `mjolnir-t28i`
**First consumer:** myscape (type file + emit). Host path, not a guest.

Grok authored. Advise reader must not be Grok (ADR-005). Fable 5.1
is the cross-family reader.

## Problem

Five questions after intend + steer:

1. Where does the TypeScript package live, under what license, and
   how is it built and published?
2. What is the wire — pino JSON files, OTLP, or syslog?
3. How does a Mac/host app (myscape) reach Mjolnir when it is not
   inside a VM?
4. How do nodes subscribe without a new broker?
5. How do pretty-print, LSP, and serializers share types the app
   owns?

## Decision 1 — MIT package `mjolnir-log` in `packages/log`, bun in, npm out

The library lives in **identikey/mjolnir** at `packages/log`.
`~/work/WorldTree/mjolnir` is not a checkout. One repo with the
Elixir ingest so the record shape cannot drift.

- **License:** MIT
- **Dev/build/runtime:** bun
- **Publish:** npm (`mjolnir-log` unscoped v1; `@mjolnir/log` only
  if the org already exists at publish time)
- **Engine:** pino. No winston, no custom logger core.

Rejected:

- A standalone npm-only repo for v1 (ingest and types would fork)
- Publishing via bun's registry
- GPL/AGPL on a library meant for myscape and other apps

## Decision 2 — Syslog is the wire; JSON is the MSG

Pino's line is a JSON object. That object is the syslog **MSG**.
v1 wire is **RFC 3164** (the parser we have). RFC 5424 header parse
is not v1. PRI encodes severity. TAG is the originating app
(`myscape`, guest tag as today).

Stdout is the same JSON (or pretty, see D5), default on. Syslog is
attempted when a UDP target is configured; unset target means
stdout only, no error. Failure to send syslog must not crash the
app. Syslog bytes never contain ANSI.

Pino transports under bun: prefer in-process `pino.multistream`
(pretty stream + UDP writer). Do not use `thread-stream` worker
transports as the v1 path.

Rejected:

- OTLP as v1 wire (collector is a new process)
- Dual JSONL files plus syslog (two dialects)
- Replacing guest RFC 3164 text from busybox `logger`

## Decision 3 — Two ingest paths, one Router; JSON `schema` discriminates

Keep **guest** `/dev/log` → vsock channel 2. The guest *forwarder*
is built (`syslog.rs`). The host does **not** yet call
`Listener.register_connection/3`; `:vm_spawned` is unmatched; with
two VMs the Listener drops all data. Wiring ch2 + multi-VM sender
id is **`add-log-ingest`**, not "already built."

**Host ingest is UDP**, not unix datagram. Bun/Node have no AF_UNIX
datagram API. Loopback port on the host; guests send to
`10.200.0.1` (ADR 0005 hotel IP). Target is explicit config;
unset = stdout only.

**Discriminator:** EventBus type is `:app_log` iff the MSG parses
as a JSON object that carries a `schema` field, **regardless of
source**. `source: :guest | :host` is a stamp, not the switch.
Non-JSON guest text stays `:vm_syslog`.

App id on `:app_log` is **self-asserted** (UDP has no peer
credentials). `EventBus.publish/3` still keys a binary id; app
ids share `{:vm, id}` with VM uuids. `:all` subscribers receive
app logs unless ingest uses a distinct `:pg` group — document
that in `add-log-subscribe`.

Max record **64 KiB**. Oversize is routed as malformed raw, never
silently dropped. Guest recv and `:gen_udp` recbuf must match.

`:app_log` default sinks are `[:eventbus]` only (not `:logger`).
Level maps from pino `level`.

Rejected:

- Guest-only (myscape would never show up)
- Unix datagram as the emitter path (not bun-native)
- Phoenix.PubSub or Redis pubsub
- A second BEAM app just for logs
- Folding unimplemented SHALLs into `openspec/specs/typed-log/`
  from this architecture change

## Decision 4 — App-owned TypeScript types → generated JSON Schema

The originating application writes TypeScript types for log events.
A generate step (bun) emits JSON Schema. `mjolnir-log` loads that
schema at runtime for:

- serializers / field allow-list
- pretty color by JSON Schema type and event name
- LSP (`add-log-lsp`) diagnostics and tokens

Schema id / `$id` travels on the record (`schema` field) so a
subscriber can choose a decoder. Unknown fields are kept on the
wire and flagged by pretty/LSP, not dropped.

Rejected:

- Hand-written JSON Schema as source (TS would drift)
- CDDL as source (mjolnir has CDDL elsewhere; TS/LSP glue is
  worse for an app whose source is already TS)
- Hard-coding myscape events inside `mjolnir-log`

## Decision 5 — Color is a sink option, not the wire

Wire is JSON (no ANSI). Pretty is a stdout transport:

- TTY + no `NO_COLOR` → color by parsed types
- `--plain`, `NO_COLOR`, or non-TTY → ASCII
- Syslog MSG never contains escape codes

## Built vs remaining

Built: guest **forwarder** (`native/mjolnir_guest_agent/src/syslog.rs`
→ vsock ch2); RFC 3164 parser; Router → EventBus `:vm_syslog` +
Logger; `:pg` EventBus.

Not built: host registration of the Listener as ch2 handler;
multi-VM sender identification; host UDP socket; JSON-`schema`
discriminator; `mjolnir-log` package.

Remaining implement: emit / ingest (includes ch2 wire-up) /
subscribe / lsp / myscape type file. This change folds the ADR
only (learning 2026-08-16).
