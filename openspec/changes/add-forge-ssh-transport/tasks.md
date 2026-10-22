# Tasks

- [ ] Open one OpenSSH ControlMaster per host and read a declared file path through it
- [ ] Refuse a remote command that is not that file read
- [ ] `POST /api/forge/hosts` with `transport: "ssh"` starts a worker whose `plan` is that diff and writes nothing
- [ ] A dropped connection backs off that worker and leaves `Forge.Supervisor` running
- [ ] Tests: observe, refused command, backoff. No live laptop in the test gate
- [ ] `apply` over SSH still returns `:ssh_transport_not_implemented_yet`

## Not this change

- Apply / adopt / delete over SSH
- Probe and enumerate over SSH
- `mjolnir-9u0` on-host agent
