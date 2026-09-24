# add-edge-op-keys

> **ACTIVE BUILD**

Bead `mjolnir-22ff.2`. Steer 2026-09-24.

**Rigor:** architecture

**Preparation (2026-09-24 /run):** still valid (advise-5 accept). No inbound code artifact missing for persist/ADR. Direct-challenge and biscuit consume this later. Authority: 22ff campaign. Ready to act.

## Why

Direct authentication trusts a selected Mjolnir edge by cryptographic
identity, not DNS. The edge needs a stable IdentiKey that can stay
offline and rotating operational keys that prove the edge and mint
capabilities. Those keys must not live on the BTRFS data volume
(snapshots would capture them).

## What

- Store the stable edge identity and operational keys under
  `/var/lib/mjolnir/auth`, `0600`, outside `btrfs_root`.
- Stable key is the offline trust anchor. Ordinary sessions do not
  require it online.
- Operational keys generate on start if missing, sign edge proof and
  capabilities, rotate with published overlap.
- Clients pin the stable edge XID. Discovery fills address only.
- ADR `0012-direct-edge-auth`.

## Impact

- Capabilities: ADDED `edge-auth`
- ADRs: will add `docs/decisions/0012-direct-edge-auth.md`

## User journey & surfaces

No new UI because `mj` profiles and the edge API already exist. This
is the key material those surfaces will pin and verify.

- **Working (after act)** — an offline verifier checks
  stable-XID → current operational key; a rotated op key still
  verifies unexpired capabilities issued under overlap.
- **Empty** — first start mints op keys; stable key is provisioned
  once, not regenerated each boot.
- **Failed (today)** — no edge identity; JWT issuer is the trust
  root; hypervisor disk would snapshot any key left under
  `btrfs_root`.
- **Off** — not this host's auth dir.

## Out of scope

- Hardware/enclave wrap of the stable key (later ceremony)
- Challenge/response wire format — `add-direct-challenge`
- Biscuit mint/verify runtime — `mjolnir-axsb.1.3`
- HTTP endpoints — `add-direct-auth-endpoints`
- `mj login` flags — `add-mj-login-modes`
