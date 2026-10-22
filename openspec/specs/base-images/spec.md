# base-images

What is built. Folded from
[`add-base-images`](../../changes/archive/2026-09-10-add-base-images/proposal.md)
on 2026-09-10. Decisions live in
[`docs/decisions/0009-base-image-catalog.md`](../../../docs/decisions/0009-base-image-catalog.md).

Fold-now SHALLs only (tasks.md fold table). Unimplemented SHALLs
wait on later changes and are **not** living truth:
`remove-deploy-node-bun` (deploy default, Node deploy uses
ubuntu+mise, recipes SHALL NOT produce `deploy-node-bun`),
`add-base-image-list` (listing surfaces),
`add-base-image-pins` (pins immutable; aliases move),
`add-base-image-health` (doctor + noisy inject).

## Purpose

`@base/` is a declared catalog of OS roots. `mj spawn` defaults to
`ubuntu-24.04`. Declared recipes bake a guest agent so a clone
boots without inject. Live declared images on the host match
current recipes (v0 in-place rebuild). Toolchains are not OS
roots. Flavors are independent bootstrap recipes sharing helpers.

## Requirements

### Requirement: @base is a declared catalog of OS roots

`@base/` SHALL contain OS-root templates (kernel-compatible
userspace, guest agent, networking hook). A name in `@base/` is
**declared** when it has a recipe in this repository and appears in
the catalog v1 list. A pin produced by a declared alias's recipe
is declared (archived), not unmanaged. Unmanaged is a name with no
recipe in this repository. `@snapshots/` SHALL hold frozen machines
(human-named snapshots and `deploy-*` content-addressed layers).
A snapshot SHALL be spawnable and SHALL NOT be a catalog entry.
Adding a declared name SHALL amend ADR 0009.

Catalog v1 declared names: `ubuntu-24.04`, `ci-ubuntu-24.04`,
`buzz-agent`, `arch`. `ubuntu-24.04` SHALL be the default for
`mj spawn`. `arch` SHALL NOT be a default.

An `@base/` subvolume that is not declared SHALL be **unmanaged**.
The system SHALL NOT delete unmanaged subvolumes automatically.

#### Scenario: Spawn default

- GIVEN no `--base` and no `--snapshot`
- WHEN `mj spawn` runs
- THEN the VM is cloned from `@base/ubuntu-24.04`

#### Scenario: Snapshot is not a catalog entry

- GIVEN a named snapshot `node-env` under `@snapshots/`
- WHEN an operator lists the base-image catalog
- THEN `node-env` is absent
- AND `mj spawn --snapshot node-env` still works

#### Scenario: Undeclared subvolume

- GIVEN `@base/tatastu-agent` exists on the host and has no recipe
  in this repository
- WHEN the catalog is listed
- THEN it is reported unmanaged
- AND it is not deleted

#### Scenario: Pin is declared, not unmanaged

- GIVEN alias `ubuntu-24.04` has a recipe in this repository
- AND pin `ubuntu-24.04-20260827` was produced by that recipe
- WHEN the catalog is listed
- THEN the pin is declared (archived)
- AND it is not reported unmanaged
- AND it is not a catalog alias operators pick as a default

### Requirement: Toolchains are not OS roots

A language runtime (Node, bun, Python, Rust, …) SHALL NOT be a
declared `@base/` image. Humans MAY snapshot a golden toolchain
into `@snapshots/`. A change that adds `scripts/build-deploy-<lang>.sh`
or a `@base/deploy-<lang>` image SHALL be rejected against this
requirement.

`@base/deploy-node-bun` SHALL NOT be a catalog name.

#### Scenario: New toolchain image proposed

- GIVEN a change that adds `@base/deploy-python` or rebuilds
  `@base/deploy-node-bun` as the deploy default
- WHEN it is reviewed
- THEN it is rejected against this requirement

### Requirement: Catalog image boots without inject

A declared image's recipe SHALL install `/usr/local/bin/mjolnir-agent`,
`/etc/systemd/system/mjolnir-agent.service`, and a
`basic.target.wants` symlink, then fail the build if any are
missing (unless `ALLOW_NO_AGENT=1`). `inject_guest_agent` SHALL be
a refresh of the binary in a clone when `:guest_agent_bin` names an
existing path. A clone of a declared image SHALL answer the vsock
ping when inject is a no-op.

#### Scenario: Fresh image, inject path missing

- GIVEN a newly built `@base/ubuntu-24.04` from the current recipe
- AND `:guest_agent_bin` is unset or the path does not exist
- WHEN a VM is spawned from that image
- THEN `/usr/local/bin/mjolnir-agent` exists in the clone
- AND the guest agent answers vsock within the boot timeout

#### Scenario: Recipe omits the unit

- GIVEN a recipe run that writes the binary but not
  `mjolnir-agent.service`
- WHEN the recipe finishes
- THEN it exits non-zero
- AND the subvolume is not a successful catalog image

### Requirement: Declared live images match current recipes

A declared alias on a host SHALL point at the output of that
name's current recipe, including a current guest agent. **v0**
(single tenant): the alias subvolume MAY be replaced in place
after snapshotting the previous tree to
`@snapshots/<name>-pre-rebuild-<date>`. After an in-place alias
rebuild the operator SHALL delete every `@snapshots/deploy-*`
layer via `mj snapshot rm` / `DELETE /api/snapshots/:name`
(sidecar `.json` included). Layer metadata records no parent, so
the chain under the rebuilt alias is not separable; a surviving
name fails the next re-snapshot with `{:snapshot_exists, _}`.
Raw `btrfs subvolume delete` SHALL NOT be the path (it leaves
the sidecar the planner lists from). D6 (`add-base-image-pins`)
removes this step. `deploy-node-bun` SHALL NOT be rebuilt.
Unmanaged names SHALL NOT be rebuilt by this requirement. Running
`@vms/<uuid>` clones SHALL NOT be destroyed by a base rebuild.

#### Scenario: Stale ubuntu is rebuilt

- GIVEN `@base/ubuntu-24.04` last built on 2026-06-23
- AND the current recipe and `mjolnir-agent` are newer
- WHEN the operator rebuilds `ubuntu-24.04`
- THEN `@snapshots/ubuntu-24.04-pre-rebuild-<date>` exists
- AND `@base/ubuntu-24.04` contains the current agent
- AND a spawn from that image answers vsock without inject
- AND every `@snapshots/deploy-*` layer is deleted via
  `mj snapshot rm` / `DELETE /api/snapshots/:name`

#### Scenario: Retired image is not rebuilt

- GIVEN `@base/deploy-node-bun` exists
- WHEN declared images are rebuilt
- THEN `deploy-node-bun` is not passed to a recipe
- AND it remains until `remove-deploy-node-bun` deletes it

### Requirement: Flavors are independent recipes sharing helpers

`ubuntu-24.04`, `ci-ubuntu-24.04`, `buzz-agent`, and `arch` SHALL
be built by separate bootstrap recipes (debootstrap or pacstrap).
They SHALL share `scripts/lib/guest-agent.sh` and
`scripts/lib/terminfo.sh`. Ubuntu-family recipes SHALL also share
`scripts/lib/mise.sh`. A FROM-ubuntu flavor DSL SHALL NOT be
required to add or rebuild a declared image. CI SHALL keep a
non-root runner user and workspace-mount plumbing. Buzz-agent SHALL
keep the harness as the signal-receiving process.

#### Scenario: Rebuild CI does not rebuild ubuntu

- GIVEN `@base/ubuntu-24.04` and `@base/ci-ubuntu-24.04` both exist
- WHEN `just build-ci-image` runs
- THEN `@base/ci-ubuntu-24.04` is replaced
- AND `@base/ubuntu-24.04` is unchanged

#### Scenario: Flavor DSL proposed as catalog v1

- GIVEN a change that requires a FROM-ubuntu DSL to declare CI or
  Buzz
- WHEN it is reviewed
- THEN it is rejected against this requirement
