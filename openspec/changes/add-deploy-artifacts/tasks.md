# Tasks

- [ ] `Deploy.Manifest`: step `artifacts = ["src:dest", …]` (strings with exactly one `:`; refuse otherwise)
- [ ] After a step with `artifacts` succeeds, copy each `src` to `dest` before snapshotting the layer; a missing `src` fails the step naming the path
- [ ] Progress prints each artifact with size, and the release snapshot size
- [ ] Tests: artifact from `/cache/…` lands in the release; missing artifact fails before cutover; steps without `artifacts` unchanged
- [ ] Example in `docs/`: identikey with `cargo-target` cache, `artifacts = ["/cache/cargo-target/release/identikey-server:/app/bin/"]`, `start_command = "/app/bin/identikey-server"`
