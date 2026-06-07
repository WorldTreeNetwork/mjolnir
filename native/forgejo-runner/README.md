# forgejo-runner (Mjolnir VM backend)

A Mjolnir microVM execution backend for the [Forgejo runner](https://code.forgejo.org/forgejo/runner).
CI jobs run inside lightweight Cloud Hypervisor microVMs instead of Docker containers.

## Architecture

```
Forgejo → forgejo-runner (patched) → Mjolnir API → Cloud Hypervisor microVM
                                      localhost:4000
```

The `pkg/mjolnir` package implements the upstream act `container.Container` interface,
routing all execution through the Mjolnir HTTP API:

- `executor.go` — `VMEnvironment` implementing all 13 `Container` methods
- `client.go` — stdlib-only HTTP client for the Mjolnir API (spawn, exec, stop)

## How it works

1. Runner receives a job with `runs-on: ubuntu-24.04`
2. Label `ubuntu-24.04` maps to `mjolnir:ci-ubuntu-24.04` (VM backend + base image)
3. `VMEnvironment.Create()` spawns a VM via `POST /api/vms`
4. Each workflow step runs via `POST /api/vms/:id/exec`
5. `VMEnvironment.Remove()` destroys the VM via `DELETE /api/vms/:id`

## Integration

The upstream runner needs a small patch to recognize `mjolnir:` labels
(similar to the existing `lxc:` prefix support). See `patches/0001-add-mjolnir-vm-backend.patch`.

### Apply the patch

```bash
# Clone the upstream runner
git clone https://code.forgejo.org/forgejo/runner.git forgejo-runner-upstream
cd forgejo-runner-upstream

# Add this package as a local dependency
echo 'replace worldtree.network/mjolnir/forgejo-runner => /path/to/mjolnir/native/forgejo-runner' >> go.mod
go get worldtree.network/mjolnir/forgejo-runner

# Apply the patch (adds IsMjolnirEnv, startMjolnirEnvironment to run_context.go)
# The patch is documented, not a raw diff — apply the changes manually to:
#   act/runner/run_context.go

# Build
go build -o forgejo-runner-mjolnir .
```

### Register the runner

```bash
forgejo-runner-mjolnir register \
  --instance http://127.0.0.1:3000 \
  --token <token> \
  --name mjolnir-vm-runner \
  --labels "ubuntu-24.04:mjolnir:ci-ubuntu-24.04"
```

### Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `MJOLNIR_API_BASE` | `http://127.0.0.1:4000` | Mjolnir API URL |
| `MJOLNIR_VM_IMAGE` | `ci-ubuntu-24.04` | Default base image |

## Build (this package only)

```bash
go build ./...
```

## Current status

- [x] `container.Container` interface fully implemented (`VMEnvironment`)
- [x] Compile-time interface verification against upstream types
- [x] HTTP client for Mjolnir API (spawn, exec, stop, status)
- [x] Patch documented for upstream runner integration
- [ ] Full fork build with patched runner (manual patch application)
- [ ] E2E test with VM-sandboxed workflow execution
