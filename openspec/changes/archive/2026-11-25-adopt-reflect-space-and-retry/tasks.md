# Tasks

- [x] Vendor homoiconic `unikernel/quic.zig` at `3122521`, unmodified; check `entity.zig`, `entity-tool.zig` and `host.zig` against it; NOTICE names the commit (`mjolnir-qwo5`).
- [x] Spawn `space` (HTTP, `mj spawn --space`, both MCP), `invalid_space`, `:unikernel_space_max`, fifth word `reflect.space=`, persisted and rendered (`mjolnir-1tvc`).
- [x] Message `outcome` on HTTP and the Elixir MCP, passed by the Rust MCP; `mj message` names a non-value outcome on stderr (`mjolnir-1tvc`).
- [x] Space fixture from homoiconic `3122521` (`deep`, reply `81 07`), and `forever`/`factorial` checked against that build's `reply`.
- [x] Deploy builds both Zig helpers before `mix release`; ignored by Git; one build script (`mjolnir-0wm4`).
- [x] A detach in the middle of a unikernel boot removes the key file; `entity_key` leaves `body_params` at parse time.
- [x] Readiness judges only complete serial lines (a name cut off mid-write failed a boot on morphie).
- [x] Morphie acceptance against a fresh image from homoiconic `origin/main`, with the space, flood/Retry, stall and self-exit checks; image hash and transcript in `evidence/`.
- [x] `mix test` green on the Mac and on morphie.

## Evidence

- [Morphie run](evidence/2026-11-25-morphie-3122521.md), image from homoiconic `3122521` (`reflect-net.elf` sha256 `1edd8f2a…b2cc`), with the [transcript](evidence/2026-11-25-morphie-3122521-transcript.txt): exit 0, 70 PASS.
- `mix test` on morphie (Linux): 1976 passed, 0 failed, 79 excluded. On the Mac: 1973 passed, 0 failed, 82 excluded.
