# forgejo-runner (Mjolnir fork)

A fork of the [Forgejo runner](https://code.forgejo.org/forgejo/runner) that adds a
**Mjolnir VM executor backend** — CI jobs run inside lightweight microVMs instead of
Docker containers.

## Relationship to the main codebase

The Mjolnir Elixir application (`../../`) exposes an HTTP API at `localhost:4000` that
manages Cloud Hypervisor microVMs. This runner fork talks to that API to spawn an
isolated VM per CI job, execute workflow steps inside it via vsock-backed exec, and
tear it down when the job finishes.

```
Forgejo → runner (this repo) → Mjolnir API → Cloud Hypervisor microVM
```

The `pkg/mjolnir` package contains:

- `executor.go` — scaffold for the act `ContainerExecutor` interface implementation
- `client.go`   — stdlib-only HTTP client for the Mjolnir API

## Build

```bash
go build ./...
```

Requires Go 1.21+. No external dependencies (stdlib only for now).

## Status

Currently scaffolding only. The full fork integration with the
[act](https://github.com/nektos/act) executor interface is pending.

Planned lifecycle per CI job:

1. **SpawnVM** — `POST /api/vms` with base image + optional extra virtio-fs mounts
2. **ExecStep** — `POST /api/vms/:id/exec` for each workflow step
3. **Teardown** — `DELETE /api/vms/:id`

The upstream Forgejo runner fork (vendoring act, registering with Forgejo, polling
for jobs) will be layered on top once the executor interface is settled.
