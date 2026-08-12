#!/usr/bin/env bash
# Shared guest-agent installation for base-image builders. Source, do not execute.
#
#   source "$SCRIPT_DIR/lib/guest-agent.sh"
#   install_guest_agent "$R"
#
# WHY THIS EXISTS
#
# A base image needs BOTH of these to be usable:
#
#   1. /usr/local/bin/mjolnir-agent
#   2. /etc/systemd/system/mjolnir-agent.service + a basic.target.wants symlink
#
# Miss either and the VM boots fine, nobody answers the vsock ping, spawn dies on
# :boot_timeout after 30s, and the API returns a bare {"error":"spawn_failed"} —
# no message anywhere naming the real cause.
#
# It is tempting to skip the binary because Mjolnir.VM.inject_guest_agent/1 copies
# one into each clone at boot. Do not: that copy happens only when :guest_agent_bin
# is configured AND the file exists, and on the prod host that path is absent, so
# injection is a silent no-op. The image must stand on its own.
#
# Four scripts each grew their own copy of this, two of them incomplete, and
# @base/ci-ubuntu-24.04 booted only because the missing pieces were added by hand
# months after it was built — making it unreproducible. That is mjolnir-0e8, and a
# shared helper with a post-condition check is the fix.

# Resolve the agent binary. Honours AGENT_BIN if already set; otherwise searches a
# freshly-built binary first, then falls back to the copy inside an existing base
# image so a host with no Rust tree can still build — noisily, since that copy is
# only as new as the image it came from.
mjolnir_resolve_agent_bin() {
    local repo_root="$1"

    if [[ -n "${AGENT_BIN:-}" ]]; then
        return 0
    fi

    local cand
    for cand in \
        "$repo_root/native/target/x86_64-unknown-linux-musl/release/mjolnir-agent" \
        "$repo_root/native/mjolnir_guest_agent/target/x86_64-unknown-linux-musl/release/mjolnir-agent" \
        "/var/lib/mjolnir/btrfs/@base/ubuntu-24.04/usr/local/bin/mjolnir-agent" \
        "/var/lib/mjolnir/btrfs/@base/ci-ubuntu-24.04/usr/local/bin/mjolnir-agent"
    do
        if [[ -f "$cand" ]]; then
            AGENT_BIN="$cand"
            return 0
        fi
    done

    return 1
}

# install_guest_agent <rootfs_root>
#
# Installs the binary, the unit, and the basic.target.wants symlink into the given
# rootfs, then verifies all three landed. Exits non-zero rather than producing an
# image that cannot boot — set ALLOW_NO_AGENT=1 to deliberately build one without.
install_guest_agent() {
    local R="$1"
    local script_lib_dir repo_root
    script_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    repo_root="$(cd "$script_lib_dir/../.." && pwd)"

    echo ""
    echo "--- Installing mjolnir guest agent ---"

    if ! mjolnir_resolve_agent_bin "$repo_root" || [[ ! -f "${AGENT_BIN:-}" ]]; then
        if [[ "${ALLOW_NO_AGENT:-0}" == "1" ]]; then
            echo "ALLOW_NO_AGENT=1: building an image with NO guest agent."
            echo "  Every spawn from it will fail with :boot_timeout. You asked for this."
            return 0
        fi
        echo "Error: no mjolnir-agent binary found." >&2
        echo "  Build one (just deploy, or scripts/build-guest-agent.sh) or pass" >&2
        echo "  AGENT_BIN=/path/to/mjolnir-agent." >&2
        echo "  Without it the image boots but never answers a vsock ping, and every" >&2
        echo "  spawn fails with :boot_timeout -> {\"error\":\"spawn_failed\"}." >&2
        exit 1
    fi

    case "$AGENT_BIN" in
        /var/lib/mjolnir/btrfs/@base/*)
            echo "Warning: no freshly-built agent found; copying from $AGENT_BIN."
            echo "         That binary is only as new as the base image it came from."
            ;;
    esac

    echo "Agent binary: $AGENT_BIN"
    install -D -m 0755 "$AGENT_BIN" "$R/usr/local/bin/mjolnir-agent"

    mkdir -p "$R/etc/mjolnir"
    chmod 700 "$R/etc/mjolnir"

    # WantedBy=basic.target, not multi-user.target: the agent has to be answering
    # before the VM counts as started, well below where ordinary services come up.
    mkdir -p "$R/etc/systemd/system"
    cat > "$R/etc/systemd/system/mjolnir-agent.service" << 'UNITEOF'
[Unit]
Description=Mjolnir Guest Agent
After=sysinit.target
Wants=sysinit.target

[Service]
Type=simple
ExecStart=/usr/local/bin/mjolnir-agent
Restart=on-failure
RestartSec=2
StartLimitBurst=3
StartLimitIntervalSec=30

[Install]
WantedBy=basic.target
UNITEOF

    # A plain symlink rather than `systemctl enable`: this runs against a chroot
    # that may have no usable systemctl, and enable would fail or no-op silently.
    mkdir -p "$R/etc/systemd/system/basic.target.wants"
    ln -sf /etc/systemd/system/mjolnir-agent.service \
        "$R/etc/systemd/system/basic.target.wants/mjolnir-agent.service"

    verify_guest_agent "$R"
}

# verify_guest_agent <rootfs_root>
#
# Post-condition check. The whole point of mjolnir-0e8 is that a builder can appear
# to succeed and still emit an unbootable image, so assert rather than assume.
verify_guest_agent() {
    local R="$1"
    local ok=1

    if [[ ! -x "$R/usr/local/bin/mjolnir-agent" ]]; then
        echo "VERIFY FAIL: $R/usr/local/bin/mjolnir-agent missing or not executable" >&2
        ok=0
    fi
    if [[ ! -f "$R/etc/systemd/system/mjolnir-agent.service" ]]; then
        echo "VERIFY FAIL: mjolnir-agent.service not installed" >&2
        ok=0
    fi
    # -L not -f: inside the chroot the target is /etc/..., which does not resolve
    # from the host, so the symlink is correctly dangling when viewed from here.
    if [[ ! -L "$R/etc/systemd/system/basic.target.wants/mjolnir-agent.service" ]]; then
        echo "VERIFY FAIL: basic.target.wants/mjolnir-agent.service symlink missing" >&2
        ok=0
    fi

    if [[ "$ok" != "1" ]]; then
        echo "Refusing to emit an image that cannot boot (mjolnir-0e8)." >&2
        exit 1
    fi

    echo "Guest agent verified: binary + unit + basic.target.wants symlink"
}
