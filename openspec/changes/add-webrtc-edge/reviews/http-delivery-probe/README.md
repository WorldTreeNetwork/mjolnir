# HTTP/1 delivery mechanism probe

See [the assessment](../2026-11-27-http-delivery-design.md). Dummy resources only; no production integration, sockets, or credentials.

From repository root:

```sh
cargo test --offline --locked --manifest-path openspec/changes/add-webrtc-edge/reviews/http-delivery-probe/Cargo.toml -j 1 -- --nocapture --test-threads=1
```

Hyper is pinned to 1.12.0. The dev profile disables debug information. Build output stays in the ignored local `target/` directory. The counters simulate pending cancellation and committed ownership; they do not simulate actual RTC handshake, expiry, or pool races.
