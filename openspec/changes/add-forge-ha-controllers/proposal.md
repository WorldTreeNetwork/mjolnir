# add-forge-ha-controllers

> **PENDING**

Bead `mjolnir-6fn.1` (parent `mjolnir-6fn`). Depends on `mjolnir-8uo` (closed).

**Rigor:** architecture. Group: human-gate. Not activated. No campaign grant.

**Preparation (2026-10-15 /run):** the parent was opened 2026-05-12 and never updated. Its only dependency, the Host worker, is closed. Nothing in the tree starts a second controller, libcluster, or Phoenix.PubSub for Forge. The acceptance says "within N seconds" and does not set N. The steer menu was declined earlier in this run. The forks below stay open. Do not treat this draft as permission to build a cluster.

## Why

One Mjolnir node is a single Forge controller. The parent asks for a survivor to resume Host workers after that node dies. That is a split-brain problem, and the bound is unset.

## What

This draft records the gap. It does not choose a topology. There is no spec delta: a SHALL written now would become living law at fold, and the contract is not decided.

Open forks:

- Whether a second controller is in scope at all.
- The failover bound N.
- How a survivor claims a Host worker without a second apply.

## Impact

- Capabilities: none until those forks are decided. No living `forge` behavior is added here.
- ADRs: none yet. An activation that chooses a cluster would amend `ARCHITECTURE.md` and needs advise before act.

## User journey & surfaces

No new UI because no operator surface can address a second controller today. `mj forge plan` still talks to the one API.

## Out of scope

- Implementing libcluster, Phoenix.PubSub, or a second BEAM.
- SSH to a second host (`add-forge-ssh-transport`).
- The Forge web UI (`mjolnir-vqa`).
- Applying resources. `auto_apply` stays false.
