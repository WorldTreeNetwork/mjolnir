# HTTP/1 local-acceptance adapter

Product change on top of `64582cac`. The edge listener is `hyper` HTTP/1 (`pipeline_flush(false)`). Body EOF only marks the SDP serialized. `DeliveryIo::poll_flush` acknowledges a ticket when the underlying flush returns `Ready(Ok(()))`. That is local transport acceptance, not peer receipt. Failure or drop cancels pending candidates. `ack_delivery` starts `Response::run` only inside the pool lock after drain, generation, token expiry, the original setup deadline, and relay liveness all pass. HTTP/2 is not enabled on this builder.

## Focused tests

Framework `dorje@100.121.90.25`, tree `/tmp/mj13-c2` (rsync of this change, not the dirty checkout). `rustc` via `cargo +1.95.0`.

```
cd /tmp/mj13-c2/native/mjolnir_relay
MISE_DISABLE=1 cargo +1.95.0 test --offline --locked --lib -- --test-threads=8
```

Result: `31 passed; 0 failed; finished in 2.08s`.

The new cases drive `edge_http::serve_connection` (the production accept path):

- partial 17-byte writes, then close after a successful flush: candidate stays, `runner_count` stays 0 on the test-dial park (no `Response` to spawn)
- write failure, partial-then-BrokenPipe, flush failure, `WriteZero`, and stall/drop: incumbent remains, candidate does not
- two pipelined 201s, second flush fails once both status lines are buffered: first session stays, second does not
- oneshot `collect` without `DeliveryContext`: 503, session 0, runner 0 (comparison seam, not delivery)
- deadline already past at the held flush: no runner, session finished
- stale generation at ack does not remove the replacement

## TLS

```
MISE_DISABLE=1 cargo +1.95.0 test --offline --locked --test edge_tls -- --test-threads=1
```

`verified_root_dials_and_a_foreign_root_does_not ... ok` in 0.43s.

## Not this run

Mint-issued browser playback and the Ubuntu 24.04 release build of this hash are not claimed here. Historical `reproduce-4169315` and `reproduce-cb1481c` scripts stay pinned to those hashes.
