# Tasks

- [x] Advise accept on this contract (architecture; gating reader per `vary-reader`). Contract `d94e71e`; see `reviews/2026-11-21-advise-2.md` (astra-arch-review).
- [x] Spike stage: resolve every line under "Unverified hypotheses" in `design.md`, on the Framework laptop; amend this change if one fails
- [x] `docs/decisions/0016-edge-relay.md` from D1–D9 and the spike results
- [x] Crate `native/mjolnir_relay`: own `moq_relay::Config`, certificate from files, own admission loop, `IrohSessions` with a deny-by-default policy, pulls off
- [x] Refusal tests: no token, wrong tenant, expired, removed key, path outside `t/<owner>/`, ticket path
- [x] `systemd/mjolnir-relay.service` with its own user; drain on stop
- [x] `deploy.sh --relay` and `build-native.sh relay`; no other flag restarts the unit
- [x] Certificate subject for `:relay_host` and the root-owned copy step at issue and renewal
- [x] Config keys `:relay_enabled`, `:relay_host`; firewall opening for UDP 443 when enabled
- [x] Docs: `docs/guide/host-sidecars.md`, a runbook, `CLAUDE.md`
- [ ] ASK: Duke enables the relay on prod and picks `:relay_host`
- [ ] EYES: real-name journey on prod — `irl publish --relay` from behind NAT, a browser on another network plays it, a gateway restart does not interrupt it

- Handoff: `add-relay-room-auth` defines the paths under `t/<owner>/` and the mint.
- Finding to carry: the host can read relayed media (see `design.md`).

## Owed by advise 2026-11-20 (astra-arch-review)

- [x] R1: Define the minimum relay token profile, trust/audience/purpose binding, operation rights, expiry/session behavior, and canonical path enforcement in this node; add negative publish/subscribe coverage on both transports independent of the deferred room mint. Closed by amendments `aed8291` and `d94e71e`; see `reviews/2026-11-21-advise-2.md`.
- [x] R2: Define validated atomic verification-key activation, startup/reload failure policy, trusted file permissions, and an observable or bounded removal-completion point; add missing/corrupt/removed-key scenarios. Closed by amendment `aed8291`; see `reviews/2026-11-21-advise.md`.
- [x] R3: Specify private certificate staging and source/destination custody, safe root-controlled copy, validated coherent pair activation, failure retention, running expiry behavior, and preservation of site-certs invariants; add permission and renewal-failure scenarios without preempting the planned reload/subject spikes. Closed by amendments `aed8291` and `d94e71e`; see `reviews/2026-11-21-advise-2.md`.
- [x] R4: Reconcile enable/disable transitions with deploy ownership; specify relay firewall cleanup, failed-enable behavior, both-transport shutdown, and bounded draining; add transition and unrelated-deploy scenarios. Closed by amendment `aed8291`; see `reviews/2026-11-21-advise.md` for the separate new R5 scenario contradiction.

## Owed by fresh advise 2026-11-21 (astra-arch-review)

R1 and R3 were left open for the residuals in `reviews/2026-11-21-advise.md`; amendment `d94e71e` closes them, as recorded in `reviews/2026-11-21-advise-2.md`.

- [x] R5: Qualify the never-enabled-host scenario so it does not forbid first intentional enable; add a successful first-enable scenario asserting active unit, tagged rule, and unchanged gateway/controller processes. Closed by amendment `d94e71e`; see `reviews/2026-11-21-advise-2.md`.
