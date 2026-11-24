# Complete call-E2EE spike: how to reproduce

Result: [`finding.md`](finding.md). Entry point: [`run-all.sh`](run-all.sh), which runs every step below in order.
This is a local, disposable harness. The relay runs in-process from `../rust` and writes a QUIC keylog
only when `E2EE_PRIVATE` is set. Never aim any of this at a production relay.

## Prerequisites

| What | Version used | Notes |
|---|---|---|
| Rust (stable) | aarch64-apple-darwin | `../rust` crate; `CARGO_TARGET_DIR` defaults to `native/mjolnir_relay/target` (a shared cache) |
| moq checkout | `4a6f522483168ace392718d68b58a402533c897d` | `bun install` at the root |
| `@moq/libav` build | from that checkout's flake | 0.1.0 is unpublished, so build it: with **Nix ≥ 2.24** (2.17 is too old), `nix build .#moq-libav`, then copy the output into `js/libav/dist` |
| iroh-live | `747b1bd0567d2f6b019a89633c04e6561ccac460` | pulled by Cargo (feature `native-media` for the native tests) |
| Bun | 1.3.14 | JS unit tests and `interop.ts` |
| Node | 26 | Playwright drivers |
| Playwright | 1.65.1 | a harness dir with `{"dependencies":{"playwright":"^1.65.1"}}`; `npx playwright install chromium firefox` (Chromium 158 headless shell, Chromium 159 full, Firefox 159) |
| tshark | 4.4.0 | captures on `lo0`; macOS needs capture permission (ChmodBPF) |
| ffmpeg | any recent | VP8 and Opus decoding of captured payloads |
| sqlite3 | system | history store check |

## Run

```bash
cd openspec/changes/add-call-e2ee/spikes/complete
MOQ=/path/to/moq HARNESS=/path/to/playwright-harness ./run-all.sh
```

Order and single-step commands (all from `spikes/` unless stated):

1. Page build: copy `page.ts bridge.ts validation*.ts interop.ts vite.config.ts` into `$MOQ/js/e2ee/spike/`, then run `node ../../../node_modules/vite/bin/vite.js build` there. Serve with `python3 complete/serve.py $MOQ/js/e2ee/spike/dist` (port 8124, CSP, `Referrer-Policy: no-referrer`).
2. JS unit: `(cd $MOQ/js/e2ee && bun test src/e2ee.test.ts src/vectors.test.ts src/epoch.test.ts spike/validation.test.ts)`
3. B1 relabel: `cargo test --manifest-path rust/Cargo.toml --test b1_relabel -- --nocapture --test-threads=1`
4. Interop: `E2EE_INTEROP=$D E2EE_PHASE=emit cargo test … --test complete_interop`; `bun interop.ts $D` (inside the spike dir); `E2EE_INTEROP=$D cargo test … --test complete_interop`
5. Native: `cargo test … --features native-media --test complete_native -- --nocapture`
6. Expiry: `cargo test … --test complete_expiry -- --nocapture --test-threads=1`
7. Fixture relay for browsers: `E2EE_PRIVATE=$PRIV cargo test … --features native-media --test complete_cross -- --ignored --nocapture &` (writes `$PRIV/admission.txt` and `relay.pem`; `complete_server` is the same without the native publisher). Touch `$PRIV/stop` to end it.
8. Browsers: `node drive.mjs chromium|firefox $PRIV`; `node cross-drive.mjs chromium $PRIV 1`; `node cross-drive.mjs firefox $PRIV 0`
9. Captures: `HARNESS=… complete/capture.sh plaintext|encrypted|tokenonly $PRIV`
10. Rekey: `node rekey-drive.mjs $PRIV`. Use a fresh fixture: stale announcements on a long-lived relay are finding F2.
11. History: `node history-drive.mjs chromium|firefox $PRIV`
12. Fragment and network leak: `node fragment-drive.mjs $PRIV` (about 60 s)
13. Crypto in browsers: serve `crypto.html` on :8123 (build of `crypto.ts`), then `node crypto-drive.mjs`

The drivers resolve `playwright` from their own directory, so copy `*.mjs` into `$HARNESS` and run them there.

## Never commit

`$PRIV` holds the relay keylog, the fixture TLS key, room tokens, pcaps and decoded media. `spikes/.gitignore`
excludes captures, keys and media. The root ignores `*.log`, so the evidence logs here are re-included
explicitly. Logs pass through a JWT redactor (`[TOKEN]`). The only key material in tracked files is the
dummy fixture secrets 32×0x11 (kid 1) and 32×0x22 (kid 2 default).
