# Ingest keyframe cost

Method. One Chromium publisher (156.0.8078.79) sends a looping fake capture into the patched WHIP ingest, through the in-process relay, and a MoQ subscriber counts video payload bytes. The three runs differ only by `KEYFRAME_POLICY`: off (the pin), trial (floor 1 s, period 2 s, loss and join on), and saturated (`keyframes.saturate`, floor 1 s). The subscriber is not a viewer PLI source.

Fixture. Generated, not a recording: ffmpeg `testsrc2=size=1280x720:rate=30`, drawtext of the frame number, 240 frames, yuv420p, plus an 8 s 440 Hz sine. The browser is capped at 2.5 Mbit/s (`maxBitrate` and `EDGE_INGEST_MBPS=2.5`) with `degradationPreference=maintain-resolution`.

Counting. `harness raw` prints each video frame's payload size and MoQ group index. A keyframe byte is the first frame of a group. Bitrate is video payload bytes over the subscriber's wall span, about 8 s, starting once frames are flowing. Audio is not included. Quality (PSNR or SSIM against the y4m, aligned by the frame counter) was not measured: quality difference missing.

| run | groups | keyframe byte share | bitrate |
| --- | ---: | ---: | ---: |
| off | 1 | 0.0061 | 1536.7 kbps |
| trial (period 2 s) | 4 | 0.0411 | 1578.3 kbps |
| saturated (floor 1 s) | 8 | 0.1098 | 1638.1 kbps |

Against off, trial costs +41.6 kbps and +0.0350 share. Saturated costs +101.4 kbps and +0.1037 share. Saturated is the named floor hook. Its log line still carries the period cause bit; the 1 s cadence, against trial's 2 s cadence and off's silence, is what identifies it.

Reproduce from a checkout that already has the harness binaries built with `CARGO_TARGET_DIR` set, debug info off, and incremental off:

```
LAN=<host-ipv4> BIN=<target>/debug EDGE_INGEST_MBPS=2.5 KEYFRAME_POLICY=off \
  openspec/changes/add-edge-keyframes/harness/adopt-whip.sh F
```

Repeat with `KEYFRAME_POLICY=trial` and `KEYFRAME_POLICY=saturated`. The script prints `share=` and `quality_difference=missing`.
