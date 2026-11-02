# add-capability-hop — independent blind take

Written before opening the change design, tasks, or delta; sources: proposal Why, living secret-tokenator spec, identikey-capability 0.1.0 src/lib.rs, and Deposit.publish/3.

1. Pin the hop as an append to the verified input Biscuit, preserving the authority and every existing block and check.
2. Refuse reminting or replacing the original holder check to make a downstream recipient pass.
3. Pin what a recorded hop means: nextKey chain integrity does not by itself authenticate a named person or prove delivery.
4. Pin structured hop fields and safe construction so metadata cannot become arbitrary Datalog or authorization facts.
5. Require authorization after append to be no broader than before for every resource, operation, and holder context.
6. Refuse token-supplied holder facts and any route that lets hop metadata satisfy the verifier's holder proof.
7. Pin malformed, untrusted-root, tampered, and non-appendable token failures without emitting a replacement token.
8. Preserve the opaque-vault boundary: no secret bytes, unsalted hashes, or new secret-bearing logs in hop data or failures.
9. Require multi-hop and adversarial tests for prior-check retention, wrong or missing holder, changed resource or operation, and tampering.
10. Tradeoff: portable nextKey attenuation is a small composable record, but cannot promise complete history or verified actor identity without additional machinery.
