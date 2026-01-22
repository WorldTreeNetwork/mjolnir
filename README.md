# Mjolnir

Distributed computational fabric for spawning checkpointable Linux shells in Firecracker microVMs.

## Quick Start

### Host Setup

```bash
# On a fresh Debian 12 or Ubuntu 22.04 server with a spare disk
sudo BTRFS_DEVICE=/dev/sdb ./scripts/setup-host.sh
```

### Run Mjolnir

```bash
mix deps.get
iex -S mix
```

```elixir
# Spawn a VM
{:ok, vm} = Mjolnir.VM.spawn(%{base_image: "debian-12", memory_mb: 1024})

# Execute a command
{:ok, output} = Mjolnir.VM.exec(vm.id, "uname -a")

# Stop the VM
:ok = Mjolnir.VM.stop(vm.id)
```

## Requirements

- Linux with KVM support (`/dev/kvm`)
- BTRFS partition for CoW snapshots
- Firecracker 1.5+
- Elixir 1.15+, Erlang 26+

## Documentation

- [Roadmap](docs/roadmap.md)
- [MicroVM Fabric Spec](docs/microvm-fabric.md)
- [Computational Fabric Theory](docs/computational-fabric.md)

## License

MIT
