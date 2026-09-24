# Independent take — recorded before reading design, tasks, or delta

1. Pin the unchanged v1 Challenge and Response bytes, signing domain, verification policy, and algorithm-committing holder fingerprint; refuse a Mjolnir identity-protocol fork.
2. Pin Challenge.aud to the expected edge stable XID, with a trustworthy client-side pin; refuse discovery data as its own trust anchor.
3. Require exact issued challenge matching, bounded lifetime, and atomic single-use consumption; define concurrent submission and restart behavior.
4. Require a separately domain-separated authorization signature from the authenticated holder that binds this specific identity exchange to the session public key, requested operation, and channel context.
5. Require a concrete channel-context derivation and verifier comparison for every supported transport; a transport name alone cannot prevent replay between connections.
6. Require proof of possession of the bound session key before granting its use, with explicit separation between identity success and authorization issuance.
7. Require canonical operation/resource encoding and equality with the executed request, plus local authorization policy; a valid holder signature alone must not confer arbitrary scope.
8. Preserve the v1 fingerprint namespace and distinguish holder keys from stable user XIDs and rotating edge keys; refuse raw-key fingerprint substitution or implicit account linking.
9. Treat C1/C2 and C3/C4 responses identically and keep identikey-core on the claimant side; refuse custody inference and protocol Schnorr additions.
10. Accept the extra signing and replay-state cost of two objects for identity-protocol reuse, provided vectors exercise success, replay, expiry, wrong edge/audience, altered request, key substitution, and cross-connection replay.
