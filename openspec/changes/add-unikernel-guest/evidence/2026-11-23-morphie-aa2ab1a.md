# Morphie acceptance on a fresh image, 2026-11-23 (second run)

This run repeats the hardware acceptance in `2026-11-23-morphie.md` on an image
built today from current homoiconic `main`. It also closes the full `mix test`
gate (`mjolnir-tinp`).

## Sources and image

- homoiconic `aa2ab1a76832600481ada28a11622d0c0ebf65b9` (origin/main), exported
  with `git archive` to `morphie:~/hom-aa2ab1a` (the morphie trees are not git
  checkouts; the older `~/hom-793b583` tree was left as it was).
- Built with `sh unikernel/build-net.sh` (Lean 4.35.0, Zig 0.16.0). The build
  ended with `quic self ok`.
- Mjolnir: main `3755123` plus the commit that adds this file, synced with
  rsync to `morphie:~/mj-uk-src`, `MIX_ENV=prod mix compile`. The host QUIC
  client was rebuilt from `native/reflect_quic/host.zig`.

```text
f8fdc41cbe7f01b7711c78ae0d3287026f6eed8d84689d17c6867af172ea1d15  ~/hom-aa2ab1a/unikernel/out-net/reflect-net.elf
72edbd770828ae73e92c6e225d6060123a7d5a6c5086461bc3b20d04de6dcda7  ~/hom-aa2ab1a/unikernel/out-net/source.sha256
ec79751375738f9a495f5d13e3e4929d321c18d6d87225044116f1b0dbad0f29  ~/mj-uk-src/priv/reflect-quic-client
3c04d4668df28dcf0a8d7efbd2355e2be2c30a3743580399af80ec6f2e5737f0  ~/mj-uk-src/native/target/release/mjolnir
cloud-hypervisor v54.0, /dev/kvm present
```

The image sources changed after `793b583`: steps are now priced (`runPriced`).
The `793b583` factorial and forever fixtures still produce the same bytes
(`82008200C24E0D13F6370F96865DF5DD54000000` and `8101`).

## How it was run

Same isolation as the first run: a new state root, the `mju-` TAP and scope
namespace, and an operator Unix socket. The production `mjolnir.service` on
morphie was not stopped, restarted or called.

```sh
sudo -n env MIX_HOME=/home/dorje/.mix HEX_HOME=/home/dorje/.hex MIX_ENV=prod \
  ELIXIR_ERL_OPTIONS=+fnu REFLECT_TEST_ROOT=/var/tmp/mj-uk-20261123-aa2ab1a-b \
  REFLECT_KERNEL=/home/dorje/hom-aa2ab1a/unikernel/out-net/reflect-net.elf \
  MJ_BINARY=/home/dorje/mj-uk-src/native/target/release/mjolnir \
  /usr/bin/mix run --no-start --no-compile --no-deps-check scripts/acceptance/unikernel.exs
```

The runner now prints each `mj` command with its output, and the Cloud
Hypervisor `vm.info` payload, CPU, memory, disk, fs and vsock fields.
Full transcript: [`2026-11-23-morphie-aa2ab1a-full.log`](2026-11-23-morphie-aa2ab1a-full.log)
(also `morphie:/tmp/mj-uk-acceptance-aa2ab1a-b.log`). The run exited 0 with
33 PASS lines. Afterwards there were no `mju-` interfaces and no `mju-*.scope`
units.

## Transcript excerpts

```text
$ mj spawn --kind unikernel --kernel /home/dorje/hom-aa2ab1a/unikernel/out-net/reflect-net.elf --peer-pin c917ae04e69fa83d5d3e34bb1d86be4196d904fe42e03800fbb459ca820d90d1 --owner <owner>
Spawning VM...
VM:           SK8VoKyUPMtxbgUhMSACgz
[exit 0]
GUEST SK8VoKyUPMtxbgUhMSACgz IP 10.238.200.188 TAP mju-SK8VoKyU SCOPE mju-SK8VoKyUPMtxbgUhMSACgz.scope
reflect: ready 10.238.200.188:29932
reflect: quic 39932
PASS persisted kind and never-restart
VMINFO payload {"cmdline":"reflect.ip=10.238.200.188 reflect.port=29932 reflect.quic_port=39932","kernel":"/home/dorje/hom-aa2ab1a/unikernel/out-net/reflect-net.elf"}
VMINFO cpus {"boot_vcpus":1,...,"max_vcpus":1,...} memory {...,"size":536870912,...}
VMINFO disks null fs null vsock null
PASS no rootfs, virtiofs or vsock
PASS kernel is the Reflect ELF and the command line is three reflect.* words
PASS 1 vCPU and 512 MiB
PASS no virtiofsd or agent process for the guest
PASS no rootfs clone for the guest
ROUTE 10.238.200.188 dev mju-SK8VoKyU src 192.168.0.164 uid 0
PASS Mjolnir TAP route
$ mj message --budget 100000000 SK8VoKyUPMtxbgUhMSACgz .../factorial-793b583.wire --owner <owner>
<hex> 82008200C24E0D13F6370F96865DF5DD54000000
[exit 0]
PASS QUIC factorial exact Lean reply 82008200C24E0D13F6370F96865DF5DD54000000
$ mj message --budget 5000 SK8VoKyUPMtxbgUhMSACgz .../forever-793b583.wire --owner <owner>
<hex> 8101
[exit 0]
PASS QUIC budget outcome 8101
PASS guest running after budget
PASS MCP program and budget over QUIC
PASS first caller admitted
PASS second caller refused busy
PASS first caller completes after busy refusal
PASS live reboot refused
PASS persisted resume refused
PASS guest still works after refused restart
PASS wrong peer pin refused
PASS wrong peer stays refused
$ mj kill SK8VoKyUPMtxbgUhMSACgz --owner <owner>
Killed SK8VoKyUPMtxbgUhMSACgz
[exit 0]
PASS kill removed SK8VoKyUPMtxbgUhMSACgz TAP and scope
PASS kill removed 4DKwFA4AK6aeHyNEfuaSQU TAP and scope
PASS guest self-exit records stopped/guest_exit
PASS guest-exit record retains ownership
PASS stopped guest cannot restart
PASS in-flight call ends after guest exit
PASS self-exit removes TAP and scope
ALL UNIKERNEL HARDWARE CHECKS PASSED
```

The cleanup log lines "virtiofsd socket rm" are the shared cleanup removing a
socket path that does not exist; no virtiofsd was started (checked above).
One "registered but its guest is unreachable; rebooting to revive" warning
appears when the runner calls `VM.revive` while the exited guest's process is
still terminating; the reboot it tries is refused (`unikernel_restart_refused`),
which is what the check asserts.

## Full `mix test` gate

The four failures that `2026-11-23-morphie.md` left open, and the flaky ones,
were test defects, not Linux-spawn regressions:

- Policy coverage: `POST /api/relay/rooms/:room/participants/:participant/token`
  is enforced by `Relay.Mint.issue`, which roots the token at
  `t/<caller's owner>/<room>`. The pattern is now registered.
- `getent` (macOS) and `btrfs` (no tool on the dev host): tagged
  `:needs_getent` / `:needs_btrfs`, excluded only where the tool is missing.
- Recording test `rm_rf!` `:eexist`: the test now waits for the restarted
  `Sites.Store` to finish `init/1` before on_exit removes its directory.
- BLAKE3 temp-file and snapshot flakes: four `async: true` modules repointed
  the global `:socket_dir` or `:btrfs_root`; they are now `async: false`.

New unit tests drive the real `Exchange.port/1` path through a stub client:
silence until the client's deadline (exit 4) is `unikernel_timeout` and frees
the guest, and exits 3/5/6 are `peer_key_refused` and transport statuses 2/3.

Result: `TMPDIR=/tmp mix test`, five consecutive full runs on macOS, each
`1943 passed, 81 excluded`, 0 failures. Rust client: 73 + 1 tests passed.
