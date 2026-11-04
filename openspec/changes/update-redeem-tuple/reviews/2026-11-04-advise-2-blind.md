1. Pin a single unambiguous byte encoding shared by holder signing, verifier nonce use, and the later proxy client.
2. Pin the signed token identity and secret id so neither can be substituted across a valid proof.
3. Pin the operation context so a proof for upstream use cannot silently become permission for copy-out.
4. Pin every supported upstream request input to the verified frame, including a precise rule for bodies and headers.
5. Refuse any path that verifies one method or resource and then executes an unsigned alternative.
6. Preserve nonce consumption before proof validation, including burn-on-failure and atomic replay exclusion.
7. Preserve holder-required Biscuit authorization and stored salt/commitment verification before releasing a secret.
8. Refuse compatibility fallback to the four-line proof if it would bypass the new request binding.
9. Require fixed byte vectors and negative cases for field mutation, malformed inputs, replay, and cross-endpoint use.
10. Tradeoff: a narrow breaking runtime profile can be safer and easier to audit than broad request support, provided its limits and later proxy migration are explicit.
