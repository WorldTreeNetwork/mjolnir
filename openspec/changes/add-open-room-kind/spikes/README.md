# add-open-room-kind spikes

Local, disposable harness. Dummy keys generated per run. Never aimed at production.

## Root-marker option (not chosen)

The owner chose a dedicated signed claim on 2026-11-25. The work below was for the withdrawn
`t/<owner>/~open/<room>` design and is kept only as evidence for that option.

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

## Claim route

See `claim-route.md` once written.
