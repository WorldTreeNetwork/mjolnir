# Tone diagnosis on the current page

No product code was changed. The page files served are the `6f98d267` sources: `src/room.js` `10f99ed76dc8ec5b5c6432b6ab48c3300c87fdd41a6bde9d67102441b0624c92`, `page/boot.js` `c636a6b977804e45bb65f8cc9fb71687236212b35b76032dc571cf30f9149791`. Gateway binaries are the accepted `4bd94d1d` build, unchanged. Chromium 156.0.8078.79. The only hook is labeled in `summary.json` as a measurement recorder of `RTCPeerConnection`. It does not alter `play()` or the media path.

Each sample attaches a new `AudioContext` to the audio track currently on the remote element, after `play()` resolves. The element was unmuted, volume 1, not paused.

Join, on track `27e87b1f-…`, readyState live, muted false, enabled true: 439 Hz, rms 0.0095. Inbound audio grew to 7213 bytes and 88 packets, audioLevel about 0.024.

Replace, after the relay logged `session ended … unroutable role="whep server"`, Bob’s tile moved to owner `1:2` and a new live track `844454e7-…`. A fresh analyser on that track measured 439 Hz, rms 0.0095, 7290 bytes, 90 packets. The earlier 0 Hz replace sample was not missing audio. `videoWidth` 640 and caption "Playing." stay true on the last decoded frame while the old subscription is already silent, so a width check can run before the new track exists.

Renew shows that gap and the recovery. Immediately after Alice’s new publish, Bob still held track `844454e7-…` (live, unmuted, enabled). `play()` resolved. Width stayed 640 and the caption stayed "Playing." Inbound audioLevel was 0, the fresh analyser measured peak 6 Hz and rms 0, and the byte count did not advance between the two analysers. The edge had already ended that WHEP session as unroutable for `0.opus` and `1.vp8`. Within the 12 second bound the page subscribed again: owner `1:3`, new live track `c96dde45-…`, 439 Hz, rms 0.0095, 7209 bytes, 89 packets, audioLevel about 0.014. Alice’s local tracks were a new live pair at incumbent 3. This is not a stuck silent call.

The non-atomic relay handover is the reason the old WHEP ends. The current page then resubscribes. Audio returns on the new stream. A sample that stops at "Playing." plus nonzero width records the gap, not the outcome.

No product patch in this review. The smallest later change, if the gap itself should not look like success, is to leave the caption on "Playing." only while the current owner’s inbound audio packets are still increasing. `.15` stays open.
