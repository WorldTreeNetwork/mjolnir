---
spike_id: proxy-data-dir
hypothesis_id: proxy-data-dir
source_synthesis: null
run_at: 2026-11-04T23:58:04Z
time_spent_min: 25
verdict: go
version-pinned: identikey-api-proxy local release binary on ubuntu-24.04 virtio-fs guest
---

# Spike: drop-in data dir and host-API allow

## Claim Tested

A systemd drop-in can point the stock unit's `--data-dir` at the real DynamicUser state directory and add `IPAddressAllow=10.200.0.1/32`, so the unit stays active, listens on `127.0.0.1`, connects to `10.200.0.1`, and does not connect to `1.1.1.1`.

## Minimal Test

Spawned one ubuntu-24.04 guest on the local operator socket (`9TUCQ3Tec59PiWR33KmHWq`, restart_policy never, 1024 MiB). Copied the stock unit, the local release binary, and `examples/registry.json` into that guest. Added only `identikey-api-proxy.service.d/data-dir.conf`. Started the stock unit. From a process moved into the unit cgroup, opened `127.0.0.1:8787`, `10.200.0.1:4000`, and `1.1.1.1:443`. Root in the same guest ran the same three connects as the control. No production host. The pre-existing local VM was left running. The throwaway guest was deleted after the evidence was captured.

## Evidence

The unit reached `active` / `running` with `NRestarts=0`, `Result=success`, and `ExecMainStatus=0`. `ss` showed `127.0.0.1:8787` owned by `identikey-api-proxy`. The log line was `identikey-api-proxy: alive; egress locked`, and the proxy's own sockets were `127.0.0.1` only.

`/var/lib/identikey-api-proxy` stayed a symlink to `private/identikey-api-proxy` (mode 777). `/var/lib/private/identikey-api-proxy` was a real directory, mode 700, owned by the dynamic user. `systemctl cat` showed the drop-in appended after the stock unit: `ExecStart` and `WorkingDirectory` point at that private directory, and `IPAddressAllow=10.200.0.1/32` sits beside the stock `IPAddressAllow=localhost` and `IPAddressDeny=any`.

Root connects: `127.0.0.1:8787` OK, `10.200.0.1:4000` OK, `1.1.1.1:443` OK. The same three from the service cgroup: loopback OK, `10.200.0.1:4000` OK, `1.1.1.1:443` FAIL.

Two observations are outside this claim. Before any route edit, `ip route` was `default dev eth0` and `resolv.conf` named `8.8.8.8` and `1.1.1.1`. The guest-agent endpoint on `GET /api/vms/:id` included a relay URL and a public address. The proxy unit did not. After a manual `ip route del default`, an added `10.200.0.1/32 dev eth0`, and a resolver of `127.0.0.1`, both root and the unit still opened `10.200.0.1:4000`, and root's connect to `1.1.1.1:443` failed. The health monitor then logged `guest_network={:dead, :no_default_route}` and an L1 heal on four ticks about 30 seconds apart. `GuestNetwork` is level 2, and that automatic heal uses `max_level: 1`, so this path does not call `reconfigure_network`. The `/32` route, the spike resolver, and the active unit were still in place after those ticks. No `Guest network configured` line appeared in that window.

## Verdict: go

The drop-in is enough for this binary to stay up on the virtio-fs root and to enforce localhost plus `10.200.0.1/32`. The journal opened the real mode-0700 directory that DynamicUser creates under `/var/lib/private`. The stock symlink was still there and was not the data directory. The address policy is the unit cgroup: root in the same guest still opened `1.1.1.1`, and the service cgroup did not.

This go does not install a proxy guest class. The image still boots with a default route, public resolvers, and a shell relay on the guest agent. Removing those was a manual edit in this guest, and the monitor's L1 loop left that edit in place. `Journal::open` and a Mjolnir-authored unit were not tested.
