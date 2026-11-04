# Independent take before design and tasks

1. Pin one unambiguous, domain-separated byte frame with explicit field order, byte lengths, encoding, and version behavior.
2. Bind the exact nonce, capability bytes or explicitly chosen textual representation, secret id, method, and resource used by the operation.
3. Refuse an egress path that verifies one tuple and subsequently reads unsigned request fields or silently substitutes defaults.
4. Specify normalization once; verification and upstream dispatch must agree on the signed method and resource.
5. Preserve consume-before-proof, burning failed attempts, 60-second in-memory expiry, restart invalidation, and atomic single use.
6. Reject malformed field types and encodings without exceptions, secret reads, upstream calls, or acceptance of the old four-line signature.
7. Retain Biscuit-named holder verification and authorization of redeem for the same secret id, including rejection of holderless tokens.
8. Clarify what the request commitment covers, how copy-out and egress interpret it, and which proof checks remain outside this handler.
9. Require independently specified golden bytes, per-field tampering tests, nonce failure/replay tests, and evidence that egress uses the verified request.
10. Tradeoff: a strict replacement simplifies fail-closed semantics but breaks existing signers; record the api-proxy coordination boundary without adding fallback acceptance.
