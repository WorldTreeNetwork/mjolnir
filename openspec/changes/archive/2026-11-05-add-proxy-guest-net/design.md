# add-proxy-guest-net

## Preparation

Outcome: revised. The goal of a confined proxy guest still stands. The recipe "boot the unmodified stock unit" does not.

Authority: explicit activation of `mjolnir-86g6.2` on 2026-11-04. This is not a grant for any other bead. Bounds: steered reachability, and the no-go finding. No api-proxy edit unless a later choice says so. No production host.

Anchors: `scripts/build-rootfs-ubuntu-24.04.sh` writes `mjolnir-network-setup`, which adds `${IP}/32` on `eth0`, `default dev eth0`, and nameservers `8.8.8.8` and `1.1.1.1`. `Mjolnir.Health.GuestNetwork.probe/1` treats a missing default route as dead and probes `http://1.1.1.1/`. `native/mjolnir_guest_agent/src/iroh.rs` builds the shell endpoint with `presets::N0` and waits in `endpoint.online()`.

## What the spike settled

`docs/spikes/proxy-unit-in-guest/finding.md` (verdict no-go, 2026-11-04):

- The stock unit's `DynamicUser` `StateDirectory` is a symlink. `Journal::open` rejects it and the process exits before bind.
- A real mode-0700 directory lets the same binary listen on `127.0.0.1:8787`.
- A transient unit with `IPAddressDeny=any` and `IPAddressAllow=localhost` can open loopback and cannot open `10.200.0.1:4000` or `1.1.1.1:443`.
- The image still installs a default route. The guest agent, a different process, still publishes a relay.

## Decided reachability

The proxy class has no default route and no public resolver. It may route to `10.200.0.1/32`. The proxy process may use loopback and that host address, and no other destination. Ordinary guests keep the setup script, the public probe, and the shell relay.

The stock allowlist is only localhost, so a process confined by that allowlist cannot reach the host API. Widening it is part of the repair, not a second product goal.

## Mechanism

The class bit is `base_image`, not `enable_iroh`. A proxy image contains the proxy `mjolnir-network-setup` and the data-dir drop-in. Spawn of that image sets `enable_iroh` false and refuses `enable_iroh` true. An ordinary image with `enable_iroh` false keeps the stock script, the default route, and the public resolvers, and publishes no relay.

The guest agent runs `/usr/local/bin/mjolnir-network-setup` on boot and again when a level-2 heal repairs `guest_network`. The proxy script adds the guest address, deletes the default route, installs `10.200.0.1/32` on `eth0`, and writes `nameserver 127.0.0.1`. `build_running_record/1` stores `base_image` and `enable_iroh`. `resume_opts/1` reads them back. A stored false stays false. A missing flag stays the ordinary default, true. The supported resume for this node is `Mjolnir.VM.reboot/1`, which resumes that stored record. Snapshot restore and dormant restore are outside this node.

Proxy `GuestNetwork` is ok only when the pin is intact and TCP to `10.200.0.1` port 4000 succeeds. Missing host route, a default route, or a public resolver is not ok, so the level-2 heal runs the proxy script instead of being skipped. No connect tool is degraded, not ok. The monitor's automatic heal stays level 1.

## Unverified hypotheses

- proxy-data-dir. The drop-in keeps the unit up on loopback and `10.200.0.1/32`. Confidence high. Verification empirically tested. Artifact `docs/spikes/proxy-data-dir/finding.md`. — go
- guest-class. Boot has no default route, no public resolver, and no shell relay, and a level-2 heal leaves that pin. Confidence high. Verification empirically tested. Artifact `docs/spikes/proxy-guest-class/finding.md`. — go
- journal-symlink. Changing `Journal::open` is not the landing. — skipped
- authored-unit. A Mjolnir-authored unit is not the landing. — skipped
