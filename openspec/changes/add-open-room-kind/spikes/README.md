# add-open-room-kind spikes

Local, disposable harness. Dummy keys generated per run. Never aimed at production.

## Path trial (revision 3, 2026-11-26)

Duke asked to try the root marker after the claim revision was sent back. Narrative:
[`path/finding.md`](path/finding.md). Logs: `logs/path-offline.log`, `logs/path-live.log`,
`logs/path-live-extra.log`. The relay in that run is the production decider (`kind-spike relay`),
not route (b).

```bash
native/mjolnir_relay/target/debug/open-room-kind-spike offline \
  > openspec/changes/add-open-room-kind/spikes/logs/path-offline.log
openspec/changes/add-open-room-kind/spikes/path/live.sh \
  openspec/changes/add-open-room-kind/spikes/logs
```

## Root-marker option (withdrawn, then retried)

The owner chose a dedicated signed claim on 2026-11-25. The offline work below was for the
withdrawn `t/<owner>/~open/<room>` design. Revision 3 retries that shape with a live transport
run and a revised contract. The 2026-11-25 offline log stays as the earlier evidence.

- `logs/root-option-offline.log`: `kind-spike offline` (harness in `rust/`), run 2026-11-25 on
  macOS. Under a kio `Manual` clock installed on the runtime, both moq-auth `KeySet::verify` and
  the relay's `profile` read the controlled time (the last rows: `t0+599` admits, `t0+600` is
  `token has expired` from moq-auth, a future `iat` is refused by `profile`, and the host clock
  refuses the 2025 token). For each marker `~open`, `@open`, `+open`: `root_allowed` is true, the
  literal path is admitted, the `%`-encoded and double-encoded spellings of the path are refused
  ("path outside the grant", no decoding), and cross-kind access is refused both ways. A tenant-wide
  token rooted at `t/<owner>` is admitted on both kinds.
- Not run before the option was withdrawn: the live WebTransport, Iroh and Chromium legs of H1, and
  the mint HTTP route spellings. A full disk on the Mac (117 MiB free) also stopped the example
  rebuild.

## Claim route (chosen 2026-11-25, sent back, not this trial)

Finding: [`claim-route.md`](claim-route.md). Reproduce:

```bash
P=<private dir>
MIX_ENV=test mix run --no-start openspec/changes/add-open-room-kind/spikes/claim/mint_fixtures.exs $P
(cd openspec/changes/add-open-room-kind/spikes/rust && CARGO_TARGET_DIR=../../../../../native/mjolnir_relay/target cargo build --bin open-room-kind-spike)
(cd native/mjolnir_relay && cargo build --example wt-session)
native/mjolnir_relay/target/debug/open-room-kind-spike claim-offline $P   # logs/claim-offline.log
openspec/changes/add-open-room-kind/spikes/claim/live.sh $P                # logs/claim-live.log (redact tokens)
```
