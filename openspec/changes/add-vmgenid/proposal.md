# add-vmgenid

> **ACTIVE BUILD**

Bead `mjolnir-3y6.13`. Campaign grant on `mjolnir-3y6` (2026-10-23, "activate all" of the pinned ready-set).

## Why

A memory snapshot restores the guest CRNG along with RAM. Two restores of one image draw the same `/dev/urandom` stream until something reseeds it. `Mjolnir.Entropy.reseed` runs after `vm.resume`, so the first `getrandom` can win the race. VM Generation ID is the kernel mechanism: the hypervisor changes a 128-bit id on restore, and Linux 5.18+ `vmgenid` calls `add_vmfork_randomness()` before userspace is supposed to run.

## What

- Guest x86_64 PVH kernel built with `CONFIG_VMGENID=y`. The disposable proof cold-boots that kernel, freezes, and thaws before the fleet boot kernel is replaced. The host kernel file is not what a saved image runs.
- Host Cloud Hypervisor is a build that always exposes the VM Generation ID device (upstream v54.0, no config knob). `45.76.77.97` already runs that binary.
- A snapshot records whether its captured kernel has `CONFIG_VMGENID`. A recorded capture must show a guest-visible generation-id change or it is not published. A missing record (every image taken before this kernel) still thaws under `Entropy.reseed` and does not claim that change. The image stays on disk either way.
- `Entropy.reseed` still gates vsock reachability. It covers userspace generators and the notify race. It is not evidence that the VM Generation ID driver ran. The driver does not reset userspace PRNGs.
- A second thaw while the first guest is running starts another guest: new VM id, vsock CID, virtiofsd socket, and TAP name, over a clone of the pinned rootfs. Guest IP, MAC, and Iroh key stay as captured. That second guest is reachable over vsock after reseed and is not given a gateway ticket. The first guest stays published. A failed second thaw leaves the first guest running.

## Impact

- Capabilities: MODIFIED `Thaw restores the same VM id`; ADDED VM Generation ID on `vm-freeze`
- ADRs: none

## User journey & surfaces

No new UI because thaw is still `mj thaw` / `POST /api/snapshots/:name/thaw`. The first thaw of a parked VM brings that same id back. A second thaw while that guest is running returns another VM on the same call. The operator sees kernel CRNG state and a second guest, not a new screen.

## Out of scope

- Replacing `Entropy.reseed` (it stays the userspace and race backstop).
- VMClock (clock disruption is the folded `add-thaw-clock` requirement).
- Patching Cloud Hypervisor. v54.0 already has the device.
- AArch64 `acpi=on`. This fleet is x86_64.
- Replacing `/var/lib/mjolnir/vmlinux-ch` before a disposable thaw of a snapshot captured on the candidate kernel shows a new generation id.
- A second public address (guest IP, MAC, or Iroh key) for the forked guest. That copied identity stays in RAM. Tracked beside `mjolnir-8m3`.
- Reopening the folded clock, Iroh, and storage requirements.

## Preparation

Outcome: revised. Upstream deps `mjolnir-3y6.15` and `mjolnir-3y6.1` are closed. CH v54.0 (2026-10-14) ships the device; the 2026-10-19 proof was v53.0 with zero VMGenID strings. Living spec `openspec/specs/vm-freeze/spec.md` at `62b43e5` has no generation-id requirement. Authority: pinned epic grant, this node only. Fresh advise is owed before act.

Re-check 2026-10-23 (`change all` on the pinned ready-set): still valid at that moment. Living spec at `4e7db53` had no generation-id requirement. `45.76.77.97` runs `cloud-hypervisor v54.0`; the binary contains `VmGenId` and `VM_Gen_Counter`. `/var/lib/mjolnir/vmlinux-ch` on that host has no vmgenid strings. This laptop's binary is still v53.0.

Steer 2026-10-23, then `/run`: revised. The human allowed a second running guest from one memory image (new VM id, vsock CID, virtiofsd socket over a pinned-rootfs clone). `Entropy.reseed` stays before publish. Proof is a disposable thaw on the v54 server before the fleet kernel is replaced. Living requirement "Thaw restores the same VM id" is MODIFIED because it refused a live source id.

Send-back `reviews/2026-10-23-advise.md` amended the same day. Legacy images stay thawable and do not claim a generation-id change. A `CONFIG_VMGENID` capture must show a guest-visible id or it is not published. `/dev/urandom` after `Entropy.reseed` is not that evidence, and the driver does not reset userspace PRNGs. The second guest is vsock-reachable only and is not gateway-published while IP, MAC, and Iroh key are the captured values. The first guest survives a failed fork. Fresh advise is owed on this text. Banner stays ACTIVE BUILD.

Accept `reviews/2026-10-23-advise-2.md` (READER `astra-arch-review`, 2026-10-23). Outcome: still valid. Spec delta SHA-256 `349b1a0fda4f409f725af48d74f356c2f7c226a6938440ba23e17325d20c8429` is the text that reader accepted. Living `openspec/specs/vm-freeze/spec.md` is unchanged on HEAD `73e33d9`. Authority: campaign grant on `mjolnir-3y6`, this node only. Banner stays ACTIVE BUILD. The second guest stays vsock-only while IP, MAC, and Iroh key stay the captured values. Host-proof and disposable-thaw boxes stay open until that thaw exists. This note does not amend the delta.
