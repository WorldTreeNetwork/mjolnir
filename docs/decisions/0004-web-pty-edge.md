# ADR 0004 — Foreign web terminals terminate on a trusted edge

**Status:** Accepted (2026-08-18)
**Date:** 2026-08-18
**Change:** [`add-web-pty-edge`](../../openspec/changes/archive/2026-08-18-add-web-pty-edge/proposal.md) (folded 2026-08-18)
**Living spec:** [`openspec/specs/web-pty-edge/spec.md`](../../openspec/specs/web-pty-edge/spec.md)
**Implement:** `mjolnir-cid` landed (xibu `/devterm4`). No API write.
**First consumer:** xibu `/devterm4`

Full argument: [`openspec/changes/archive/2026-08-18-add-web-pty-edge/design.md`](../../openspec/changes/archive/2026-08-18-add-web-pty-edge/design.md).

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

Built: the PTY WebSocket, `mj connect`, `/term/:id` cookie stash,
and the v1 edge (`ttyd4` on xibu wrapping `mj connect` to a
dedicated VM). Design B stays available as a later landing, not
as this one.

Remaining: none on this change. A dedicated WS-to-WS proxy is a
new change if someone picks it.
