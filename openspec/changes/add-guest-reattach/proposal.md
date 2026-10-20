# add-guest-reattach

> **PENDING**

Bead `mjolnir-uepi.2`. Depends on `mjolnir-uepi.1` (closed: port close does not kill either VMM). Blocks `mjolnir-uepi.3` and `mjolnir-uepi.4`.

**Rigor:** architecture

## Why

An Elixir restart reboots every guest. The Erlang port close does not do that killing. `KillMode=control-group` and `Cleanup.sweep` do.

## What

ADR 0014. Guests run in `mjolnir-vms.slice`. Detach, adopt, and `:attach` are specified there. This change does not implement spawn or adopt. Those are `mjolnir-uepi.3` and `mjolnir-uepi.4`, and they stay blocked until this decision is accepted.

## Impact

- Capabilities: VM lifetime, Cleanup, Reconcile
- ADRs: 0014

## User journey

Operator restarts the Elixir service. A guest that was running is still running, same id, uptime unchanged. A guest whose VMM had already died cold-boots. `mj kill` still destroys that guest.

## Out of scope

Implementation of the scope spawn and the adopt classifier. Memory-snapshot thaw. Raising resume concurrency. A guest-agent deploy that does not reboot.
