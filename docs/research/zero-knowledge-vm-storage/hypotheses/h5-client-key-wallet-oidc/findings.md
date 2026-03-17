# H5: Client-Side Key Wallet + OIDC Bridge (with FOKS Integration)

## Summary

The identity-to-crypto bridge is the linchpin of the zero-knowledge model. OIDC (Identikey) establishes *who you are*; client-side keys establish *what you can decrypt*. The discovery of FOKS (Federated Open Key Service, by the Keybase co-founders) dramatically simplifies this problem — FOKS provides exactly the key hierarchy, device management, signature chains, and federated key discovery that Mjolnir needs. Rather than building a custom key wallet, Mjolnir should integrate FOKS as its key management layer.

## Evidence

### The FOKS Key Hierarchy Maps Perfectly onto Mjolnir

```
FOKS Hierarchy              →  Mjolnir Mapping
─────────────────────────────────────────────────
Device Keys (never leave     →  Per-device keys for the `mjolnir` CLI
  the machine)                  (stored in OS keychain or encrypted file)

Per-User Keys (PUKs)         →  User's encryption identity
  rotate on device removal      (used to wrap/unwrap VM DEKs)
  encrypted for all devices     (all user's devices can decrypt)

Per-Team Keys (PTKs)         →  Shared access to team VMs/snapshots
  recursive team nesting        (org → team → sub-team)
  encrypted for members         (team members share PTK-wrapped DEKs)
```

**Key property**: When a device is revoked, PUKs rotate, which triggers cascading PTK rotation across all teams. This means: if a user loses their laptop, revoking that device automatically re-keys all shared snapshots. No manual key rotation needed.

### The OIDC → FOKS → Crypto Bridge

Instead of deriving keys from OIDC claims (which requires the server to know the derivation), the flow becomes:

```
User                    Identikey (OIDC)        FOKS Server         Mjolnir
  |                          |                      |                  |
  |-- OIDC Auth ----------->|                      |                  |
  |<--- JWT (sub claim) ----|                      |                  |
  |                          |                      |                  |
  |-- Register public key ----------------------->|                  |
  |   (one-time, verified    |                     |                  |
  |    by OIDC identity)     |                     |                  |
  |                          |                      |                  |
  |-- POST /api/vms (JWT + FOKS identity) --------------------------->|
  |                          |                      |                  |
  |                          |    look up user's    |                  |
  |                          |    public key ------>|                  |
  |                          |    <--- PUK ---------|                  |
  |                          |                      |                  |
  |<--- { vm_id, biscuit, wrapped_dek(PUK) } -------------------------|
  |                          |                      |                  |
  |  (DEK wrapped with user's FOKS PUK —                              |
  |   only the user's devices can unwrap)                              |
```

**The server never holds the user's private key.** It only knows the public key (via FOKS lookup). It wraps the DEK with the public key and stores the wrapped DEK. Only the user's devices (which hold the FOKS device keys → PUK chain) can unwrap.

### FOKS vs Custom Key Wallet

| Aspect | Custom Wallet | FOKS |
|--------|--------------|------|
| Key hierarchy | Build from scratch | Device → PUK → PTK, battle-tested |
| Multi-device | Manual export/import or seed phrase | Automatic — PUK encrypted for all devices |
| Device revocation | Manual re-key everything | Cascading automatic re-keying |
| Key discovery | Custom registry in Identikey | Federated protocol with Merkle tree accountability |
| Team/group keys | Build from scratch | Recursive PTK nesting |
| Signature chains | Not planned | Built-in, prevents server tampering |
| Post-quantum | Depends on Recrypt | Curve25519 + ML-KEM |
| Federation | Not planned | Native — each Mjolnir node can run a FOKS server |
| Maturity | 0 (not started) | Production-ready, MIT-licensed, Go |

### How FOKS Composes with Recrypt and Biscuit

Three orthogonal concerns, each handled by the right tool:

```
FOKS    = Key Management   (who holds which keys, device/team hierarchy)
Recrypt = Re-encryption    (transform ciphertext between keys without decrypting)
Biscuit = Authorization    (who is allowed to do what, with Datalog policies)

Composition:
  1. User authenticates via OIDC (Identikey) → gets JWT
  2. User's FOKS identity provides their public key (PUK)
  3. Snapshot DEK wrapped with user's PUK (stored in snapshot metadata)
  4. Biscuit capability token authorizes API access to the snapshot
  5. For sharing: Recrypt re-encrypts wrapped DEK from Alice's PUK to Bob's PUK
     - Alice generates rk_A→B using her FOKS private key + Bob's FOKS public key
     - Server transforms wrapped DEK without seeing plaintext
     - Bob's FOKS devices can unwrap the re-encrypted DEK
  6. Team sharing: DEK wrapped with team PTK (all team members can unwrap)
     - When team membership changes, FOKS rotates PTK automatically
     - Old snapshots remain accessible (PTK chain preserves history)
```

### Identikey Extensions

Since the team controls Identikey, they can:
1. **Add a FOKS public key claim to the JWT** — `foks_pub_key` claim in the OIDC token, linking OIDC identity to FOKS identity
2. **Run FOKS as a sidecar to Identikey** — same infrastructure, same auth domain
3. **Use FOKS's Merkle tree as the key registry** — Identikey doesn't need to store keys itself, just point to the FOKS server
4. **Cross-realm federation** — different Identikey realms can share via FOKS federation protocol

### Client UX

```bash
# First-time setup (generates device key, registers with FOKS)
mjolnir init
# → Generates Ed25519 device key, stores in OS keychain
# → Authenticates with Identikey (device auth flow)
# → Registers device key with FOKS server
# → Derives PUK, encrypted for this device

# Multi-device (add a new laptop)
mjolnir device add
# → OIDC auth on new device
# → New device key generated
# → Existing device approves (or backup key used)
# → PUK re-encrypted for new device set

# Spawn VM (DEK wrapped with PUK)
mjolnir spawn
# → Server wraps random DEK with user's PUK (from FOKS)
# → VM boots, client injects DEK via Iroh
# → "🔒 Snapshot encryption: active (PQ-secure)"

# Share snapshot
mjolnir snap share my-checkpoint --to bob@identikey.io --ops restore --ttl 7d
# → Looks up Bob's PUK via FOKS federation
# → Generates re-encryption key (Recrypt)
# → Attenuates Biscuit capability
# → Bob gets: capability token + re-encrypted DEK
```

## Confidence

**High.** FOKS solves the hardest part of the problem (key lifecycle management) with a production-quality, MIT-licensed implementation. The composition with Recrypt and Biscuit is clean — three orthogonal systems, each handling its own concern. The main risk is integration complexity (Go ↔ Rust ↔ Elixir), but FOKS exposes a protocol-based API that can be consumed from any language.

## Sources

- https://foks.pub/ — FOKS project documentation
- https://foks.pub/docs/crypto/ — Cryptographic architecture (key hierarchy, signature chains, Merkle trees)
- https://foks.pub/docs/arch/ — Federation model and trust architecture
- https://github.com/foks-proj/go-foks — Source code (MIT license)
- https://github.com/IdentiKey/recrypt — Proxy re-encryption system
- `docs/plans/rbac-design.md` — Biscuit capability token design
- `docs/plans/rbac-design.md:167-218` — OIDC to capability bridge flow

## Open Questions

1. **FOKS is Go, Mjolnir is Elixir/Rust** — Integration options: (a) Run FOKS server as sidecar process, communicate via gRPC/HTTP, (b) Port key primitives to Rust (significant effort), (c) Use FOKS's protocol definitions and implement a minimal client in Rust. Option (a) is most pragmatic.

2. **FOKS + Recrypt crypto compatibility** — FOKS uses Curve25519 + ML-KEM. Recrypt uses OpenFHE BFVrns (lattice-based). These are different lattice schemes. Can they share a key hierarchy? Or does the user need two keypairs? Ideally Recrypt adopts ML-KEM to align with FOKS.

3. **FOKS server hosting** — Should each Mjolnir node run a FOKS server? Or should there be a central FOKS server per Identikey realm? Central is simpler but adds a dependency. Per-node leverages FOKS's federation but is more complex.

4. **Signature chain verification in the guest** — The guest agent (Rust) needs to verify FOKS signature chains to trust incoming key material. This means implementing FOKS chain verification in Rust, or calling out to a FOKS client binary.

5. **PUK rotation impact on encrypted snapshots** — When a PUK rotates (device revocation), existing wrapped DEKs are encrypted with the old PUK. FOKS preserves the PUK chain (old PUKs remain usable for decryption), but this means revoked devices that cached old PUKs could still decrypt old snapshots. Is this acceptable? Forward secrecy vs backward access.
