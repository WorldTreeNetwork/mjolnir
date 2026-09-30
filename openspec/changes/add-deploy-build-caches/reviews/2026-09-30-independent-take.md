# Independent take — before opening the proposed contract

1. Pin empty, missing, evicted, or incompatible cache behavior to an equivalent runnable release; cached compiler output must never become an undeclared release dependency.
2. Pin cache configuration and output materialization to the snapshot-layer executor, including partial layer hits and the no-VM full-hit path.
3. Refuse shared writable cache trees: each build needs a private generation and an explicit concurrency policy for publishing successful work.
4. Pin publication to a concrete atomic host operation with a defined success boundary, immutable published data, and recovery at every interrupted transition.
5. Pin orphan cleanup to durable build/VM identity and positive evidence that writers are stopped; an Elixir after block or missing process alone is insufficient.
6. Refuse caller-controlled tenant or trust claims: authenticated owner/app authorization must govern reads, writes, cache administration, and CI/PR publication denial.
7. Refuse broad home-directory caching or implicit credential sharing; specify cache path containment and what less-trusted builds may read.
8. Pin compatibility to actual base/toolchain identity, including today's in-place alias rebuild and deploy-layer purge, without putting source hashes into mutable-cache identity.
9. Pin quota accounting, concurrent admission, active-generation eviction protection, and disk-full fallback to measurable behavior rather than an unbounded cleanup promise.
10. Accept the complexity of isolated CoW generations only with cold/warm correctness tests and a controlled virtiofs performance gate after the known build stalls are resolved.
