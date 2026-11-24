# Blind take — add-call-e2ee — written before design.md / tasks.md / spec delta / ADR 0016 / ADR 0017

Inputs read: bd prime; beads mjolnir-rurh, .1-.9, pfeq; proposal.md lines 1-12 (Why only);
openspec/specs/edge-relay/spec.md; openspec/specs/relay-room-auth/spec.md;
native/mjolnir_relay/src/{lib,main,iroh_sessions}.rs + Cargo.toml; lib/mjolnir/relay/mint.ex;
docs/architecture.md:856-877; docs/LEARNINGS.md lines 74-90.
Contamination: the bead NOTES already name two proposed decisions (epoch in last path segment
bound to the participant label; removal closes old broadcasts). Not blind on those two.

1. PIN the key boundary: the content credential never transits or rests on any Mjolnir process
   (API, mint, relay, logs, typed log, mailbox spool, deploy secrets). Browser: fragment only,
   scrubbed from the address bar/history at once, no-referrer, no third-party script on the page.
2. PIN (key, nonce) uniqueness as a stated invariant, not an upstream assumption: one shared
   secret, many senders, many reconnects. What makes a publisher session's key fresh? If a
   reconnect or a rejoin restarts group/frame sequences under the same derived key, AES-GCM
   breaks (plaintext XOR + forgery). Name the freshness input and who mints it.
3. PIN that hazard for Mjolnir specifically: guests are checkpointable. A publisher restored
   from a BTRFS/memory snapshot resumes with the same key state and counters. The upstream
   draft will not have considered this. Restore must force a fresh key input.
4. PIN what the ciphertext is bound to (AAD): path/track, group, frame, key id/epoch. The relay
   may drop and delay; it must not be able to replay, reorder across tracks, or splice one
   participant's frames into another's. State that members can forge each other (shared secret)
   and that only the relay's token path scope stands between members.
5. PIN metadata honestly: owner id, room name and participant label are cleartext in the token
   root/publish pattern AND in the controller's mint log line. The goal says track names and
   catalogs are unreadable; say which names stay visible, and make the shipped client use opaque
   room and participant labels or admit the operator sees them. Sizes/timing reveal who talks.
6. PIN removal semantics: no forward secrecy, no post-compromise security; a removed member
   keeps the old secret AND a working room token until exp. Removal = new credential over a
   channel that is not Mjolnir + every publisher switching + nothing new under the old key.
   Define who decides and how a late joiner learns the current credential.
7. REFUSE plaintext fallback: a client with a credential never plays or publishes an unprotected
   broadcast in that room, and a relay-announced plaintext look-alike must not be rendered.
8. REFUSE our own crypto and silent divergence: one upstream pin on both sides; Rust<->JS
   vectors in both directions are a gate, because two implementations of an unpublished draft is
   where a nonce-derivation mismatch hides. Any departure from the draft's layout needs a stated
   reason and a wire/profile version that fails closed.
9. REFUSE overclaiming: with an operator-served page this is protection against the relay
   process, its logs, a seized relay box and a passive operator. Not against an operator who
   serves different JS. (Accepted by Duke for this iteration; the contract must say exactly that.)
   Non-extractable WebCrypto keys stop export of key bytes, not use of the key or reading frames.
   Guests: the host can read guest memory, so a guest participant is protected from the relay only.
10. TRADEOFF: shared link-secret + epoch rekey on the upstream draft (small, interoperable with
   moq, no delivery service; but experimental, single-vendor, no FS/PCS/sender auth) versus
   MLS/SFrame (real membership; no implementation at the pin, needs a delivery service). Link
   secret is the right size now IF the credential/KDF labels are versioned so MLS can replace
   the key source later. And the relay should need zero code for E2EE: if the design changes the
   relay or the mint, ask why. Content-layer E2EE is also the precondition for ever letting
   untrusted peers carry fan-out, which is the original bandwidth goal.
written 2026-11-24T06:43:00Z
