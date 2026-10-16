# Tasks

- [x] `Deploy.Manifest` accepts a step as a string or `{ run, inputs }`; any other key or shape is refused with the step's index
- [x] `CacheKey.hash_globs/2`: sorted relative paths + contents of the files matching `inputs`; an empty list hashes to a fixed "no inputs" value
- [x] `plan_to_steps/3` keys table steps on `hash_globs` and copies only the matched files into `/app`; `inputs = []` copies nothing
- [x] String steps unchanged: whole-tree key, `cp -a` prelude
- [x] Progress reports each layer as hit or miss, with a reason
- [x] Tests: command-only step hits after a source edit; glob step misses only when a matched file changes; string step still misses on any edit; malformed step refused before boot
- [x] The `mjolnir.toml` reference (the `Deploy.Manifest` module doc; there is no docs/ page) shows `inputs = []` for an apt step and `inputs = ["web/**"]` for a web step
- [x] Store command and input digests in each `deploy-*` snapshot's metadata and compare parent-step metadata to report `command`, `inputs`, or `parent`, including string-step command changes
- [x] Copy table-step inputs from a NUL-delimited file list on a temporary mount, keeping the exec command under 64 KB; test a 5,000-file glob and selective copying (`mjolnir-08e`)
