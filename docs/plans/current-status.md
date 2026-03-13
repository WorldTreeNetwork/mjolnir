# Mjolnir Current Status — 2026-03-13

## Secrets Architecture (2026-03-12 → 2026-03-13)

### Implementation Complete
- **LUKS2 encrypted secrets volumes** inside guest VMs (AES-XTS-plain64, 512-bit, Argon2id)
- **Iroh SECRET_INJECT_ALPN** (`mjolnir-secret-inject/1`) for passphrase delivery bypassing the host
- **Peer authentication** — authorized inject peers configured via vsock, validated via `conn.remote_id()`
- **Environment variable auto-sourcing** — every `exec` command sources `/etc/mjolnir/secrets.env`
- **Security hardened** — zeroize, atomic injection guard, keyfile 0600 + zero-fill before delete, env key validation, secrets.env 0600

### New/Modified Files
| File | Changes |
|------|---------|
| `native/mjolnir_guest_agent/src/secrets.rs` | New — full LUKS engine, env management, security hardening |
| `native/mjolnir_guest_agent/src/iroh.rs` | SECRET_INJECT_ALPN handler, peer auth, action dispatch |
| `native/mjolnir_guest_agent/src/vsock.rs` | Exec auto-sources secrets.env, ConfigureSecretsAuth handler |
| `native/mjolnir_guest_agent/src/protocol.rs` | ConfigureSecretsAuth request type |
| `native/mjolnir_guest_agent/Cargo.toml` | Added zeroize crate |
| `lib/mjolnir/vm.ex` | secrets_mode field, authorize_inject_peer/2, dormancy guard |
| `lib/mjolnir/api/router.ex` | secrets_mode param, POST authorize-inject endpoint |
| `lib/mjolnir/vsock/protocol.ex` | configure_secrets_auth_request/2 |
| `lib/mjolnir/vsock/connection.ex` | Generic send_request/3 for correlated request/response |
| `scripts/build-kernel.sh` | CONFIG_BLK_DEV_DM, CONFIG_DM_CRYPT, CONFIG_CRYPTO_XTS/AES |
| `scripts/build-rootfs.sh` | cryptsetup-bin, kmod packages |
| `docs/secrets-architecture.md` | Full architecture documentation |

### Tests
- **186 unit tests, 0 failures** (up from 101)
- 8 new tests in secrets.rs (env parsing, key validation)

### What Needs Testing
- [ ] E2E: spawn VM → authorize peer → inject secrets → exec with env vars
- [ ] Secrets persist across VM restart (LUKS file on virtio-fs)
- [ ] Dormancy guard prevents handle_done with secrets_mode: :persistent

---

## Previous Sessions

## What Was Done (2026-02-26)

### 1. Cloud Hypervisor as Default Hypervisor
- Changed `config/config.exs` to set `hypervisor: Mjolnir.Hypervisor.CloudHypervisor`
- Added `ch_kernel_path: "/var/lib/mjolnir/vmlinux-ch"` to config
- Both hypervisors (CH and Firecracker) are behind the `Mjolnir.Hypervisor` behaviour (8 callbacks)
- Config key `guest_agent_bin` added for auto-injection into rootfs at boot

### 2. Critical Bug Fixes (6 total)
| Bug | Fix | File(s) |
|-----|-----|---------|
| TAP cleanup race condition | Process dictionary tracks partial boot resources; `cleanup_partial_boot/4` with try/rescue | `vm.ex`, `hypervisor/cloud_hypervisor.ex`, `hypervisor/firecracker.ex` |
| Supervisor restart cascade | `{:stop, :normal, state}` for transient restart policy | `vm.ex` |
| Negative boot_time | `System.system_time(:millisecond)` instead of `monotonic_time` | `vm.ex` |
| No error response on spawn failure | `try/catch` around spawn in router | `api/router.ex` |
| Orphan TAP device leak | `clean_orphan_taps/0` in Cleanup module | `cleanup.ex` (new) |
| Guest agent protocol incompatibility | `inject_guest_agent/1` auto-injects current binary into rootfs | `vm.ex` |

### 3. New Modules
- **`lib/mjolnir/cleanup.ex`** — Sweeps orphan hypervisor processes, stale TAPs, sockets on startup
- **`lib/mjolnir/dormant_registry.ex`** — ETS registry for dormant VM metadata (snapshot + config for wake-on-message)

### 4. Config Fixes
- `boot_args` in `CloudHypervisor.Config` now includes `root=myfs rootfstype=virtiofs rw` (virtio-fs rootfs; Firecracker uses `is_root_device` flag with virtio-blk)
- `vsock_cid` now generated per-VM from UUID via MD5 hash (was hardcoded to 3, causing CID collisions)
- CID range: [3, 0xFFFFFFFF), derived from first 4 bytes of `MD5(vm_uuid)`

### 5. New API Endpoints
- `POST /api/vms/:id/messages` — Inter-VM messaging (buffered during boot)
- `GET /api/dormant` — List dormant VMs

### 6. Test Harness
- **101 unit tests, 0 failures** (`mix test` on macOS)
- Test files created this session:
  - `test/mjolnir/cloud_hypervisor/config_test.exs` (12 tests)
  - `test/mjolnir/vm_unit_test.exs` (8 tests)
  - `test/mjolnir/cleanup_test.exs` (1 test)
  - `test/mjolnir/ticket_test.exs` (7 tests)
  - `test/mjolnir/cloud_hypervisor_integration_test.exs` (6 integration tests)
  - `test/mjolnir/snapshot_test.exs` (5 integration tests)
- Spec: `docs/plans/test-harness-spec.md`

### 7. Full Server Rebuild
- Deployed code, guest agent (musl binary), and rootfs (Ubuntu 24.04, 913MB) to server
- Deploy command: `./scripts/deploy.sh root@45.76.77.97 --agent`
- Server restarted — Cleanup module successfully killed 17 orphan hypervisor processes on boot

---

## Open Issue: CH vm.create Returns 400

**Priority: HIGH — VMs cannot spawn**

### Symptoms
- POST to `/api/vms` returns `{"error": "spawn_failed", ...}`
- Server logs show: `Cloud Hypervisor API error: 400 - ["Bad Request"]`
- Everything before the API call succeeds: rootfs clone, guest agent injection, TAP creation, CH process start, socket ready

### What We Know
- CH v50.0 is installed and running (`cloud-hypervisor --version` confirms)
- Both kernels exist: `/var/lib/mjolnir/vmlinux` (43MB) and `/var/lib/mjolnir/vmlinux-ch` (46MB, PVH)
- The CH log file (`/tmp/cloud-hypervisor-{vm_id}.log`) is empty — CH doesn't log before rejecting
- The `configure_vm` function in `hypervisor/cloud_hypervisor.ex` builds a Config struct from the VM state, checks for `ch_kernel_path`, and calls `Config.vm_create_payload/2`
- The CH OpenAPI spec says our payload structure matches (payload, cpus, memory, disks, net, vsock)
- A debug `Logger.info` has been added to `client.ex:create_vm/2` to log the exact JSON payload — **this needs to be deployed and tested**

### Debugging Steps for Next Agent
1. Deploy the current code to server (has the debug log line)
2. Restart Mjolnir: kill beam, start `iex -S mix` in tmux session 0
3. Spawn a VM: `curl -s -H 'Authorization: Bearer mjolnir-dev-token' -X POST http://localhost:4000/api/vms`
4. Check tmux output for `vm.create payload: {...}` — this shows the exact JSON sent to CH
5. Compare the payload against [CH v50 OpenAPI spec](https://github.com/cloud-hypervisor/cloud-hypervisor/blob/main/vmm/src/api/openapi/cloud-hypervisor.yaml)
6. Test manually: start `cloud-hypervisor --api-socket /tmp/test-ch.sock`, then `curl --unix-socket /tmp/test-ch.sock -X PUT http://localhost/api/v1/vm.create -H 'Content-Type: application/json' -d '<payload>'`

### Likely Causes (in order of probability)
1. **Kernel path issue** — CH PVH boot may need a specific kernel format; verify `/var/lib/mjolnir/vmlinux-ch` is actually PVH-capable
2. **Rootfs path** — The ext4 image might be too large (8GB) or need a specific format flag in the disk config (e.g., `"image_type": "Raw"`)
3. **Memory format** — CH expects `size` in bytes (we send `mem_size_mib * 1024 * 1024`); verify it's not exceeding host memory
4. **CID value** — Large CIDs from MD5 hash might be outside CH's acceptable range (try hardcoding CID to 3 as a test)

### Quick Test: Isolate the Issue
In the server's `iex` session, try hardcoding a minimal payload:
```elixir
Mjolnir.CloudHypervisor.Client.create_vm("/tmp/mjolnir/test.sock", %{
  "payload" => %{"kernel" => "/var/lib/mjolnir/vmlinux-ch", "cmdline" => "console=ttyS0"},
  "cpus" => %{"boot_vcpus" => 1, "max_vcpus" => 1},
  "memory" => %{"size" => 536_870_912}
})
```
(After starting a CH process with `cloud-hypervisor --api-socket /tmp/mjolnir/test.sock`)

---

## What's Working
- Elixir app compiles and starts cleanly (27 modules)
- Cleanup module sweeps orphans on startup (verified: killed 17 processes)
- HTTP API serves on port 4000 with auth
- 101 unit tests pass on macOS
- Rootfs (Ubuntu 24.04) built and deployed
- Guest agent (Rust, musl) built and deployed
- TAP creation, IP allocation, MAC generation all work
- Guest agent injection into rootfs works

## What Needs Testing (After vm.create Fix)
- Integration tests on server: `mix test --include integration`
- Snapshot create/restore lifecycle
- Concurrent VM spawning (3+ VMs)
- Dormant VM wake-on-message flow
- Inter-VM messaging

## Remaining Test Harness Work
- [ ] DormantRegistry unit tests
- [ ] Mock Hypervisor (enables testing VM GenServer without KVM — highest leverage)
- [ ] Expanded Router tests with mock hypervisor
- [ ] E2E API lifecycle tests
