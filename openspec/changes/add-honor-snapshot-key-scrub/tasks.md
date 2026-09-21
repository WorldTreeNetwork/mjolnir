# Tasks

- [x] Scrub grok config dir and shell history (and any other
      guest path that can hold `XAI_API_KEY`) before
      `mj snapshot create` of a hosted being
- [x] Confirm a `hosted-<xid>` / `hosted-devpreview-test` snapshot
      tree does not contain `XAI_API_KEY` (unit: KeyScrub over a
      fixture tree; live tree is EYES after deploy)
- [x] Key still injects to `/run/mjolnir/` tmpfs after boot from
      that snapshot (inject path unchanged; scrub is rootfs-only)
