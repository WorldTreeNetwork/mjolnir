# Design

No topology is chosen.

The parent names libcluster and Phoenix.PubSub. That is a candidate, not a decision. A cluster that resumes a Host worker during a reconcile can apply the same resource twice. The closed Host worker is per-node and does not have a lease.

## Open

- Second controller: in scope, or this stays a single node until a fleet exists.
- Bound: the parent's "N seconds" is unset. No test can pass without it.
- Claim: a survivor needs a lease that the dead node cannot also hold. That lease is not designed.

Activation is a human decision. Advise comes after the contract exists. This file is not that contract.
