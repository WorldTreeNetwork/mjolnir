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

Pino's line is a JSON object. That object is the syslog **MSG**
(RFC 5424 preferred; RFC 3164 still parsed for guests). PRI encodes
severity. TAG / APP-NAME is the originating app (`myscape`, `xela`,
guest tag as today).

Stdout is the same JSON (or pretty, see D5), default on. Syslog is
always attempted. Failure to send syslog must not crash the app;
stdout still works.

Rejected:

- OTLP as v1 wire (collector is a new process)
- Dual JSONL files plus syslog (two dialects)
- Replacing guest RFC 3164 text from busybox `logger`

## Decision 3 — Two ingest paths, one Router

Keep **guest** `/dev/log` → vsock channel 2 → `Syslog.Listener`
(already built).

Add **host** unix datagram (or UDP localhost) that the same
`Syslog.Listener`/`Router` family accepts. Apps like myscape on a
Mac write that socket. Router stamps `source: :guest | :host` and
publishes EventBus:

- guests: existing `:vm_syslog` (unchanged payload)
- typed app JSON MSG: `:app_log` with parsed map + schema id

`EventBus.publish/3` already keys on a binary id. Host apps use an
app id string (e.g. `"myscape"`), not a VM uuid.

Rejected:

- Guest-only (myscape would never show up)
- Phoenix.PubSub or Redis pubsub (house style is `:pg`; Phase 4
  cluster `:pg` is the scale path)
- A second BEAM app just for logs

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

Built: guest syslog vsock ch2, RFC 3164 parser, Router → EventBus
`:vm_syslog` + Logger, `:pg` EventBus.

Remaining: advise, then emit / ingest / subscribe / lsp / myscape
type file. Architecture-only SHALLs that are not true of the code
must not fold into living specs until the implementing act lands
(learning 2026-08-16).
