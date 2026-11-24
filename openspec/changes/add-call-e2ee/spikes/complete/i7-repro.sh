#!/usr/bin/env bash
set -euo pipefail
: "${MOQ:?pinned moq checkout}" "${CARGO_TARGET_DIR:?existing build cache}"
test "$(git -C "$MOQ" rev-parse HEAD)" = 4a6f522483168ace392718d68b58a402533c897d
df -h /
cargo test --offline --locked --manifest-path "$MOQ/Cargo.toml" -p moq-e2ee
