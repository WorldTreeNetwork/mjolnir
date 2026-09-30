# Tasks

- [ ] `Deploy.Manifest` parses `build = { vcpus, memory_mb }` (positive integers; other keys refused)
- [ ] Host config `deploy_build_vcpus` / `deploy_build_memory_mb` (defaults 4 / 4096) and `deploy_build_max_vcpus` / `deploy_build_max_memory_mb`
- [ ] `build_opts/3` passes both `vcpus` and `memory_mb` to the build VM spawn; service VM sizing untouched
- [ ] Progress prints the build VM size, and any clamp
- [ ] `vsock_unavailable` during a build step is reported with the VM's size and the manifest key to raise
- [ ] Tests: manifest value wins over host default; ceiling clamps; service VM memory unaffected; diagnostic text on agent loss
