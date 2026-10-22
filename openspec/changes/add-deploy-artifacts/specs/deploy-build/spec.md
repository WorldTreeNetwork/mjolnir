## ADDED Requirements

### Requirement: Steps copy declared artifacts into the release

A manifest step MAY declare `artifacts`, a list of `"<src>:<dest>"`
strings. After the step succeeds and before its layer is snapshotted,
the builder SHALL copy each `src` (relative to `/app`, or absolute,
including under `/cache/`) to `dest` in the layer. A missing `src` SHALL
fail the step and name the path. Deploy progress SHALL print each copied
artifact with its size, and the release snapshot's size.

#### Scenario: Binary copied out of the cache

- GIVEN `cargo-target` is mounted at `/cache/cargo-target`
- AND the build step declares `artifacts = ["/cache/cargo-target/release/app:/app/bin/"]`
- WHEN the step succeeds
- THEN `/app/bin/app` exists in the release snapshot
- AND nothing under `/cache/` is in the release snapshot

#### Scenario: Missing artifact

- GIVEN a step declares an artifact whose `src` the build did not create
- WHEN the step finishes
- THEN the build fails at that step naming the missing path
- AND no cutover happens
