---
spike_id: proxy-unit-in-guest
hypothesis_id: null
source_synthesis: null
run_at: 2026-11-04T19:28:00Z
time_spent_min: 25
verdict: no-go
version-pinned: identikey-api-proxy 0.1.0 (local release binary, 2026-10-24) on ubuntu-24.04 virtio-fs guest
---

# Spike: stock api-proxy unit inside a Mjolnir VM

## Claim Tested

The locked identikey-api-proxy unit keeps non-loopback closed inside a Mjolnir VM with no default route.

## Minimal Test

Spawned one ubuntu-24.04 guest on the local host through the operator socket, with restart_policy never. Copied the stock unit, the local release binary, and examples/registry.json into that guest's virtio-fs root. Started the unit. Separately started the same binary with a real directory as its data dir, and ran a transient systemd unit that carries the stock IPAddressDeny, IPAddressAllow=localhost, and RestrictAddressFamilies. The guest kept the image's default route. No production host. The pre-existing local VM was left running.

## Evidence

The stock unit reached active and then exited 1. After five restarts it stayed failed. The only log line was `journal storage unavailable`. systemd had made `/var/lib/identikey-api-proxy` a symlink to `private/identikey-api-proxy`. `Journal::open` uses `symlink_metadata` and rejects anything that is not a directory.

The same binary, given a real mode-0700 directory on the virtio-fs root, stayed up until it was killed. It listened on `127.0.0.1:8787` and reported its Iroh sockets as `127.0.0.1` only.

From the guest's unrestricted root, TCP to `10.200.0.1:4000` and to `1.1.1.1:443` both succeeded. `ip route` showed `default dev eth0`. A transient unit with the stock address policy could open `127.0.0.1:8787` and could not open `10.200.0.1:4000` or `1.1.1.1:443`.

The guest agent, which is not the proxy unit, published a relay address and a public IP in its endpoint address. That path was not confined by the proxy unit.

## Verdict: no-go

The stock unit does not stay running in this guest, so it does not enforce the address pin. The failure is the DynamicUser state-directory symlink against `Journal::open`, which runs before the listener. The systemd address policy itself does hold in this VM when a process actually runs under it, and that policy refuses `10.200.0.1` as well as the public internet. The image still installs a default route, and the shell Iroh endpoint still uses a relay.

## Why the Hypothesis Is Wrong

The claim needs the unit to be the process that is confined. This unit exits in `Journal::open` because its StateDirectory is a symlink. Nothing in that process then binds or accepts a connection.

## Recommended Replan

Make the proxy data directory a real directory the journal will open, on storage the journal accepts, and then start the unit again. Widening reach to `10.200.0.1/32` is a second change: the same address policy that blocks the public internet also blocks the host API. The shell relay and the default route are still separate from this unit.
