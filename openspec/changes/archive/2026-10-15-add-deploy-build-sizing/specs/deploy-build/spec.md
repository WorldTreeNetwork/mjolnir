## ADDED Requirements

### Requirement: The build VM is sized separately from the service VM

The deploy builder SHALL size the build VM from the manifest's
`build = { vcpus, memory_mb }` when present, else from the host's
`deploy_build_vcpus` and `deploy_build_memory_mb`, clamped to the host's
`deploy_build_max_vcpus` and `deploy_build_max_memory_mb`. These values
SHALL NOT affect the service VM. Deploy progress SHALL print the size
used and any clamp. When the build VM's agent stops responding during a
step, the failure SHALL state the VM's memory and name
`build.memory_mb`.

#### Scenario: Manifest asks for more

- GIVEN `build = { memory_mb = 8192 }` and a host max of 16384
- WHEN the operator deploys
- THEN the build VM has 8192 MB
- AND the service VM has the memory given by `--memory` or its own default

#### Scenario: Request above the ceiling

- GIVEN `build = { memory_mb = 65536 }` and a host max of 16384
- WHEN the operator deploys
- THEN the build VM has 16384 MB
- AND progress says the request was clamped to the host max

#### Scenario: Build VM runs out of memory

- GIVEN a build step exhausts the build VM's memory
- WHEN its agent stops responding
- THEN the deploy fails at stage `build`
- AND the message states the VM's memory and suggests raising `build.memory_mb`
