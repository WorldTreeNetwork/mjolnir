# ADR 0017 — Call content encryption

**Status:** Proposed (2026-11-23). Contract and spikes only; requires Duke's decisions and Fable advise before implementation.
**Change:** [add-call-e2ee](../../openspec/changes/add-call-e2ee/proposal.md)
**Argument and evidence:** [design](../../openspec/changes/add-call-e2ee/design.md), [tasks](../../openspec/changes/add-call-e2ee/tasks.md)

The relay terminates transport encryption, so room admission alone gives the operator access to media and catalog bytes. Protect those bytes and semantic names with upstream `moq-e2ee-01-wip`, pinned to moq `4a6f52248`. This remains experimental; no claim of independent cryptographic audit is made.

Proposed decisions D1–D9 in the design:

1. Separate room admission tokens from client-generated content credentials. Neither Mjolnir nor the relay gets usable content key material. Opaque derived paths and encrypted frames necessarily reach the relay.
2. Use `t/<owner>/<room>/<label>/<credential.path(label)>/<epoch>`. Rust's real relay spike proves room grants work unchanged and label-derived paths differ. Default MoQ wire replaces Instance epoch; last path segment works. This deliberately differs from draft-01 layout and needs Duke/advise. Opting every peer into lite-07 and adding an iroh-live instance hook is the alternative.
3. Deliver a per-guest room token plus the shared content credential in an invite fragment, strip it on load, keep the secret out of requests/logs. Token goes only to relay admission. Network-leak verification is not run. Whoever serves executable page code remains trusted for code integrity; Duke must choose whether operator delivery is acceptable.
4. Native iroh-live `747b1bd` can use Node::publish_with and a local bridge without a fork, proven for synthetic frames. Real LocalBroadcast encoding and native playback are not run. If that bridge cannot forward demand, propose an upstream track-factory hook and obtain review.
5. Removal creates a new kid and fresh secret. Remaining publishers republish then finish/close old tracks and broadcast; remaining subscribers follow on existing sessions. Withdraw alone was refuted (51 extra frames). New credential switched in 48 ms in the original spike, 44 ms in the repeat. Token/metadata access remains until exp, up to 3600 s. A publisher that retains the old generation defeats content removal.
6. Encrypt the catalog and every semantic track name. Keep names at most 15 UTF-8 bytes for one padded length class. Relay still learns owner/room/labels, opaque paths, UUIDv7 start time, track count/kind, sizes, timing and group structure.
7. Pin Rust and JS together. Profile changes break key/name derivation and require coordinated client upgrades; relay does not change. Vectors and Rust↔JS interop remain owed.
8. New process instances mint new epochs. Future guest publishers must remint on VM generation change before encryption; no guest publisher ships in this change.
9. Acceptance requires actual audio/video playback at two holders plus a relay-process capture decrypted with relay session keys, a plaintext positive control and a token-only tap. A marker search alone does not establish that media cannot decode. This acceptance has not run.

Browser evidence proves JS encrypted marker frames and catalogs on Chromium 158 and Firefox 159 over moq-lite-06. Hang publish/watch component integration is **not run**: the simple Bun fixture builder cannot resolve upstream worklet/CSS imports. This is a tooling gap, not a finding that the components cannot support encryption. No product code is authorized by this ADR.
