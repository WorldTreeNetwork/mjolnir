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

`deep-3122521.hom` is the program homoiconic's `unikernel/check-net.sh`
uses for a run that passes its space (`def deep x = [x, ...deep x]`
applied to 0). Its wire and reply were made with the `reply` of homoiconic
`3122521938cc8c953b0915eb0a52740af8a836f3`, which takes the default space
of 4000000 cells:

```sh
reply source deep-3122521.hom > deep-3122521.wire
reply run 100000000 deep-3122521.wire > deep-3122521.reply   # 81 07
```

That build's `reply` gives byte-identical `.wire` files and replies for
factorial and forever (homoiconic `kernel/WireReplyCheck.lean` checks the
same bytes).

Send the **.wire** files, not the textual .hom source. Expected replies are
the unmodified stdout of the reference Lean evaluator. Factorial is 30!
(value reply, 20 bytes, outcome `value`); forever at 5000 is the budget
outcome (`81 01`, outcome `budget`); deep at 100000000 is the space outcome
(`81 07`, outcome `space`). Mjolnir transports these bytes and names only
the envelope's tag; it does not decode Lean values.

Hardware runner: `scripts/acceptance/unikernel.exs`. It uses the production
VM, networking, Cloud Hypervisor, HTTP operator socket, CLI and MCP handler,
with separate state, TAP and scope namespaces. It starts only the required
supervisors, avoiding production cleanup, reconciliation and sidecars.
The kernel and Zig 0.16 compiler must already exist on morphie. The kernel
must be a `reflect-net.elf` built at homoiconic `7efea06` or later (it must
know `reflect.space`); `3122521` or later also answers Retries. The
runner's flood and stall checks need that build's `quic-client` and the
`quic-client-e9a4c86` control (`REFLECT_QUIC_CLIENT`,
`REFLECT_OLD_CLIENT`). The runner makes its entity keys per run under
`$REFLECT_TEST_ROOT/keys` (0600) and never prints them; Mjolnir's own client
key is `$REFLECT_TEST_ROOT/state/reflect-client.key`.

```sh
bash scripts/build-reflect-quic.sh
cargo build --manifest-path native/Cargo.toml --release -p mjolnir-client
MIX_ENV=prod mix compile
sudo env MIX_ENV=prod \
  REFLECT_TEST_ROOT=/var/tmp/mj-unikernel-acceptance-UNIQUE \
  REFLECT_KERNEL=/path/to/reflect-net.elf \
  REFLECT_QUIC_CLIENT=/path/to/out-net/quic-client \
  REFLECT_OLD_CLIENT=/path/to/out-net/quic-client-e9a4c86 \
  MJ_BINARY="$PWD/native/target/release/mjolnir" \
  mix run --no-start scripts/acceptance/unikernel.exs
```

Use a new, empty test root. The runner cleans its own live guests in an
`after` block and retains serial logs/state for inspection. Its self-exit
check raises `:unikernel_space_max` for one guest, spawns it with the space
limit undone (`2^64 - 1`) and sends `deep`, which ends that guest in
`INTERNAL PANIC: out of memory`. With the default space the same program is
the `81 07` reply and the guest goes on.
