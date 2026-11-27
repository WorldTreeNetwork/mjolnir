# Independent CODE re-review — cb1481c

**Code verdict: SEND-BACK.** Exact product: `cb1481c27d30a3773368c4f8baefd4a70e4b7fae`. Reviewed the full gateway implementation, the implementation delta since `4bcc87f43bb90ac4dd3d3830052be70af9539122`, the repair commit, accepted contract `7f9195cb` / advise-4, ADR 0020, living relay requirements, `.13` history, prior `2026-11-27-code-review-4169315.md`, and its nine probes. This independent reader did not author the product. No agents, product edits, deployment, remote workloads, closure or fold.

**Release readiness: not accepted.** No current-hash Mint-issued browser/media or Ubuntu build result is asserted here. The builder owns those concurrent evidence runs. Even successful results there would not waive the code defects below. **Gateway-dependent named-peer `.15` implementation must still wait for a green local `.13` slice.** Independent client contract/fixture preparation may proceed; the previously separated Ubuntu, roster and device gates remain separate.

## Required repairs

### C1 — P1: last release removes the index, not the live connection

`native/mjolnir_relay/src/edge.rs:762–777,979–997`; `native/mjolnir_relay/src/moq_session.rs:24–39`.

The relay-closure watcher owns a strong `Arc<Shared>` while awaiting `shared.closed()`. Removing `pool.links[token]` cannot drop the connection while this watcher owns it. The task also owns `Arc<Edge>` and the bearer string. No release/drain path explicitly closes or aborts the connection. The expiry timer similarly remains detached until expiry.

**Reproduced with a real ephemeral TLS relay:** acquire, retain only a `Weak<Shared>` observer, release the last reservation, wait 100 ms. `link_count()` is zero but upgrading the weak pointer still yields a connected `Shared`. Acquire again: `dials()` becomes two while the old generation remains connected. Drain still cannot reach that removed connection. This is a same-token old/new overlap, not a surviving other-token link or a strong reference introduced by the probe.

Smallest repair: explicitly terminate the removed connection generation, including on final release and drain, and cancel its watcher/timer ownership. The pinned `moq_tokio::Connection::abort(&self, Error)` already stops every clone and closes the session; expose an appropriate operation through `Shared`. Detach under the pool lock, perform teardown without awaiting under it, and make the watcher observe ownership without keeping an otherwise released generation alive. Verify real connection closure as well as map counts.

### C2 — P1: body EOF is not successful HTTP delivery

`edge.rs:1090–1152`, especially `QueuedBody::poll_frame` at 1118–1121.

The new guard fixes dropping an unconsumed response. It disarms when Hyper polls the body to EOF, before Hyper necessarily writes the buffered response. A write failure after that point has no owner to release the candidate. `queue_http` also starts the runner before constructing/handing back the response.

**Reproduced with actual production negotiation and Hyper's HTTP/1 serializer:** first fully consume an incumbent's answer. Send a second valid WHIP request through `serve_connection` with an `AsyncWrite` that deterministically returns `BrokenPipe`. Hyper returns `Err(BodyWrite, BrokenPipe)` without delivering an answer; edge counts remain **refs=2, sessions=2, runners=2**, rather than the incumbent's 1/1/1. This uses a failing transport implementation to make the real HTTP write error deterministic; it is not represented as a TCP reset experiment. A separate real loopback TCP test verifies successful delivery and disconnect during WHEP setup.

Smallest repair: retain the pending candidate's cancellation owner through the HTTP write outcome, and transfer to durable runner ownership only at the agreed queued/delivery boundary. Integrate the HTTP connection/service failure path; `Body::poll_frame(None)` alone is insufficient. On failure release only that candidate, preserving the incumbent. Keep both the now-passing unconsumed-body regression and this post-EOF write-failure regression.

### C3 — P1: drain does not invalidate an in-flight setup

`edge.rs:280–286,700–759,400–423,578–590`.

Drain marks the snapshot and enumerates only existing holds. An already-admitted request whose dial is pending has a flight but no hold, so drain misses it. `lead` can subsequently insert a hold/link; neither `finish_gate` nor `insert_session` checks drain. The next good key reload correctly leaves the drain flag set, but that does not fix an already-running setup.

**Controlled production-pool probe:** delay the test transport dial, start `open_session`, wait for the dial counter, drain, then finish the dial. Admissions are closed but setup succeeds with a registered session and link. The dial is simulated in this probe; pool/drain/registration code is the product's. The same absence of a drain check is present on the real negotiation path.

Smallest repair: invalidate/cancel flights and candidates as part of drain; recheck a drain/ownership epoch atomically when publishing the dial result and registering the session. A removed flight must not subsequently publish a result. Retain the distinction between key-health failure (old sessions survive) and drain (all connections stop).

### C4 — P1: generation checks and mutations are still separate critical sections

`edge.rs:400–423,578–590,842–875`.

This is a source-proven interleaving, not a claimed stress-test result. `drop_token_gen(token, g)` checks `g` under one lock, releases it, then calls `drop_token(token)`, which reads whichever generation exists now. Between those locks, final release can remove `g` and a new acquire can install `g+1`; the old watcher then drops **g+1**. `drop_token` also snapshots ids, releases the lock for per-id cleanup, and later removes the hold: a concurrent `insert_session` can insert an id after the snapshot and before removal, leaving an id without its hold. The production binary uses a multithreaded runtime, so these are real scheduling windows.

The final setup gate has the same gap: it validates the generation, unlocks, and later `insert_session` inserts unconditionally. A timer/drain/relay-close finalization between these steps can be followed by publication of an already-invalid session. Taking the expiry decision before the mutex fixed the reported recursive-lock case, but did not make these check/mutation pairs atomic.

Smallest repair: pass the expected generation into the teardown operation and validate/detach that generation and its ids in one critical section. Atomically validate generation/expiry/drain and insert the session in the corresponding registration operation. Run runner/connection teardown after detachment. Do not broaden this into a new pool design. Add controlled stale-watcher/new-acquire and final-check/registration interleavings.

### C5 — P2: checked-in TLS test does not compile

`native/mjolnir_relay/tests/edge_tls.rs:92,108`.

`relay: url` moves the URL for the malformed-root case, then the foreign-CA case uses `url.clone()`. Exact-source `cargo +1.95.0 test --offline --locked --lib --test edge_tls -j 1 --target-dir ../target` fails with **E0382: borrow of moved value: url**. Thus the commit's claimed “24 lib + TLS” command is not reproducible from this hash. The separate library-only command passes all 24 tests.

Smallest repair: clone at the first assignment (or use the already retained `edge_url`), then run the checked-in TLS target. The foreign-valid-CA and hostname-mismatch cases are present in source but have no passing execution at this exact commit from this review. No product/test repair was made by this reader.

### C6 — P2: a configured origin list is not authoritative

`edge.rs:1175–1185`.

After failing the configured-list check, `origin_allowed` always permits either scheme for the request Host. With origins set to only `https://named-peer.test`, both `http://edge.test` and `https://edge.test` are still allowed when Host is `edge.test`. A direct predicate probe reproduces this. D2 says the configured list applies, with same-origin fallback **when that list is empty**.

Smallest repair: return allowlist membership when configured; use same-origin fallback only for an empty list. That fallback must compare the effective scheme as well as authority, rather than assuming both schemes are the same origin. Avoid trusting arbitrary forwarding headers without an explicit proxy configuration.

## Disposition of the prior ten findings

| Prior finding | Result on this hash |
| --- | --- |
| R1 reservation, completion, relay death | Cancellation releases the candidate; real ICE timeout and real relay shutdown remove session/ref/runner maps. Connection ownership still fails C1, generation mutation C4. |
| R2 one deadline, expiry precedence | Deadline starts before acquisition and is carried into negotiation. First-dial expiry finishes without the prior mutex deadlock. Actual missing catalog timeout preserves an incumbent; controlled candidate expiry clears same-token legs and preserves a distinct token. Final registration is still non-atomic, C4. |
| R3 answer delivery | Unconsumed-body drop now cleans up. Post-EOF actual HTTP write failure still leaks, C2. |
| R4 follower reservations | Rejected leader preserves the follower reservation; cancelled leader lets a live waiter retry. Original cancelled-waiter test passes. Final-release/new-acquire still overlaps real connections, C1; stale generation window C4. |
| R5 once-only path decode | Converted Router cases pass on WHIP and WHEP: slash, double escape, backslash, dots, malformed escapes rejected before dial. A valid encoded character reaches the recorded moq path once-decoded. Bounds remain in the parser. |
| R6 typed errors | Real absent broadcast now returns `NotStarted`/409 and clears its candidate; typed enum matching replaces Display substring matching. |
| R7 CORS/admit | No wildcard for unlisted origin, successful admit has no-store, missing-field JSON is 400 envelope, no-token malformed JSON precedence test passes. Configured-origin fallback still fails C6. |
| R8 tombstones | Owner repeat/foreign bearer, expiry ownership, and sweep-only horizon reaping pass. These tests establish time retention, not a cardinality quota. |
| R9 ceiling/drain | Snapshot TTL and environment wiring exist; lower ceiling rejection passes. Reload no longer clears draining. Pending setup and actual connection close still fail C3/C1. The shipped “good reload” drain test writes an empty key set and ignores reload failure, so it does not prove a successful reload while draining. |
| R10 cap | Real WHIP answer contains `b=TIAS:2250000`, the pin's 90% steering target for `INGEST_CAP_BPS=2500000`; trial keyframes remain enabled. No over-cap sender/REMB runtime proof is claimed here. |

`Checked` Debug is now redacted. Test dial/attach helpers are still public and compiled into the library; the shipped binary does not enable them. `moq_paths` also remains an unbounded production trace vector. These previously requested test-scope cleanup items remain owed; they are not evidence that real playback used mocks. Further coverage remains owed for pinned port-zero/inactive answer rejection, valid key reload/recovery/drain, and authenticated real-expiry/media enforcement beyond the isolated edge probes.

## Independent validation and reproducibility

New `reproduce-cb1481c.py` extracts exact product/vendor source into a temporary directory, appends only the new review tests and their dev dependencies, and runs locally/offline with Rust 1.95 and one Cargo job. Historical `reproduce-4169315.py` and `.rs` are unchanged. No remote services or builder evidence files were touched.

- Exact checked-in library: **24 passed**. Log: `cb1481c-original-lib-result.txt`.
- Exact checked-in combined library/TLS command: **compile failure E0382**, no TLS test executed. Log: `cb1481c-original-tls-build.txt`.
- Final independent suite: **15 passed, 0 failed**, 42.13 seconds runtime. Log: `reproduce-cb1481c-result.txt`. Four are intentionally defect-characterization assertions (connection retention, failed write, pending drain, CORS); passing the suite is **not** code acceptance.
- The nine historical defect scenarios were ported to the new API and contract expectations, grouped into six tests: HTTP decode; CORS/cache/JSON; rejected leader; first expiry plus tombstones; actual response drop plus WHEP cancellation; absent source; natural completion. Grouping combines some scenarios rather than omitting them. All nine old scenarios improve at the tested boundary; C1/C2 expose remaining defects beyond the old map-count/unconsumed-body assertions.
- Additional probes cover leader cancellation with live waiter, actual final-release/redial connection overlap, drain during flight, actual HTTP/1 write failure beside an incumbent, successful loopback TCP response delivery and request cancellation, first-dial expiry, controlled expiry with two distinct valid tokens, and actual relay shutdown with two same-token runners.
- Token isolation uses independently generated signing keys with unique `kid` values, both installed in the local verifier, and an explicit token inequality assertion. Request broadcast paths distinguish incumbent, candidate and control. The short-expiry edge test deliberately injects a shortened `Checked.exp`; it is **not** a real short Mint token or a test of relay-side token expiry.
- Two exploratory probe mistakes were corrected before the final run: TIAS initially expected the full cap instead of the pin's 90% target; the two-key fixture initially omitted key ids and refused admission. Neither is a product defect. The final saved probe source and result use the corrected expectations/fixture.
- `git diff --check` passed; product/vendor files remained byte-identical to the reviewed hash during validation. No browser playback, current-hash real Mint issuance, Ubuntu build, remote TLS run, production install, Safari or full-repository suite is claimed.

Small next step: repair C1–C4 in the existing ownership transaction, fix C5/C6, rerun these independent probes plus the missing atomic-interleaving tests, and obtain a fresh independent code verdict. Keep `.13` open and the accepted contract/keyframe policy intact. Builder-owned evidence remains separate; do not substitute map counts for connection close or body EOF for successful delivery.
