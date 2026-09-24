# steer add-biscuit-profiles

**When.** 2026-09-24
**Depth.** explicit

## Decided
- Runtime: unpark `mjolnir-axsb.1.3` as shared mint/verify; this node is profiles only (user)
  Why: epic forbids a second Biscuit runtime; axsb.1.3 is holder-bound + auth-challenge §5 fps. k8y.5 stays VM RBAC.
- Holder-bound default; bearer explicit (epic / auto)
- Mode must be unambiguous; holder-bound must not verify as bearer (epic)

## Skipped
- Numeric bearer / holder lifetimes — `add-direct-auth-endpoints`

## Feeds change
Write the profile contract and vectors. Do not add biscuit-auth here. `add-direct-auth-endpoints` waits on this and on axsb.1.3.
