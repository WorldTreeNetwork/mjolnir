# Mjolnir Orchestrator

Mjolnir is a distributed computational fabric for spawning **checkpointable Linux microVMs** in milliseconds, with NAT-traversing P2P access via [Iroh](https://iroh.computer). Think "instant, snapshottable sandboxes" — clone a filesystem with a BTRFS reflink, boot a [Cloud Hypervisor](https://www.cloudhypervisor.org) microVM, run code, snapshot, restore.

**Default hypervisor: Cloud Hypervisor v50.0** with virtio-fs + BTRFS subvolumes. (Firecracker was removed — it lacks virtio-fs, which the storage architecture requires.)

---

## Which path are you on?

| You want to… | Go to |
|---|---|
| **Use a Mjolnir server** (spawn/exec/connect to VMs) | [Use it](#use-it) — the `mj` CLI |
| **Call host services from a VM** (blob store, Postgres, API) | [Host sidecars](docs/guide/host-sidecars.md) |
| **Operate a server you can SSH into** | [Operate it](#operate-it) — the `just` control plane |
| **Stand up your own server** from scratch | [Run your own server](#run-your-own-server) |
| **Understand the internals** | [Architecture](#architecture) |

> VMs require Linux + KVM, so the **server** must be a Linux host. The `mj` CLI and the `just` control plane both run fine from a Mac.

---

## Use it

The `mj` CLI (also installed as `mjolnir`) talks to a Mjolnir server's HTTP API. It handles auth, VM lifecycle, and interactive shells.

### Install

```bash
# From the repo (needs Rust). Builds target/release/mjolnir and installs
# both `mjolnir` and the short `mj` alias to /usr/local/bin (or ~/.local/bin).
./scripts/build-client.sh --install
```

### Spawn a VM in three commands

```bash
mj login --api https://mjolnir.example.com   # authenticate, saves API + token
mj spawn                                      # returns vm_id + an Iroh ticket
mj connect <vm_id>                            # drop into an interactive PTY
```

### Everyday commands

```bash
mj list                          # list your VMs
mj info <vm_id>                  # detailed status
mj exec <vm_id> "uname -a"       # run a one-shot command
mj connect <vm_id>               # interactive shell (gateway WebSocket)
mj connect <ticket>              # interactive shell (P2P over Iroh QUIC, NAT-traversing)
mj ssh <ticket>                  # SSH into the VM over the Iroh tunnel
mj snapshot create <vm_id> my-snap  # checkpoint a running VM
mj snapshot list                 # list snapshots
mj spawn --snapshot my-snap      # restore from a snapshot
mj kill <vm_id>                  # stop and destroy (or `mj kill --all`)
mj doctor <vm_id>                # health probe (--fix to repair); no id checks API + host
mj status                        # show current auth + config
```

Run `mj --help` for the full surface (config profiles, ticket conversion, `mcp-serve` for Claude Code integration, and `forge` for host config). The `--api`/`--token` flags (or `MJOLNIR_TOKEN` / `MJOLNIR_PROFILE` env vars) override saved config per-invocation.

### Host sidecars (from inside a VM)

Every guest can reach a few **host sidecars** on `10.200.0.1` (not
`127.0.0.1` — that is the host's own loopback). Locators land in
`/etc/mjolnir/vm.json` on boot.

| Service | From the VM | Locator |
|---|---|---|
| Blob store (content-addressed, B2 behind a door) | `http://10.200.0.1:7222` | `blob_door_url` |
| Orchestrator API | `http://10.200.0.1:4000` | `api_url` |
| Postgres (declared tenant DBs only) | `10.200.0.1:5432` | `DATABASE_URL` in deploy secrets |

How to PUT/GET a blob, how Postgres tenants are provisioned, and how
to add another sidecar: **[Host sidecars](docs/guide/host-sidecars.md)**.

---

## Operate it

VM and snapshot operations all live in the **`mj` binary above** — including health (`mj doctor`), repair (`mj doctor --fix`), and dormant VMs (`mj list --dormant`). The `just` control plane is for **server operations**: deploying, building, and host management. If you have **SSH access** to the server, point `just` at it:

```bash
# 1. Point just at your server
cp .env.example .env             # then edit: MJOLNIR_HOST=root@your-server-ip

# 2. Deploy, manage, inspect
just deploy                      # rsync code, rebuild guest agent, restart service
just logs                        # follow journald logs (live)
just status                      # systemctl status mjolnir
just server-networking           # IP forwarding, NAT rules, TAP interfaces
```

You can also pass the host inline without `.env`: `just host=root@1.2.3.4 status`.

Run `just --list` for everything — deploys, host management, IdentiKey Sites, and the Forge host-config reconciler (`just forge-plan`, `just forge-apply`). VM lifecycle and health live in `mj` (see above); a quick `mj doctor` confirms the server is reachable and healthy.

---

## Run your own server

The server is a Linux host with KVM. The bootstrap script installs every dependency (Cloud Hypervisor, Erlang/Elixir via mise, Rust), provisions BTRFS storage, builds the rootfs + guest agent, and starts the orchestrator.

### Requirements

| Requirement | Minimum | How to check |
|---|---|---|
| CPU | x86_64 with VT-x/AMD-V | `grep -oE "(vmx\|svm)" /proc/cpuinfo \| head -1` |
| KVM | enabled | `ls -la /dev/kvm` |
| Memory / Disk | 4 GB / 20 GB free | `free -h` · `df -h /var/lib` |
| OS / Kernel | Ubuntu 22.04+ / 5.10+ | `uname -r` |

Cloud Hypervisor 50+, Erlang 26+, Elixir 1.15+, and Rust are installed by the bootstrap script. If you're inside a VM, you need **nested virtualization** enabled by your provider.

### Bootstrap

```bash
git clone https://github.com/IdentiKey/mjolnir.git
cd mjolnir

# Dev: keeps code in your workspace for live editing, loopback storage
sudo DEV_MODE=1 USE_LOOPBACK=1 ./scripts/bootstrap-host-ubuntu.sh

# Production: deploys to /opt/mjolnir
sudo USE_LOOPBACK=1 ./scripts/bootstrap-host-ubuntu.sh        # loopback file
sudo BTRFS_DEVICE=/dev/sdb ./scripts/bootstrap-host-ubuntu.sh # dedicated device
```

(Arch Linux hosts: use `bootstrap-host-arch.sh`.)

After a prod bootstrap, Mjolnir runs as a systemd service — manage it with `just status`, `just restart`, `just logs`.

### Running it for development

For live-editing the orchestrator, run it interactively. VM operations need root (TAP interfaces + Cloud Hypervisor):

```bash
sudo bash -c 'eval "$(mise activate bash)" && iex -S mix'   # interactive console
recompile()                                                  # hot-reload after edits
```

```elixir
# Drive VMs directly from IEx
{:ok, vm} = Mjolnir.VM.spawn(%{base_image: "ubuntu-24.04", memory_mb: 1024})
{:ok, out} = Mjolnir.VM.exec(vm.id, "uname -a")
:ok = Mjolnir.VM.stop(vm.id)
```

Dev mode uses isolated paths (`@vms-dev`, `/tmp/mjolnir-dev`) so it won't clobber prod state.

### Bootstrap environment variables

| Variable | Default | Description |
|---|---|---|
| `DEV_MODE` | `0` | `1` = workspace-based dev setup (no `/opt` deploy) |
| `BTRFS_DEVICE` | (prompts) | Block device for BTRFS, e.g. `/dev/sdb` |
| `USE_LOOPBACK` | `0` | `1` = create a loopback file instead of a device |
| `BTRFS_LOOPBACK_SIZE_GB` | `50` | Loopback file size when `USE_LOOPBACK=1` |
| `SKIP_BTRFS` / `SKIP_ROOTFS` | `0` | Skip BTRFS / rootfs build |
| `MJOLNIR_REPO` / `MJOLNIR_BRANCH` | (cwd) / `main` | Repo URL / branch to check out |

---

## Architecture

Mjolnir is Elixir/OTP for orchestration over a Rust guest agent inside each VM.

- **`Mjolnir.VM`** — a GenServer per VM (spawn → boot → running → snapshot/stop). Boot = BTRFS reflink clone → inject guest agent → create TAP → launch Cloud Hypervisor → configure via its Unix-socket API → wait for the guest agent over vsock → configure network/identity/Iroh.
- **`Mjolnir.BTRFS`** — instant CoW cloning of base images via `btrfs subvolume snapshot`. Layout: `@base/` templates, `@vms/<uuid>/`, `@snapshots/<name>/`.
- **Guest agent** (`native/mjolnir_guest_agent/`, Rust) — runs inside the VM on vsock, handles `exec`, networking, identity, and Iroh-backed PTY/SSH.
- **HTTP API** — Bandit on port `4000`, JWT/OIDC-authenticated. This is what `mj` and the `just` control plane talk to. Guests see it as `api_url` on `10.200.0.1`.
- **Host sidecars** — processes on the reserved overlay IP (`10.200.0.1`): blob door `:7222`, tenant Postgres `:5432`. Catalog: [Host sidecars](docs/guide/host-sidecars.md).
- **Forge** (`lib/mjolnir/forge/`) — a declarative host-config reconciler with three-way diff (declared/owned/observed) and a TUI (`mj forge tui`).

The deepest reference is [`CLAUDE.md`](CLAUDE.md) (module-by-module map). Plans and specs live in [`docs/`](docs/).

---

## Status & limitations

- **Single node** — VMs run on the local host; distributed scheduling is a future milestone.
- VMs are fully functional end-to-end: spawn, exec, connect (WebSocket + Iroh PTY), snapshot, restore.

---

## Troubleshooting

**`/dev/kvm` not found** — load the modules and make them persistent:
```bash
sudo modprobe kvm && sudo modprobe kvm_intel   # kvm_amd on AMD
echo -e "kvm\nkvm_intel" | sudo tee /etc/modules-load.d/kvm.conf
```

**Permission denied on `/dev/kvm`** — join the `kvm` group:
```bash
sudo usermod -aG kvm $USER && newgrp kvm
```

**Hypervisor fails to start a VM** — you're likely inside a VM without nested virt:
```bash
grep -q "hypervisor" /proc/cpuinfo && echo "in a VM — enable nested virtualization"
```

**`just` commands fail** — check `MJOLNIR_HOST` is set (`.env`). To confirm the server is reachable and healthy, run `mj doctor`.

---

## Documentation

**New here?** Start with the [Guide](docs/guide/) — user-facing docs for spawning and working
with VMs. Type-along [Getting Started](docs/guide/getting-started.md), then
[Working with Snapshots](docs/guide/snapshots.md). If you think in containers, read
[Coming from Docker](docs/guide/coming-from-docker.md). To put an app on a domain, see
[Deploying a Web App](docs/guide/deploying-an-app.md). Host services
every VM can call: [Host sidecars](docs/guide/host-sidecars.md).

- [Guide (user-facing)](docs/guide/) · [Getting Started](docs/guide/getting-started.md) · [Snapshots](docs/guide/snapshots.md) · [Coming from Docker](docs/guide/coming-from-docker.md) · [Deploying a Web App](docs/guide/deploying-an-app.md) · [Host sidecars](docs/guide/host-sidecars.md)
- [Current status / handoff notes](docs/plans/current-status.md)
- [Roadmap](docs/roadmap.md)
- [MicroVM Fabric Spec](docs/microvm-fabric.md)
- [Computational Fabric Theory](docs/computational-fabric.md)

## License

MIT
