# Tasks

- [ ] Vendor homoiconic `unikernel/quic.zig` at `3122521`, unmodified; check `entity.zig`, `entity-tool.zig` and `host.zig` against it; NOTICE names the commit (`mjolnir-qwo5`).
- [ ] Spawn `space` (HTTP, `mj spawn --space`, both MCP), `invalid_space`, `:unikernel_space_max`, fifth word `reflect.space=`, persisted and rendered (`mjolnir-1tvc`).
- [ ] Message `outcome` on HTTP and the Elixir MCP, passed by the Rust MCP; `mj message` names a non-value outcome on stderr (`mjolnir-1tvc`).
- [ ] Space fixture from homoiconic `3122521` (`deep`, reply `81 07`), and `forever`/`factorial` checked against that build's `reply`.
- [ ] Deploy builds both Zig helpers before `mix release`; ignored by Git; one build script (`mjolnir-0wm4`).
- [ ] A detach in the middle of a unikernel boot removes the key file; `entity_key` leaves `body_params` at parse time.
- [ ] Morphie acceptance against a fresh image from homoiconic `origin/main`, with the space, flood/Retry, stall and self-exit checks; image hash and transcript in `evidence/`.
- [ ] `mix test` green on the Mac and on morphie.
