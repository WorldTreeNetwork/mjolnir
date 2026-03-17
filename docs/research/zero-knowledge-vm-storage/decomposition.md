# Zero-Knowledge VM Storage: Research Decomposition

## Core Question

How can Mjolnir achieve a zero-knowledge server model where the server cannot see
VM contents, using btrfs send/receive for snapshot transfer, proxy re-encryption
(Recrypt) for capability-based key delegation, and client-side key management —
while integrating with Identikey OIDC as the identity bootstrap?

## Sub-Questions

1. **What does "server can't see it" actually mean for a VM hypervisor?**
   The server runs the VM. It has /proc/pid/mem, it controls virtio-fs, it owns the
   BTRFS subvolume. What's the realistic trust boundary? Is confidential computing
   (SEV-SNP, TDX) required, or can we get meaningful guarantees with encryption alone?

2. **How do we inject secrets into a VM without the server seeing them?**
   The guest agent currently receives config over vsock from the host. If the host is
   untrusted, how does the user get their decryption key into the VM? Iroh direct
   connection? Sealed secrets? Remote attestation?

3. **How does proxy re-encryption (Recrypt) map onto snapshot sharing?**
   Recrypt can transform ciphertext from Alice's key to Bob's key without decrypting.
   How does this compose with btrfs send/receive streams? What's the performance
   overhead for multi-GB streams? Can we use the capability model from rbac-design.md?

4. **What's the right encryption layer for btrfs send/receive streams?**
   XChaCha20 vs AES-256-GCM vs AES-512 (Rijndael-512). Streaming encryption of
   multi-GB data. Key management for the stream itself. How does this interact with
   BTRFS's own checksumming?

5. **How do client-side keys work with OIDC identity?**
   Users authenticate via Identikey. But if the server is untrusted, the server can't
   derive keys from OIDC claims. The user needs a local key/wallet. How does this
   integrate with Recrypt's key model? What's the UX for key provisioning?

6. **What does distributed snapshot sync look like with encrypted blobs?**
   Iroh can transfer content-addressed blobs. But if blobs are encrypted per-user,
   there's no cross-user dedup. How does re-encryption help here? What's the node
   discovery and availability model?

## Ranked Hypotheses

| # | Hypothesis | Plausibility | Info Value | Agent |
|---|-----------|-------------|-----------|-------|
| 1 | Encrypt-at-snapshot with client-held DEK, inject DEK via Iroh direct channel | High | High | architect |
| 2 | Proxy re-encryption enables server-side snapshot sharing without server seeing plaintext | High | Very High | document-specialist |
| 3 | Confidential computing (SEV/TDX) is needed for true zero-knowledge runtime | Medium | Very High | architect |
| 4 | btrfs send streams can be encrypted with XChaCha20 streaming cipher at near-zero overhead | High | High | scientist |
| 5 | Client-side key wallet bootstrapped from OIDC + device key provides the identity-to-crypto bridge | Medium | High | analyst |
