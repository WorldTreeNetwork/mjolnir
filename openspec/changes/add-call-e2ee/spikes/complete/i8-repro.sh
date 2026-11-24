#!/usr/bin/env bash
set -euo pipefail
: "${MOQ:?prepared pinned moq workspace}"
HERE=$(cd "$(dirname "$0")" && pwd)
PRIVATE=$(mktemp -d /tmp/mjolnir-i8.XXXXXX)
chmod 700 "$PRIVATE"
ffmpeg -hide_banner -loglevel error -f lavfi -i 'sine=frequency=440:sample_rate=48000:duration=60' -c:a libopus -frame_duration 20 "$PRIVATE/audio.ogg"
cp -f "$HERE/i8-shaper.ts" "$MOQ/js/e2ee/spike/i8-shaper.ts"
(cd "$MOQ/js/e2ee/spike" && bun i8-shaper.ts "$PRIVATE/audio.ogg")
# Private audio stays outside the repository; no captures/keylogs/tokens are produced.
