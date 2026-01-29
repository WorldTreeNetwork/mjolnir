# Iroh Shell Phase 2 — Todo List

**Started:** 2026-01-28
**Status:** In Progress

---

## Tasks

- [x] 2.1: Measure baseline binary size
- [x] 2.2: Add iroh-net to Cargo.toml
- [ ] 2.3: Extract vsock module
- [ ] 2.4: Implement keypair load/generate
- [ ] 2.5: Implement PTY module
- [ ] 2.6: Implement Iroh endpoint setup
- [ ] 2.7: Implement shell connection handler
- [ ] 2.8: Implement iroh_ready vsock notification
- [ ] 2.9: Update Elixir protocol module
- [ ] 2.10: Update VM.ex for shell state
- [ ] 2.11: Add VM shell API
- [ ] 2.12: Integration tests & documentation

---

## Progress Log

| Time | Task | Status | Notes |
|------|------|--------|-------|
| 2026-01-28 21:41 | 2.1 | complete | Baseline: 1.4 MB |
| 2026-01-28 21:46 | 2.2 | complete | iroh 0.96, nix 0.29 added |

---

## Binary Size Tracking

| Stage | Size | Delta |
|-------|------|-------|
| Baseline (no iroh) | 1.4 MB (1,413,296 bytes) | - |
| With iroh deps (unused) | 1.4 MB (1,437,704 bytes) | +24 KB |
| With iroh used | TBD | TBD |

