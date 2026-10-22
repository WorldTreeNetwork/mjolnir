# Independent blind take — add-offline-jwks

Written before opening design.md, tasks.md, or the delta; inputs are the packet's Why, the web-pty-edge living spec, and the four cited code files.

1. Pin boot completion to local initialization: issuer DNS, TLS, or HTTP failure must not prevent the supervisor from starting.
2. Pin cached-key verification to the same signature, algorithm, issuer, and time checks as live-key verification; preserve downstream authorization.
3. Bind persisted trust to the configured issuer and key source so a configuration change cannot silently reuse another authority's keys.
4. Refuse unknown or ambiguous key identifiers, malformed keys, and any empty or failed refresh that would destroy the last usable set.
5. Define key retirement explicitly: token expiry and key trust lifetime are different, and overlap needs a bounded, restart-stable rule.
6. Pin disk updates to validated data, atomic replacement, restrictive file/directory permissions, and placement outside btrfs_root.
7. Refuse a cache parse, permissions, or I/O failure becoming either an authentication bypass or a new application boot dependency.
8. Pin refresh to bounded background work that cannot stall known-key verification; specify recovery and missing-cache behavior.
9. Prove outage reboot, rotation overlap, unknown-kid rejection, issuer mismatch, cache corruption, and bootstrap seeding with focused tests.
10. Accept the availability tradeoff of trusting previously fetched keys during an outage only with an explicit retention/revocation policy and visible cache age.
