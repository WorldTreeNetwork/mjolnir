# Iroh Shell Phase 2 — Todo List

**Started:** 2026-01-28
**Completed:** 2026-01-28
**Status:** Complete

---

## Tasks

- [x] 2.1: Measure baseline binary size
- [x] 2.2: Add iroh-net to Cargo.toml
- [x] 2.3: Extract vsock module
- [x] 2.4: Implement keypair load/generate
- [x] 2.5: Implement PTY module
- [x] 2.6: Implement Iroh endpoint setup
- [x] 2.7: Implement shell connection handler
- [x] 2.8: Implement iroh_ready vsock notification
- [x] 2.9: Update Elixir protocol module
- [x] 2.10: Update VM.ex for shell state
- [x] 2.11: Add VM shell API
- [x] 2.12: Integration tests & documentation

---

## Progress Log

| Time | Task | Status | Notes |
|------|------|--------|-------|
| 2026-01-28 21:41 | 2.1 | complete | Baseline: 1.4 MB |
| 2026-01-28 21:46 | 2.2 | complete | iroh 0.96, nix 0.29 added |
| 2026-01-28 21:54 | 2.3 | complete | protocol.rs, vsock.rs extracted |
| 2026-01-28 22:19 | 2.4-2.8 | complete | Rust side done, 3 PTY tests pass |
| 2026-01-28 22:30 | 2.9-2.11 | complete | Elixir protocol + VM API done |
| 2026-01-28 22:35 | 2.12 | complete | Tests + docs updated |

---

## Binary Size Tracking

| Stage | Size | Delta |
|-------|------|-------|
| Baseline (no iroh) | 1.4 MB (1,413,296 bytes) | - |
| With iroh deps (unused) | 1.4 MB (1,437,704 bytes) | +24 KB |
| With iroh used | 24 MB (23,821,144 bytes) | +22.4 MB |

