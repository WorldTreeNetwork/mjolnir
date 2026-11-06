# steer add-proxy-guest-net

**When.** 2026-11-04
**Depth.** standard

## Decided
- Spike timing: Spike now (auto). The user delegated this fork ("up to you") after saying the only question was whether to spike now or after the spec.
  Why: The stock unit already failed in a guest. Another contract around an untested drop-in repeats that order. The experiment is the drop-in, on this machine, 60 minutes, no production host.

## Skipped
- Repair as a landing — still open. Drop-in, `Journal::open`, and a Mjolnir-authored unit are not a closed choice. This pass only tests the drop-in. Decline of the earlier menu is not a choice of the drop-in.
- Stock spike line — `proxy-unit-in-guest` stays no-go. It is not set to `go` or `skipped`.

## Feeds change
Spike the drop-in now (`proxy-data-dir`): a real mode-0700 data directory and `IPAddressAllow` for localhost plus `10.200.0.1/32`, copied only into a throwaway guest. Do not mark the stock line go. Reachability is unchanged. No api-proxy edit and no production boot.

## Result
`docs/spikes/proxy-data-dir/finding.md` is go for the drop-in. `docs/spikes/proxy-guest-class/finding.md` is go for the class: `enable_iroh: false` plus a proxy `mjolnir-network-setup`. A level-2 heal re-runs that script and leaves the pin. The stock unit stays no-go. `Journal::open` and an authored unit are skipped. Act waits on a fresh advise accept. The landing also teaches `GuestNetwork` that this class has no default route, so the probe stops reporting it dead.
