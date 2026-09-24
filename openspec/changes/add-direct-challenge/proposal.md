# add-direct-challenge

> **ACTIVE BUILD**

Bead `mjolnir-22ff.3`. Steer 2026-09-24.

**Rigor:** architecture

**Preparation (2026-09-24 /run):** still valid (advise-5 accept). Inbound: identikey-auth v1 exists; channel/edge-proof owned by add-edge-op-keys (not yet implemented). Prefer act after op-keys persist exists, or keep gateway-handoff tests host-side. Authority: 22ff campaign.

## Why

Native clients (CLI, desktop, mobile, agent, SSH, local socket) must
authenticate to a Mjolnir edge without OAuth redirects. A draft
challenge protocol already exists (`identikey-auth-challenge-v1`).
Inventing a v2 or stuffing session keys into `Challenge` would mix
identity with authorization and fork Papyrus/peer auth.

## What

- Consume `identikey-auth` / `identikey-auth-challenge-v1` unchanged
  for identity. `Challenge.aud` is the pinned edge stable XID.
- Bind session public key, requested operation, and channel context
  in a second signed authorization object.
- identikey-core is not the verifier. C1/C2 may be a claimant via
  `add-managed-challenge-responder` (`mjolnir-22ff.3.1`).
- Vectors: success, replay, expiry, wrong edge, wrong audience,
  altered request, holder-key substitution, transport replay.

## Impact

- Capabilities: ADDED `edge-auth`
- ADRs: none (cite `0012-direct-edge-auth` from `add-edge-op-keys`;
  protocol file stays in identikey-protocol)

## User journey & surfaces

No new UI because `mj login` is the later surface
(`add-mj-login-modes`). This change is the proof format that login
and the edge will speak.

- **Working (after act)** — a native client completes v1
  challenge/response to the pinned XID, then a session-bind object;
  no browser, no OP.
- **Empty** — no pin → refused (`add-edge-op-keys`).
- **Failed (today)** — `mj login` is device-code or loopback OIDC
  against `auth.identikey.me`; no edge-issued Challenge.
- **Off** — hosted `--hosted` path (later).

## Out of scope

- Adding Schnorr (or any new alg) to identikey-auth v1
- identikey-core as OP for this path
- HTTP endpoints that issue/consume the exchange —
  `add-direct-auth-endpoints`
- Managed C1/C2 signer — `add-managed-challenge-responder`
- Biscuit profiles — `add-biscuit-profiles`
