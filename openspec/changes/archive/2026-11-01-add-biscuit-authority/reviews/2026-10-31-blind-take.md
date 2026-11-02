1. Pin one durable Ed25519 authority per host so a token minted before restart verifies afterward.
2. Pin an explicit provisioning boundary; ordinary keypair generation must not silently establish or replace production authority.
3. Pin the verifier public key to the private root by derivation and reject configured mismatches before serving authority-dependent work.
4. Refuse fallback to a fresh root when durable material is missing, corrupt, unreadable, or wrongly permissioned.
5. Pin creation and publication semantics so concurrent initialization or a crash cannot expose partial keys or competing roots.
6. Refuse secret transport through process arguments: the current mint RPC embeds private_hex in System.cmd argv.
7. Pin private-key custody, restrictive storage, and redacted failure paths; callers that only verify need only the public half.
8. Preserve the existing identikey-capability mint/verify and holder-check contract without another crypto path or Blake3 changes.
9. Pin tests for restart continuity, public/private mismatch, failed initialization, and separation from fresh test keypairs.
10. Tradeoff: operator-provisioned roots simplify durable identity and recovery but add setup; automatic first-use creation must earn its extra race and loss semantics.
