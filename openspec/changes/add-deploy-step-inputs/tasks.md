# Tasks

- [x] `Deploy.Manifest` accepts a step as a string or `{ run, inputs }`; any other key or shape is refused with the step's index
- [x] `CacheKey.hash_globs/2`: sorted relative paths + contents of the files matching `inputs`; an empty list hashes to a fixed "no inputs" value
- [x] `plan_to_steps/3` keys table steps on `hash_globs` and copies only the matched files into `/app`; `inputs = []` copies nothing
- [x] String steps unchanged: whole-tree key, `cp -a` prelude
- [x] Progress reports each layer as hit or miss, with a reason
- [x] Tests: command-only step hits after a source edit; glob step misses only when a matched file changes; string step still misses on any edit; malformed step refused before boot
- [x] The `mjolnir.toml` reference (the `Deploy.Manifest` module doc; there is no docs/ page) shows `inputs = []` for an apt step and `inputs = ["web/**"]` for a web step
- [ ] Miss cause is inferred today: a layer key is one hash, so `command` vs `inputs` cannot be told apart (a changed string-step command is reported as `inputs`). Store the command and input digests in each `deploy-*` snapshot's metadata and compare, or narrow the spec to `parent` vs `this step`
- [ ] Table-step prelude emits one `mkdir`/`cp` per matched file inside the exec command; a large glob can exceed the 64 KB vsock frame (`mjolnir-08e`). Copy from a file list (or tar) instead of inlining paths, with a test for a 5,000-file glob
