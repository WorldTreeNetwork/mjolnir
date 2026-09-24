# steer add-edge-op-keys

**When.** 2026-09-24
**Depth.** explicit

## Decided
- Custody: host files `/var/lib/mjolnir/auth`, `0600`, not btrfs (user)
  Why: escrow/blob-cache precedent; snapshots must not capture identity keys.
- Edge trust: client profile pins stable XID; Lightning/mesh/Iroh are address only; no TOFU (user)
- Hardware/enclave wrap later, not v1 (user, by picking host files)
- Operational keys issue capabilities (epic / auto)

## Skipped
- Numeric overlap lifetime
- Multi-edge picker UX — one pin per profile for v1 (`add-mj-login-modes`)

## Feeds change
Stable key is the pin and the offline anchor. Op keys are online, minted on start if missing, overlap on rotation. Compromise/recovery is: rotate op keys; stable key recovery is a separate restore of the auth dir, not a DNS cutover.
