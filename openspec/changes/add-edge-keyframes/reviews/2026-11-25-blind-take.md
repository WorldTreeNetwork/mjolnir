# Independent take before the proposed design and tasks

1. The pinned ingest already requests PLI for the first decodable video and a deferred timestamp step.
2. Include those requests in the same per-source, per-line monotonic budget as periodic, loss and reader feedback.
3. The producer must have a negotiated, available video stream. An idle timer must not terminate a session before RTP starts.
4. A receiver's feedback MID belongs to its own session. Map the selected track back to its originating ingest line.
5. Bind feedback to the authorized broadcast and session generation, with bounded, coalesced pending work.
6. A sustained one-request-per-second ceiling still gives an authorized viewer influence over encoder quality and rate.
7. A lite-06 hop suppresses remote refresh. A timer can bound request cadence but cannot compel a timely decoder output.
8. Measure the old build first, distinguish requests from encoded frames, and measure bytes under matched rate settings.
9. Cargo root patch selection and a standalone vendored manifest are independent requirements; check resolved package IDs.
10. Preserve upstream notices, distinguish the carried diff from the main-API port, and leave submission to the owner.
