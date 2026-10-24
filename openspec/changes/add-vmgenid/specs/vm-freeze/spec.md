## MODIFIED Requirements

### Requirement: Thaw restores the same VM id
<!-- base: fe70713db379ef0087e055fd468af04db9286cff openspec/specs/vm-freeze/spec.md -->
The system SHALL expose `POST /api/snapshots/:name/thaw` that restores a
memory snapshot. When the `source_vm_id` recorded at freeze is not running,
thaw SHALL restore that same id. When that id is already live, thaw SHALL
start a second guest from the same memory image. The second guest SHALL
have a new VM id, a new vsock CID, a new virtiofsd socket, and a new TAP
name. That socket SHALL serve a clone of the pinned rootfs, not the first
guest's daemon. Guest IP, MAC, and Iroh key SHALL stay the captured values.
The second guest SHALL be reachable over its own vsock after
`Entropy.reseed`. It SHALL NOT be published on the gateway and SHALL NOT
receive a connection ticket while those captured identities would collide
with the first guest. The first guest SHALL stay running and published.
A failed second thaw SHALL leave the first guest running. Entropy SHALL
be reseeded before the first guest is reachable (PTY, ticket, gateway).

#### Scenario: Thaw brings the same VM back
- GIVEN a memory snapshot whose source VM is not running
- WHEN `POST /api/snapshots/:name/thaw`
- THEN a VM with the original id is running
- AND entropy has been reseeded before the VM is reachable (PTY, ticket,
  gateway)

#### Scenario: A second thaw starts another guest
- GIVEN a memory snapshot whose source VM id is already running
- WHEN thaw is requested
- THEN a second VM is running
- AND that VM's id, vsock CID, virtiofsd socket, and TAP name differ from the first guest
- AND its virtiofsd serves a clone of the pinned rootfs
- AND the second guest is reachable over vsock only after `Entropy.reseed`
- AND the second guest has no gateway route and no connection ticket
- AND the first guest is still running and published

#### Scenario: Thaw refuses a filesystem snapshot
- GIVEN a filesystem-only snapshot
- WHEN thaw is requested
- THEN the response is 400 naming spawn-from-snapshot as the filesystem path

## ADDED Requirements

### Requirement: Thaw reseeds the kernel CRNG from VM Generation ID
A thaw SHALL boot a hypervisor that exposes VM Generation ID. A memory snapshot SHALL record whether the captured guest kernel was built with `CONFIG_VMGENID`. Replacing the host kernel file SHALL NOT change that record.

When the record says the captured kernel has `CONFIG_VMGENID`, the generation id SHALL change on thaw. The guest SHALL observe that change. A `/dev/urandom` sample taken after `Entropy.reseed` SHALL NOT count as that observation. The thaw SHALL NOT be published if the observation is missing. The kernel reseed SHALL NOT be claimed to reset userspace PRNGs.

When the record is absent or says the captured kernel lacks `CONFIG_VMGENID`, thaw SHALL continue under `Entropy.reseed`, SHALL NOT report a generation-id change, and SHALL leave the image on disk.

`Entropy.reseed` SHALL still complete before a guest is reachable over vsock. It SHALL NOT be treated as proof that the VM Generation ID driver ran.

#### Scenario: A VMGENID capture changes the generation id
- GIVEN a memory snapshot whose record says the captured kernel has `CONFIG_VMGENID`
- WHEN that snapshot is thawed
- THEN the guest observes a generation id different from the id at capture
- AND that observation is not a `/dev/urandom` sample taken after `Entropy.reseed`
- AND the VM is not published if that observation is missing

#### Scenario: A legacy image stays thawable
- GIVEN a memory snapshot with no VMGENID capture record
- WHEN that snapshot is thawed
- THEN the thaw is not refused for lack of VMGENID
- AND the image is still present
- AND the result does not claim a generation-id change
- AND the guest is not reachable over vsock until `Entropy.reseed` has completed

#### Scenario: Two VMGENID guests see different generation ids
- GIVEN one memory snapshot recorded as `CONFIG_VMGENID` and a guest already running from it
- WHEN a second thaw of that snapshot is running
- THEN the two guests observe different generation ids
