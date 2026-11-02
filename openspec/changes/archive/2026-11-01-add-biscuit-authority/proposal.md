# add-biscuit-authority

> **ACTIVE BUILD**

Bead `mjolnir-reki.1`. **Rigor:** architecture. Group: human-gate. Activated by the campaign grant on `mjolnir-reki` ("activate and run").

## Why

`add-biscuit-runtime` is folded. `Mjolnir.Biscuit.keypair/0` still asks `mjolnir-biscuit` for a new Ed25519 key on every call. `MJOLNIR_BISCUIT_PUBLIC_HEX` is only a verifier. Mint and redeem cannot share a root until one durable private key exists.

## What

- One Ed25519 mint root that survives a process restart.
- Its public hex is the host verifier (`biscuit_public_hex`).
- Production mint uses that root. A per-call `keypair` is not the authority.
- Blake3, §5 holder fingerprints, and the `mjolnir-biscuit` JSON face stay as folded.

## Impact

- Capabilities: ADDED `Mint root is durable` on `biscuit-runtime`
- ADRs: none

## User journey & surfaces

No new UI because the root is host configuration. A second mint in the same boot, and a mint after restart, verify with the same public key. There is no operator screen.

- **Working** — two production mints share one public key, and redeem's verifier is that key.
- **Empty** — no root file and no configured public hex. Mint fails closed.
- **Failed** — the stored private key and the configured public hex disagree. Mint fails closed.
- **Off** — tests may still build an ephemeral keypair for round-trip checks. That key is not the host root.

## Out of scope

- Replacing Blake3 or reopening `add-biscuit-runtime`.
- `POST /api/secrets/redeem` (`add-tokenator-redeem`).
- Deposit and owner fingerprint (`add-capability-mint`).
- Hop blocks (`add-capability-hop`).
- The guest fence (`add-guest-fence-host`).
- Putting the private key in the per-VM LUKS escrow directory, or in an environment variable.

## Preparation

Outcome: revised. The 2026-10-31 api-proxy note called Blake3 a SHA-256 stub. Living `openspec/specs/biscuit-runtime/spec.md` and `Mjolnir.Biscuit.blake3_hash/1` are real Blake3. `config/runtime.exs` reads `MJOLNIR_BISCUIT_PUBLIC_HEX` and nothing stores the matching private key. Steer 2026-10-31: reconcile the tree; this node is only the durable root. `--go` on "activate and run" auto-logged the open key home: one `0600` file outside `btrfs_root`, default `/var/lib/mjolnir/biscuit-root`, not the LUKS escrow dir and not an env private key. Authority: campaign grant on `mjolnir-reki`, this dependency-ready node. Fresh advise is owed before act.

Send-back `reviews/2026-10-31-advise.md` (READER `astra-arch-review`). Amended the same day: private key stays off argv and out of error text, file body is 64 lowercase hex chars provisioned by the operator, `authority/0` is the production load, and the delta now covers restart, mismatch, bad files, and an unset public override. Banner stays ACTIVE BUILD.
