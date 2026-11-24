# Browser spike fixtures

Not product code. Uses fixed dummy secrets in request query strings and a public, unauthenticated loopback relay. Never use real credentials. Room-token admission and the final epoch-in-path layout are tested separately in Rust. This fixture obtains epoch out of band from its test driver.

Frame/catalog API verdict: proven on Chromium 158 and Firefox 159 (>=153), moq-lite-06. See `../e2ee-js.out`. This does not prove Hang media rendering, audio, invite-fragment handling or security headers.

Prepare a disposable workspace W with:

- `moq/`: moq-dev/moq source at `4a6f52248` (copy or checkout); run `bun install --ignore-scripts` there. Recorded toolchain: Bun 1.3.14.
- `target/release/moq-relay`: build that pin with `CARGO_TARGET_DIR="$W/target" cargo build --release -p moq-relay` from moq's Rust workspace (`moq/rs`).
- `harness/`: Node project with `playwright` 1.65.1 installed; run `npx playwright install chromium firefox` there. The recorded browser versions are printed in the transcript.

From the Mjolnir root, with ports TCP 8088, TCP/UDP 4443 free:

```bash
bash openspec/changes/add-call-e2ee/spikes/js/run.sh "$W" chromium default
bash openspec/changes/add-call-e2ee/spikes/js/run.sh "$W" firefox default
```

The driver opens publisher, subscriber and no-credential contexts, tests catalog and three marker frames, tries a wrong key, prints a verdict, and closes the browser. `run.sh` cleans up its relay and HTTP server. `lite07` is an optional wire experiment, not the shipped default.

`COMPONENTS=1` switches to `components-page.ts` and `bridge.ts`. This is **unvalidated scaffolding**, not a working runner: Bun cannot bundle upstream `?worklet` and CSS imports. The attempted command/build errors are in `../e2ee-js-components.out`. Use upstream Vite plugins in `js/common/vite-plugin-{worklet,libav}.ts` when resolving it; do not count a build as playback. Prove moving canvas frames and audio decoding in both browsers. A successful component bundle is still not secret-handling acceptance because these fixtures carry dummy keys in queries.
