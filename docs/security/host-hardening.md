# Host Hardening

How the Mjolnir control plane is secured at the OS and process level.

> **See also:** `docs/encryption-and-security.md` for the data encryption model,
> `docs/secrets-architecture.md` for LUKS2 secrets injection.

## Process Model

Mjolnir runs as **root** under systemd. This is a deliberate choice — as a
hypervisor-class system that manages VMs, networking, BTRFS subvolumes,
device access, and host configuration (Forge), it requires the same
privileges as Docker, libvirtd, or kubelet. The security boundary is
filesystem and kernel protections, not UID isolation.

## systemd Hardening (`systemd/mjolnir.service`)

The unit applies `ProtectSystem=strict`, which makes the entire filesystem
read-only except for explicit `ReadWritePaths`. This is the single most
impactful protection — even as root, the BEAM cannot write to `/usr`,
`/boot`, `/etc` (outside allowed paths), `/home`, or any other system
directory.

| Directive | Value | Purpose |
|---|---|---|
| `ProtectSystem` | `strict` | Entire FS read-only; only `ReadWritePaths` writable |
| `ReadWritePaths` | `/var/lib/mjolnir /etc/mjolnir /etc/systemd/system /tmp/mjolnir /var/run/mjolnir /var/log/mjolnir` | Scoped write access |
| `ProtectHome` | `yes` | No access to `/home`, `/root`, `/run/user` |
| `ProtectControlGroups` | `yes` | Cannot modify cgroup hierarchy |
| `PrivateTmp` | `no` | UDS sockets in `/tmp/mjolnir` shared with CH/virtiofsd children |
| `PrivateMounts` | `no` | virtiofsd needs host BTRFS mount propagation to guest VMs |
| `NoNewPrivileges` | `no` | Postgres sidecar uses `setpriv --reuid` to drop to `mjolnir_pg` |
| `DeviceAllow` | `/dev/kvm rw`, `/dev/net/tun rw` | Only KVM and TUN devices accessible |
| `KillMode` | `control-group` | Stop kills all children: VMs, virtiofsd, CH processes |

### Why certain protections are off

- **`ProtectKernelTunables=no`**: Health checks run `sysctl net.ipv4.ip_forward=1` at boot.
- **`ProtectKernelModules=no`**: Health checks run `modprobe kvm` and `modprobe vhost_vsock`.
- **`NoNewPrivileges=no`**: The postgres sidecar uses `setpriv` to change UID to `mjolnir_pg`, which requires the ability to gain new privileges.

These could be tightened if the bootstrap script pre-loads modules and sets
sysctls before Mjolnir starts. Filed as future work.

## Forge (Host Config Reconciler)

`Mjolnir.Forge` manages host-side configuration declaratively. Resources
(systemd units, config files) are tracked with a three-way diff:
**declared** (what the code says), **owned** (what Forge last applied),
**observed** (what's actually on disk).

This prevents configuration drift — if someone hand-edits
`/etc/systemd/system/mjolnir.service`, `forge-plan` will show `:drifted`
and `forge-apply` will restore it.

Key properties:
- Forge never auto-applies. All changes require explicit `forge-apply`.
- `:conflict` and `:unmanaged` resources are never auto-resolved.
- State is a JSON ledger per resource at `/var/lib/mjolnir/forge/state/`.
- Sandbox mode (test/dev): systemd units are written but `systemctl` calls are skipped.

## Postgres Sidecar

The OTP-managed Postgres instance runs with defense-in-depth:

- **Process isolation**: Runs as dedicated `mjolnir_pg` system user via `setpriv`.
- **Socket-only access**: `listen_addresses = ''` — no TCP listener, Unix socket only.
- **Peer authentication**: `pg_hba.conf` uses `peer` auth via `pg_ident.conf` mapping. The OS user identity (verified by the kernel) determines the DB role.
- **Role separation**: `mjolnir_admin` (migrations only, used by `Mjolnir.Repo.Admin`) and `mjolnir_sites` (app CRUD, used by `Mjolnir.Repo`). App roles cannot DDL.
- **Derived data only**: Postgres holds indexes derived from the filesystem (SecretStore). It can be rebuilt from disk — it's a cache, not the source of truth.

## API Authentication

The HTTP API runs on `localhost:4000` with no TLS (transport security is
provided by SSH tunneling for remote access).

| Mode | How it works |
|---|---|
| **JWT bearer** | `Authorization: Bearer <token>` verified via `Mjolnir.Auth.Token`. Token `sub` claim maps to `user_id`. |
| **Localhost bypass** | When `MJOLNIR_AUTH_BYPASS_LOCALHOST=true`, requests from `127.0.0.1` skip JWT and get `user_id="localhost"` with full scope. Off by default in prod. |

Scope-based authorization controls per-endpoint access. Resource-level
policy (`Mjolnir.Policy.VM`, `Mjolnir.Policy.Snapshot`) enforces ownership:
users can only act on resources they spawned. The localhost identity has
full access.

Remote operations via the Justfile use SSH-tunneled curl:
`ssh host "curl localhost:4000/..."`. The SSH tunnel makes curl appear as
localhost, which is how the auth bypass works for ops. Security relies on
SSH key management.

## Lifecycle Durability

- `Restart=always` + `StartLimitBurst=5` per 60s: systemd restarts Mjolnir on any exit.
- `Mjolnir.Reconcile` rehydrates stranded VMs from `StateStore` on boot.
- `Mjolnir.Cleanup` kills orphan hypervisor processes, stale TAP devices, and dangling sockets on startup.

The restart + reconcile loop means a BEAM crash results in ~15-30 seconds
of downtime, not permanent VM loss. Validated in production (2026-05-25
incident: postgres binary missing caused crash loop; after fix, all 3 VMs
rehydrated automatically).
