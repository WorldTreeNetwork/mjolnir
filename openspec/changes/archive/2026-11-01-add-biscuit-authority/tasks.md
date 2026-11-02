# Tasks

- [x] Load the Ed25519 mint root from the `0600` file outside `btrfs_root` (default `/var/lib/mjolnir/biscuit-root`) and use its public half as the verifier
- [x] Production mint uses that root and does not call `new_keypair` for it
- [x] A missing root, or a public hex that disagrees with the stored key, fails closed
- [x] A test shows two mints share one public key
- [x] A fresh process reloads the same file, verifies a pre-restart token, and mints again under that public key
- [x] Tests cover configured-public mismatch, invalid or wrong-mode files, missing-file non-creation, and verifier derivation when the public override is unset
- [x] A regression shows the production private key is absent from argv and from a forced CLI failure

## Advise owed — 2026-10-31

- [x] Amend the contract to keep durable private-key bytes out of subprocess argv and diagnostics, with a focused regression check (review finding 1)
- [x] Pin root file encoding, operator provisioning and safe installation, invalid-file/permission/path failure behavior, and the production authority/verifier initialization boundary (review finding 2)
- [x] Add acceptance scenarios and test tasks for restart continuity, configured-public mismatch, invalid roots, missing-file non-creation, and verifier derivation without a public override (review finding 3)
- [x] Fresh advise after preparation — review the amended contract; this send-back does not unblock act

## Out of scope

- Redeem, deposit, hop, and the guest fence
