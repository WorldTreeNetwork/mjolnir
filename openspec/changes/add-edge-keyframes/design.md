# add-edge-keyframes — active design

Pin: moq `4a6f522483168ace392718d68b58a402533c897d`. The previous viewer-path design is not implementable. It is kept at `notes/withdrawn-viewer-path-design.md` and in the reviews. This file is the only design a build follows.

## D1. Ingest policy

`keyframe::Keyframes` on `whip::Request`, default off.

| Cause | When | Default when enabled |
|---|---|---|
| Startup | Line has no keyframe yet (pinned path) | on |
| Step | Deferred timeline step (pinned path) | on |
| Period | Period since the later of last keyframe and last sent PLI | 2 s |
| Loss | str0m marks a non-keyframe frame not contiguous | on |
| Join | `Demand::wanted` becomes a group past the largest written, and `Info::refresh` is `Some(4)` | on |

There is no viewer cause. A WHEP PLI or FIR does not call this gate. `on_loss: false` adds no loss-cause request; startup can still request.

One gate per video line. Floor default 1 s. `whip::accept` returns `Error::InvalidKeyframes` for an enabled zero floor or zero period. A PLI counts as sent only when the writer existed and accepted it. At most one held request. A keyframe cancels it. No receive stream, or `NoWriter` / `NoReceiverSource` / `NotReceivingDirection`: hold, do not move `last_sent`, disarm a past deadline, do not end the session, do not spin. Re-arm on a receive-stream transition or a strictly future deadline.

Pending state is one bit, a cause mask, and one deadline. Memory does not grow with callers.

The period is a request cadence. It is not a 2 s GOP and not a viewer-recovery deadline. On lite-06 a later join at the relay, while the upstream subscription stays open, does not reach this gate. The relay's first or reopened upstream subscription can. Task B records those two traces separately, with the negotiated wire version.

## D2. What the patch does not add

No `Response::keyframes`, no `Requester`, no `whep::Request::source`, no `whep::Request::keyframes`, no pairing table, no in-process WHEP origin. Egress keeps the pin: a viewer PLI is logged and dropped (`session.rs:337-341`). WHEP media stays on a relay session admitted with the viewer's token. Connection reuse is `add-webrtc-edge`, not this patch.

## D3. Negative control

Bob plays Alice through the relay. Bob's PLIs do not add a WHIP request. The before and after media route is that same relayed WHEP. The measurement probe must not itself cause a join PLI: it opens the video track only after a group exists, and a rendition change is checked the same way. Subscribing at announcement time is not that proof.

## D4. Carry

Vendor only `moq-webrtc` at the pin under `native/vendor/moq-webrtc/`, consumer-local `[patch]`, relay manifest and lock byte-identical. Licences unchanged: upstream MIT notice "Copyright (c) 2023 Luke Curley" and Apache text, modification notices on changed files, outbound `MIT OR Apache-2.0`. Push and PR stay with Duke or a named submitter.

## D5. Upstream port and drop

One local patch series against a named `main` commit: ingest cadence, loss, and eligible join demand. No WHEP refresh and no requester in this series. Drop the vendor when the pin contains that ingest behaviour and the same ingest tests pass. Viewer-driven refresh stays a separate follow-up, not a condition of this drop.

## D6. Measurements

Same relayed route before and after. Rows:

| Id | Observation | Gate |
|---|---|---|
| A | WHEP first presented frame, H.264 and VP8, 10 joins | median ≤ 2.0 s, max ≤ 2.5 s, from the period, not from a viewer PLI |
| B | MoQ late join, 10 joins, plus the two relay-hop traces | first decodable ≤ 1.0 s; lag ≤ 2.2 s |
| C | Exporter late join | record only; failure files a bead under `.13` |
| D1 | Viewer-side 1.5 s blackout, same route | record time; 1.2 s is not a pass gate; no viewer-cause PLI required |
| D2 | Publisher-side 1.5 s blackout | loss-cause PLI; first post-burst keyframe ≤ 1.2 s |
| E | Viewer storm (1 then 4) | negative control: zero viewer-cause sends |
| F | Saturated 1 s requests from a test hook on eligible ingest causes, named as a harness, plus policy-off and period-2 s | keyframe byte share, bitrate delta, quality delta or "missing" |

Adoption of the trial defaults waits on A, B, D2, E, and F. D1 is recorded and does not block adoption.

## D7. Hypotheses still unrun

H1 join signal, H2 gate log shape, H4 vendored resolution on macOS and Linux. K0 then K1a/K1b before the patch. Arch spike success is not an Ubuntu or vendored build.
