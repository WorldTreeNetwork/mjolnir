# steer add-honor-snapshot-key-scrub

**When.** 2026-09-20
**Depth.** lean

## Decided
- Activate this change (user)
  Why: living honor-being already names the grok-config / history gap.
- Buzz DNS pin: leave CNAME to apex (user: don't bother)
  Why: `buzz.identikey.me` already follows `identikey.me` → 45.76.77.97.
  Tracked on `add-buzz-relay`, not this change.

## Skipped
- none

## Feeds change
Scrub XAI_API_KEY from grok config, shell history, and storefront
.env on the host-visible rootfs **after pause, before** the BTRFS
snapshot, when the snapshot name starts with `hosted-`. Do not
touch `/run/mjolnir/` tmpfs inject.
