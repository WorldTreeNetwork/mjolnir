# Independent take before reading the design and tasks

1. Bind kind to an authenticated namespace and one owner decision across concurrent mints and renewals.
2. Treat omission on legacy room tokens as protected and require positive evidence of open at the gateway.
3. The pinned JWT wire decoder refuses unknown fields. A claim requires a reader-first rollout.
4. A reserved segment gives disjoint namespaces for ordinary room tokens without changing the verifier.
5. Tenant-wide signed grants exist in tests. Ordinary mint confinement and relay-wide confinement are different guarantees.
6. Check exact canonical signed roots independently of transport URL normalization and effective session grants.
7. Gateway admission must precede negotiation. The relay sees an ordinary token-authorized MoQ session.
8. A protected invitation must bind expected room identity and refuse any downgrade before media starts.
9. Key derivation, joins, renewals, presence and accounting need a consistent definition of room identity.
10. Weigh the operational cost of reader deployment against the lasting cost of two same-name rooms.
