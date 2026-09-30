# Tasks

- [ ] `Deploy.Manifest` accepts a step as a string or `{ run, inputs }`; any other key or shape is refused with the step's index
- [ ] `CacheKey.hash_globs/2`: sorted relative paths + contents of the files matching `inputs`; an empty list hashes to a fixed "no inputs" value
- [ ] `plan_to_steps/3` keys table steps on `hash_globs` and copies only the matched files into `/app`; `inputs = []` copies nothing
- [ ] String steps unchanged: whole-tree key, `cp -a` prelude
- [ ] Progress reports each layer as hit or miss, with the reason
- [ ] Tests: command-only step hits after a source edit; glob step misses only when a matched file changes; string step still misses on any edit; malformed step refused before boot
- [ ] identikey's `mjolnir.toml` example in `docs/` shows `inputs = []` for apt and `inputs = ["web/**"]` for the web step
