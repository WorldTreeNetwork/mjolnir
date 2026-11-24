---
spike_id: i7-upstream-rust-vectors
run_at: 2026-11-24
verdict: go
version-pinned: moq@4a6f522483168ace392718d68b58a402533c897d
---

# I7 — upstream Rust vectors repeated

Ran the upstream workspace package, not the scratch vector wrapper: `cargo test --offline --locked --manifest-path "$MOQ/Cargo.toml" -p moq-e2ee`, with the existing relay target cache. Verified checkout HEAD equals the full pin. Result: 51 unit tests (including the shared vector suites), 5 integration tests, and 2 compile-fail doc tests, **58 passed / 0 failed**. No code changes to upstream. Raw log: [i7-rust-vectors.log](logs/i7-rust-vectors.log). Disk before/after: 22/20 GiB available. This replaces the historical “not re-run” status for I7 only.
