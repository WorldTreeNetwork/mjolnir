#!/usr/bin/env bash
# Shared Ghostty terminfo install for base-image builders. Source, do not execute.
#
#   source "$SCRIPT_DIR/lib/terminfo.sh"
#   install_ghostty_terminfo "$R"
#
# WHY THIS EXISTS
#
# Ghostty sets TERM=xterm-ghostty. ncurses/tmux then look up that name in the
# guest's terminfo database. Ubuntu 24.04 and Arch's ncurses packages do not
# ship it yet (it landed in ncurses 6.5-20241228). Without the entry, `tmux`,
# `clear`, `less`, and friends die with "unknown terminal type" inside a VM
# that was spawned from Ghostty (`mj connect`, SSH, serial).
#
# Ghostty's own recipe is `infocmp -x xterm-ghostty | tic -x -`. We vendor
# the source (scripts/lib/xterm-ghostty.terminfo) so the build host does not
# need Ghostty installed, and compile into /etc/terminfo — the same override
# path used on the Mjolnir host. Do not write /usr/share/terminfo: that tree
# belongs to the distro ncurses package.
#
# tic runs on the BUILD HOST against the rootfs directory (not inside the
# chroot), so the image does not need ncurses-bin just to receive the entry.

# install_ghostty_terminfo <rootfs_root>
#   Compiles xterm-ghostty into $1/etc/terminfo/{x,78}/xterm-ghostty.
install_ghostty_terminfo() {
    local rootfs="${1:?install_ghostty_terminfo: rootfs path required}"
    local here src dest
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    src="$here/xterm-ghostty.terminfo"
    dest="$rootfs/etc/terminfo"

    if [[ ! -f "$src" ]]; then
        echo "Error: missing Ghostty terminfo source: $src" >&2
        exit 1
    fi
    if ! command -v tic >/dev/null; then
        echo "Error: tic not found (install ncurses-bin / ncurses). Need it to compile Ghostty terminfo." >&2
        exit 1
    fi

    mkdir -p "$dest"
    # -x: write extended capabilities (Tc, RGB, etc.) that infocmp -x emitted.
    tic -x -o "$dest" "$src"

    if [[ ! -f "$dest/x/xterm-ghostty" && ! -f "$dest/78/xterm-ghostty" ]]; then
        echo "Error: tic did not produce xterm-ghostty under $dest" >&2
        ls -la "$dest" >&2 || true
        exit 1
    fi
    echo "Installed xterm-ghostty terminfo into $dest"
}
