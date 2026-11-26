# Tasks — add-turn-service

No product code in this pass. Checked items are observations already captured. Unchecked items are the implementation, and each names the test that has to fail before the code lands.

## Spikes

- [x] S1 eturnal accepts the username shape, a second secret, and refuses expired Allocate and Refresh. Evidence: `spikes/evidence/s1-allocate.txt`, `s1-second-secret.txt`, `s1-expiry.txt`, `s1-already-expired.txt`, `s1-eturnal.log`.
- [x] S1 refuses blacklisted IPv4 peers with 403 and refuses TCP transport with 442. Evidence: `spikes/evidence/s1-blacklist.txt`, `s1-tcp-transport.txt`.
- [x] S1 IPv4-mapped and IPv6 peers on an IPv4 allocation return 443, not 403. Evidence: `spikes/evidence/s1b-mapped.txt`.
- [x] S1 a live allocation still sends after the username timestamp. Evidence: `spikes/evidence/s1c-send.txt`, `s1c-sessions.txt`.
- [x] S1 session list shows username and byte counts. Evidence: `spikes/evidence/s1-sessions.txt`.
- [x] S2 uid OUTPUT drops with an empty daemon blacklist. Counters moved; captures on `dummy-mjolnir` and `lo` were empty; `eno1` saw the public peer. Evidence: `spikes/evidence/s2-counters.txt`, `s2-tcpdump-dummy.txt`, `s2-tcpdump-lo.txt`, `s2-tcpdump-eno1.txt`.
- [x] Port range sits above the ephemeral range on morphie and on production (read-only). Evidence: `spikes/evidence/host.txt` and the verdict.

## Implementation (after advise)

- [ ] Mint module. First test, not in tree: `test/mjolnir/turn/mint_test.exs` (owner from `sub`, forged owner ignored, HMAC, expiry, `c1`/`g1`). Fails until `lib/mjolnir/turn/mint.ex` exists.
- [ ] Routes and scope `turn:relay`. First test, not in tree: `test/mjolnir/api/turn_credentials_test.exs` plus the room-mint assertion for `ice_servers`. Fails until the router and `auth.ex` scope list change.
- [ ] Pure rule builder for the DROP list, the relay port match, and the overlap refusal. First test, not in tree: `test/mjolnir/turn/rules_test.exs`. The live counter observation stays `spikes/evidence/s2-counters.txt`.
- [ ] `deploy.sh --turn`, unit, `STUN_SERVICE=false`, user, `/etc/mjolnir-turn/`. Observation the flag must keep: a deploy without `--turn` does not restart this unit (same bar as `--relay`). No test harness runs that SSH. The implementation records the command output on morphie, not on production.
- [ ] `scripts/turn-mint-secret.sh` overlap. Observation still missing, so this task starts by capturing it: reload eturnal with a live allocation and show the allocation still listed, on morphie, dummy secret. Do not write the script's "reload is safe" claim before that capture.
- [ ] Add `3478` to `:published_port_reserved`. First test: extend `test/mjolnir/published_ports_test.exs` (the new example fails until the list contains 3478).
- [ ] Rate cap install and remove by the same flag. Lab observation required on morphie before the task is checked: the cap is present when the unit is up and gone when `--turn` removes it.
- [ ] Runbook `docs/runbooks/turn-service.md` and fold only after advise and the tasks above.

## ASK (Duke has not confirmed these)

- [ ] **ASK** eturnal, not Pion and not coturn. Recommendation: eturnal. Spike S1 passed the fit bar with the expiry limit in the design.
- [ ] **ASK** own unit, off by default, `deploy.sh --turn` only. Recommendation: yes.
- [ ] **ASK** ports 3478 and 61000–65535, no 5349, no 443. Recommendation: yes. Ephemeral range does not overlap.
- [ ] **ASK** REST credentials, `ice_servers`, scope `turn:relay`, overlap script. Recommendation: yes.
- [ ] **ASK** kernel filter matches uid and relay source port, not uid alone. Recommendation: yes, because uid alone drops STUN replies to private clients.
- [ ] **ASK** host-wide cap default 100 Mbit/s. Recommendation: 100 until `mjolnir-rurh.4`.
- [ ] **ASK** production enable on `45.76.77.97`. Recommendation: no, until `turn.worldtree.network` has an A record to that address and Duke says enable.
