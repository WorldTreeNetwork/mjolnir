---
spike_id: i6-rekey-clean-exit
run_at: 2026-11-24
verdict: go-with-open-c4-bug
version-pinned: moq@4a6f522483168ace392718d68b58a402533c897d
---

# I6 — teardown diagnosis and successful Morphie rerun

**The earlier inference that browser.close() did not return was false.** The diagnostic logs CLOSE_BEGIN and CLOSE_RETURNED after both scenarios, followed later by the original 90-second watchdog. That timer was never cleared; it keeps Node alive and calls process.exit(2) even after browser.close returns. The scenario-B Promise.race timeout also remained armed. The driver now clears both, logs close duration, and fails if scenario B does not recover (the old driver only reported recovered:false).

Evidence: [filtered diagnostic](logs/i6-teardown-diagnostic.log), [diagnostic source](i6-diagnostic.mjs), [fixed-driver failed run](logs/i6-fixed-failure.log). Reproduce with the README's prepared page/relay and `node rekey-drive.mjs <private-fixture-dir>`; i6-diagnostic.mjs intentionally retains the old watchdog to demonstrate the cause. The first scratch page bundle was stale; it was rebuilt from committed complete/page.ts and bridge.ts before the fixed/fresh runs. None of the old-bundle observations is counted as a current-bridge pass.

The initial Mac attempts did not establish a clean successful idle run; the Morphie follow-up below now does. Mac load remained above or close to its 10 logical CPUs, with other apps/builds busy; before/after uptime and CPU are in the fixed/fresh logs. The Framework laptop timed out at 192.168.0.108 and 100.121.90.25 (10-second ConnectTimeout), and 10.43.1.243 was unreachable. No other workload was stopped. Idle host availability was requested while diagnosis continued.

The fixed driver closes in 31 ms and exits 1 correctly on scenario-B media recovery failure (it reached 15 video frames late, without meeting the audio criterion). Other diagnostic runs pass both scenarios but show retirement sampling stretches of 23–25 seconds and thousands of backwards NotFound group fetches. CDP samples include gaps/query/time work, so there is retirement/backfill CPU churn, not a proven infinite browser-close spin. This is a C4 lifecycle/retired-subscription bug/compatibility risk, not a reason to weaken authentication or mark tests. Preserve the positive control: removed readers still decode while old publication is deliberately left up. C4 must bound retired reads/backfill and verify audio/catalog convergence and responsive teardown under load. No latency or clean-idle claim follows from these data; These Mac attempts alone did not close I6; Morphie supplies the successful idle run below.

Fresh-relay rerun also hit the watchdog before completing A; see [fresh log](logs/i6-fresh.log). Before: load 7.26/17.52/33.88, CPU 51% idle; after: load 26.08/19.12/32.73, CPU 57% idle, 90 runnable processes. This was not an idle host. The timeout is preserved, not hidden by retrying to get a green sample. Issue mjolnir-rurh.9.2 tracks the retirement/backfill/media recovery risk.


## Morphie follow-up — successful idle-host run

Duke suggested Morphie after the Mac limitation. SSH alias resolves to **archbox**, 12 logical CPUs, ~730 GiB free. Copied only the harness sources/local relay crate and the freshly built page bundle to an isolated `/tmp/mjolnir-i6-run`; remote checkout/workloads unchanged. Built the real fixture from the same pinned crate (4 build jobs), waited for compilation to finish, then ran Chromium **159.0.8154.6**, Playwright 1.65.1, Node 25.9.0. No production/deploy. Runtime/logging script: [i6-morphie-run.sh](i6-morphie-run.sh); [complete runtime log](logs/i6-morphie.log), with uptime and vmstat before/after.

**Both scenario assertions pass; driver exit 0; browser.close returns in 36 ms.** The before/after vmstat samples establish idle CPU during the control intervals; the one-minute load retains the prior compilation history. A: announced/discovered 22/37 ms, first new-player frame 3817 ms, media criterion 5143 ms; removed reader receives +158 frames while old publication is deliberately up, then 42 buffered frames and last change at 1958 ms after retire. Remaining playback continues. B: immediate retirement, same session, discovery 24 ms, recovered true, first new-player frame / sampled stall 280/280 ms; 15-frame+audio criterion 482 ms.

A's sampler reports a 9501 ms no-advance gap. This is a sampled observation, not proof of an exact on-screen stall, and still warrants C4/issue mjolnir-rurh.9.2: an idle-host clean exit does not resolve backfill churn, media convergence or a timing bound. The timer fix is now validated with a complete clean run. The reviewer inference that exit 2 established browser.close non-return is superseded: the uncleared watchdog is directly demonstrated and clearing it permits normal exit. Keep the earlier failures as evidence, not discarded runs. Private tokens/certificates/keylogs/media/target stayed off-repo; only the redacted runtime log is committed.
