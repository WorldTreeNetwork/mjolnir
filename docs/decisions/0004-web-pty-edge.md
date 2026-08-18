# ADR 0004 — Foreign web terminals terminate on a trusted edge

**Status:** Proposed — awaiting advise
**Date:** 2026-08-18
**Change:** [`add-web-pty-edge`](../../openspec/changes/add-web-pty-edge/proposal.md)
**Living spec:** none yet (capability `web-pty-edge` materializes at fold)
**Implement:** brief `nod-devterm4-stand` (`mjolnir-cid`). No API write.
**First consumer:** xibu `/devterm4`

Full argument: [`openspec/changes/add-web-pty-edge/design.md`](../../openspec/changes/add-web-pty-edge/design.md).

## One screen

1. **S2S is the existing PTY WebSocket.**
   `wss://<api>/api/vms/:id/pty` + `Authorization: Bearer`.
   Binary = raw PTY bytes. Text = resize JSON. Optional `?session=`.
2. **The browser never holds the Mjolnir JWT** on a foreign origin.
   The trusted box holds `mj`'s token.
3. **Design A:** local web PTY (ttyd family) runs `mj connect`.
   Same auth story as `/devterm`–`/devterm3`. Double PTY is accepted.
4. **No tokenless public PTY.** Loopback bypass and `/term/:id` +
   `mj_term` stay; they are not the dashboard path.
5. **Design B (WS-to-WS proxy) and Design C (hosted `/term/:id` as
   the xibu surface) are rejected** for this landing.

## Built vs remaining

Built: the PTY WebSocket, `mj connect`, `/term/:id` cookie stash.

Remaining: advise, then the xibu brief (unit + nginx + `mj login`).
Do not add a proxy binary. Do not change `PtyHandler`.
