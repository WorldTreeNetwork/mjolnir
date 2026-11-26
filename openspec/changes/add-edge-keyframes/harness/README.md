# webrtc-edge spikes S4 and S7: how to replay

Result: [`finding.md`](finding.md). Entry point: [`run-all.sh`](run-all.sh). Design: `docs/plans/webrtc-turn-sfu.md`
(spikes S4 `moq-webrtc-embed`, S7 `protected-refusal`, gating node D `webrtc-edge`).

Local, disposable harness. The relay runs in-process (`harness relay`: `moq-relay` + `mjolnir_relay::spawn_web_decider`)
with a per-run dummy EdDSA key (kid `spike-dummy`) and a self-signed certificate. Never aim it at a production relay.

## Pieces

| File | What |
|---|---|
| `rust/src/bin/edge.rs` | The edge under test: WHIP/WHEP/roster/DELETE, room-token verification with the relay's `assess`, one relay session per WebRTC session with the caller's token |
| `rust/src/bin/harness.rs` | `relay`, `mint`, `keygen`, `publish` (fMP4/MKV on stdin → MoQ), `raw` (plain subscriber → IVF/Annex-B + Ogg Opus), `export` (moq-mux MKV exporter), `catalog`, `frames`, `protected-pub`, `protected-read` |
| `pages/rtc.{html,js}` | WHIP/WHEP test page; token in the URL fragment; `window.content()` samples decoded pixels and the audio spectrum |
| `drive.mjs` | Playwright driver (`pub`, `play`, `room`, `auth`, `expiry`, `simulcast`, `viewers`, `publishers`) |
| `analyze.py` | Decodes recordings with ffmpeg and checks colours and tone (content, not exit codes) |
| `lossy.py` | UDP proxy that drops a fraction of packets per direction |
| `lib.sh` | Shared start/stop helpers and the native fixture publisher (`pub_native`) |
| `claim*.sh` | One script per claim; each writes nothing tracked except what `run-all.sh` redirects into `logs/` |

## Prerequisites

| What | Version used |
|---|---|
| Rust | 1.96.0 stable (the relay pins 1.95.0); `CARGO_TARGET_DIR` defaults to `native/mjolnir_relay/target`, a shared cache |
| moq | git rev `4a6f52248` (Cargo pulls it; same as `native/mjolnir_relay`) |
| Node + Playwright | Node 26, Playwright 1.65.1 in `$HARNESS` (`npm i playwright@1.65.1`); Chromium 158 and Firefox 159 from the Playwright cache |
| ffmpeg / ffprobe | 7.1.1 with libx264, libvpx, libsvtav1, libopus |
| Python | 3 with numpy |
| Network | the Mac's LAN address (`ipconfig getifaddr en0`) for the media socket: Chromium does not use loopback candidates |

Safari needs "Allow remote automation" in Safari's Developer settings; it was off, so Safari was not run.

## Never commit

`$P` (default `/tmp/mjolnir-rtc-private`) holds the relay's private key set, tokens, TLS key, fixtures and
recordings. `.gitignore` excludes media, keys and tokens; logs are re-included and pass through a JWT redactor
(`[TOKEN]`). Delete `$P` and `$HARNESS` when finished.
