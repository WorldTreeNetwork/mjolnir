1. Pin the already mounted POST challenge and redeem routes on the existing API; refuse a second route or overlay listener.
2. Pin ceremony as handler-authenticated access with no inherited control-plane scopes; refuse skip-auth or a required VM JWT.
3. Describe the actual Auth precedence, including operator and presented credentials, without reviving the obsolete localhost-bypass model.
4. Pin Ed25519 signing to the exact newline tuple: domain, nonce, submitted Biscuit base64, and secret id, with no trailing newline.
5. Require proof by the token-named holder and denial of holderless tokens; signature validity alone is insufficient authorization.
6. Preserve fail-closed nonce handling, including expiration, reuse, concurrent consumption, and consumption before proof validation.
7. Resolve the living copy-out contract of value plus salt against the current value_b64-only handler without weakening salted commitments.
8. Require a real holder-proof round trip through the existing router and negative cases for altered tuple fields and unauthorized rights.
9. Refuse changes to mint, hop, guest fencing, or egress policy merely to reconcile this redeem specification.
10. Tradeoff: consuming a nonce before verification burns failed attempts but simplifies replay exclusion; document retry-by-new-challenge explicitly.
