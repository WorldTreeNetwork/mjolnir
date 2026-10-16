# Tasks

- [x] Write `docs/decisions/0013-site-alias-certs.md` with the four steer rules plus the send-back bounds: renewal reinstalls and does not append a `[[domain]]` that is not already present, on any branch; an unreadable alias index is an error (`503 alias_index_unreadable` on issue, and the renewal pass installs nothing); site-alias issuance returns `409 host_routed_elsewhere` before HTTP-01 when the host would classify as Local or Iroh. Note the `app_not_found` / `name_not_found` existence oracle as an accepted cost.
- [x] Point `docs/plans/http01-custom-certs.md` and `docs/plans/initiatives/identikey-sites.md` §6.5 at that ADR, including the site-only install exception, the renewal bound, and the 409
- [x] Fresh advise after preparation — accept, `reviews/2026-10-15-advise-2.md` (opus-arch-review). Contract: `proposal.md` Why + `specs/site-certs/spec.md`

## Answered (advise 2026-10-15, opus-arch-review — send-back)

- [x] S1: renewal never appends a `[[domain]]` that was not already present, on any branch. An unreadable alias index is an error, not a miss. Spec scenarios: "Hand-installed name renews without a new apex", "Deleted alias does not capture a sibling", "Unreadable index does not renew as a stranger". Design rule 4 and the renewal seam.
- [x] S2: site-alias issuance classifies before HTTP-01. Local or Iroh is `409 host_routed_elsewhere` and Let's Encrypt is not called. Reject and Parked still issue. Spec scenario "Host already routed elsewhere is refused". Design lookup.

## Not this change

- Issuer, ensure flag, router lookup, renewal classification, cert list, and tests — `add-sites-alias-certs` (`mjolnir-uktt.2.2`)
- Follow-on test on that node: a site-only `[[cert]]` config still classifies the host as `Reject(DomainMismatch)` before and after a renewal pass. Widen the ops `ensure` seam beyond 3-arity so fakes see the site-only flag.
- Static-site guide — that same follow-on, once the command works
- `mjolnir-kzrt`, `mjolnir-9bq.10`, Conduit, DNS-01
