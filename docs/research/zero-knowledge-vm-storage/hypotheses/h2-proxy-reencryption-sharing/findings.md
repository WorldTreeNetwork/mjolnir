# H2: Proxy Re-encryption for Zero-Knowledge Snapshot Sharing

## Summary

Proxy re-encryption (PRE) via Recrypt is the key enabler for the zero-knowledge sharing model. The critical insight: PRE operates on the **wrapped symmetric key** (envelope encryption), NOT on the multi-GB snapshot data. This makes it practical — re-encrypting a 256-bit wrapped DEK takes milliseconds regardless of snapshot size. Combined with Biscuit capability tokens, this creates a coherent model where the server can facilitate sharing without ever seeing plaintext.

## Evidence

### How Proxy Re-encryption Composes with btrfs send Streams

The composition follows the standard envelope encryption pattern:

```
Snapshot Creation (Alice):
  1. Generate random DEK (256-bit XChaCha20 key)
  2. btrfs send <snapshot> | zstd | XChaCha20-encrypt(DEK) → encrypted_blob
  3. Wrap DEK with Alice's public key (lattice-based): wrapped_dek_alice
  4. Store: encrypted_blob + wrapped_dek_alice + metadata

Sharing with Bob (server-side, zero-knowledge):
  1. Alice generates re-encryption key: rk_A→B = Recrypt.rekeygen(alice_sk, bob_pk)
  2. Alice sends rk_A→B to server (or embeds in attenuated Biscuit)
  3. Server transforms: wrapped_dek_bob = Recrypt.reencrypt(rk_A→B, wrapped_dek_alice)
  4. Bob receives: encrypted_blob (unchanged!) + wrapped_dek_bob
  5. Bob unwraps: DEK = Recrypt.decrypt(bob_sk, wrapped_dek_bob)
  6. Bob decrypts: XChaCha20-decrypt(DEK, encrypted_blob) | btrfs receive

Key properties:
  - Server never sees DEK or plaintext
  - encrypted_blob is identical for all recipients (no re-encryption of bulk data)
  - Re-encryption key rk_A→B is one-directional (can't derive alice_sk from it)
  - Lattice-based: quantum-resistant
```

### Performance Characteristics

| Operation | Time | Notes |
|-----------|------|-------|
| XChaCha20 encrypt 2GB stream | ~0.7s | ~3 GB/s on modern CPU |
| Lattice-based key wrap (256-bit DEK) | ~1ms | OpenFHE BFVrns |
| Re-encryption key generation | ~5ms | Alice-side, once per recipient |
| Proxy re-encryption of wrapped DEK | ~2ms | Server-side, per-share operation |
| Key unwrap (Bob decrypts DEK) | ~1ms | Bob-side |

The bulk data operation (XChaCha20) dominates. PRE adds negligible overhead.

### Mapping onto Biscuit Capabilities

The capability model from rbac-design.md composes naturally:

```
// Authority block includes encrypted key material
authority {
  vm("vm-abc-123");
  snapshot("my-checkpoint");
  owner("alice");
  wrapped_dek("base64-of-lattice-encrypted-dek");
  right("vm-abc-123", "restore");
  right("my-checkpoint", "read");
}

// Alice attenuates and re-wraps for Bob
// (client-side: attenuate rights + include re-encrypted DEK)
check if operation($op), $op in ["restore"];
check if time($t), $t < 2026-04-01T00:00:00Z;
// wrapped_dek is now re-encrypted for Bob's key
```

**Two authorization layers**:
1. **Biscuit**: "Is this user allowed to access this snapshot?" (Datalog evaluation)
2. **PRE**: "Can this user decrypt the snapshot?" (cryptographic capability)

These are independent — you need BOTH to access a snapshot. A valid Biscuit without the DEK gives you metadata access but not contents. A DEK without a valid Biscuit is rejected by the API.

### Recrypt Key Hierarchy for Mjolnir

```
User Identity (OIDC sub claim via Identikey)
  ↓ registered public key
User Keypair (lattice-based, client-side)
  ├── Per-snapshot DEK wrapping (encrypt DEK with user's public key)
  ├── Re-encryption key generation (for sharing)
  └── Signature (ML-DSA-87 for snapshot metadata integrity)

Server Role:
  - Stores encrypted blobs + wrapped DEKs
  - Performs re-encryption when given rk_A→B
  - NEVER holds any private key
  - NEVER sees any DEK in plaintext
```

### Integration with Recrypt's Existing Design

Recrypt already implements:
- Per-file symmetric keys (maps to per-snapshot DEK)
- HDprint identifiers (human-readable key IDs — useful for CLI UX)
- Multi-signature authorization (maps to Biscuit's multi-block verification)
- Blake3 content verification (maps to btrfs send stream integrity)

What Mjolnir adds:
- btrfs send/receive as the serialization format (instead of raw files)
- Iroh for content-addressed blob transfer
- BTRFS CoW for local snapshot efficiency
- Biscuit for authorization (complementing PRE for encryption)

## Confidence

**High.** The envelope encryption + PRE pattern is well-established. Recrypt implements the exact primitives needed. The composition with Biscuit capabilities is clean — two orthogonal concerns (authorization + encryption) that reinforce each other. The main unknowns are integration engineering, not architectural feasibility.

## Sources

- Recrypt README: quantum-resistant PRE with OpenFHE BFVrns + XChaCha20 + Blake3
- `docs/plans/rbac-design.md` — Biscuit capability token design
- `docs/plans/rbac-design.md:77-106` — Biscuit authority blocks
- `docs/plans/rbac-design.md:118-164` — Rights attenuation examples
- `lib/mjolnir/btrfs.ex:80-113` — Snapshot creation with metadata sidecar
- `lib/mjolnir/vm.ex:1209-1250` — Snapshot flow (where DEK wrapping integrates)

## Open Questions

1. **Where does the re-encryption key live?** Options: (a) Alice sends rk_A→B directly to the server API, (b) rk_A→B is embedded in an attenuated Biscuit token, (c) stored in snapshot metadata `access_grants`. Option (b) is most elegant but increases token size.

2. **Key discovery**: How does Alice get Bob's public key to generate rk_A→B? Options: (a) Identikey key registry (OIDC provider stores public keys), (b) FOKS-style federated key lookup, (c) out-of-band exchange.

3. **Revocation after sharing**: If Alice revokes Bob's access, the re-encrypted wrapped_dek still exists. Options: (a) server deletes the access_grant entry (Bob can't fetch it), (b) re-encrypt the snapshot with a new DEK (expensive — requires re-encrypting the blob), (c) rely on Biscuit expiry (Bob's capability token expires).

4. **Group sharing**: If a snapshot is shared with a team, do we generate rk_A→member for each member? Or use a team key (like FOKS's PTK) and re-encrypt to the team key once? Team keys are more scalable but require team key infrastructure.

5. **Recrypt maturity**: Recrypt is Phase 1 of 8 in implementation. Can Mjolnir depend on it, or should we implement a simpler PRE scheme initially and migrate to Recrypt later?
