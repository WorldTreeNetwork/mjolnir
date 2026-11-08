---
spike_id: aie-npu-path
hypothesis_id: aie-npu-path
source_synthesis: null
run_at: 2026-11-07T22:00:00Z
time_spent_min: 25
verdict: go
version-pinned: Framework5070 Arch, amdxdna in-tree 7.2.11, XRT 2.21.75, NPU Krackan 1 firmware 1.1.2.64, IRON Lab just hello vector-add, Cloud Hypervisor guest ubuntu-24.04
---

# Spike: host XDNA NPU can serve a guest without VFIO via overlay RPC

## Claim Tested

Host XDNA NPU can serve a Cloud Hypervisor guest without VFIO via overlay RPC on `10.200.0.1`.

## Minimal Test

On Framework5070, `amdxdna` owns `/dev/accel/accel0` (IOMMU group 26 is only `0000:c3:00.1`). `ironlab doctor` passes. Host `just hello` (IRON vector-add) returns `NPU vector add: PASS`. A throwaway Python HTTP sidecar bound `10.200.0.1:7422`, held the accel fd, and on `POST /hello` ran that same vector-add. Spawned Mjolnir guest `Awrn8teovvzhNoRQDg3JLr` (`ubuntu-24.04`, `10.199.131.206`). Guest `curl` health and `POST /hello`. Guest `ls /dev/accel` fails. Guest deleted after capture.

`xrt-smi validate -r latency` failed with `No archive found` (stock XRT test archives are not installed). That is not this claim.

## Evidence

- `evidence.log` — host hello PASS, sidecar health, guest health JSON, guest hello JSON (`ok: true`, `match: true`, `dt_ms: 716`), guest has no `/dev/accel`
- `evidence.code` — `sidecar.py`
- `repro-command.sh` — spawn, curl, delete
- Host hello stdout also at `/tmp/aie-hello.log` during the run

Guest hello result (trimmed): `NPU vector add: PASS`, `Got: [10 11 12 13 14 15 16 17 18 19]`, `Match: True`.

## Verdict: go

The NPU stays on the host KMD. A guest on the TAP overlay reached a process on `dummy-mjolnir` and completed a real AIE kernel (IRON `npu2` vector-add, bit-exact). The guest had no accel or DRM device node. Sidecar-on-`10.200.0.1` is a viable path for `add-aie-host-sidecar`. VFIO was not required. Occupancy/locking (IRON Lab flock) and guild auth were not part of this spike.
