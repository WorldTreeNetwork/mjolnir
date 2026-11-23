# H-handoff

Measured on the laptop relay, 2026-11-22, with controller-minted tokens. Publishers send one 19-byte frame every 200ms. The subscriber stays up across the hole and does not resubscribe.

WebTransport, room `standup`, path `alice`. Reader window 14s. First publisher stopped after frame 15 at t=3812ms. The replacement publisher then sent 380 bytes. The reader received none of them. The largest gap between two frames that did arrive was 202ms, which is the send cadence. From t=3812ms to the end of the 14s window the count stayed at 15. No `Restart` line was printed.

Iroh, absolute path `t/<owner>/standup/alice`. Reader window 10s. Fourteen frames arrived. The last was at t=2516ms. The replacement publisher's frames did not arrive. The largest gap between received frames was 202ms. The subscriber was silent for the rest of the window.

The relay does not bridge the two publishers. A subscriber that keeps the first subscription gets nothing from the next one.
