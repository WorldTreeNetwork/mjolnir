#!/bin/bash
set -euo pipefail

# Mjolnir CLI installer
# Usage: curl -fsSL https://get.mjolnir.dev | sh
#
# Environment variables:
#   MJOLNIR_VERSION   - version to install (default: latest)
#   MJOLNIR_INSTALL   - install directory (default: /usr/local/bin or ~/.local/bin)
#   MJOLNIR_NO_SYMLINK - set to 1 to skip creating the 'mj' symlink

REPO="worldtreetech/mjolnir"
BINARY_NAME="mjolnir"
SYMLINK_NAME="mj"

main() {
    need_cmd uname
    need_cmd curl
    need_cmd tar

    local version="${MJOLNIR_VERSION:-latest}"
    local os arch target

    os="$(detect_os)"
    arch="$(detect_arch)"
    target="$(build_target "$os" "$arch")"

    info "Detected platform: ${os}/${arch}"
    info "Target: ${target}"

    if [ "$version" = "latest" ]; then
        version="$(fetch_latest_version)"
    fi
    info "Version: ${version}"

    local install_dir
    install_dir="$(resolve_install_dir)"
    info "Install directory: ${install_dir}"

    local tmp
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT

    local archive="mjolnir-${target}.tar.gz"
    local url="https://github.com/${REPO}/releases/download/${version}/${archive}"

    info "Downloading ${url}..."
    if ! curl -fSL --progress-bar -o "${tmp}/${archive}" "$url"; then
        err "Download failed. Check that version '${version}' exists and has a release for '${target}'."
    fi

    info "Extracting..."
    tar -xzf "${tmp}/${archive}" -C "$tmp"

    if [ ! -f "${tmp}/${BINARY_NAME}" ]; then
        err "Archive did not contain '${BINARY_NAME}' binary"
    fi

    install_binary "$tmp" "$install_dir"
    create_symlink "$install_dir"
    verify_install "$install_dir"

    echo ""
    success "Mjolnir CLI installed successfully!"
    echo "  Binary: ${install_dir}/${BINARY_NAME}"
    if [ "${MJOLNIR_NO_SYMLINK:-0}" != "1" ]; then
        echo "  Alias:  ${install_dir}/${SYMLINK_NAME} -> ${BINARY_NAME}"
    fi
    echo ""
    echo "  Run 'mjolnir --help' or 'mj --help' to get started."
}

detect_os() {
    local os
    os="$(uname -s)"
    case "$os" in
        Linux)  echo "linux" ;;
        Darwin) echo "darwin" ;;
        *)      err "Unsupported OS: ${os}" ;;
    esac
}

detect_arch() {
    local arch
    arch="$(uname -m)"
    case "$arch" in
        x86_64|amd64)  echo "x86_64" ;;
        arm64|aarch64) echo "aarch64" ;;
        *)             err "Unsupported architecture: ${arch}" ;;
    esac
}

build_target() {
    local os="$1" arch="$2"
    case "$os" in
        linux)  echo "${arch}-unknown-linux-musl" ;;
        darwin) echo "${arch}-apple-darwin" ;;
    esac
}

fetch_latest_version() {
    local url="https://api.github.com/repos/${REPO}/releases/latest"
    local version
    version="$(curl -fsSL "$url" | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"//;s/".*//')"

    if [ -z "$version" ]; then
        err "Failed to fetch latest version from GitHub. Set MJOLNIR_VERSION explicitly."
    fi
    echo "$version"
}

resolve_install_dir() {
    if [ -n "${MJOLNIR_INSTALL:-}" ]; then
        echo "$MJOLNIR_INSTALL"
        return
    fi

    if [ -w /usr/local/bin ]; then
        echo "/usr/local/bin"
    else
        local local_bin="${HOME}/.local/bin"
        mkdir -p "$local_bin"
        echo "$local_bin"
        if ! echo "$PATH" | tr ':' '\n' | grep -qx "$local_bin"; then
            warn "${local_bin} is not in your PATH. Add it with:"
            warn "  export PATH=\"${local_bin}:\$PATH\""
        fi
    fi
}

install_binary() {
    local src_dir="$1" dest_dir="$2"
    local dest="${dest_dir}/${BINARY_NAME}"

    if [ -f "$dest" ]; then
        local old_version new_version
        old_version="$("$dest" --version 2>/dev/null || echo "unknown")"
        info "Replacing existing install (${old_version})"
    fi

    chmod +x "${src_dir}/${BINARY_NAME}"

    if [ -w "$dest_dir" ]; then
        mv "${src_dir}/${BINARY_NAME}" "$dest"
    else
        info "Elevated permissions required to install to ${dest_dir}"
        sudo mv "${src_dir}/${BINARY_NAME}" "$dest"
    fi
}

create_symlink() {
    local dir="$1"
    if [ "${MJOLNIR_NO_SYMLINK:-0}" = "1" ]; then
        return
    fi

    local link="${dir}/${SYMLINK_NAME}"
    if [ -L "$link" ] || [ -e "$link" ]; then
        rm -f "$link" 2>/dev/null || sudo rm -f "$link"
    fi

    if [ -w "$dir" ]; then
        ln -s "$BINARY_NAME" "$link"
    else
        sudo ln -s "$BINARY_NAME" "$link"
    fi
}

verify_install() {
    local dir="$1"
    local bin="${dir}/${BINARY_NAME}"
    if ! "$bin" --version >/dev/null 2>&1; then
        warn "Binary installed but 'mjolnir --version' failed. The binary may not be compatible with this platform."
    fi
}

need_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        err "Required command not found: $1"
    fi
}

info()    { echo "  → $*"; }
warn()    { echo "  ⚠ $*" >&2; }
success() { echo "  ✓ $*"; }
err()     { echo "  ✗ ERROR: $*" >&2; exit 1; }

main "$@"
