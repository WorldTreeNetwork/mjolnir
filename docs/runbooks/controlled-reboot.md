# Controlled host shutdown and reboot

`scripts/controlled_reboot.py` packages the controlled production reboot procedure:
review an inventory, pause writers, back up databases, stop their dependencies,
sync guests, take read-only BTRFS snapshots, verify an off-host archive, request
the host action, and compare actual recovery with the original baseline.

It runs on a Linux/macOS operator machine with Python 3.11+ and BatchMode SSH to
root on an Ubuntu systemd/GRUB/BTRFS Mjolnir host. Python 3.11+ is also required on
the host. The helper is sent over SSH, so no control-plane deployment or pip
installation is needed. Guests need systemctl, timeout, mountpoint, awk and sh.
The root-only `/run/mjolnir/operator.sock` is required; there is no TCP bypass.

## Configure and plan

Copy the template to a private, ignored directory and edit it for the actual
workloads. **The example is not a production inventory.** Replace the kernel,
app selector, manual-unit patterns and health URLs before use.

```sh
mkdir -p .mjolnir-maintenance
chmod 700 .mjolnir-maintenance
cp scripts/maintenance.example.json .mjolnir-maintenance/config.json
chmod 600 .mjolnir-maintenance/config.json

python3 scripts/controlled_reboot.py plan mjolnir \
  --config .mjolnir-maintenance/config.json \
  --run-dir .mjolnir-maintenance/run-001
```

Plan does not stop/start services, execute backup/probe hooks, create snapshots or
acquire a maintenance lease. It reads host/GRUB/SSH and VM state and runs fixed
guest inspection commands. It refuses active CI-tagged guests because the exec API
would renew their leases. Drain CI separately. Read the saved private `run.json`:
it freezes the target, machine/boot identity, VM roots/policies, guest boots,
services, configuration and HTTP baseline. Do not edit the frozen file; make a
new plan after any configuration or inventory change.

Registry app names identify their service units. Add manual services/jobs to
`application_units`; put PostgreSQL/Redis/MinIO or other storage services in
`dependency_units`. Unknown active units stop planning. Protected system, SSH and
guest-agent units can never be selected for stop. Applications must be enabled
at boot. Dependencies must be enabled too; Debian PostgreSQL instances may instead
prove activation through an enabled umbrella plus persistent `start.conf=auto`.
An existing manually started/transient job without that startup contract needs a
separate operator plan. The script never changes enablement or VM restart policy.

## Backups and probes are explicit coverage

`backup_hooks` are **trusted operator argv arrays**. Host hooks have no VM selector;
guest hooks use one `app` registry name or `vm` ID. Hook output is suppressed.
Hooks are privileged operator code, not a sandbox: review them as backup-only
operations. Never hide host power, VM lifecycle, database initialization or restore
commands inside a hook/probe; the tool's dispatch guards cannot constrain arbitrary
code deliberately supplied by the operator.
Do not put passwords/tokens in argv; use existing protected credentials/peer auth.
The tool creates a private per-hook directory and substitutes `{run_dir}` or
`{guest_run_dir}` with that path. Every declared export must be a nonempty regular
file freshly written by that hook, with a basename-only filename. Hook paths never
come from shell-expanded tenant input. Hook failure refuses the host action.

The archive includes those exports, host configuration/state/escrow and configured
`guest_backup_paths` taken from the read-only snapshots. Defaults include guest
configuration, encrypted secrets, known data directories and `/app/data`.
Configure additional persistent databases/data paths for your apps. Logical dumps
can use `gzip -t` or another explicit check inside their hook. This tool verifies
fresh files, archive readability and matching SHA-256 bytes outside the host; it
does not prove restorability, discover every database, or create complete off-site
VM-image backups. Complete VM-root snapshots remain on the BTRFS data volume.

`readiness_probes` are trusted, **read-only** argv commands with mandatory zero
exit status and optional `stdout_pattern`. They run under execution authority
before preparation and during recovery, not during plan. Default phase is
`dependencies`; `applications` probes run after writers are restored. Include
actual database readiness, not only a frontend root returning static HTML.
Do not log secret values from these commands; normal tool output never echoes
their stdout/stderr. Only gateway/runner admission services may be paused on the
host; the controller, SSH and host database sidecars stay available for preparation.

`http_urls` are explicit public read probes. Unreachable/unknown configured URLs
refuse planning/recovery. A healthy baseline must remain healthy; a known 401/404
or other non-success response is retained explicitly and may improve, but cannot
silently become a different failure. Choose useful health paths, rather than
assuming every API root should return 200.

## Execute

Preparation causes production downtime. Review the plan, backups, recovery-console
access and maintenance window first. Each mutating entry point requires the flag.

```sh
# Optional separate preparation: pauses writers and dependencies, snapshots and
# copies/verifies backup.tar.gz into the private LOCAL run directory.
python3 scripts/controlled_reboot.py prepare mjolnir \
  --run-dir .mjolnir-maintenance/run-001 --execute

# Also prepares automatically when called directly from a valid plan.
python3 scripts/controlled_reboot.py reboot mjolnir \
  --run-dir .mjolnir-maintenance/run-001 --execute --timeout 900

# Same safeguards, normal systemctl poweroff. Provider power-on stays external.
python3 scripts/controlled_reboot.py shutdown mjolnir \
  --run-dir .mjolnir-maintenance/run-001 --execute
```

The local run directory must be outside the target host, private and have enough
space for the configured compressed-backup budget plus reserve. `max_backup_bytes`
bounds the remote archive and copy; `max_logical_bytes` bounds sparse/decompressed
data and is divided among declared export files as a per-file write limit. Host
preflight reserves space for logical exports plus the compressed archive; the
data volume also needs logical-export headroom. Hooks remain trusted code and must
not create unbounded undeclared scratch files. Guest shell block limits may be
more conservative than the configured file allowance. Over-budget backups fail
instead of rebooting or filling the operator disk.
Root snapshots are retained; there is no automatic snapshot deletion/retention job.

The remote journal and exclusive lease live under
`/var/lib/mjolnir/ops/maintenance/<run-id>/`. A host operation lock covers the full
mutating request, including same-run clients. Stop intent is written before each
stop and completion only after it is proven inactive. Service activation timestamps
detect reactivation even when a timer/socket starts and stops a writer again.
The VM set, roots, policy, guest boots, quiescence, boot target, backup receipt and
lease are rechecked before power. No destructive VM lifecycle API is used.
The local off-host archive is also rehashed immediately before dispatch; deleting
or changing it after preparation refuses power and attempts owned-stop recovery.

## Disconnects, failures and recovery

```sh
python3 scripts/controlled_reboot.py status mjolnir --run-dir .mjolnir-maintenance/run-001

# Before any host power request: invalidate readiness and restore only owned stops.
python3 scripts/controlled_reboot.py resume mjolnir \
  --run-dir .mjolnir-maintenance/run-001 --execute

# After reboot, or after manually powering on a shutdown host:
python3 scripts/controlled_reboot.py verify mjolnir \
  --run-dir .mjolnir-maintenance/run-001 --timeout 900
```

A preparation error attempts dependency-first restoration automatically. An
uncertain inactive stop is never claimed as owned: inspect it and reconcile it
manually. If it is already active, no start is needed. Partial restoration stays a
failure and retains the journal/lease. Resume is bound to the original host AND
guest boot identities. It cannot replay stops onto newly booted guests. A resumed
run is terminal; use a fresh plan, snapshots and exports before trying again.

SSH/client loss does not erase the remote journal. A still-running remote operation
keeps its host lock; another client must wait, not steal the lease. Do not start a
second operator workflow against the same host. Once power intent is durable,
missing acknowledgement is ambiguous: the script never sends another automatic
reboot/poweroff. Rerunning `reboot` on that journal only verifies. Poweroff with
unknown acknowledgement exits nonzero. Inspect status/provider console rather
than editing the journal to force a retry. Ctrl-C cannot recall an accepted power
request. Recovery failures never initialize an empty database, replace a VM or
force another reboot.
Keep the same tool checkout while a run is in progress; do not edit its frozen
configuration or baseline to bypass a refusal.

The lease serializes this tool, not arbitrary administrator or application activity.
Freeze deployments and unmanaged/manual writers separately. The script detects
changed running-unit sets and activation timestamps; it is not a process freezer
or a checkpoint mechanism for arbitrary shell jobs. During long preparation the
CLI prints journal progress; `status` can also be run from another terminal.

Verification requires a new host boot, the expected kernel, original VM IDs and
disk identities, new guest boot IDs, preserved known identities, managed-secret
mounts, prior services, no new failures, configured probes and HTTP continuity.
It retains a private `verification.json` and returns nonzero on partial/unknown
results. Existing failures remain explicit. Success releases the owned lease;
recovery evidence/backups stay for operator retention. A full restore drill and
application transaction tests remain separate work.

## Offline verification

```sh
python3 -m unittest discover -s scripts -p test_controlled_reboot.py -v
```

The fixtures inject a fake host/transport and use only temporary local data. They
never SSH, start another Mjolnir instance, stop production services or reboot a
machine. A live `plan` is a useful final check; it is not a live rehearsal of the
mutating phases. Backup configuration must be reviewed for each host.
