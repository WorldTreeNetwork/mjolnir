---
spike_id: complete-call-e2ee
run_at: 2026-11-24T06:33:00Z
verdict: inconclusive
version-pinned: moq@4a6f522483168ace392718d68b58a402533c897d, iroh-live@747b1bd0567d2f6b019a89633c04e6561ccac460
---

# Complete call E2EE spike — incremental evidence

This file is updated while the experiment runs. Overall acceptance is not established.
Baseline main: 847f60df501384b9520af1aeab4c0bdd81a5181e. Tracking: mjolnir-rurh.9.1.
Only disposable harness/evidence changes; no product or design changes.

## Observations so far

- Chromium 158: actual Hang canvas movement and decoded injected 440 Hz audio over authenticated moq-lite-06, label-bound opaque and epoch read from announcement path. Firefox 159: same after forcing VP8 and preventing stale catalog groups from overwriting newer catalogs. See final transcripts when copied alongside this finding.
- Native LocalBroadcast software H.264 + Opus encoding through Node::publish_with, authenticated Iroh relay ingress and WebTransport egress, decrypting mirror and native RemoteBroadcast player: 20 decoded frames with 20 different pixel checksums, 18,888 decoded audio samples, peak 0.509. No upstream fork. The eager bridge subscribes to all listed tracks; adaptive demand propagation remains a limitation.
- Rust→JS and JS→Rust names, paths, grouped frame payloads agree. Payload, group identity, semantic name, and wrong key fail authentication. **Changing the public frame timestamp from 124 ms to 999 ms still decrypts.** The profile does not authenticate this metadata; do not describe all transport metadata as authenticated.
- 57 upstream JS vector/epoch/unit tests passed. Complete upstream transport suite on Bun 1.3.14 failed on missing WritableStreamDefaultController.signal; that is distinct from the real-browser tests. Rust upstream vectors not yet run.
- Browser non-extractable HKDF and AES key export rejection proven in shared T3 Chromium 152, automated Chromium 158 and Firefox 159. Pinned profile is HKDF-SHA-256 / AES-128-GCM. Non-extractability does not prevent code with the credential handle from deriving 16 raw media-key bytes and decrypting; tested successfully. Initial fragment/key bytes and decoded plaintext remain accessible to same-origin code. No interpretation of the user's unspecified cipher comparison is assumed.
- Local loopback capture permission works (tshark 4.4.0). No relay capture acceptance verdict yet.

## Harness repairs

Upstream worklet/libav Vite plugins are used unchanged. libav 0.1.0 is unpublished; build.ts reports npm 404. Installed Nix 2.17 is too old. Scratch Nix 2.24.11 plus explicit daemon access successfully built pinned .#moq-libav, using its existing flake.lock and upstream cache configuration. No system Nix upgrade. Worklets must use hosted assets under the restrictive CSP. The first Rust self-signed certificate had excessive validity for WebTransport; fixture certificates now last seven days.

Private captures, relay keys, certificates, admission tokens and raw media stay under /tmp/mjolnir-e2ee-private* and are excluded from commits. Shared scratch dependency sources are reused without deleting another session's files. Cargo clean was scoped to call-e2ee-spikes after its own test artifacts consumed available disk.
