# 0df60bee page against accepted gateway 4bd94d1d

Evidence only. The page and `room.js` were not edited for this run. `reviews/2026-11-27-tone-diagnosis/` is the older `6f98d267` page and is not this source.

Served hashes (`page-hashes.txt`): boot.js `07350c8103550b3d10b5428517842b44e34e6f3546518c0cc232cb0d249bbe31`, room.js `532c2de9906d55ea26d6ce5b9564931c98d7a3df1455d72b56e0367c0dcc93cb`. Those match `0df60bee`. Gateway binaries match the accepted edge `57a21527…` and relay `9c24f67c…`.

## Sustained picture and tone

Bob subscribed to Alice. Each phase took two fresh analysers on the current `srcObject` audio track, about 800 ms apart, and read inbound audio RTP between them. A canvas sample of the current frame was taken with the second analyser.

| phase | owner | audio track | peak | rms | audio bytes | frame |
| --- | --- | --- | --- | --- | --- | --- |
| join | 1:1 | faf5a5ce-537b-4668-a8c0-750aabcb3a0e | 439 then 439 | 0.0277 then 0.0156 | 702 → 3968 | 640, left [200,49,120], right [30,160,159] |
| replace | 1:2 | f80232d4-6484-4ca9-b37b-1b3e8748ff16 | 439 then 439 | 0.0095 then 0.0095 | 81 → 3402 | same colors |
| renew | 1:3 | 4a984588-098b-4085-a212-d694d7e77ffe | 439 then 439 | 0.0095 then 0.0095 | 648 → 3888 | same colors |

Caption on those samples was `Playing.` Page errors were empty.

The handover gap is in `summary.json` `gap` and `renewGap`. After replace, the tile dropped its stream at about 8.1 s (`srcObject` false, caption `Waiting — the other side must publish again.`, width 0). The new owner `1:2` reached `Playing.` at 640 px about 1.4 s later, and the sustained samples above are on that new track. Renew repeated the same shape: stream detached at about 8.3 s, new owner `1:3` playing by about 10.7 s, then 439 Hz with rising inbound audio bytes. The gap is the relay ending the previous WHEP subscription. The current page does not keep `Playing.` on the detached view.

## Leave and a held WHIP body

The first driver wrapped `fetch` after the module had already captured it, so that wrapper never saw the 201. That negative is in `summary.json` `lateBody.aliceDuring.held === false`. Leave on that pass still cleared the tiles and the local preview, and they were still clear 600 ms later (`Left the room.`).

`late-body-driver.mjs` installs the hold in the init script, before the page captures `fetch`. The label is `labeled init: hold the next WHIP 201 body until __releaseBody`. After a decoded join, the next WHIP 201 body was held (`held: true`, status `Replacing the connection…`). While it was held, Bob's existing tile stayed `Playing.` at 640 px on owner `1:1` with its stream attached. Leave during that hold cleared Alice's tiles and local preview (`tiles: 0`, no captions) before the body was released. After release, the status stayed `Left the room.` and no tile caption returned. Raw stats are in `late-body.json`.

`.15` stays open. Roster, Safari, three networks, and eight peer connections are still out of this run.
