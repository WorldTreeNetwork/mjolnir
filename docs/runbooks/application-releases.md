# Application releases

`/opt/mjolnir` is the stable symlink to a complete deployed source/build tree
under `/opt/mjolnir-releases/<revision>-<timestamp>-<pid>`. Systemd and helper
commands continue to use `/opt/mjolnir`. VM roots, databases and credentials
remain in `/var/lib/mjolnir` and `/etc/mjolnir`.

## Deploy

Before restarting a production controller, take fresh protected database/configuration
backups, verify an off-host copy, and retain a tested restore path. On local
development and other non-production hosts, a protected local backup with a
verified restore is sufficient; an off-host destination is optional and must not
block an upgrade. Include durable signing keys in the protected backup and retain
the previous release for rollback in either environment.

A controller restart briefly interrupts its API and tenant PostgreSQL connections; guest
hypervisors stay in independent systemd scopes. Active database transactions
must quiesce before activation, and clients must tolerate reconnecting.

```sh
just host=root@server deploy
# Controller, dependencies and bundled runtime only; leave host sidecars alone:
./scripts/deploy.sh root@server --app-only
# Gateway only; does not restart or modify the controller release:
./scripts/deploy.sh root@server --gateway
# Controller plus gateway:
./scripts/deploy.sh root@server --gateway --full
```

The core Rust workspace is portable across release directories. The optional
LAN-files guest executable has its own workspace/lockfile because it requires
pinned sibling source checkouts; see its README for explicit builds.

Existing `--agent`, `--rootfs`, `--runner`, and `--no-iroh` options remain.
Gateway-only cannot be combined with those options without `--full`.
The deployment syncs the working tree, as before; commit intended changes first.

Every deployment creates a new tree, copying dependency/build caches and installed
helpers without hardlinks. Rsync never writes through the active symlink. The
host's `.mise.toml` pins select the compiler/runtime through `mise exec`. Native
compilation and the Hex advisory/retirement audit finish before controller
activation. Elixir and native builds each run with a two-CPU quota and4GiB memory limit;
native compilation also limits Cargo to one concurrent job. Build and activation
run as separate transient systemd units and
survive SSH disconnection. A disconnected build can finish, but deployment does
not automatically advance from build into activation after its client exits.

Activation is serialized by a host file lock. It checks the current controller,
all hypervisor PIDs, guest boot IDs, agent exec, secret mounts, and PostgreSQL
transactions before switching the symlink with atomic rename. It installs the
canonical unit, restarts the controller, and verifies the same guest identities,
PostgreSQL readiness, release marker, every loaded packaged dependency version,
bundled ERTS, and actual code/release root. IEx is bundled for remote shells and
is allowed to be unloaded. There is no application-only hotload in this procedure.

Optional `/etc/mjolnir/release-checks.json` extends verification to public URLs:

```json
{"urls": ["https://example.com/", "https://api.example.com/api/health"]}
```

Previously responding statuses below500 must remain the same. Baseline timeouts
and5xx responses are recorded as pre-existing failures, not successful probes.
An empty/missing configuration supplies no public endpoint coverage.
Evidence is private under `/var/lib/mjolnir/releases/<activation>/`.

If restart or verification fails, activation restores the old link and unit,
restarts it, verifies its original marker and guest baseline, and exits nonzero.
A failed rollback remains explicitly `rollback_requested` in the journal and
requires operator investigation. Automatic rollback applies to the controller
release/unit, not database contents, gateway, Redis, blob door or base images.
Application data/schema compatibility with the prior release must be reviewed
before deployment. No release or backup is automatically deleted.

Default full deployments apply host sidecar installations after controller
verification; failures there report a failed command with the controller already
updated. `--app-only` provides the isolated controller maintenance path.

## Inspect and roll back

```sh
readlink -f /opt/mjolnir
systemctl show mjolnir -p ExecStart -p DropInPaths
cat /var/lib/mjolnir/releases/<activation>/activation.json
# Same guarded activation procedure for a retained, compatible older release:
systemd-run --wait --pipe --collect --unit=mjolnir-manual-rollback \
  /bin/bash /opt/mjolnir/scripts/cutover-release.sh \
  /opt/mjolnir-releases/<previous-release>
```

The canonical unit has no release-specific override. `UnsetEnvironment=RELEASE_ROOT`
prevents an old environment file selecting a different root; the release launcher
resolves `/opt/mjolnir` to its physical tree. Changing the symlink alone does not
change a running VM or controller.

Legacy directory installations must be migrated explicitly: preserve their full
tree, populate a complete versioned release with all installed native helpers,
replace `/opt/mjolnir` with its symlink, and remove only reviewed release-specific
unit overrides. Standard deployment refuses a directory or dangling symlink
before rsync. Do not bootstrap or rsync an old deployment script over a live
versioned tree. Release directories become read-only by convention after
publication; root can still change them, so use the deploy procedure.

## Validation

```sh
bash scripts/deploy_test.sh -v
python3 -m unittest discover -s scripts -p test_controlled_reboot.py
python3 scripts/test_native_workspace.py -v
shellcheck scripts/deploy.sh scripts/build-release.sh scripts/build-native.sh scripts/cutover-release.sh
```

The deployment tests exercise the actual shell procedure with isolated transport
fixtures, real atomic filesystem switching and locking, build/activation errors,
rollback verification, installed helper preservation, and guest/runtime checks.
They do not emulate a real hypervisor or PostgreSQL server; verify those against
the live baseline during the authorized deployment.
