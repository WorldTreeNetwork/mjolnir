---
spike_id: proxy-guest-class
hypothesis_id: guest-class
source_synthesis: null
run_at: 2026-11-05T00:45:40Z
time_spent_min: 30
verdict: go
version-pinned: ubuntu-24.04 base plus guest-local mjolnir-network-setup, spawn enable_iroh false, identikey-api-proxy local release binary
---

# Spike: proxy guest class at boot

## Claim Tested

A proxy-class guest boots with no default route, no public resolver, and no shell relay. The proxy drop-in stays active, listens on `127.0.0.1`, opens `10.200.0.1`, and does not open `1.1.1.1`. An L2 heal runs network setup again and leaves that pin in place. The ordinary `ubuntu-24.04` base keeps its default route.

## Minimal Test

Copied `@base/ubuntu-24.04` to a throwaway base, `proxy-guest-class-spike`, and edited only that copy. Its `mjolnir-network-setup` deletes the default route, installs `10.200.0.1/32` on `eth0`, and writes `nameserver 127.0.0.1`. The same copy carried the stock unit, the data-dir drop-in, and the proxy binary, enabled for multi-user. Spawned that base through the local operator socket with `enable_iroh` false. Observed the route, resolver, listener, and connects from the unit cgroup. Posted `/heal` with `max_level` 2 and observed again. The original base script still contained `ip route add default`. The pre-existing local VM was left running. The throwaway guest and the throwaway base were deleted after the evidence was captured.

## Evidence

Boot of `44vHonfMKSUUTG6NposQ66` (guest `10.219.106.50`) logged `Guest network configured` and `Iroh disabled`. The spawn body had no ticket and no iroh address. `ip route` was `10.200.0.1 dev eth0 scope link`. `resolv.conf` was `nameserver 127.0.0.1`. The unit was active and listening on `127.0.0.1:8787`.

Root and the service cgroup both opened `127.0.0.1:8787` and `10.200.0.1:4000`. Both failed `1.1.1.1:443`.

`POST /heal` with `max_level` 2 reported `guest_network` dead, reason `no_default_route`, action `healed`, and logged `Guest network configured` again. After that heal the route was still only `10.200.0.1/32`, the resolver was still `127.0.0.1`, the unit was still active, and the same four connect results held. `iroh_connection` was skipped as ok.

`@base/ubuntu-24.04/usr/local/bin/mjolnir-network-setup` still had `ip route add default dev eth0`.

An earlier guest, `5RYkLgdZeizg2mvRVTLUUV`, showed why the script has to be in place before configure. With the stock script, heal reported `guest_network` ok and skipped it, so the default route stayed. After the proxy script was written and run, the same L2 heal re-ran that script and the default route stayed gone.

## Verdict: go

The class is the guest's `mjolnir-network-setup` plus `enable_iroh: false`, with the data-dir drop-in from `proxy-data-dir`. Boot and the L2 heal both execute that script through the guest agent. They do not hard-code the default route in the host. `enable_iroh: false` never starts the shell endpoint, so this guest publishes no relay. Ordinary guests stay on the stock script and the default `enable_iroh` true.

`GuestNetwork` still treats a missing default route as dead. The monitor's automatic heal is level 1, so it does not re-run network setup. A level-2 heal does, and with this script that reapplies the pin. A landing still has to teach that probe about this class, or every proxy guest stays a standing `no_default_route` warning.
