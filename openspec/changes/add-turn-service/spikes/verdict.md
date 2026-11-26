# Spike verdicts — add-turn-service

Host: `morphie` (Arch, `192.168.0.164`, interface `eno1`, `dummy-mjolnir` at `10.200.0.1/32`). The Framework laptop (`192.168.0.108`, `10.43.1.243`, `100.121.90.25`) timed out on SSH. Nothing here ran on `45.76.77.97`.

Image: `ghcr.io/processone/eturnal:1.12.3`. Secret in the lab config was the dummy string `dummy-turn-secret-not-a-real-key` (and a second dummy for overlap). Neither is a production secret. The lab user `mjolnir-turn-spike`, the container, and the `mjolnir-turn` iptables chain were removed after the run.

Client: `turn_client.py` (long-term MESSAGE-INTEGRITY, TURN REST password). Runner: `run-s1-s2.sh`, follow-up `run-s2-followup.sh`.

## Port range (observation, not a spike)

| Host | `net.ipv4.ip_local_port_range` | Notes |
|---|---|---|
| morphie, 2026-11-26 | `32768 60999` | `spikes/evidence/host.txt` |
| production `45.76.77.97`, read-only, 2026-11-26 | `32768 60999` | UDP 443 is bound. UDP 3478 is not. `MJOLNIR_PUBLISHED_PORT_RANGE` is not set in `/etc/mjolnir/env`. |

`61000–65535` sits above that ephemeral range and above the published-port guidance (ranges stay below 32768). `3478` is not in `:published_port_reserved` (`config/config.exs`). No overlap with the reserved list or with a published range that is unset.

## S1 `eturnal-fit` — proven, with two limits

Evidence: `spikes/evidence/s1-*.txt`, `s1-eturnal.log`, `s1b-mapped.txt`, `s1c-send.txt`, `s1c-sessions.txt`.

Proven:

- Username `expiry:c1.<owner>.<room>.<participant>` and `expiry:g1.<owner>.<label>` allocate. Software attribute is `eturnal`. Relay address was the configured `192.0.2.10`, ports inside `61000–61020`.
- A second secret in the same list also allocates (`s1-second-secret.txt`).
- A username already in the past is refused on Allocate (`401`, log line `Credentials expired`).
- Refresh after the timestamp is refused (`401`, log line `Credentials expired`). `strict_expiry: true`.
- CreatePermission and ChannelBind return `403 Forbidden` for `10.200.0.1`, `127.0.0.1`, `169.254.1.1`, `10.1.2.3`, `192.168.0.164`, `100.64.1.1`, `224.0.0.1`. Log: `Rejecting permission creation request: Forbidden`.
- CreatePermission for `1.1.1.1` succeeds.
- REQUESTED-TRANSPORT TCP (6) returns `442 Unsupported Transport Protocol`. eturnal 1.12.3 has no RFC 6062 switch to turn on. TCP relaying stays off because it is absent.
- `eturnalctl sessions` prints the username, client, relay, permissions, and `Sent` / `Received` byte and packet counts. Session end log (on the rejected TCP attempt): `Relayed 0 KiB (in 0 B / 0 packets, out 0 B / 0 packets)` plus the username. That is enough for a later meter to scrape. It is not per-owner quota.

Limits, both observed:

1. **Expiry does not close the allocation.** After the username timestamp, on the same socket, a second Send indication was accepted (`Sent: 0 KiB (2 packets)` in `s1c-sessions.txt`) and Refresh returned 401. The session was still listed. `strict_expiry` stops a new Allocate and a Refresh. It does not stop an allocation that already exists. The allocation created in the log used the default lifetime of 600 seconds. A stolen or expired credential can keep relaying until that lifetime ends.
2. **IPv4-mapped peers are refused with `443 Peer Address Family Mismatch`, not by the blacklist.** This held with `relay_ipv6_addr` unset and with it set to `2001:db8::10`. The allocation eturnal returned was IPv4 (`family` byte `0x01` in XOR-RELAYED-ADDRESS). `::1`, `fe80::1`, `2001:db8::1`, and `::ffff:10.200.0.1` all got 443. The blacklist path for those addresses was not reached. An IPv6 allocation (REQUESTED-ADDRESS-FAMILY) was not requested, so this spike does not prove what an IPv6 allocation would do with a mapped address.

The image wrapper `/usr/local/bin/eturnalctl` runs `stun -4 $STUN_SERVICE` unless `STUN_SERVICE=false`. The lab log contains `Cannot query stun.conversations.im:3478`. Setting `relay_ipv4_addr` in YAML does not stop that probe. The unit must set `STUN_SERVICE=false`.

The same process listens on `127.0.0.1:3470` for the Erlang protocol (`-erl_epmd_port 3470`). That stays on loopback.

## S2 `turn-egress-uid` — proven

Evidence: `spikes/evidence/s2-counters.txt`, `s2-send.txt`, `s2-tcpdump-dummy.txt`, `s2-tcpdump-lo.txt`, `s2-tcpdump-eno1.txt`.

Daemon `blacklist_peers` was a single unused prefix (`198.51.100.9/32`). CreatePermission then succeeded for `10.200.0.1`, `127.0.0.1`, `169.254.1.1`, `10.1.2.3`, `192.168.0.164`, and `1.1.1.1`.

iptables chain `MJOLNIR_TURN_SPIKE`, jumped from `OUTPUT` with comment `mjolnir-turn`, DROP for uid 948 toward `10/8`, `127/8`, `169.254/16`, `172.16/12`, `192.168/16`, `100.64/10`, `224/4`. A RETURN rule for `1.1.1.1` counted passes.

Counters after one send each: `10/8` 2 packets, `127/8` 1, `169.254/16` 1, `192.168/16` 1, `1.1.1.1` 1. `tcpdump` on `dummy-mjolnir` and `lo` captured 0 packets. `tcpdump` on `eno1` captured `192.0.2.10.61013 > 1.1.1.1.9`.

A first attempt that also dropped uid traffic to `127.0.0.0/8` while the client was on `127.0.0.1:3478` timed out: the DROP ate the server's replies, and the `127/8` counter moved. The uid rule is not only a peer filter. It filters every destination of that user, including STUN replies to a client who sits in a dropped range. The successful run put the client at `203.0.113.50` in a netns, outside every drop. See the design for the consequence: match the relay source-port range, not every packet the user sends.

## Advise round, 2026-11-25 — glibc tarball

Evidence: `spikes/evidence/advise-2026-11-25.txt`. Owner decisions that day are on bead `mjolnir-rurh.10`. This round does not amend the contract. The binary is the official glibc build `eturnal-1.12.3-linux-glibc-x64.tar.gz`, SHA-256 `4a16e00592802777163efbfaf3c05efc1ab9e61d85b6f16cac8921e234425c8c`, not the Docker image.

| Spike | Verdict |
|---|---|
| 1 Allocation and lifetime | Proven, and the cap does not hold. 12/12 allocates on one username with the key unset (the 11th succeeded). 24/24 distinct usernames from one source. `max_allocations: 2` still allowed 4 on one username and 4 more usernames. Every lifetime request (omit, 60, 3600, 4294967295) was granted 600. `max_lifetime` is an unknown parameter; reload kept the old config and the listener. `disconnect <username>` removed 12 sessions. `disconnect` with no username is a usage error. |
| 2 Reload and rotation | Proven. New secret allocates after reload. Removed secret: new Allocate is 401. Held allocation stayed up and `sessions` counted 2 sent packets, one of them after the secret was removed. Refresh after removal returned 438 Stale Nonce and was not retried. Malformed YAML on reload keeps 3478 listening. Malformed YAML on start does not listen. |
| 3 Kernel filter, no 3478 exemption | Not run. The nft table was rejected on a syntax error and never installed. No exemption recording run. No systemd restart cycle. Reboot not run. |
| 4 IPv6 refusal | Proven. Allocate with REQUESTED-ADDRESS-FAMILY returned 440 Address Family not Supported. Log: `IPv6 not supported`. No IPv6 socket on the beam. |
| 5 Artefact, STUN, distribution, modules | Proven. Tarball above. Startup tcpdump of udp/3478 excluding the host: 0 packets. No `stun.conversations.im` line. Listens on `0.0.0.0:3478` udp and tcp, and `127.0.0.1:3470` for Erlang distribution. `-start_epmd false`. Host epmd on 4369 is not this process. `modules: {}` added no listener. The binary crashes before bind if it cannot create `$HOME/.erlang.cookie`. |
| 6 Blacklist classes and TCP | Proven. `recommended` plus explicit `1.1.1.1`: CreatePermission 403 for `172.16.9.9`, `240.0.1.1`, `0.1.2.3`, and `1.1.1.1`. `9.9.9.9` allowed. CONNECT returned 405 Method not allowed. TCP 3478 with raw STUN allocated. A RFC 4571 length prefix got EOF. |
| 7 Cap at 25 Mbit/s and unauthenticated flood | Not run. |

Decision 3, against these numbers: keep eturnal only with a reaper, and the reaper is not optional. `max_allocations` did not enforce, 24 usernames from one source all allocated, and the lifetime grant is 600 seconds with no config key to lower it. `eturnalctl sessions` plus `eturnalctl disconnect <username>` is the working control. There is no disconnect-all.

Spike 3 and spike 7 stopped because this run installed ufw (it was absent) and `ufw --force enable` left incoming deny with no allow rule in the status output. The next SSH to port 22 timed out. Ping still answers. At the morphie console: `sudo ufw disable`. The lab beam, the cookie home, and `/tmp/turn-advise-out2` may still be there.
