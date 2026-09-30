## ADDED Requirements

### Requirement: Build steps are content-addressed layers

The deploy builder SHALL run each build step in order on one ephemeral
build VM and snapshot the result to `deploy-<key>`, where `key` is
SHA-256 over the parent layer key, the step command, and the step's
input hash. The first step's parent is the base image. When every layer
key already exists, the builder SHALL boot no VM and SHALL reuse the
existing release snapshot. When some exist, it SHALL resume from the
deepest cached layer and run only the remaining steps.

#### Scenario: Full hit boots nothing

- GIVEN every layer key for the app's steps exists under `@snapshots/`
- WHEN the operator deploys
- THEN no build VM boots
- AND the service starts from the existing release snapshot

#### Scenario: Resume from the deepest hit

- GIVEN layers 1 and 2 exist and layer 3's key does not
- WHEN the operator deploys
- THEN the build VM boots from layer 2
- AND only steps 3 and later run

### Requirement: A step declares the inputs it is keyed on

A manifest step SHALL be either a string or a table `{ run, inputs }`.
For a table step, the input hash SHALL be computed over the sorted
relative paths and contents of the files under the source root that match
`inputs`, and only those files SHALL be copied into `/app` before the
step runs. `inputs = []` SHALL key the step on its command alone and copy
no source. A string step SHALL be keyed on the whole source tree and
receive a full copy, as before. A table with keys other than `run` and
`inputs`, or `inputs` that is not a list of strings, SHALL be refused
before any VM boots, naming the step.

#### Scenario: Command-only step survives a source edit

- GIVEN step 1 is `{ run = "apt-get install -y git", inputs = [] }`
- AND its layer exists
- WHEN only `src/main.rs` changes and the operator deploys
- THEN step 1 is a cache hit

#### Scenario: Glob step misses only on its files

- GIVEN a step with `inputs = ["web/**"]`
- WHEN a file outside `web/` changes
- THEN that step's key is unchanged
- WHEN a file under `web/` changes
- THEN that step and every later step miss

#### Scenario: String step keeps whole-tree keying

- GIVEN a string step
- WHEN any source file changes
- THEN that step and every later step miss

#### Scenario: Malformed step is refused early

- GIVEN a step `{ run = "make", input = ["x"] }`
- WHEN the operator deploys
- THEN the deploy fails before a VM boots
- AND the error names step 1 and the unknown key `input`

### Requirement: Deploy progress explains each layer

`mj deploy` progress SHALL list every layer as `hit` or `miss`. A miss
SHALL name its first cause: `command`, `inputs`, or `parent`.

#### Scenario: Parent miss is reported as such

- GIVEN step 1 misses because its inputs changed
- WHEN step 2's own command and inputs are unchanged
- THEN step 2 is reported as `miss (parent)`
