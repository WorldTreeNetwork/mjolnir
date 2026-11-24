# Reflect wire fixtures

Source: WorldTreeNetwork/homoiconic commit
`793b583824a5de384bcb36cc4d111348d5a9f5f0`, `examples/factorial.hom`
and `examples/forever.hom`. The source files here are verbatim Git blobs.

Generated on morphie using that image build's `unikernel/out-net/reply`:

```sh
reply source factorial-793b583.hom > factorial-793b583.wire
reply run 100000000 factorial-793b583.wire > factorial-793b583.reply
reply source forever-793b583.hom > forever-793b583.wire
reply run 5000 forever-793b583.wire > forever-793b583.reply
```

Send the **.wire** files, not the textual .hom source. Expected replies are
the unmodified stdout of the reference Lean evaluator. Factorial is 30!
(value reply, 20 bytes); forever is the budget outcome (`81 01`, 2 bytes).
Mjolnir transports these bytes without decoding Lean values.

Hardware runner: `scripts/acceptance/unikernel.exs`. It uses the production
VM, networking, Cloud Hypervisor, HTTP operator socket, CLI and MCP handler,
with separate state, TAP and scope namespaces. It starts only the required
supervisors, avoiding production cleanup, reconciliation and sidecars.
The kernel and Zig 0.16 compiler must already exist on morphie. The kernel
must be a `reflect-net.elf` built at homoiconic e9a4c86 or later: an older
image has a built-in key and no `reflect: entity` line, and its boot fails
with `entity_name_mismatch`. The runner makes its entity keys per run under
`$REFLECT_TEST_ROOT/keys` (0600) and never prints them; Mjolnir's own client
key is `$REFLECT_TEST_ROOT/state/reflect-client.key`.

The wire fixtures above were made with the 793b583 `reply` tool. The runner
assumes the e9a4c86 image gives the same replies; if it does not, make the
fixtures again with that build's `reply`.

```sh
zig build-exe native/reflect_quic/host.zig -lc -O ReleaseFast \
  -femit-bin=priv/reflect-quic-client
zig build-exe native/reflect_quic/entity-tool.zig -lc -O ReleaseFast \
  -femit-bin=priv/reflect-entity
cargo build --manifest-path native/Cargo.toml --release -p mjolnir-client
MIX_ENV=prod mix compile
sudo env MIX_ENV=prod \
  REFLECT_TEST_ROOT=/var/tmp/mj-unikernel-acceptance-UNIQUE \
  REFLECT_KERNEL=/path/to/reflect-net.elf \
  MJ_BINARY="$PWD/native/target/release/mjolnir" \
  mix run --no-start scripts/acceptance/unikernel.exs
```

Use a new, empty test root. The runner cleans its own live guests in an
`after` block and retains serial logs/state for inspection. It also tests
the pinned image's fatal memory exhaustion with a large forever run;
that is separate from the ordinary 5000-step budget outcome.
