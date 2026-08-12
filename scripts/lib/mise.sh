#!/usr/bin/env bash
# Shared mise installation for base-image builders. Source, do not execute.
#
#   source "$SCRIPT_DIR/lib/mise.sh"
#   install_mise "$R"
#   mise_use "$R" node@20 bun@latest
#   mise_link "$R" node "$(mise_find_tool "$R" node node)"
#
# WHY MISE IS IN EVERY IMAGE
#
# mise is the one thing a base image needs in order to grow any other toolchain
# on demand. Bake mise in and an image never has to be rebuilt to gain rust, node,
# python or go — a job installs what it needs. That is why this is a shared helper
# rather than a per-image concern.
#
# THE PATH TRAP THIS EXISTS TO AVOID
#
# Commands reach a VM through the guest agent as a BARE, NON-LOGIN shell. Nothing
# sources /etc/profile, nothing runs `mise activate`, and $HOME may not be /root.
# So the usual mise setup — PATH in profile.d plus `eval "$(mise activate bash)"`
# in .bashrc — leaves mise invisible to every command Mjolnir actually runs.
# build-rootfs-ubuntu-24.04.sh had exactly that shape: mise installed, mise
# unreachable from `mj exec`.
#
# Two rules follow, and both are load-bearing:
#
#   1. Everything must be reachable at a PLAIN path in /usr/local/bin, which is on
#      the default PATH of even a bare sh.
#   2. Link the REAL install path, never mise's shims. Shims resolve through mise
#      at exec time and point at an absolute path that dangles when tested from
#      the host (observed: node -> /mise), so a `-x` test from the builder is
#      false and the link is silently wrong.

# install_mise <rootfs_root>
#
# Installs mise into the image and makes it reachable from a non-login shell.
install_mise() {
    local R="$1"

    echo ""
    echo "--- Installing mise ---"

    # Explicit HOME and MISE_INSTALL_PATH: the installer otherwise picks a location
    # from the ambient environment, which inside a chroot is the HOST's.
    chroot "$R" /bin/bash -c \
        "HOME=/root curl -fsSL https://mise.run | HOME=/root MISE_INSTALL_PATH=/root/.local/bin/mise sh"

    if [[ ! -x "$R/root/.local/bin/mise" ]]; then
        echo "ERROR: mise installer did not produce /root/.local/bin/mise" >&2
        exit 1
    fi

    mise_link "$R" mise /root/.local/bin/mise

    # Convenience for humans on a serial console or SSH session. NOT the mechanism
    # anything depends on — that is the /usr/local/bin wrapper above.
    mkdir -p "$R/etc/profile.d"
    cat > "$R/etc/profile.d/mise.sh" << 'PROFEOF'
export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$PATH"
PROFEOF

    if ! grep -q 'mise activate bash' "$R/root/.bashrc" 2>/dev/null; then
        cat >> "$R/root/.bashrc" << 'BASHEOF'

# mise — version manager for dev toolchains
eval "$(/root/.local/bin/mise activate bash)"
BASHEOF
    fi

    verify_mise "$R"
}

# mise_use <rootfs_root> <tool@version>...
#
# Installs tools and pins them globally, then reshims.
#
# Mounts /proc for the duration, because tool installers need it and fail in ways
# that do not name it:
#
#   - rust's rustup-init exits 1 with no useful message, surfacing only as
#     "mise ERROR ~/.cache/mise/rust/rustup-init failed".
#   - `mise reshim` resolves mise's own location via /proc/self/exe, and without
#     /proc it emits shims pointing at a bare `/mise` that exists nowhere. Silent
#     at build time; shows up much later as "command not found" in a live VM.
#
# We link real install paths rather than shims anyway (see mise_link), so the
# second is belt-and-braces — but a correct reshim costs nothing.
mise_use() {
    local R="$1"; shift
    local tools=("$@")
    local mounted_proc=0 rc=0

    if ! mountpoint -q "$R/proc" 2>/dev/null; then
        mount -t proc proc "$R/proc"
        mounted_proc=1
    fi

    echo "--- Installing via mise: ${tools[*]} ---"
    # No `set -e` abort here: /proc must be unmounted before we surface a failure,
    # or the caller's subvolume cannot be deleted on the next run.
    chroot "$R" /bin/bash -c "HOME=/root /root/.local/bin/mise install ${tools[*]}" \
        && chroot "$R" /bin/bash -c "HOME=/root /root/.local/bin/mise use -g ${tools[*]}" \
        && chroot "$R" /bin/bash -c "HOME=/root /root/.local/bin/mise reshim" \
        || rc=$?

    if [[ "$mounted_proc" == "1" ]]; then
        umount -lf "$R/proc" || true
    fi

    if [[ "$rc" != "0" ]]; then
        echo "ERROR: mise failed to install: ${tools[*]}" >&2
        exit 1
    fi
}

# mise_find_tool <rootfs_root> <tool> <binary>
#
# Prints the guest-absolute path of a binary inside a mise install, or nothing.
# Versions must be DISCOVERED, not constructed: mise resolves node@20 to e.g.
# 20.20.2 and rust@latest to a concrete version this script cannot predict.
#
# Two layouts have to be handled, because mise backends differ:
#
#   node/bun — installs/<tool>/<version>/ is a real directory tree. Search it.
#   rust     — mise's rust backend is a thin wrapper over rustup, so
#              installs/rust/1.97.1 is a SYMLINK to /root/.cargo/bin. That target
#              is guest-absolute, so it dangles when resolved from the host and
#              `find` walks straight past it, finding nothing at all.
mise_find_tool() {
    local R="$1" tool="$2" bin="$3"
    local base="$R/root/.local/share/mise/installs/$tool"
    local link target path

    # Layout 2 first: a version entry that is a symlink to a guest-absolute path.
    for link in "$base"/latest "$base"/*; do
        [[ -L "$link" ]] || continue
        target="$(readlink "$link")"
        case "$target" in
            /*)
                if [[ -e "$R$target/$bin" ]]; then
                    printf '%s' "$target/$bin"
                    return 0
                fi
                ;;
        esac
    done

    # Layout 1: an ordinary install tree.
    path=$(find "$base" -maxdepth 4 \
        \( -type f -o -type l \) -name "$bin" 2>/dev/null | head -1)
    [[ -n "$path" ]] && printf '%s' "${path#"$R"}"
}

# mise_link <rootfs_root> <name> <guest_absolute_target>
#
# Places an exec wrapper at /usr/local/bin/<name>.
mise_link() {
    local R="$1" bin="$2" src="$3"

    # Fail loudly rather than warn: a missing toolchain binary makes the image
    # useless for its one purpose, and a `Warning:` is easy to scroll past in
    # 1300 lines of debootstrap output.
    if [[ -z "$src" || ! -e "$R$src" ]]; then
        echo "ERROR: $bin not found (looked for '${src:-<nothing found>}')" >&2
        exit 1
    fi

    # A WRAPPER, not a symlink. npm and npx are shell scripts that derive their
    # install prefix from $0 (`dirname $(dirname $0)`), so a symlink at
    # /usr/local/bin/npm makes npm compute a prefix of /usr/local and die with
    #   Cannot find module '/usr/local/lib/node_modules/npm/bin/npm-cli.js'
    # exec'ing the real path keeps $0 inside the mise install, so the prefix math
    # lands where the files actually are. node and rustc are real binaries and
    # would survive a symlink, but wrapping uniformly means nobody has to remember
    # which tools do prefix arithmetic.
    # rm first: a leftover ABSOLUTE symlink from an earlier run dangles when seen
    # from the host (it resolves against the host's /), and `>` onto a dangling
    # symlink fails.
    rm -f "$R/usr/local/bin/$bin"
    mkdir -p "$R/usr/local/bin"
    cat > "$R/usr/local/bin/$bin" << EOF
#!/bin/sh
exec "$src" "\$@"
EOF
    chmod 755 "$R/usr/local/bin/$bin"
    echo "  $bin -> $src"
}

# verify_mise <rootfs_root>
#
# Post-condition check: mise must answer from a shell with a DEFAULT PATH and an
# empty environment — the same conditions the guest agent execs commands under.
# Checking `-x /usr/local/bin/mise` would pass on a wrapper pointing at nothing.
verify_mise() {
    local R="$1"

    if ! chroot "$R" /usr/bin/env -i \
        PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
        /bin/sh -c 'mise --version' >/dev/null 2>&1
    then
        echo "VERIFY FAIL: mise is not runnable from a bare non-login shell." >&2
        echo "  That is how the guest agent runs every command, so an image in" >&2
        echo "  this state has mise installed and unreachable." >&2
        exit 1
    fi

    echo "mise verified: runnable from a bare non-login shell"
}
