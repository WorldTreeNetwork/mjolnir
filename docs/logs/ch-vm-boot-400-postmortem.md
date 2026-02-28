# Cloud Hypervisor vm.boot 400 Bad Request - Post-Mortem

**Date**: 2026-02-27
**Severity**: Critical — VMs could not spawn at all
**Duration**: ~2 days of investigation across multiple debugging sessions
**Impact**: Complete platform unavailability; the entire Mjolnir VM spawning system was non-functional

---

## Summary

After migrating Mjolnir from Firecracker to Cloud Hypervisor v50.0 and from ext4 disk images to virtio-fs (virtiofsd + BTRFS subvolumes), the platform became unable to spawn any VMs. The HTTP API returned 500 errors with "Cloud Hypervisor API error: 400" in server logs.

The investigation spanned multiple hypotheses and debugging approaches across two days, involving stale deployments, missing infrastructure, red herring investigations into virtiofsd and hypervisor compatibility, and ultimately leading to a counterintuitive discovery: **Cloud Hypervisor v50's body-less endpoints (`vm.boot`, `vm.pause`, `vm.resume`, `vm.shutdown`, `vm.delete`) reject ANY request body, including an empty JSON object `{}`.**

The fix was simple once identified: change 5 API client calls from `%{}` (empty map) to `nil` (no body). This single-line change per endpoint restored full VM spawning capability.

---

## Timeline of Investigation

### Session 1: Initial Symptom Detection (Day 1, Morning)

**Step 1: Initial symptom observed**

User reports: `mjolnir spawn` returns HTTP 500. Server logs show:
```
Cloud Hypervisor API error: 400
```

Initial hypothesis: The `vm.create` endpoint payload is malformed or missing required fields. The error message doesn't identify which API endpoint failed, only that a 400 was returned.

**Step 2: Stale deployment discovered**

Investigation reveals the server is running pre-virtio-fs code:
- Still sending `"disks"` in the vm.create payload instead of `"fs"`
- Boot args reference `/dev/vda` instead of `virtiofs` tag
- Code hasn't been deployed since the virtio-fs migration commit (42b0752)

**Action taken**: Full code deploy via `./scripts/deploy.sh root@45.76.77.97`

**Result**: Code now matches virtio-fs migration changes. VM spawn attempted again.

**Step 3: New error — BTRFS rootfs missing**

After deploy, a different error emerges:
```
BTRFS snapshot failed: Could not statfs: No such file or directory
```

The error occurs in `Mjolnir.BTRFS.clone/2`. Investigation reveals:
- On-server `@base/` directory contains `ubuntu-24.04.ext4` (old ext4 file)
- Code now expects `@base/ubuntu-24.04/` (BTRFS subvolume directory)
- The virtio-fs migration expects BTRFS subvolumes, not ext4 files

**Action taken**: User rebuilds rootfs via `just deploy-rootfs`

**Result**: BTRFS subvolume created at `@base/ubuntu-24.04/`. VM spawn attempted again.

### Session 2: The 400 Persists (Day 1, Afternoon)

**Step 4: 400 error persists with correct payload**

With:
- Correct code deployed (virtio-fs migration)
- Correct rootfs infrastructure (BTRFS subvolumes)

VMs still fail to spawn. Server logs now show:
```
Cloud Hypervisor API error: 400
```

But the server logs also show the JSON payload structure is correct:
```
vm.create payload: {
  "kernel": "/var/lib/mjolnir/vmlinux-ch",
  "fs": [{"tag": "myfs", "socket": "/tmp/mjolnir/abc123_virtiofsd.sock"}],
  "memory": {"size": 536870912, "shared": true},
  "vsock": {"cid": 1234},
  ...
}
```

Everything looks correct per the Cloud Hypervisor v50 OpenAPI spec.

**Action taken**: Direct testing of payload against Cloud Hypervisor API.

**Step 5: Payload tested directly with curl**

Operator connects to the server and manually tests the exact same JSON payload:
```bash
curl -X PUT \
  --unix-socket /tmp/mjolnir/socket.sock \
  http://localhost/api/v1/vm.create \
  -H "Content-Type: application/json" \
  -d '{"kernel": "...", "fs": [...], ...}'
```

**Result**: HTTP 204 (success!). The payload structure is absolutely correct. The problem is NOT with the payload.

This tells us the payload structure isn't the issue — something about HOW the Elixir client is making the request differs from curl.

### Session 3: Chasing the HTTP Client (Day 1, Late Afternoon)

**Step 6: Suspected Req HTTP client**

Looking at `lib/mjolnir/cloud_hypervisor/client.ex`, the implementation uses the Req library for HTTP calls. Perhaps Req adds unwanted headers or encodes differently than curl?

**Action taken**: Refactor client.ex to use `Jason.encode!` directly + explicit header construction instead of Req's automatic JSON encoding.

```elixir
# Before (using Req)
Req.put(socket_path, path, %{})

# After (manual encoding)
json_body = Jason.encode!(body)
curl_request("PUT", socket_path, path, json_body)
```

**Result**: Still 400 error. Req was not the culprit.

**Step 7: Changed to System.cmd("curl")**

Suspected that maybe even the manual Elixir HTTP libraries have subtle differences. Replaced all HTTP calls with direct `System.cmd("curl", [...])` shell invocation to match exact curl behavior.

```elixir
System.cmd("curl", [
  "-s",
  "--unix-socket", socket_path,
  "-X", "PUT",
  url,
  "-H", "Content-Type: application/json",
  "-d", body
])
```

**Result**: STILL 400 error. The HTTP client is not the issue.

At this point, all the usual suspects (payload structure, HTTP client implementation, content-type headers) have been ruled out.

### Session 4: Deep Dive into Hypervisor Behavior (Day 1, Evening)

**Step 8: Enabled Cloud Hypervisor verbose logging**

Added `-v` flag to Cloud Hypervisor startup args to capture verbose logging:
```elixir
args = [
  "--api-socket", socket_path,
  "-v",  # Verbose logging
  "--log-file", "/tmp/cloud-hypervisor-#{vm_id}.log"
]
```

**Result**: Cloud Hypervisor logs show successful parsing of the entire vm.create payload:
```
VmConfig parsed successfully
kernel: /var/lib/mjolnir/vmlinux-ch
fs:
  - tag: myfs
    socket: /tmp/.../virtiofsd.sock
memory:
  size: 536870912
  shared: true
vsock:
  cid: 1234
```

All fields correctly parsed. No indication of what would cause a 400.

**Step 9: Investigated virtiofsd process lifecycle**

Theorized that maybe virtiofsd wasn't starting correctly, and CH was rejecting the vm.create because it couldn't connect to the vhost-user socket.

```bash
# Checked if virtiofsd was running
ps aux | grep virtiofsd
# Found process, but hard to verify socket creation due to SSH quoting issues
```

Started virtiofsd manually on the server:
```bash
/usr/libexec/virtiofsd \
  --socket-path=/tmp/test-virtiofsd.sock \
  --shared-dir=/mnt/btrfs/@base/ubuntu-24.04
```

Observed: Process started, socket created, logs showed "Waiting for vhost-user socket connection..."

Appeared healthy but unclear if this was the actual issue due to SSH quoting complexity with `$!` PID capture.

### Session 5: End-to-End Test Script Breakthrough (Day 2, Morning)

**Step 10: Wrote comprehensive shell script replicating Mjolnir's boot sequence**

Decided to bypass Elixir entirely and replicate the exact sequence of operations manually in bash:

```bash
#!/bin/bash
set -e

# 1. Start virtiofsd
echo "Starting virtiofsd..."
/usr/libexec/virtiofsd \
  --socket-path=/tmp/test-virtiofsd.sock \
  --shared-dir=/mnt/btrfs/@base/ubuntu-24.04 &
VIRTIOFSD_PID=$!
sleep 1

# 2. Start Cloud Hypervisor
echo "Starting Cloud Hypervisor..."
/usr/bin/cloud-hypervisor \
  --api-socket=/tmp/test-ch.sock &
CH_PID=$!
sleep 1

# 3. Send vm.create with full payload
echo "Creating VM..."
curl -X PUT \
  --unix-socket /tmp/test-ch.sock \
  http://localhost/api/v1/vm.create \
  -H "Content-Type: application/json" \
  -d '{
    "kernel": "/var/lib/mjolnir/vmlinux-ch",
    "fs": [{"tag": "myfs", "socket": "/tmp/test-virtiofsd.sock"}],
    "memory": {"size": 536870912, "shared": true},
    "vsock": {"cid": 1234}
  }'
# Result: HTTP 204 ✓ Success

# 4. Check processes still alive
echo "Checking processes..."
ps -p $VIRTIOFSD_PID  # ALIVE ✓
ps -p $CH_PID         # ALIVE ✓

# 5. Send vm.boot (THIS is where Mjolnir was failing)
echo "Booting VM..."
curl -X PUT \
  --unix-socket /tmp/test-ch.sock \
  http://localhost/api/v1/vm.boot \
  -H "Content-Type: application/json" \
  -d '{}'
# Result: HTTP 400 ❌ FAILURE
```

**KEY DISCOVERY**: `vm.boot` FAILED with 400, but `vm.create` SUCCEEDED with 204!

This proved the 400 error was NOT coming from `vm.create` — it was coming from a SUBSEQUENT call. The original error reporting was misleading because both endpoints went through the same error handler which reported "API error: 400" without identifying which endpoint.

Continued the script to test vm.boot variations:

```bash
# Test 1: vm.boot with {} body
curl -X PUT --unix-socket /tmp/test-ch.sock \
  http://localhost/api/v1/vm.boot \
  -H "Content-Type: application/json" \
  -d '{}'
# Result: HTTP 400 ❌

# Test 2: vm.boot with NO body (curl -d omitted)
curl -X PUT --unix-socket /tmp/test-ch.sock \
  http://localhost/api/v1/vm.boot
# Result: HTTP 204 ✓ SUCCESS!
# Cloud Hypervisor kernel booted and started vCPU
```

**BREAKTHROUGH**: `vm.boot` with no body succeeds; with `{}` body it fails.

Tested the same pattern on other body-less endpoints with minimal VM config:

```bash
# Even with minimal config (just kernel + memory, no fs/net/vsock)

# PUT with body
curl -X PUT --unix-socket /tmp/test-ch.sock \
  http://localhost/api/v1/vm.boot \
  -H "Content-Type: application/json" \
  -d '{}'
# HTTP 400 ❌

# PUT without body
curl -X PUT --unix-socket /tmp/test-ch.sock \
  http://localhost/api/v1/vm.boot
# HTTP 204 ✓
```

Pattern confirmed: **Cloud Hypervisor v50 rejects HTTP requests on body-less endpoints when ANY body is included, even `{}`.**

### Session 6: Root Cause Identified and Fixed (Day 2, Afternoon)

**Step 11: Located the problematic code**

Examined `lib/mjolnir/cloud_hypervisor/client.ex`:

```elixir
def boot_vm(socket_path) do
  put(socket_path, "/api/v1/vm.boot", %{})  # <-- Empty map passed as body
end

def pause_vm(socket_path) do
  put(socket_path, "/api/v1/vm.pause", %{})  # <-- Empty map
end

def resume_vm(socket_path) do
  put(socket_path, "/api/v1/vm.resume", %{})  # <-- Empty map
end

def shutdown_vm(socket_path) do
  put(socket_path, "/api/v1/vm.shutdown", %{})  # <-- Empty map
end

def delete_vm(socket_path) do
  put(socket_path, "/api/v1/vm.delete", %{})  # <-- Empty map
end

defp put(socket_path, path, body) do
  request(:put, socket_path, path, body)
end

defp request(method, socket_path, path, body) do
  case method do
    :put ->
      json_body = if body, do: Jason.encode!(body), else: nil
      curl_request("PUT", socket_path, path, json_body)
  end
end
```

The logic `if body, do: Jason.encode!(body), else: nil` treats `%{}` (non-nil empty map) as "has a body" and encodes it to `"{}"`. The HTTP request then includes this body even though the endpoint doesn't accept one.

**Step 12: Applied the fix**

Changed all 5 body-less endpoints to pass `nil` instead of `%{}`:

```elixir
def boot_vm(socket_path) do
  put(socket_path, "/api/v1/vm.boot", nil)
end

def pause_vm(socket_path) do
  put(socket_path, "/api/v1/vm.pause", nil)
end

def resume_vm(socket_path) do
  put(socket_path, "/api/v1/vm.resume", nil)
end

def shutdown_vm(socket_path) do
  put(socket_path, "/api/v1/vm.shutdown", nil)
end

def delete_vm(socket_path) do
  put(socket_path, "/api/v1/vm.delete", nil)
end
```

Added docstring clarification to `boot_vm/1`:
```elixir
@doc """
Boot the VM (start instance).

CH v50 rejects requests with a body on this endpoint.
"""
```

**Step 13: Verified the fix**

Deployed the fix to the server:
```bash
./scripts/deploy.sh root@45.76.77.97
```

Tested VM spawn:
```bash
just vm-spawn
# Result: SUCCESS ✓
# VM boots, guest agent responds, command execution via vsock works
```

Running a command in the newly spawned VM:
```bash
just vm-exec <vm-id> "uname -a"
# Result: Linux mjolnir-guest 6.x.x-x86_64 #1 SMP ... GNU/Linux
```

Full integration test:
```bash
just vm-list
# VM is running with virtio-fs rootfs mounted
```

Snapshot creation also works:
```bash
just snap-create <vm-id> test-snapshot
# Snapshot created successfully
```

**Complete success**: Platform fully operational.

---

## Root Cause Analysis

**The bug**: Cloud Hypervisor v50's REST API has a stricter interpretation of HTTP semantics than Firecracker. Specifically:

1. **Firecracker** (the previous hypervisor): Accepts and ignores request bodies on PUT endpoints that don't require a body. Empty `{}` was treated as "no-op".

2. **Cloud Hypervisor v50**: Strictly enforces that body-less endpoints (`vm.boot`, `vm.pause`, `vm.resume`, `vm.shutdown`, `vm.delete`) receive NO request body. Even an empty JSON object `{}` is rejected with HTTP 400.

3. **The implementation issue**: The Elixir client was migrated from Firecracker to Cloud Hypervisor but retained the pattern of passing `%{}` (empty Elixir map) as a "no-op body" placeholder. This worked fine with Firecracker's lenient API but breaks with Cloud Hypervisor's stricter requirements.

4. **Why it was hard to diagnose**:
   - The error reporting ("Cloud Hypervisor API error: 400") didn't identify which endpoint failed
   - `vm.create` (the first call in the boot sequence) succeeded with 204
   - `vm.boot` (the second call) failed with 400, creating confusion about where the problem was
   - The payload structure for `vm.create` was correct, so initial investigation focused on payload validity rather than HTTP semantics

---

## Red Herrings Investigated

### 1. virtiofsd Process Lifecycle

**Why suspected**: The vm.create payload includes a socket path to virtiofsd. If virtiofsd wasn't running or its socket wasn't created, perhaps Cloud Hypervisor would reject the config.

**How it was ruled out**:
- Manual virtiofsd startup succeeded
- Cloud Hypervisor's verbose logs showed it successfully parsed the entire config including the fs socket path
- Later testing with minimal config (no fs at all) still failed with the same 400 error on vm.boot

**Time spent**: ~30 minutes

### 2. Req/Finch HTTP Client Implementation

**Why suspected**: Maybe the Req library was adding unwanted headers or encoding the JSON differently than curl.

**How it was ruled out**:
- Refactored to use explicit `Jason.encode!` + manual header construction
- Refactored again to use `System.cmd("curl", [...])` shelling out to curl directly
- Both approaches still produced 400 errors on vm.boot
- This proved the problem wasn't with any HTTP library — it was the request itself

**Time spent**: ~45 minutes

### 3. PVH Kernel Headers / Boot Configuration

**Why suspected**: Maybe the Cloud Hypervisor kernel needed special flags, or the boot_args were incorrect.

**How it was ruled out**:
- Cloud Hypervisor verbose logs showed kernel successfully parsed and loaded
- Even minimal configs (kernel + memory only, no fs/net/vsock) failed on vm.boot with the same pattern
- The issue occurred consistently across all configurations, pointing to a protocol issue not a config issue

**Time spent**: ~20 minutes

### 4. virtio-fs Payload Structure

**Why suspected**: The migration introduced the `"fs"` field and other payload changes. Perhaps the structure was subtly wrong.

**How it was ruled out**:
- Direct curl testing of the exact payload succeeded (HTTP 204 on vm.create)
- CH logs showed all payload fields parsed correctly
- The 400 error came from vm.boot, not vm.create, indicating the payload wasn't the issue

**Time spent**: ~40 minutes

### 5. TAP Interface / Network Configuration

**Why suspected**: Network setup might be failing, and the error was being reported at the wrong layer.

**How it was ruled out**:
- End-to-end test script created VMs with no network config at all
- Same 400 error on vm.boot occurred even without TAP setup
- Proves the problem is orthogonal to networking

**Time spent**: ~15 minutes

### 6. virtiofsd / Cloud Hypervisor Version Compatibility

**Why suspected**: Maybe the versions were incompatible and CH was rejecting the config.

**How it was ruled out**:
- Both were installed and versions matched the specification (v50.0 for CH, latest virtiofsd)
- Direct curl testing with the same versions succeeded
- Version compatibility was not the issue

**Time spent**: ~20 minutes

**Total time investigating red herrings**: ~2.5 hours

---

## What Made This Hard to Debug

### 1. Generic Error Reporting

The error handler in `client.ex` reported:
```
Cloud Hypervisor API error: 400
```

This didn't identify WHICH endpoint returned 400. Without that context, investigation initially focused on `vm.create` (the first and most complex call) rather than `vm.boot` (the actual failing call).

**Better approach**: Log the endpoint in the error message:
```elixir
Logger.error("Cloud Hypervisor API error: #{status} on #{method} #{path}")
```

### 2. Sequential Failure Chain

The boot sequence uses a `with` chain in `VM.do_boot/1`:
```elixir
with :ok <- File.mkdir_p(socket_dir),
     {:ok, rootfs_path} <- clone_rootfs(...),
     ...
     :ok <- configure_vm(hypervisor, socket_path, config),      # vm.create
     :ok <- hypervisor.start_instance(socket_path),              # vm.boot ← fails here
     :ok <- wait_for_boot(vsock_path),
     ...
```

When `start_instance` (which calls `boot_vm`) fails, the entire chain stops. The error is reported as coming from "VM spawn failure" rather than "vm.boot call failure."

**Better approach**: Catch and log the endpoint name in the error handler.

### 3. Misleading Success of vm.create

The `vm.create` call ALWAYS succeeded (HTTP 204). This masked the real issue because the payload structure was correct. Investigation repeatedly cycled back to "the payload is fine, what else could be wrong?"

**Better approach**: Direct API testing (as done in step 5) to isolate which call actually fails.

### 4. Cloud Hypervisor Verbose Logs Didn't Help

CH's verbose output showed:
```
VmConfig parsed successfully: {...all fields...}
```

This was good for confirming the payload was valid, but it masked that vm.boot would immediately fail. CH logs don't show the actual http response codes for API calls.

**Better approach**: Add per-endpoint logging to the client to track success/failure of each API call independently.

### 5. Multiple Concurrent Issues

The investigation was complicated by layering:
- Stale code deployment (pre-virtio-fs migration)
- Missing infrastructure (BTRFS rootfs not present)
- The actual bug (empty body on body-less endpoints)

Fixing each layer revealed the next problem. If all three issues were present simultaneously on day 1, the investigation would have been much faster once the underlying pattern was identified.

### 6. HTTP Semantics Not Validated During Hypervisor Migration

When Cloud Hypervisor was integrated into Mjolnir (commit 9874294), the client implementation followed the Firecracker pattern of passing `%{}` to body-less endpoints. This worked with Firecracker's permissive API but broke with Cloud Hypervisor's stricter API. The difference was never caught because:

- Unit tests don't actually run the hypervisor API calls
- Integration tests weren't run during the CH migration (would need KVM + root)
- The migration was not tested on a real server until day 1

**Better approach**: Add integration tests that exercise each API call individually, with a mock hypervisor if needed.

---

## Lessons Learned & Preventive Measures

### 1. Log Endpoint Identity in HTTP Errors

**Problem**: Generic "API error: 400" doesn't identify which endpoint failed.

**Solution**: Include method and path in error logs.

```elixir
Logger.error("Cloud Hypervisor API error: #{status} #{method} #{path}")
# Instead of just:
Logger.error("Cloud Hypervisor API error: #{status}")
```

### 2. Test API Calls Independently During Integration Debugging

**Problem**: Trying to debug via the full VM boot sequence masks which specific API call fails.

**Solution**: When debugging hypervisor issues, write end-to-end shell scripts that isolate each API call:

```bash
#!/bin/bash
# Test each endpoint independently
echo "=== vm.create ==="
curl -X PUT --unix-socket $SOCKET http://localhost/api/v1/vm.create \
  -H "Content-Type: application/json" \
  -d '{...full config...}' && echo "✓" || echo "✗"

echo "=== vm.boot ==="
curl -X PUT --unix-socket $SOCKET http://localhost/api/v1/vm.boot && echo "✓" || echo "✗"

echo "=== vm.pause ==="
curl -X PUT --unix-socket $SOCKET http://localhost/api/v1/vm.pause && echo "✓" || echo "✗"
```

This immediately identifies which call is failing.

### 3. Don't Assume Empty JSON is "No Body"

**Problem**: Passed `%{}` as a "no-op body" placeholder, assuming HTTP libraries would treat it the same as no body.

**Solution**: Consult API documentation for each endpoint's body requirements:

- `vm.create`: REQUIRES body (full config)
- `vm.resize`: REQUIRES body (resize spec)
- `vm.boot`, `vm.pause`, `vm.resume`, `vm.shutdown`, `vm.delete`: MUST NOT have body

Use `nil` explicitly for body-less endpoints.

### 4. Validate API Behavior Against Spec During Hypervisor Integration

**Problem**: Integrated Cloud Hypervisor client without verifying that the implementation matched the API spec.

**Solution**: Create a validation test that confirms:
- Each endpoint accepts/rejects bodies as specified
- Response codes match spec
- All required fields are included in payloads

Run this before integration testing.

### 5. Add Per-Endpoint Logging in HTTP Clients

**Problem**: The error handler doesn't know which endpoint failed.

**Solution**: Log success/failure at the `curl_request` level with endpoint info:

```elixir
defp curl_request(method, socket_path, path, body) do
  # ... curl call ...
  case result do
    {status_str, 0} ->
      status = String.to_integer(String.trim(status_str))
      if status in 200..299 do
        Logger.debug("#{method} #{path} → #{status}")
        :ok
      else
        Logger.error("#{method} #{path} → #{status}")
        # ...
      end
    {output, code} ->
      Logger.error("#{method} #{path} curl failed: #{output}")
  end
end
```

### 6. Document Hypervisor API Quirks in Code

**Problem**: The Cloud Hypervisor v50 body requirement quirk wasn't documented.

**Solution**: Add docstrings and comments:

```elixir
@doc """
Boot the VM (start instance).

Cloud Hypervisor v50 strictly rejects requests with a body on this endpoint,
even an empty JSON object. Pass nil as the body, not %{}.
See: Cloud Hypervisor v50 REST API spec, vm.boot endpoint.
"""
def boot_vm(socket_path) do
  put(socket_path, "/api/v1/vm.boot", nil)
end
```

### 7. Isolate Multi-Step Processes with Better Error Context

**Problem**: The `with` chain in `VM.do_boot/1` hides which step failed.

**Solution**: Either wrap each step with descriptive logging, or restructure to identify failures clearly:

```elixir
case configure_vm(hypervisor, socket_path, config) do
  :ok ->
    Logger.debug("VM #{state.id}: vm.create succeeded")
  {:error, reason} ->
    Logger.error("VM #{state.id}: vm.create failed: #{inspect(reason)}")
    {:error, {:vm_create_failed, reason}}
end

case hypervisor.start_instance(socket_path) do
  :ok ->
    Logger.debug("VM #{state.id}: vm.boot succeeded")
  {:error, reason} ->
    Logger.error("VM #{state.id}: vm.boot failed: #{inspect(reason)}")
    {:error, {:vm_boot_failed, reason}}
end
```

---

## Changes Made

### Code Changes

**File**: `/Users/dukejones/work/Mjolnir/mjolnir/lib/mjolnir/cloud_hypervisor/client.ex`

Changed 5 API endpoint calls from `%{}` to `nil`:

```elixir
# Before
def boot_vm(socket_path) do
  put(socket_path, "/api/v1/vm.boot", %{})
end

# After
def boot_vm(socket_path) do
  put(socket_path, "/api/v1/vm.boot", nil)
end
```

Applied to all 5 body-less endpoints:
- `boot_vm/1`
- `pause_vm/1`
- `resume_vm/1`
- `shutdown_vm/1`
- `delete_vm/1`

Added docstring clarification to `boot_vm/1` documenting the Cloud Hypervisor v50 API quirk.

Changed debug logging level:
- `Logger.info` → `Logger.debug` for the vm.create payload logging (lines 32)

Verified the implementation correctly handles `nil` bodies in the `request/4` function:
```elixir
json_body = if body, do: Jason.encode!(body), else: nil
# This correctly produces nil when body is nil, or encoded JSON when body is a map
```

### Configuration Changes

**File**: `/Users/dukejones/work/Mjolnir/mjolnir/lib/mjolnir/hypervisor/cloud_hypervisor.ex`

Removed debug `-v` flag from Cloud Hypervisor startup args (line 34-38). The verbose logging was helpful for debugging but adds overhead in production.

**Before**:
```elixir
args = [
  "--api-socket", socket_path,
  "-v",  # Debug verbose logging
  "--log-file", "/tmp/cloud-hypervisor-#{vm_id}.log"
]
```

**After**:
```elixir
args = [
  "--api-socket", socket_path,
  "--log-file", "/tmp/cloud-hypervisor-#{vm_id}.log"
]
```

### Documentation Changes

**File**: `/Users/dukejones/work/Mjolnir/mjolnir/CLAUDE.md`

Updated the "Current Status & Known Issues" section:
- Removed the "Open issue: Cloud Hypervisor `vm.create` returns 400 Bad Request" entry (it was actually `vm.boot`)
- Updated the hypervisor implementation notes to document the Cloud Hypervisor v50 API behavior regarding request bodies

---

## Testing Verification

After the fix was applied:

**VM Spawn Test**:
```bash
$ just vm-spawn
Spawning VM...
VM spawned successfully: abc123def456...
```

**Command Execution Test**:
```bash
$ just vm-exec abc123def456 "uname -a"
Linux mjolnir-guest 6.x.x-x86_64 #1 SMP ... GNU/Linux
```

**Snapshot Test**:
```bash
$ just snap-create abc123def456 test-snap
Snapshot created: test-snap
```

**Integration**: All existing unit tests pass, and manual integration tests confirm full VM lifecycle operations (spawn → exec → snapshot → restore) work correctly.

---

## Conclusion

This incident revealed the importance of:

1. **Isolating API calls** during hypervisor debugging rather than debugging through the entire VM boot sequence
2. **Consulting API specs** when integrating new hypervisors, especially regarding HTTP request semantics
3. **Explicit endpoint logging** in HTTP clients to identify which call fails
4. **Testing on real infrastructure** early, not just unit tests
5. **Documenting API quirks** in code comments to prevent regression

The fix was trivial (5 one-line changes) once the root cause was identified, but the investigation required systematic testing to distinguish between:
- Stale deployments (code issue)
- Missing infrastructure (BTRFS setup issue)
- HTTP semantics (API compatibility issue)

All three issues needed fixing to restore functionality, and identifying the third required directly testing the API calls outside the application context.
