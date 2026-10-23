## ADDED Requirements

### Requirement: Thaw reseeds the kernel CRNG from VM Generation ID
A thaw SHALL boot a hypervisor that exposes VM Generation ID and a guest kernel with `CONFIG_VMGENID`. The generation id SHALL change on that thaw. The guest kernel CRNG SHALL reseed from that change. `Entropy.reseed` SHALL still complete before the VM is reachable. The system SHALL keep refusing to fork a second running VM from the same memory image.

#### Scenario: Restore changes the generation id
- GIVEN a memory snapshot taken on a VMGenID-capable hypervisor
- WHEN that snapshot is thawed
- THEN the guest observes a generation id different from the id at capture
- AND the VM is not reachable until `Entropy.reseed` has completed

#### Scenario: Fork stays refused
- GIVEN one memory snapshot
- WHEN a second thaw is requested while the first thawed VM is running
- THEN the response is a refusal
- AND only one VM is running from that image
