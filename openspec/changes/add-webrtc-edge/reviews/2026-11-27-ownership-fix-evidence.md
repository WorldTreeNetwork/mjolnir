# Ownership fix evidence (review 40c42a3f of cb1481c2)

Framework `dorje@100.121.90.25`, rustc/cargo 1.95.0, `MISE_DISABLE=1`, `--offline -j 1`. No deploy. Host relay left running.

## Fixed sources

`native/mjolnir_relay/src/edge.rs` sha256 `86c4f7745d73f71204518e99e06cbaa4afc96ffae05d03a874b8b23433243eed`
`native/mjolnir_relay/src/moq_session.rs` sha256 `6c6d75e31a2e15e48b098ad7a1fb3d550e4e2485450582dfe1d74770cd51e6ca`
`native/mjolnir_relay/tests/edge_tls.rs` sha256 `8a559c49707d88c107c0597d6b599b0e474b42611e55c88e8bd8ff4f91dee666`

Copied to `/tmp/mj13-own` with the Mac `native/vendor/moq-webrtc` (the Framework checkout vendor does not export `Keyframes`). An accidental rsync through a symlink dirtied `native/vendor/moq-webrtc/src/lib.rs` on that checkout; it was restored with `git checkout --` that one file.

## edge_tls on the fixed sources

```
cd /tmp/mj13-own/mjolnir_relay
cargo +1.95.0 test --offline --locked --test edge_tls -j 1 --target-dir /tmp/mj13-own-tgt -- --test-threads=1
```

Exit 0. `verified_root_dials_and_a_foreign_root_does_not` ok (0.44s).

Same command on a `git archive` of `cb1481c27d30a3773368c4f8baefd4a70e4b7fae` at `/tmp/mj13-red` exited 101: `error[E0382]: borrow of moved value: url` at `tests/edge_tls.rs:108` after `relay: url` at line 92.

## Lib tests on the fixed sources

```
cargo +1.95.0 test --offline --locked --lib -j 1 --target-dir /tmp/mj13-own-tgt -- --test-threads=1
```

Exit 0. 28 passed, 0 failed, 1.12s. Includes `configured_origins_are_an_exact_list`, `drain_during_dial_does_not_register`, `stale_generation_cleanup_leaves_the_replacement`, `last_release_closes_the_real_relay_connection`.

## Review probes

`reproduce-cb1481c.rs` appended to `src/edge.rs`, plus str0m/rind-str0m/hyper/hyper-util on the crate, then:

```
cargo +1.95.0 test --offline --lib edge::independent_review -j 1 -- --test-threads=1 --nocapture
```

Red, `/tmp/mj13-red`, archive of cb1481c2, target `/tmp/mj13-red-tgt`: exit 0, 15 passed, 41.08s. Defect lines printed for the live link, the post-drain registration, the origin allowlist, and `WRITE FAILURE actual Hyper=Err(hyper::Error(BodyWrite, Kind(BrokenPipe))); refs=2 sessions=2 runners=2`.

Green, `/tmp/mj13-probe` copy of the fixed tree, target `/tmp/mj13-probe-tgt`: exit 101, 12 passed, 3 failed, 41.13s. Failures are the three defect characterizations that the fix removes:

- `defect_last_release_retains_real_connection_and_redial_overlaps` panicked `characterizes retained live link`
- `defect_drain_allows_pending_dial_to_publish` panicked `characterizes post-drain success`
- `defect_configured_origin_list_still_allows_unlisted_same_host` panicked on `origin_allowed(..., "http://edge.test", "edge.test")`

`defect_http_write_failure_after_body_eof_leaks_candidate` still passed: `refs=2 sessions=2 runners=2` beside the incumbent, `hyper::Error(BodyWrite, Kind(BrokenPipe))`.

Regressions that stayed green on the fixed tree include `prior_real_natural_runner_cleanup_and_cap` (answer contains `b=TIAS:2250000`), `prior_real_absent_source_is_now_409`, expiry isolation of the other token, relay-death cleanup, and HTTP disconnect leaving the incumbent at refs=1.

## C2 blocker (not fixed)

hyper 1.12.0 `proto/h1/dispatch.rs` `poll_write` polls `Body::poll_frame` until the SDP is buffered (`can_buffer_body` is true for this body), and `QueuedBody` reaches EOF in that poll. `poll_loop` calls `poll_flush` only after `poll_write` returns. The `FailedWire` probe returns `BrokenPipe` from `poll_write` on the socket, which is `BodyWrite` after the body has already yielded EOF. `http_body::Body` has no write-completion or cancellation callback. `BodyExt::collect` (the successful runner test) polls that same EOF. Disarming `RunGuard` only on `Drop` aborts the runner that `prior_real_natural_runner_cleanup_and_cap` requires to stay up. The body cannot tell those two poll sequences apart, and the probe drives `hyper::server::conn::http1::Builder::serve_connection` around `router.oneshot`, so a custom accept loop would not change the probe.

## Not run

No new Ubuntu 24.04 release. Image `ubuntu:24.04` `sha256:562111b88caa79c71391c0c4d3c2114a7d5c35915c20561fd893cb1e07929e6b` is present. `/opt/rust-1.95/bin/cargo` from the earlier container is not. No Chromium playback on this hash. The cb1481c2 playback and Ubuntu binary hashes are not this tree.
