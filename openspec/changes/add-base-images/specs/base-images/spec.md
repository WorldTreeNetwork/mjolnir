## ADDED Requirements

### Requirement: @base is a declared catalog of OS roots

`@base/` SHALL contain OS-root templates (kernel-compatible
userspace, guest agent, networking hook). A name in `@base/` is
**declared** when it has a recipe in this repository and appears in
the catalog v1 list. `@snapshots/` SHALL hold frozen machines
(human-named snapshots and `deploy-*` content-addressed layers).
A snapshot SHALL be spawnable and SHALL NOT be a catalog entry.
Adding a declared name SHALL amend ADR 0009.

Catalog v1 declared names: `ubuntu-24.04`, `ci-ubuntu-24.04`,
`buzz-agent`, `arch`. `ubuntu-24.04` SHALL be the default for both
`mj spawn` and `mj deploy`. `arch` SHALL NOT be a default.

An `@base/` subvolume that is not declared SHALL be **unmanaged**.
The system SHALL NOT delete unmanaged subvolumes automatically.

#### Scenario: Spawn default

- GIVEN no `--base` and no `--snapshot`
- WHEN `mj spawn` runs
- THEN the VM is cloned from `@base/ubuntu-24.04`

#### Scenario: Deploy default

- GIVEN an app with no `base_image` in `mjolnir.toml` and no
  `--base` on `mj deploy`
- WHEN the orchestrator spawns the build VM
- THEN `base_image` is `ubuntu-24.04`
- AND it is not `deploy-node-bun`

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

### Requirement: Toolchains are not OS roots

A language runtime (Node, bun, Python, Rust, …) SHALL NOT be a
declared `@base/` image. Deploy SHALL install runtimes with `mise`
as a cache-keyed layer on `ubuntu-24.04` (or another declared
catalog name the app pins). Humans MAY snapshot a golden toolchain
into `@snapshots/`. A change that adds `scripts/build-deploy-<lang>.sh`
or a `@base/deploy-<lang>` image SHALL be rejected against this
requirement.

`@base/deploy-node-bun` SHALL NOT be a catalog name. Recipes SHALL
NOT produce it.

#### Scenario: Node deploy uses ubuntu plus mise

- GIVEN a SvelteKit app whose plan starts with `mise install`
- WHEN `mj deploy` runs with no base override
- THEN the build VM is cloned from `@base/ubuntu-24.04`
- AND `mise install` is a layer keyed on the runtime spec
- AND a second deploy of the same runtime spec is a cache hit on
  that layer

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

### Requirement: Flavors are independent recipes sharing helpers

`ubuntu-24.04`, `ci-ubuntu-24.04`, and `buzz-agent` SHALL be built
by separate debootstrap recipes. They SHALL share
`scripts/lib/guest-agent.sh`, `scripts/lib/mise.sh`, and
`scripts/lib/terminfo.sh`. A FROM-ubuntu flavor DSL SHALL NOT be
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
