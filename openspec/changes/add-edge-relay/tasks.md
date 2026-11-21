# Tasks

- [ ] Advise accept on this contract (architecture; gating reader per `vary-reader`)
- [ ] Spike stage: resolve every line under "Unverified hypotheses" in `design.md`, on the Framework laptop; amend this change if one fails
- [ ] `docs/decisions/0016-edge-relay.md` from D1–D9 and the spike results
- [ ] Crate `native/mjolnir_relay`: own `moq_relay::Config`, certificate from files, own admission loop, `IrohSessions` with a deny-by-default policy, pulls off
- [ ] Refusal tests: no token, wrong tenant, expired, removed key, path outside `t/<owner>/`, ticket path
- [ ] `systemd/mjolnir-relay.service` with its own user; drain on stop
- [ ] `deploy.sh --relay` and `build-native.sh relay`; no other flag restarts the unit
- [ ] Certificate subject for `:relay_host` and the root-owned copy step at issue and renewal
- [ ] Config keys `:relay_enabled`, `:relay_host`; firewall opening for UDP 443 when enabled
- [ ] Docs: `docs/guide/host-sidecars.md`, a runbook, `CLAUDE.md`
- [ ] ASK: Duke enables the relay on prod and picks `:relay_host`
- [ ] EYES: real-name journey on prod — `irl publish --relay` from behind NAT, a browser on another network plays it, a gateway restart does not interrupt it

- Handoff: `add-relay-room-auth` defines the paths under `t/<owner>/` and the mint.
- Finding to carry: the host can read relayed media (see `design.md`).

## Owed by advise 2026-11-20 (astra-arch-review)

- [ ] R1: Define the minimum relay token profile, trust/audience/purpose binding, operation rights, expiry/session behavior, and canonical path enforcement in this node; add negative publish/subscribe coverage on both transports independent of the deferred room mint. See `reviews/2026-11-20-advise.md`.
- [ ] R2: Define validated atomic verification-key activation, startup/reload failure policy, trusted file permissions, and an observable or bounded removal-completion point; add missing/corrupt/removed-key scenarios. See `reviews/2026-11-20-advise.md`.
- [ ] R3: Specify private certificate staging and source/destination custody, safe root-controlled copy, validated coherent pair activation, failure retention, running expiry behavior, and preservation of site-certs invariants; add permission and renewal-failure scenarios without preempting the planned reload/subject spikes. See `reviews/2026-11-20-advise.md`.
- [ ] R4: Reconcile enable/disable transitions with deploy ownership; specify relay firewall cleanup, failed-enable behavior, both-transport shutdown, and bounded draining; add transition and unrelated-deploy scenarios. See `reviews/2026-11-20-advise.md`.
