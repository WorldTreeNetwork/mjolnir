---
spike_id: i6-rekey-clean-exit
run_at: 2026-11-24
verdict: inconclusive
version-pinned: moq@4a6f522483168ace392718d68b58a402533c897d
---

# I6 — teardown diagnosis, idle rerun not established

**The earlier inference that browser.close() did not return was false.** The diagnostic logs CLOSE_BEGIN and CLOSE_RETURNED after both scenarios, followed later by the original 90-second watchdog. That timer was never cleared; it keeps Node alive and calls process.exit(2) even after browser.close returns. The scenario-B Promise.race timeout also remained armed. The driver now clears both, logs close duration, and fails if scenario B does not recover (the old driver only reported recovered:false).

Evidence: [filtered diagnostic](logs/i6-teardown-diagnostic.log), [diagnostic source](i6-diagnostic.mjs), [fixed-driver failed run](logs/i6-fixed-failure.log). Reproduce with the README's prepared page/relay and `node rekey-drive.mjs <private-fixture-dir>`; i6-diagnostic.mjs intentionally retains the old watchdog to demonstrate the cause. The first scratch page bundle was stale; it was rebuilt from committed complete/page.ts and bridge.ts before the fixed/fresh runs. None of the old-bundle observations is counted as a current-bridge pass.

A clean **successful idle-machine** rerun has not been established. Mac load remained above or close to its 10 logical CPUs, with other apps/builds busy; before/after uptime and CPU are in the fixed/fresh logs. The Framework laptop timed out at 192.168.0.108 and 100.121.90.25 (10-second ConnectTimeout), and 10.43.1.243 was unreachable. No other workload was stopped. Idle host availability was requested while diagnosis continued.

The fixed driver closes in 31 ms and exits 1 correctly on scenario-B media recovery failure (it reached 15 video frames late, without meeting the audio criterion). Other diagnostic runs pass both scenarios but show retirement sampling stretches of 23–25 seconds and thousands of backwards NotFound group fetches. CDP samples include gaps/query/time work, so there is retirement/backfill CPU churn, not a proven infinite browser-close spin. This is a C4 lifecycle/retired-subscription bug/compatibility risk, not a reason to weaken authentication or mark tests. Preserve the positive control: removed readers still decode while old publication is deliberately left up. C4 must bound retired reads/backfill and verify audio/catalog convergence and responsive teardown under load. No latency or clean-idle claim follows from these data; I6 stays open.

Fresh-relay rerun also hit the watchdog before completing A; see [fresh log](logs/i6-fresh.log). Before: load 7.26/17.52/33.88, CPU 51% idle; after: load 26.08/19.12/32.73, CPU 57% idle, 90 runnable processes. This was not an idle host. The timeout is preserved, not hidden by retrying to get a green sample. Issue mjolnir-rurh.9.2 tracks the retirement/backfill/media recovery risk.
