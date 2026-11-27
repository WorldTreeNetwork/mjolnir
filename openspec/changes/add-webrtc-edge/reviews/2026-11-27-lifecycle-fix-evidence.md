# Lifecycle fix evidence — after 952f09a5 send-back

Product changes answer N1–N5 in `2026-11-27-code-review-952f09a.md`. The flush commit (successful `poll_flush` starts a real runner; a failed flush does not) is unchanged. This note is the unit run of the corrected sources. It is not a Mint.issue playback run and not an Ubuntu rebuild of the new commit.

## What the tests lock

- A past monotonic setup bound with an unexpired token returns `SetupFailed` and leaves the same-token incumbent and the other token in place (`preexpiry_deadline_does_not_drop_incumbents`).
- With tokio time paused, advancing the original five-second bound finishes a held HTTP/1 flush and drops only the candidate (`paused_setup_bound_cancels_only_the_candidate_and_the_http_task`).
- DELETE while the test double holds `poll_write` or `poll_flush` ends that connection task without the test aborting it. The incumbent and the other token stay (`invalidated_pending_wakes_held_write_and_flush_without_abort`).
- Ack that first observes `exp_unix == 0` detaches that token generation and terminates the held HTTP task. The other token's session remains (`ack_expiry_removes_the_token_and_leaves_the_other`).
- The retire probe runs while the pool mutex is still held, before the link is removed (`last_release_aborts_before_the_slot_is_reusable`). `shared.close()` is called in that same locked section. This is lock-order evidence, not a second live QUIC handshake observed in the overlap.
- Four pipelined 201s on one keepalive leave `OPEN_TICKETS == 0` while the connection is still up (`settled_tickets_do_not_accumulate_on_a_keepalive`).

These HTTP doubles are in-process `serve_connection` plus test-dial (`response: None`), except where an existing test already closes a real relay link (`last_release_closes_the_real_relay_connection`, still passing). They are not browser playback.

## Command

Framework (Arch, `dorje@100.121.90.25`), rustc 1.95.0, sources copied from git archive `952f09a59a899d71e27635099760dcde5bd483bf` at `/tmp/mj13-952` into `/tmp/mj13-fix`, then `edge.rs` and `edge_http.rs` overlaid. `CARGO_TARGET_DIR=/tmp/mj13-fix-tgt`. The 952f09a5 release binaries and `/tmp/mj13-952-tgt` were not overwritten.

```bash
cd /tmp/mj13-fix/native/mjolnir_relay
MISE_DISABLE=1 CARGO_TARGET_DIR=/tmp/mj13-fix-tgt \
  cargo +1.95.0 test --offline --lib -- --test-threads=8
```

Result: `37 passed; 0 failed; 0 ignored` in 0.40s (`Finished test profile` reused the fix target).

```bash
MISE_DISABLE=1 CARGO_TARGET_DIR=/tmp/mj13-fix-tgt \
  cargo +1.95.0 test --offline --test edge_tls -- --test-threads=1
```

Result: `verified_root_dials_and_a_foreign_root_does_not` ok. 1 passed, 0.45s. Baseline Ubuntu ELF hashes from the 952f09a5 container compile stay:

- edge `0a5005a0ab18f38e3161226f2ab48f73a6d08fefdbecb2423628672b18cd4c98`
- relay `4d52b90c29376c40aa992f24421b435c0b633fb31831d02bb556b1c6aa592491`

Those binaries are the pre-fix tree. Arch release of 952f09a5 remains edge `ffede246f8fbe9e8506b8c6839f5a97052dccc5e414f50eadc9bcc3791c480bf`, relay `143c8c0d45a7adf34bb1bc60c77f33cd9abb68ac04121bac2496cb9eaa73829b`.
