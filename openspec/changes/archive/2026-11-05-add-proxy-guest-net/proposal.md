# add-proxy-guest-net

> **ACTIVE BUILD**

## Why

A proxy guest has to enforce the fixed route, the address pin, and refused relays. The stock `identikey-api-proxy.service` does not do that in a Mjolnir VM: `docs/spikes/proxy-unit-in-guest/finding.md` is no-go.

## What

- Add a proxy guest class that is not an ordinary guest.
- Keep ordinary guests on `mjolnir-network-setup`, the `1.1.1.1` health probe, and the shell Iroh relay.
- On the proxy class, no default route, no public resolver, and no shell relay. The proxy process may use loopback and `10.200.0.1/32`.
- Do not install the unmodified stock unit as that boundary. The process stays up through the data-dir drop-in (`docs/spikes/proxy-data-dir/finding.md`). The class itself is `enable_iroh: false` plus a proxy `mjolnir-network-setup` (`docs/spikes/proxy-guest-class/finding.md`).

Capability: `proxy-guest-net`.

**Rigor:** instrument

## Impact

- Capabilities: ADDED `proxy-guest-net`
- ADRs: none

## User journey & surfaces

No new UI because this is a guest image and a process confinement, not a page.

An operator boots one proxy-class guest on the local host. Working: the proxy process is up, listens on `127.0.0.1`, can open `10.200.0.1`, cannot open a public address, and that guest publishes no relay. Failed: the process exits before bind, or the guest has a default route or a public resolver. An ordinary guest beside it still has its default route.

## Out of scope

- Editing the api-proxy signer, dial, or `POST /v1/execute`. Tracked in api-proxy `add-secret-use-proxy`.
- Replacing synthetic HostFence. HostFence is not this firewall.
- The shell path `mj connect` uses. Ordinary guests keep `presets::N0`.
- The redeem frame. Folded as `update-redeem-tuple`.
- A production boot or a restart of `mjolnir.service`.
