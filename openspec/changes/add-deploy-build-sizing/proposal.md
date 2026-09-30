# add-deploy-build-sizing

> **PENDING**

Second of four build-caching changes. Independent of
`add-deploy-step-inputs`; can land in either order.

## Why

Every build VM gets `:deploy_build_memory_mb` (default 2048) and the host
`:default_vcpus` (2), whatever it builds. `Orchestrator.build_opts/3`
already records that too little memory kills the build VM's agent and
surfaces only as `{:vsock_unavailable, …}`. On 2026-09-29 identikey's
`cargo build --release` (thin LTO, `codegen-units = 1`) ran 14.5 h in
2 GB and ended that way. A retry at 8 GB (set through `rpc`
`Application.put_env`, the only per-deploy knob today) then wedged with
idle vCPUs and a silent serial console. So memory is not the whole story;
that wedge is tracked separately (see Out of scope). Sizing is still
owed: the two numbers are host-global, 2 vCPUs starve `rustc`, and a
per-app value should not need an `rpc`.

## What

- `mjolnir.toml` gains `build = { vcpus, memory_mb }`, used only for the
  build VM. The service VM keeps `--memory` / the manifest's own value.
- Defaults move from constants to host config with saner values:
  `deploy_build_vcpus` (default 4) and `deploy_build_memory_mb` (default
  4096), clamped to a host ceiling (`deploy_build_max_*`).
- A build VM that loses its agent mid-step reports "build VM stopped
  responding; it had N MB. Raise `build.memory_mb`." instead of a bare
  `vsock_unavailable`.

## Impact

- Capabilities: ADDED requirement in `deploy-build` (capability added by `add-deploy-step-inputs`;
  if this lands first, it creates `deploy-build`)
- Modules: `Deploy.Manifest`, `Deploy.Orchestrator.build_opts/3`,
  `Deploy.Diagnostics`
- ADRs: none

## User journey & surfaces

The operator adds `build = { memory_mb = 8192 }` to `mjolnir.toml` and
runs `mj deploy`.

- Working: progress prints `build VM: 4 vCPU, 8192 MB` before the first
  step.
- Empty: no `build` table uses the host defaults, printed the same way.
- Failed: a request above the ceiling is clamped, and progress says so
  (`memory_mb 65536 → 16384 (host max)`). A VM that dies mid-step names
  its size and the key to raise.
- Off: not applicable.

## Out of scope

- Queuing or admission control across concurrent builds (host
  overcommit): not tracked yet; bead to open if contention shows up.
- Sizing service VMs: unchanged.
- Build VMs that wedge mid-`cargo build` (vCPUs asleep, agent silent, no
  kernel message, rootfs on virtiofs): seen 2026-09-29/30 on
  `5ePZwwNnYGhzhPFUofYccf` and `XkRsavU8xaFYcRnu2qQEBy`. Tracked in
  `mjolnir-mne7`; the idle-VM step watchdog belongs there, not here.
