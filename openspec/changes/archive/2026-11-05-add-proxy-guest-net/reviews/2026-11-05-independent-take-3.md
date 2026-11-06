1. Pin class selection to a reproducible proxy base-image identity; false Iroh alone must never classify an ordinary guest.
2. Pin the api-proxy unit as the egress boundary, with positive loopback and host-API connects plus negative non-allowlisted connects.
3. Refuse route absence as proof of unit confinement: the same guest's root must reach the denied IPv4 targets while the unit cannot.
4. Pin both the proxy network script and data-dir repair to the image; a running unit and a reachable host /32 are separate assertions.
5. Keep ordinary network setup and its existing 1.1.1.1 probe unchanged, including ordinary guests with Iroh disabled.
6. Make proxy health inspect route and resolver drift before connectivity; Health.do_heal skips repair whenever the probe returns ok.
7. Refuse successful health without a measured TCP connect, and require the proxy script to repair each isolated drift condition.
8. Preserve base_image and explicit false across build_running_record, resume_opts, and reboot; reject true before a proxy guest runs.
9. Require acceptance to fail on absent inspection, bad guest exit, failed cgroup placement, and failed reboot, with invocation-owned cleanup.
10. Accept the narrow reboot and IPv4-kernel scope as a tradeoff only when exclusions are explicit and future class-aware probe tests remain owed.
