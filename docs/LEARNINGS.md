# Learnings

Hard-won facts from folded changes. One dated line each.

- **2026-08-16 / add-buzz-local-client:** Folding an architecture-plus-one-slice change must not import unimplemented SHALLs into `openspec/specs/`. Built truth is fail-closed `Mjolnir.Admit` plus `:never` refuses `DormantRegistry`; leftover SHALLs went to PENDING `add-buzz-local-runtime`.
- **2026-08-16 / add-buzz-local-client:** The I5 wake hole was `DormantRegistry` thaw on any `deliver_message`, not Reconcile — `restart_policy: never` already finalizes a stranded record.
- **2026-08-16 / add-buzz-local-client:** Same-family advise cannot sole-accept (ADR-005). Grok authored the ADR; Fable + Sol had to accept.
